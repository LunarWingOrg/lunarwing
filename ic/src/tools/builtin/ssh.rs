//! Built-in SSH tool (delivery Option 2) — runs a command on a configured
//! remote host, in-process, via the russh client.
//!
//! The `host` parameter must be an alias configured in `[[ssh.hosts]]`; user,
//! port, key type, timeouts, and host-key policy come from that configuration.
//! The configured host map is therefore the egress allowlist — the agent cannot
//! target arbitrary hosts. Keys are loaded from the encrypted secrets store and
//! never appear as tool parameters.
//!
//! Runs in the main agent process (`ToolDomain::Orchestrator`) and always
//! requires approval. See `docs/proposals/SSH_HARNESS_OPTION_2_3_IMPLEMENTATION.md`.

use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use tokio::sync::RwLock;

use crate::bridge::ssh::{SSHBridge, SSHKeyType, SshBridgeError};
use crate::bridge::ssh_client;
use crate::context::JobContext;
use crate::tools::tool::{
    ApprovalRequirement, Tool, ToolDomain, ToolError, ToolOutput, ToolRateLimitConfig, require_str,
};

/// Runs a command on a configured remote SSH host.
pub struct SshTool {
    ssh_bridge: Arc<RwLock<SSHBridge>>,
}

impl SshTool {
    pub fn new(ssh_bridge: Arc<RwLock<SSHBridge>>) -> Self {
        Self { ssh_bridge }
    }
}

#[async_trait]
impl Tool for SshTool {
    fn name(&self) -> &str {
        "ssh"
    }

    fn description(&self) -> &str {
        "Run a command on a configured remote SSH host and return its stdout, stderr, and exit code. \
         The `host` must be one of the aliases configured in [[ssh.hosts]]; the user, port, and key are \
         taken from that configuration (you cannot target arbitrary hosts). Ed25519 and ECDSA keys are \
         supported; RSA is not."
    }

    fn parameters_schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "properties": {
                "host": {
                    "type": "string",
                    "description": "Configured SSH host alias (must exist in [[ssh.hosts]])"
                },
                "command": {
                    "type": "string",
                    "description": "Command to execute on the remote host"
                }
            },
            "required": ["host", "command"]
        })
    }

    async fn execute(
        &self,
        params: serde_json::Value,
        _ctx: &JobContext,
    ) -> Result<ToolOutput, ToolError> {
        let start = std::time::Instant::now();
        let host = require_str(&params, "host")?;
        let command = require_str(&params, "command")?;

        // Resolve host config + credentials + verifier while briefly holding the
        // read guard, then drop it before the (potentially long) SSH session.
        let (host_cfg, creds, verifier) = {
            let bridge = self.ssh_bridge.read().await;
            let host_cfg = bridge
                .get_host_config(host)
                .await
                .map_err(|e| ToolError::NotAuthorized(format!("unknown SSH host '{host}': {e}")))?;
            let creds = bridge
                .load_key(host)
                .await
                .map_err(|e| ToolError::ExecutionFailed(e.to_string()))?
                .ok_or_else(|| {
                    ToolError::NotAuthorized(format!("no SSH key stored for host '{host}'"))
                })?;
            let verifier = bridge.host_key_verifier();
            (host_cfg, creds, verifier)
        };

        // Ed25519/ECDSA only. The current RSA path would use legacy ssh-rsa
        // (SHA-1), which modern OpenSSH servers reject. Fail fast with a clear
        // message.
        if host_cfg.key_type == SSHKeyType::Rsa {
            return Err(ToolError::ExecutionFailed(
                "RSA keys are not supported by the built-in ssh tool (use Ed25519 or ECDSA)"
                    .to_string(),
            ));
        }

        let result = ssh_client::connect_and_exec(&host_cfg, &creds, verifier, command)
            .await
            .map_err(map_ssh_error)?;

        let stdout = String::from_utf8_lossy(&result.stdout).to_string();
        let stderr = String::from_utf8_lossy(&result.stderr).to_string();
        Ok(ToolOutput::success(
            serde_json::json!({
                "host": host,
                "output": stdout,
                "stderr": stderr,
                "exit_code": result.exit_code,
                "success": result.exit_code == 0,
                "truncated": result.truncated,
            }),
            start.elapsed(),
        ))
    }

    fn requires_approval(&self, _params: &serde_json::Value) -> ApprovalRequirement {
        // Remote command execution — always require explicit approval.
        ApprovalRequirement::Always
    }

    fn requires_sanitization(&self) -> bool {
        // Remote output is untrusted (potential prompt injection).
        true
    }

    fn domain(&self) -> ToolDomain {
        // Runs in the main agent process, not a container.
        ToolDomain::Orchestrator
    }

    fn execution_timeout(&self) -> Duration {
        Duration::from_secs(180)
    }

    fn rate_limit_config(&self) -> Option<ToolRateLimitConfig> {
        Some(ToolRateLimitConfig::new(30, 300))
    }
}

/// Map an [`SshBridgeError`] to the appropriate [`ToolError`].
fn map_ssh_error(err: SshBridgeError) -> ToolError {
    match err {
        SshBridgeError::ConnectionTimeout(secs) => ToolError::Timeout(Duration::from_secs(secs)),
        SshBridgeError::AuthenticationFailed { .. }
        | SshBridgeError::HostKeyMismatch { .. }
        | SshBridgeError::UnknownHostKey { .. }
        | SshBridgeError::PermissionDenied(_) => ToolError::NotAuthorized(err.to_string()),
        other => ToolError::ExecutionFailed(other.to_string()),
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;

    use super::*;
    use crate::bridge::ssh::{HostKeyMode, NullAuditLogger, SSHHostConfig};
    use crate::bridge::ssh_secrets::SshSecretsManager;
    use crate::secrets::{InMemorySecretsStore, SecretsCrypto, SecretsStore};

    fn test_store() -> Arc<dyn SecretsStore + Send + Sync> {
        Arc::new(InMemorySecretsStore::new(Arc::new(
            SecretsCrypto::new(secrecy::SecretString::from(
                "test-master-key-that-is-at-least-32-bytes-long!",
            ))
            .unwrap(),
        )))
    }

    fn host_cfg(name: &str, key_type: SSHKeyType) -> SSHHostConfig {
        SSHHostConfig {
            host: name.to_string(),
            port: 22,
            user: "user".to_string(),
            key_type,
            host_key_mode: HostKeyMode::Strict,
            known_host_key: None,
            connect_timeout_secs: 5,
            operation_timeout_secs: 5,
            keepalive_interval_secs: 60,
            keepalive_max_misses: 3,
        }
    }

    async fn bridge_with(
        store: Arc<dyn SecretsStore + Send + Sync>,
        hosts: Vec<SSHHostConfig>,
    ) -> Arc<RwLock<SSHBridge>> {
        let mut map = HashMap::new();
        for h in hosts {
            map.insert(h.host.clone(), h);
        }
        let bridge = SSHBridge::new(
            uuid::Uuid::new_v4(),
            "test-tenant".to_string(),
            map,
            store,
            Arc::new(NullAuditLogger),
        )
        .await
        .unwrap();
        Arc::new(RwLock::new(bridge))
    }

    #[tokio::test]
    async fn test_metadata_and_approval() {
        let tool = SshTool::new(bridge_with(test_store(), vec![]).await);
        assert_eq!(tool.name(), "ssh");
        assert!(matches!(
            tool.requires_approval(&serde_json::json!({})),
            ApprovalRequirement::Always
        ));
        assert!(matches!(tool.domain(), ToolDomain::Orchestrator));
        assert!(tool.requires_sanitization());
    }

    #[tokio::test]
    async fn test_unknown_host_rejected() {
        let bridge = bridge_with(test_store(), vec![host_cfg("known", SSHKeyType::Ed25519)]).await;
        let tool = SshTool::new(bridge);
        let ctx = JobContext::new("test", "ssh test");
        let err = tool
            .execute(
                serde_json::json!({"host": "missing", "command": "echo hi"}),
                &ctx,
            )
            .await
            .unwrap_err();
        assert!(matches!(err, ToolError::NotAuthorized(_)), "got {err:?}");
    }

    #[tokio::test]
    async fn test_missing_key_rejected() {
        let bridge = bridge_with(test_store(), vec![host_cfg("h1", SSHKeyType::Ed25519)]).await;
        let tool = SshTool::new(bridge);
        let ctx = JobContext::new("test", "ssh test");
        let err = tool
            .execute(
                serde_json::json!({"host": "h1", "command": "echo hi"}),
                &ctx,
            )
            .await
            .unwrap_err();
        match err {
            ToolError::NotAuthorized(m) => assert!(m.contains("no SSH key"), "msg: {m}"),
            other => panic!("expected NotAuthorized, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn test_rsa_key_rejected() {
        let store = test_store();
        // Store a dummy key so load_key returns Some; the RSA guard fires before parse.
        SshSecretsManager::new(Arc::clone(&store), "test-tenant")
            .store_key("rsa1", b"dummy-key-material", None)
            .await
            .unwrap();
        let bridge = bridge_with(Arc::clone(&store), vec![host_cfg("rsa1", SSHKeyType::Rsa)]).await;
        let tool = SshTool::new(bridge);
        let ctx = JobContext::new("test", "ssh test");
        let err = tool
            .execute(
                serde_json::json!({"host": "rsa1", "command": "echo hi"}),
                &ctx,
            )
            .await
            .unwrap_err();
        match err {
            ToolError::ExecutionFailed(m) => assert!(m.contains("RSA"), "msg: {m}"),
            other => panic!("expected ExecutionFailed(RSA), got {other:?}"),
        }
    }

    #[test]
    fn test_map_ssh_error() {
        assert!(matches!(
            map_ssh_error(SshBridgeError::ConnectionTimeout(5)),
            ToolError::Timeout(_)
        ));
        assert!(matches!(
            map_ssh_error(SshBridgeError::AuthenticationFailed {
                user: "u".into(),
                host: "h".into()
            }),
            ToolError::NotAuthorized(_)
        ));
        assert!(matches!(
            map_ssh_error(SshBridgeError::UnknownHostKey {
                fingerprint: "fp".into()
            }),
            ToolError::NotAuthorized(_)
        ));
        assert!(matches!(
            map_ssh_error(SshBridgeError::ConnectionRefused("x".into())),
            ToolError::ExecutionFailed(_)
        ));
    }
}
