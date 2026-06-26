//! SSH Agent Server — Handles ssh-agent protocol for worker authentication.
//!
//! This module implements the ssh-agent protocol over Unix sockets, allowing
//! worker containers to authenticate to remote SSH servers without accessing
//! private keys directly.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;

use async_trait::async_trait;
use futures::Future;
use russh_keys::agent::server::{Agent, MessageType};
use russh_keys::key::{self, KeyPair};
use secrecy::ExposeSecret;
use tokio::net::UnixListener;
use tokio::sync::Mutex;
use tokio_stream::wrappers::UnixListenerStream;
use tracing::{info, warn, error};

use crate::bridge::ssh::{SSHCredentials, SshBridgeError, Result};

/// SSH Agent implementation that holds keys in memory.
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
        let key_pair = Self::parse_key(&creds)?;
        
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

    fn parse_key(creds: &SSHCredentials) -> Result<KeyPair> {
        let key_str = String::from_utf8_lossy(&creds.key_data).to_string();
        
        let passphrase = creds.passphrase.as_ref().map(|s| s.expose_secret());
        
        russh_keys::format::decode_secret_key(&key_str, passphrase.as_deref())
            .map_err(|e| SshBridgeError::InvalidKeyFormat(format!("Key parse error: {}", e)))
    }
}

#[async_trait]
impl Agent for SshAgent {
    fn confirm(
        self,
        _pk: Arc<KeyPair>,
    ) -> Box<dyn Future<Output = (Self, bool)> + Unpin + Send> {
        Box::new(futures::future::ready((self, true)))
    }

    async fn confirm_request(&self, _msg: MessageType) -> bool {
        true
    }
}

/// SSH Agent Server wrapper.
pub struct SshAgentServer {
    socket_path: PathBuf,
    keys: Arc<Mutex<HashMap<String, Arc<KeyPair>>>>,
    _join_handle: tokio::task::JoinHandle<()>,
}

impl Drop for SshAgentServer {
    fn drop(&mut self) {
        self._join_handle.abort();
        
        {
            let mut keys = self.keys.blocking_lock();
            keys.clear();
        }
        
        let _ = std::fs::remove_file(&self.socket_path);
        
        info!("SSH agent server stopped: {}", self.socket_path.display());
    }
}

impl SshAgentServer {
    pub async fn start(
        socket_path: PathBuf,
        keys: HashMap<String, SSHCredentials>,
    ) -> Result<Arc<Self>> {
        if socket_path.exists() {
            warn!("SSH agent socket exists, removing: {}", socket_path.display());
            let _ = std::fs::remove_file(&socket_path);
        }

        let listener = UnixListener::bind(&socket_path)
            .map_err(|e| {
                warn!("Failed to bind SSH agent socket: {}", e);
                SshBridgeError::AgentSocketUnavailable
            })?;

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let perms = std::fs::Permissions::from_mode(0o600);
            let _ = std::fs::set_permissions(&socket_path, perms);
        }

        info!("SSH agent server listening: {}", socket_path.display());

        let keys_map: Arc<Mutex<HashMap<String, Arc<KeyPair>>>> = Arc::new(Mutex::new(HashMap::new()));
        
        for (hostname, creds) in keys {
            match Self::parse_key(&creds) {
                Ok(key_pair) => {
                    let mut guard = keys_map.lock().await;
                    guard.insert(hostname, Arc::new(key_pair));
                }
                Err(e) => {
                    warn!("Failed to parse key for {}: {}", hostname, e);
                }
            }
        }

        let keys_clone = Arc::clone(&keys_map);
        let socket_path_clone = socket_path.clone();

        let server = Arc::new(Self {
            socket_path,
            keys: keys_clone,
            _join_handle: tokio::spawn(async move {
                Self::run_listener(listener, keys_clone, socket_path_clone).await;
            }),
        });

        Ok(server)
    }

    async fn run_listener(
        listener: UnixListener,
        keys: Arc<Mutex<HashMap<String, Arc<KeyPair>>>>,
        socket_path: PathBuf,
    ) {
        let stream = UnixListenerStream::new(listener);
        
        let agent = SshAgent {
            keys: Arc::clone(&keys),
        };
        
        if let Err(e) = russh_keys::agent::server::serve(stream, agent).await {
            error!("SSH agent server error on {}: {}", socket_path.display(), e);
        }
    }

    pub fn socket_path(&self) -> &PathBuf {
        &self.socket_path
    }

    pub async fn add_key(&self, hostname: String, creds: SSHCredentials) -> Result<()> {
        let key_pair = Self::parse_key(&creds)?;
        
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
    let passphrase = creds.passphrase.as_ref().map(|s| s.expose_secret());
    
    russh_keys::format::decode_secret_key(&key_str, passphrase.as_deref())
        .map_err(|e| SshBridgeError::InvalidKeyFormat(format!("Key parse error: {}", e)))
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
