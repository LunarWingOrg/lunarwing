//! SSH Agent Server — Handles ssh-agent protocol for worker authentication.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;

use async_trait::async_trait;
use futures::Future;
use russh_keys::agent::server::{Agent, MessageType};
use russh_keys::key::KeyPair;
use secrecy::ExposeSecret;
use tokio::net::UnixListener;
use tokio::sync::Mutex;
use tokio_stream::wrappers::UnixListenerStream;
use tracing::{info, warn, error};

use crate::bridge::ssh::{SSHCredentials, SshBridgeError, Result};

#[derive(Clone)]
pub struct SshAgent {
    keys: Arc<Mutex<HashMap<String, Arc<KeyPair>>>>,
}

impl SshAgent {
    pub fn new() -> Self {
        Self {
            keys: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    pub async fn add_key(&self, hostname: String, creds: SSHCredentials) -> Result<()> {
        let key_pair = parse_key(&creds)?;
        let mut keys = self.keys.lock().await;
        keys.insert(hostname.clone(), Arc::new(key_pair));
        info!("Added key to SSH agent for host {}", hostname);
        Ok(())
    }

    pub async fn remove_key(&self, hostname: &str) -> Result<bool> {
        let mut keys = self.keys.lock().await;
        let removed = keys.remove(hostname).is_some();
        if removed {
            info!("Removed key from SSH agent for host {}", hostname);
        }
        Ok(removed)
    }

    pub async fn list_keys(&self) -> Vec<String> {
        let keys = self.keys.lock().await;
        keys.keys().cloned().collect()
    }
}

fn parse_key(creds: &SSHCredentials) -> Result<KeyPair> {
    let key_str = String::from_utf8_lossy(&creds.key_data).to_string();
    let passphrase = creds.passphrase.as_ref().map(|s| s.expose_secret().as_ref());
    
    // Use the internal format decoder - it's public in the crate root
    russh_keys::decode_secret_key(&key_str, passphrase)
        .map_err(|e| SshBridgeError::InvalidKeyFormat(format!("Key parse error: {}", e)))
}

#[async_trait]
impl Agent for SshAgent {
    fn confirm(self, _pk: Arc<KeyPair>) -> Box<dyn Future<Output = (Self, bool)> + Unpin + Send> {
        Box::new(futures::future::ready((self, true)))
    }
    async fn confirm_request(&self, _msg: MessageType) -> bool { true }
}

pub struct SshAgentServer {
    socket_path: PathBuf,
    keys: Arc<Mutex<HashMap<String, Arc<KeyPair>>>>,
    _join_handle: tokio::task::JoinHandle<()>,
}

impl Drop for SshAgentServer {
    fn drop(&mut self) {
        self._join_handle.abort();
        // Best-effort key clearing: try_lock avoids panicking when Drop runs
        // inside a tokio runtime (blocking_lock would). If the lock is
        // contended, the keys will be zeroized when the last Arc clone drops.
        if let Ok(mut keys) = self.keys.try_lock() {
            keys.clear();
        }
        let _ = std::fs::remove_file(&self.socket_path);
        info!("SSH agent server stopped: {}", self.socket_path.display());
    }
}

impl SshAgentServer {
    pub async fn start(socket_path: PathBuf, keys: HashMap<String, SSHCredentials>) -> Result<Arc<Self>> {
        if socket_path.exists() {
            warn!("SSH agent socket exists, removing: {}", socket_path.display());
            let _ = std::fs::remove_file(&socket_path);
        }

        let listener = UnixListener::bind(&socket_path).map_err(|e| {
            warn!("Failed to bind SSH agent socket: {}", e);
            SshBridgeError::AgentSocketUnavailable
        })?;

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            // 0o666: the socket is in the tenant's run dir (not /tmp), and
            // rootless podman maps the host UID to root inside the container.
            // Worker processes run as a different user (e.g. "nanocode") and
            // need read+write access to the socket. The run dir itself is
            // tenant-owned, so this doesn't expose the socket to other tenants.
            let perms = std::fs::Permissions::from_mode(0o666);
            let _ = std::fs::set_permissions(&socket_path, perms);
        }

        info!("SSH agent server listening: {}", socket_path.display());

        let keys_map: Arc<Mutex<HashMap<String, Arc<KeyPair>>>> = Arc::new(Mutex::new(HashMap::new()));
        for (hostname, creds) in keys {
            match parse_key(&creds) {
                Ok(key_pair) => {
                    let mut guard = keys_map.lock().await;
                    guard.insert(hostname, Arc::new(key_pair));
                }
                Err(e) => warn!("Failed to parse key for {}: {}", hostname, e),
            }
        }

        let keys_clone = Arc::clone(&keys_map);
        let socket_path_for_log = socket_path.clone();

        Ok(Arc::new(Self {
            socket_path,
            keys: keys_clone.clone(),
            _join_handle: tokio::spawn(async move {
                let stream = UnixListenerStream::new(listener);
                let agent = SshAgent { keys: keys_clone };
                if let Err(e) = russh_keys::agent::server::serve(stream, agent).await {
                    error!("SSH agent server error on {}: {}", socket_path_for_log.display(), e);
                }
            }),
        }))
    }

    pub fn socket_path(&self) -> &PathBuf { &self.socket_path }

    pub async fn add_key(&self, hostname: String, creds: SSHCredentials) -> Result<()> {
        let key_pair = parse_key(&creds)?;
        let mut keys = self.keys.lock().await;
        keys.insert(hostname.clone(), Arc::new(key_pair));
        info!("Added key to SSH agent for host {}", hostname);
        Ok(())
    }

    pub async fn remove_key(&self, hostname: &str) -> Result<bool> {
        let mut keys = self.keys.lock().await;
        let removed = keys.remove(hostname).is_some();
        if removed { info!("Removed key from SSH agent for host {}", hostname); }
        Ok(removed)
    }

    pub async fn list_keys(&self) -> Vec<String> {
        let keys = self.keys.lock().await;
        keys.keys().cloned().collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[tokio::test]
    async fn test_agent_server_start_stop() {
        let temp_dir = TempDir::new().unwrap();
        let socket_path = temp_dir.path().join("test.sock");
        let keys: HashMap<String, SSHCredentials> = HashMap::new();
        let server = SshAgentServer::start(socket_path.clone(), keys).await;
        assert!(server.is_ok());
        drop(server);
    }
}
