//! In-process SSH client (Option 2) — runs a command on a remote host using the
//! russh client.
//!
//! This is the first live consumer of the `russh` client half (the harness
//! otherwise only uses russh's agent server, `ssh_agent.rs`). It is also
//! the first live wiring of [`HostKeyVerifier`](crate::bridge::ssh_hostkeys::HostKeyVerifier):
//! host-key verification runs inside russh's [`Handler::check_server_key`] during
//! key exchange, *before* authentication.
//!
//! Credentials are decoded from the encrypted secrets store (via
//! [`crate::bridge::ssh_agent::parse_key`]); keys never leave the daemon process.

use std::sync::Arc;
use std::time::Duration;

use russh::client::{self, Handle, Handler};
use russh::keys::key::PrivateKeyWithHashAlg;
use russh::keys::{PublicKey, PublicKeyBase64};
use russh::{ChannelMsg, Disconnect};

use crate::bridge::ssh::{SSHCredentials, SSHHostConfig, SshBridgeError};
use crate::bridge::ssh_agent::parse_key;
use crate::bridge::ssh_hostkeys::HostKeyVerifier;

/// Maximum bytes captured per stream (stdout / stderr). Output beyond this is
/// dropped and the result is flagged `truncated` to avoid unbounded buffering.
const MAX_OUTPUT_BYTES: usize = 1024 * 1024;

/// Result of a remote command execution.
#[derive(Debug)]
pub struct CommandResult {
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
    pub exit_code: i32,
    /// True if stdout or stderr hit [`MAX_OUTPUT_BYTES`] and was truncated.
    pub truncated: bool,
}

/// russh client handler. The only behavior we customize is host-key
/// verification, which delegates to the harness `HostKeyVerifier`.
struct ClientHandler {
    verifier: Arc<HostKeyVerifier>,
    host: SSHHostConfig,
    /// Set when `check_server_key` rejects a key, so `connect_and_exec` can
    /// surface the precise reason instead of a generic connection error.
    reject_reason: Arc<std::sync::Mutex<Option<SshBridgeError>>>,
}

impl Handler for ClientHandler {
    type Error = russh::Error;

    fn check_server_key(
        &mut self,
        server_public_key: &PublicKey,
    ) -> impl std::future::Future<Output = Result<bool, Self::Error>> + Send {
        // `public_key_bytes()` yields the raw SSH wire blob — the same
        // representation `HostKeyVerifier` compares against (it byte-compares,
        // not fingerprint strings, so no base64-padding mismatch).
        let key_bytes = server_public_key.public_key_bytes();
        let verifier = Arc::clone(&self.verifier);
        let host = self.host.clone();
        let reject_reason = Arc::clone(&self.reject_reason);

        async move {
            match verifier.verify_from_config(&host, &key_bytes).await {
                Ok(_) => Ok(true),
                Err(e) => {
                    if let Ok(mut slot) = reject_reason.lock() {
                        *slot = Some(e);
                    }
                    // Returning Ok(false) aborts the handshake; the precise
                    // reason was stashed above for connect_and_exec to report.
                    Ok(false)
                }
            }
        }
    }
}

/// Connect to `host`, verify the server key, authenticate with `creds`, run
/// `command`, and return its output. Bounded by the host's connect/operation
/// timeouts.
pub async fn connect_and_exec(
    host: &SSHHostConfig,
    creds: &SSHCredentials,
    verifier: Arc<HostKeyVerifier>,
    command: &str,
) -> Result<CommandResult, SshBridgeError> {
    let reject_reason = Arc::new(std::sync::Mutex::new(None));
    let handler = ClientHandler {
        verifier,
        host: host.clone(),
        reject_reason: Arc::clone(&reject_reason),
    };

    let config = Arc::new(client::Config::default());
    let connect_secs = host.connect_timeout_secs.max(1);

    let connect_res = tokio::time::timeout(
        Duration::from_secs(connect_secs),
        client::connect(config, (host.host.as_str(), host.port), handler),
    )
    .await;

    let mut session = match connect_res {
        Err(_) => return Err(SshBridgeError::ConnectionTimeout(connect_secs)),
        Ok(Err(e)) => {
            // Prefer a precise host-key rejection reason if the handler recorded one.
            if let Some(reason) = reject_reason.lock().ok().and_then(|mut s| s.take()) {
                return Err(reason);
            }
            return Err(SshBridgeError::ConnectionRefused(e.to_string()));
        }
        Ok(Ok(session)) => session,
    };

    // Authenticate with the decoded private key (Ed25519/ECDSA).
    let key = parse_key(creds)?;
    let authenticated = session
        .authenticate_publickey(
            host.user.as_str(),
            PrivateKeyWithHashAlg::new(Arc::new(key), None),
        )
        .await
        .map_err(|e| SshBridgeError::Internal(format!("SSH authentication error: {e}")))?;
    if !authenticated.success() {
        return Err(SshBridgeError::AuthenticationFailed {
            user: host.user.clone(),
            host: host.host.clone(),
        });
    }

    // Run the command, bounded by the operation timeout.
    let op_secs = host.operation_timeout_secs.max(1);
    let result = match tokio::time::timeout(
        Duration::from_secs(op_secs),
        run_command(&mut session, command),
    )
    .await
    {
        Err(_) => {
            let _ = session.disconnect(Disconnect::ByApplication, "", "").await;
            return Err(SshBridgeError::ConnectionTimeout(op_secs));
        }
        Ok(r) => r?,
    };

    let _ = session.disconnect(Disconnect::ByApplication, "", "").await;
    Ok(result)
}

async fn run_command(
    session: &mut Handle<ClientHandler>,
    command: &str,
) -> Result<CommandResult, SshBridgeError> {
    let mut channel = session
        .channel_open_session()
        .await
        .map_err(|e| SshBridgeError::Internal(format!("failed to open SSH channel: {e}")))?;
    channel
        .exec(true, command.as_bytes())
        .await
        .map_err(|e| SshBridgeError::Internal(format!("failed to exec remote command: {e}")))?;

    let mut stdout = Vec::new();
    let mut stderr = Vec::new();
    let mut exit_code: Option<i32> = None;
    let mut truncated = false;

    loop {
        match channel.wait().await {
            Some(ChannelMsg::Data { data }) => append_capped(&mut stdout, &data, &mut truncated),
            // ext == 1 is SSH_EXTENDED_DATA_STDERR.
            Some(ChannelMsg::ExtendedData { data, ext: 1 }) => {
                append_capped(&mut stderr, &data, &mut truncated)
            }
            Some(ChannelMsg::ExitStatus { exit_status }) => exit_code = Some(exit_status as i32),
            Some(ChannelMsg::Eof) => {}
            Some(ChannelMsg::Close) | None => break,
            Some(_) => {}
        }
    }

    Ok(CommandResult {
        stdout,
        stderr,
        exit_code: exit_code.unwrap_or(-1),
        truncated,
    })
}

/// Append `data` to `buf`, capping total length at [`MAX_OUTPUT_BYTES`] and
/// setting `truncated` if the cap is hit.
fn append_capped(buf: &mut Vec<u8>, data: &[u8], truncated: &mut bool) {
    if buf.len() >= MAX_OUTPUT_BYTES {
        *truncated = true;
        return;
    }
    let remaining = MAX_OUTPUT_BYTES - buf.len();
    if data.len() > remaining {
        buf.extend_from_slice(&data[..remaining]);
        *truncated = true;
    } else {
        buf.extend_from_slice(data);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_append_capped_under_limit() {
        let mut buf = Vec::new();
        let mut truncated = false;
        append_capped(&mut buf, b"hello", &mut truncated);
        assert_eq!(buf, b"hello");
        assert!(!truncated);
    }

    #[test]
    fn test_append_capped_crosses_limit() {
        let mut buf = vec![0u8; MAX_OUTPUT_BYTES - 3];
        let mut truncated = false;
        append_capped(&mut buf, b"abcdef", &mut truncated);
        assert_eq!(buf.len(), MAX_OUTPUT_BYTES);
        assert!(truncated);
    }

    #[test]
    fn test_append_capped_already_full() {
        let mut buf = vec![0u8; MAX_OUTPUT_BYTES];
        let mut truncated = false;
        append_capped(&mut buf, b"x", &mut truncated);
        assert_eq!(buf.len(), MAX_OUTPUT_BYTES);
        assert!(truncated);
    }
}
