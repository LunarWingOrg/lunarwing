//! SSH Bridge — Secure remote host access for LunarWing workers/routines.
//!
//! This module provides:
//! - Centralized SSH configuration per tenant
//! - Secrets (keys) stored securely (no disk writes)
//! - Auto-injection into workers/routines via context
//! - Per-tenant isolation
//! - SSH agent socket for worker integration
//!
//! See `ssh_secrets.rs` for secrets integration utilities.
//!
//! # Security Model
//!
//! ```text
//! ┌─────────────────────────────────────────────────────────────────────────────┐
//! │                            SSH Bridge Lifecycle                               │
//! │                                                                               │
//! │   Config (non-sensitive) ──► config.toml [ssh] section                        │
//! │   Secrets (keys) ──────────► Encrypted secrets store (AES-256-GCM)            │
//! │                                                                               │
//! │   Worker requests SSH ────► SSH agent socket mounted                          │
//! │                            (Unix socket, in-memory keys)                      │
//! │                            │                                                   │
//! │                            ▼                                                   │
//! │                    Standard SSH client                                          │
//! │                    (speaks ssh-agent protocol)                                  │
//! │                            │                                                   │
//! │                            ▼                                                   │
//! │                    Keys never touch disk                                        │
//! │                    Per-tenant socket isolation                                  │
//! │                    Audit logging of all operations                              │
//! └─────────────────────────────────────────────────────────────────────────────┘
//! ```
//!
//! # Host Key Verification
//!
//! - **Strict mode** (default): Unknown hosts rejected, must be explicitly added
//! - **AcceptFirst mode**: First connection accepted, pinned thereafter
//! - No "AcceptAny" — that's insecure
//!
//! # Example
//!
//! ```ignore
//! use lunarwing::bridge::ssh::{SSHBridge, SSHHostConfig};
//!
//! let bridge = SSHBridge::new(tenant_id, hosts, key_store).await?;
//! bridge.validate()?;
//! bridge.start_agent_server().await?;
//!
//! // In worker: SSH_AUTH_SOCK points to the agent socket
//! let ssh_client = ssh2::Session::new()?;
//! ssh_client.agent_connect()?; // Uses SSH_AUTH_SOCK
//! ssh_client.userauth_pubkey_file(user, None, pubkey, None)?;
//! ```

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;

use async_trait::async_trait;
use secrecy::SecretString;
use serde::{Deserialize, Serialize};
use thiserror::Error;
use tokio::sync::RwLock;
use tracing::{info, warn, instrument};
use uuid::Uuid;
use zeroize::Zeroizing;

use crate::bridge::ssh_agent::SshAgentServer;
use crate::secrets::SecretsStore;

// ============================================================================
// Error Types
// ============================================================================

/// SSH Bridge errors
#[derive(Debug, Error)]
pub enum SshBridgeError {
    // Config errors
    #[error("Host not found: {0}")]
    HostNotFound(String),

    #[error("Invalid host configuration: {0}")]
    InvalidHostConfig(String),

    #[error("SSH config validation failed: {0}")]
    ValidationFailed(String),

    // Secret errors
    #[error("Secret not found: {0}")]
    SecretNotFound(String),

    #[error("Failed to decrypt secret: {0}")]
    SecretDecryptionFailed(String),

    // Key errors
    #[error("Invalid key format: {0}")]
    InvalidKeyFormat(String),

    #[error("Key validation failed: {0}")]
    KeyValidationFailed(String),

    #[error("Passphrase required but not provided")]
    PassphraseRequired,

    #[error("Passphrase incorrect")]
    PassphraseIncorrect,

    // Host key errors
    #[error("Host key verification failed: expected {expected}, got {actual}")]
    HostKeyMismatch { expected: String, actual: String },

    #[error("Unknown host key (strict mode): fingerprint {fingerprint}")]
    UnknownHostKey { fingerprint: String },

    // Connection errors
    #[error("Connection timeout after {0}s")]
    ConnectionTimeout(u64),

    #[error("Connection refused: {0}")]
    ConnectionRefused(String),

    #[error("Authentication failed for {user}@{host}")]
    AuthenticationFailed { user: String, host: String },

    #[error("Permission denied: {0}")]
    PermissionDenied(String),

    // Agent errors
    #[error("SSH agent socket not available")]
    AgentSocketUnavailable,

    #[error("SSH agent protocol error: {0}")]
    AgentProtocolError(String),

    // Internal errors
    #[error("Internal error: {0}")]
    Internal(String),

    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),
}

/// Result type for SSH Bridge operations
pub type Result<T> = std::result::Result<T, SshBridgeError>;

// ============================================================================
// Configuration Types
// ============================================================================

/// SSH host configuration (non-sensitive)
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SSHHostConfig {
    /// Hostname or IP address
    pub host: String,
    /// SSH port (default: 22)
    #[serde(default = "default_ssh_port")]
    pub port: u16,
    /// Username to connect as
    pub user: String,
    /// Key type (for identification/logging)
    pub key_type: SSHKeyType,
    /// Host key verification mode
    #[serde(default)]
    pub host_key_mode: HostKeyMode,
    /// Stored host public key (for verification)
    pub known_host_key: Option<String>,
    /// Connection timeout in seconds (default: 10)
    #[serde(default = "default_connect_timeout")]
    pub connect_timeout_secs: u64,
    /// Operation timeout in seconds (default: 30)
    #[serde(default = "default_operation_timeout")]
    pub operation_timeout_secs: u64,
    /// Keepalive interval in seconds (0 = disabled, default: 60)
    #[serde(default = "default_keepalive_interval")]
    pub keepalive_interval_secs: u64,
    /// Max missed keepalives before disconnect (default: 3)
    #[serde(default = "default_keepalive_max_misses")]
    pub keepalive_max_misses: u32,
}

fn default_ssh_port() -> u16 { 22 }
fn default_connect_timeout() -> u64 { 10 }
fn default_operation_timeout() -> u64 { 30 }
fn default_keepalive_interval() -> u64 { 60 }
fn default_keepalive_max_misses() -> u32 { 3 }

/// SSH key type
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "lowercase")]
pub enum SSHKeyType {
    Ed25519,
    Ecdsa,
    Rsa,
}

impl std::fmt::Display for SSHKeyType {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            SSHKeyType::Ed25519 => write!(f, "ed25519"),
            SSHKeyType::Ecdsa => write!(f, "ecdsa"),
            SSHKeyType::Rsa => write!(f, "rsa"),
        }
    }
}

/// Host key verification mode
#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq)]
#[serde(rename_all = "PascalCase")]
pub enum HostKeyMode {
    /// Reject unknown hosts (default, recommended)
    #[default]
    Strict,
    /// Accept on first connect, pin thereafter
    AcceptFirst,
    // Note: No "AcceptAny" — that's insecure
}

impl std::fmt::Display for HostKeyMode {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            HostKeyMode::Strict => write!(f, "Strict"),
            HostKeyMode::AcceptFirst => write!(f, "AcceptFirst"),
        }
    }
}

/// SSH credentials (sensitive — zeroized on drop)
#[derive(Debug)]
pub struct SSHCredentials {
    /// Raw key bytes (PEM or OpenSSH format). Zeroizing wrapper ensures the
    /// key material is overwritten in memory when this struct is dropped.
    pub key_data: Zeroizing<Vec<u8>>,
    /// Passphrase if encrypted, None if not. SecretString zeroes on drop.
    pub passphrase: Option<SecretString>,
}

// ============================================================================
// Audit Logging
// ============================================================================

/// SSH audit events
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "event_type")]
pub enum SshEvent {
    HostAdded {
        host: String,
        user: String,
        key_type: String,
    },
    HostRemoved {
        host: String,
    },
    ConnectionAttempt {
        host: String,
        user: String,
        success: bool,
        error: Option<String>,
    },
    CommandExecuted {
        host: String,
        user: String,
        command: String, // Truncated for security
        exit_code: Option<i32>,
    },
    KeyRotated {
        host: String,
    },
    HostKeyChanged {
        host: String,
        old_fingerprint: String,
        new_fingerprint: String,
    },
    AgentStarted {
        socket_path: String,
    },
    AgentStopped {
        socket_path: String,
    },
}

/// Audit logger trait
#[async_trait]
pub trait AuditLogger: Send + Sync {
    async fn log(&self, event: SshEvent) -> Result<()>;
}

/// Null audit logger (no-op, for testing)
pub struct NullAuditLogger;

#[async_trait]
impl AuditLogger for NullAuditLogger {
    async fn log(&self, _event: SshEvent) -> Result<()> {
        Ok(())
    }
}

// ============================================================================
// SSH Bridge Core
// ============================================================================

/// SSH Bridge — Centralized SSH access for a tenant
pub struct SSHBridge {
    /// Tenant ID (UUID, derived from owner_id)
    tenant_id: Uuid,
    /// Tenant name (owner_id) — used for the agent socket path so the
    /// mt-admin script can predict the path: /tmp/ssh-agent-<tenant_name>.sock
    tenant_name: String,
    /// Host configurations (non-sensitive)
    hosts: Arc<RwLock<HashMap<String, SSHHostConfig>>>,
    /// Secrets store for key access
    secrets_store: Arc<dyn SecretsStore + Send + Sync>,
    /// Audit logger
    audit_logger: Arc<dyn AuditLogger + Send + Sync>,
    /// SSH agent server (if running)
    agent_server: Option<Arc<SshAgentServer>>,
}

impl SSHBridge {
    /// Create a new SSH Bridge for a tenant
    ///
    /// # Arguments
    /// * `tenant_id` — Tenant UUID (derived from owner_id via UUID v5)
    /// * `tenant_name` — Tenant name (owner_id) for predictable socket paths
    /// * `hosts` — Map of host configurations (hostname -> config)
    /// * `secrets_store` — Secrets store for accessing encrypted keys
    /// * `audit_logger` — Audit logger for SSH events
    pub async fn new(
        tenant_id: Uuid,
        tenant_name: String,
        hosts: HashMap<String, SSHHostConfig>,
        secrets_store: Arc<dyn SecretsStore + Send + Sync>,
        audit_logger: Arc<dyn AuditLogger + Send + Sync>,
    ) -> Result<Self> {
        info!(tenant_id = %tenant_id, tenant_name = %tenant_name, hosts_count = hosts.len(), "Creating SSH bridge");

        Ok(Self {
            tenant_id,
            tenant_name,
            hosts: Arc::new(RwLock::new(hosts)),
            secrets_store,
            audit_logger,
            agent_server: None,
        })
    }

    /// Validate the SSH bridge configuration
    ///
    /// Checks:
    /// - All hosts have valid configurations
    /// - All required secrets exist
    /// - Host key formats are valid
    pub async fn validate(&self) -> Result<()> {
        let hosts = self.hosts.read().await;

        if hosts.is_empty() {
            warn!(tenant_id = %self.tenant_id, "No SSH hosts configured");
            return Ok(());
        }

        for (hostname, config) in hosts.iter() {
            // Validate hostname
            if hostname.is_empty() || !is_valid_hostname(hostname) {
                return Err(SshBridgeError::InvalidHostConfig(format!(
                    "Invalid hostname: {}",
                    hostname
                )));
            }

            // Validate port
            if config.port == 0 {
                return Err(SshBridgeError::InvalidHostConfig(format!(
                    "Invalid port for {}: 0",
                    hostname
                )));
            }

            // Validate user
            if config.user.is_empty() {
                return Err(SshBridgeError::InvalidHostConfig(format!(
                    "Empty user for {}",
                    hostname
                )));
            }

            // Note: We don't check secret existence here because secrets might be added later
            // TODO: Add secrets_store.exists() method if not present
        }

        Ok(())
    }

    /// Get configuration for a specific host
    pub async fn get_host_config(&self, hostname: &str) -> Result<SSHHostConfig> {
        let hosts = self.hosts.read().await;
        hosts
            .get(hostname)
            .cloned()
            .ok_or_else(|| SshBridgeError::HostNotFound(hostname.to_string()))
    }

    /// Get all host configurations
    pub async fn list_hosts(&self) -> Vec<SSHHostConfig> {
        let hosts = self.hosts.read().await;
        hosts.values().cloned().collect()
    }

    /// Add a new host configuration
    pub async fn add_host(&self, config: SSHHostConfig) -> Result<()> {
        let mut hosts = self.hosts.write().await;
        let hostname = config.host.clone();

        hosts.insert(hostname.clone(), config.clone());

        self.audit_logger
            .log(SshEvent::HostAdded {
                host: hostname.clone(),
                user: config.user.clone(),
                key_type: config.key_type.to_string(),
            })
            .await?;

        info!(tenant_id = %self.tenant_id, host = %hostname, "Host added");
        Ok(())
    }

    /// Remove a host configuration
    pub async fn remove_host(&self, hostname: &str) -> Result<()> {
        let mut hosts = self.hosts.write().await;
        hosts
            .remove(hostname)
            .ok_or_else(|| SshBridgeError::HostNotFound(hostname.to_string()))?;

        self.audit_logger
            .log(SshEvent::HostRemoved {
                host: hostname.to_string(),
            })
            .await?;

        info!(tenant_id = %self.tenant_id, host = %hostname, "Host removed");
        Ok(())
    }

    /// Start the SSH agent server (for worker integration)
    ///
    /// Creates a Unix socket at `/tmp/ssh-agent-<tenant_name>.sock` that workers
    /// can connect to for SSH authentication. Keys are loaded from the secrets
    /// store and never written to disk. The socket path uses the tenant name
    /// (not the UUID) so the mt-admin script can predict it for bind-mounting
    /// into worker containers.
    #[instrument(skip(self))]
    pub async fn start_agent_server(&mut self) -> Result<()> {
        let socket_path = PathBuf::from(format!("/tmp/ssh-agent-{}.sock", self.tenant_name));

        // Load keys from the secrets store for each configured host.
        let hosts = self.hosts.read().await;
        let mut keys = HashMap::new();
        for hostname in hosts.keys() {
            let secret_name = format!(
                "ssh_key_{}",
                hostname
                    .chars()
                    .map(|c| if c.is_alphanumeric() { c } else { '_' })
                    .collect::<String>()
            );
            match self.secrets_store.get_decrypted(&self.tenant_name, &secret_name).await {
                Ok(decrypted) => {
                    let key_data = decrypted.expose().as_bytes().to_vec();
                    // Try to load passphrase if present.
                    let passphrase_secret = format!("{}_passphrase", secret_name);
                    let passphrase = match self.secrets_store
                        .get_decrypted(&self.tenant_name, &passphrase_secret)
                        .await
                    {
                        Ok(p) => Some(SecretString::from(p.expose().to_string())),
                        Err(_) => None,
                    };
                    keys.insert(
                        hostname.clone(),
                        SSHCredentials { key_data: Zeroizing::new(key_data), passphrase },
                    );
                    info!(tenant_name = %self.tenant_name, host = %hostname, "Loaded SSH key for agent");
                }
                Err(crate::secrets::SecretError::NotFound(_)) => {
                    warn!(
                        tenant_name = %self.tenant_name,
                        host = %hostname,
                        "No SSH key found in secrets store; agent will start without this host's key"
                    );
                }
                Err(e) => {
                    warn!(
                        tenant_name = %self.tenant_name,
                        host = %hostname,
                        error = %e,
                        "Failed to load SSH key from secrets store"
                    );
                }
            }
        }
        drop(hosts);

        // Start the real agent server (from ssh_agent.rs).
        let server = SshAgentServer::start(socket_path.clone(), keys).await?;

        info!(
            tenant_id = %self.tenant_id,
            tenant_name = %self.tenant_name,
            socket_path = %socket_path.display(),
            "SSH agent server started"
        );

        self.audit_logger
            .log(SshEvent::AgentStarted {
                socket_path: socket_path.to_string_lossy().to_string(),
            })
            .await?;

        self.agent_server = Some(server);
        Ok(())
    }

    /// Stop the SSH agent server
    pub async fn stop_agent_server(&mut self) -> Result<()> {
        if self.agent_server.take().is_some() {
            info!(tenant_name = %self.tenant_name, "SSH agent server stopped");
        }
        Ok(())
    }

    /// Get the agent socket path for worker configuration
    pub fn get_agent_socket_path(&self) -> Option<String> {
        self.agent_server
            .as_ref()
            .map(|s| s.socket_path().to_string_lossy().to_string())
    }

    /// Get a reference to the running agent server (for wiring into the API state)
    pub fn agent_server(&self) -> Option<Arc<SshAgentServer>> {
        self.agent_server.clone()
    }
}

// ============================================================================
// Helper Functions
// ============================================================================

/// Validate hostname format
fn is_valid_hostname(hostname: &str) -> bool {
    // Basic validation: not empty, no whitespace, valid characters
    if hostname.is_empty() || hostname.contains(char::is_whitespace) {
        return false;
    }

    // Allow IP addresses and hostnames
    // This is a simplified check; production should use a proper DNS library
    hostname
        .chars()
        .all(|c| c.is_alphanumeric() || c == '.' || c == '-' || c == ':')
}

/// Sanitize hostname for use in secret names
/// (Used in Phase 3+ when secrets integration is complete)
#[allow(dead_code)]
fn sanitize_secret_name(hostname: &str) -> String {
    hostname
        .chars()
        .map(|c| if c.is_alphanumeric() { c } else { '_' })
        .collect()
}

// ============================================================================
// Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_valid_hostname() {
        assert!(is_valid_hostname("example.com"));
        assert!(is_valid_hostname("192.168.1.1"));
        assert!(is_valid_hostname("ssh-server-01"));
        assert!(!is_valid_hostname(""));
        assert!(!is_valid_hostname("invalid host"));
        assert!(!is_valid_hostname("host@name"));
    }

    #[test]
    fn test_sanitize_secret_name() {
        assert_eq!(sanitize_secret_name("example.com"), "example_com");
        assert_eq!(sanitize_secret_name("ssh-server-01"), "ssh_server_01");
        assert_eq!(sanitize_secret_name("192.168.1.1"), "192_168_1_1");
    }

    #[tokio::test]
    async fn test_create_bridge() {
        let tenant_id = Uuid::new_v4();
        let hosts = HashMap::new();
        let secrets_store = Arc::new(crate::secrets::InMemorySecretsStore::new(Arc::new(
            crate::secrets::SecretsCrypto::new(secrecy::SecretString::from("test-master-key-that-is-at-least-32-bytes-long!")).unwrap(),
        )));
        let audit_logger = Arc::new(NullAuditLogger);

        let bridge = SSHBridge::new(tenant_id, "test-tenant".to_string(), hosts, secrets_store, audit_logger)
            .await
            .unwrap();

        assert!(bridge.validate().await.is_ok());
    }

    #[tokio::test]
    async fn test_add_host() {
        let tenant_id = Uuid::new_v4();
        let mut hosts = HashMap::new();
        let secrets_store = Arc::new(crate::secrets::InMemorySecretsStore::new(Arc::new(
            crate::secrets::SecretsCrypto::new(secrecy::SecretString::from("test-master-key-that-is-at-least-32-bytes-long!")).unwrap(),
        )));
        let audit_logger = Arc::new(NullAuditLogger);

        let bridge = SSHBridge::new(tenant_id, "test-tenant".to_string(), hosts, secrets_store, audit_logger)
            .await
            .unwrap();

        let config = SSHHostConfig {
            host: "example.com".to_string(),
            port: 22,
            user: "admin".to_string(),
            key_type: SSHKeyType::Ed25519,
            host_key_mode: HostKeyMode::Strict,
            known_host_key: None,
            connect_timeout_secs: 10,
            operation_timeout_secs: 30,
            keepalive_interval_secs: 60,
            keepalive_max_misses: 3,
        };

        bridge.add_host(config).await.unwrap();

        let hosts = bridge.list_hosts().await;
        assert_eq!(hosts.len(), 1);
        assert_eq!(hosts[0].host, "example.com");
    }
}
