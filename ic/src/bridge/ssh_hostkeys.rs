//! SSH host key verification — managing known_hosts and verifying remote keys.
//!
//! This module provides:
//! - Strict host key verification (reject unknown hosts)
//! - AcceptFirst mode (accept on first connect, pin thereafter)
//! - Per-tenant known_hosts management
//! - Host key fingerprinting
//!
//! # Security Model
//!
//! ```text
//! ┌─────────────────────────────────────────────────────────────────────────────┐
//! │                      Host Key Verification Flow                              │
//! │                                                                              │
//! │   Strict Mode (Default) ────────────────────────────────────────────────────│
//! │                                                                              │
//! │   1. Connect to host ──► Check known_hosts ──► Key not found                 │
//! │                              │                                               │
//! │                              ▼                                               │
//! │                      REJECT CONNECTION                                       │
//! │                      (Error: UnknownHostKey)                                 │
//! │                                                                              │
//! │   2. Admin adds host ──► Store key in known_hosts ──► Future connections OK  │
//! │                                                                              │
//! │   ───────────────────────────────────────────────────────────────────────────│
//! │                                                                              │
//! │   AcceptFirst Mode ──────────────────────────────────────────────────────────│
//! │                                                                              │
//! │   1. Connect to host ──► Check known_hosts ──► Key not found                 │
//! │                              │                                               │
//! │                              ▼                                               │
//! │                      ACCEPT + STORE KEY                                      │
//! │                      (Pin to this key)                                       │
//! │                                                                              │
//! │   2. Future connects ──► Verify against pinned key ──► Reject if mismatch    │
//! │                                                                              │
//! └─────────────────────────────────────────────────────────────────────────────┘
//! ```

use std::collections::HashMap;
use std::sync::Arc;

use base64::{Engine, engine::general_purpose::STANDARD as BASE64};
use sha2::{Digest, Sha256};
use tracing::{info, instrument, warn};

use crate::bridge::ssh::{HostKeyMode, Result, SSHHostConfig, SshBridgeError};

/// SSH host key verifier — manages known_hosts per tenant.
pub struct HostKeyVerifier {
    /// Known hosts (hostname -> stored public key)
    known_hosts: Arc<tokio::sync::RwLock<HashMap<String, StoredHostKey>>>,
}

/// A stored host public key with metadata.
#[derive(Debug, Clone)]
pub struct StoredHostKey {
    /// The public key data (in the format received from the server)
    pub public_key: Vec<u8>,
    /// Key type (ssh-ed25519, ecdsa-sha2-nistp256, ssh-rsa)
    pub key_type: String,
    /// Fingerprint (SHA256 base64)
    pub fingerprint: String,
}

impl HostKeyVerifier {
    /// Create a new host key verifier.
    pub fn new() -> Self {
        Self {
            known_hosts: Arc::new(tokio::sync::RwLock::new(HashMap::new())),
        }
    }

    /// Create a verifier with pre-loaded known hosts.
    pub fn with_hosts(hosts: HashMap<String, StoredHostKey>) -> Self {
        Self {
            known_hosts: Arc::new(tokio::sync::RwLock::new(hosts)),
        }
    }

    /// Compute SHA256 fingerprint of a public key.
    pub fn compute_fingerprint(key_data: &[u8]) -> String {
        let mut hasher = Sha256::new();
        hasher.update(key_data);
        let digest = hasher.finalize();
        BASE64.encode(digest)
    }

    /// Parse an OpenSSH-style public key (e.g., "ssh-ed25519 AAAAC3NzaC...").
    ///
    /// Returns (key_type, key_data, comment).
    pub fn parse_openssh_public_key(key_str: &str) -> Option<(String, Vec<u8>, String)> {
        let parts: Vec<&str> = key_str.trim().split_whitespace().collect();
        if parts.len() < 2 {
            return None;
        }

        let key_type = parts[0].to_string();
        let key_data = BASE64.decode(parts[1]).ok()?;
        let comment = parts.get(2).map(|s| s.to_string()).unwrap_or_default();

        Some((key_type, key_data, comment))
    }

    /// Verify a host's public key against stored keys.
    ///
    /// # Returns
    /// - `Ok(true)` if key matches stored key
    /// - `Ok(false)` if key doesn't match (Strict mode)
    /// - `Ok(StoredHostKey)` if key was accepted (AcceptFirst mode, first time)
    #[instrument(skip(self, remote_key_data))]
    pub async fn verify_host_key(
        &self,
        hostname: &str,
        port: u16,
        remote_key_type: &str,
        remote_key_data: &[u8],
        mode: HostKeyMode,
    ) -> Result<VerifyResult> {
        let full_host = format!("{}:{}", hostname, port);
        let remote_fingerprint = Self::compute_fingerprint(remote_key_data);

        let known_hosts = self.known_hosts.read().await;

        match known_hosts.get(&full_host) {
            Some(stored) => {
                // Key already stored — verify it matches
                if remote_key_data == &stored.public_key[..] {
                    info!(
                        host = %full_host,
                        fingerprint = %remote_fingerprint,
                        "Host key verified"
                    );
                    Ok(VerifyResult::Verified)
                } else {
                    warn!(
                        host = %full_host,
                        expected_fingerprint = %stored.fingerprint,
                        actual_fingerprint = %remote_fingerprint,
                        "Host key mismatch"
                    );
                    Err(SshBridgeError::HostKeyMismatch {
                        expected: stored.fingerprint.clone(),
                        actual: remote_fingerprint,
                    })
                }
            }
            None => {
                // Key not stored — depends on mode
                match mode {
                    HostKeyMode::Strict => {
                        warn!(
                            host = %full_host,
                            fingerprint = %remote_fingerprint,
                            "Unknown host key (strict mode)"
                        );
                        Err(SshBridgeError::UnknownHostKey {
                            fingerprint: remote_fingerprint,
                        })
                    }
                    HostKeyMode::AcceptFirst => {
                        let stored = StoredHostKey {
                            public_key: remote_key_data.to_vec(),
                            key_type: remote_key_type.to_string(),
                            fingerprint: remote_fingerprint,
                        };

                        drop(known_hosts); // Release read lock before writing

                        let mut hosts = self.known_hosts.write().await;
                        hosts.insert(full_host.clone(), stored);

                        info!(
                            host = %full_host,
                            key_type = %remote_key_type,
                            "Host key accepted and pinned (AcceptFirst mode)"
                        );

                        Ok(VerifyResult::Accepted)
                    }
                }
            }
        }
    }

    /// Add a host key to known_hosts.
    #[instrument(skip(self, public_key))]
    pub async fn add_host_key(
        &self,
        hostname: &str,
        port: u16,
        public_key: Vec<u8>,
        key_type: String,
    ) -> Result<()> {
        let full_host = format!("{}:{}", hostname, port);
        let fingerprint = Self::compute_fingerprint(&public_key);

        let stored = StoredHostKey {
            public_key,
            key_type,
            fingerprint: fingerprint.clone(),
        };

        let mut hosts = self.known_hosts.write().await;
        hosts.insert(full_host.clone(), stored);

        info!(
            host = %full_host,
            fingerprint = %fingerprint,
            "Host key added to known_hosts"
        );

        Ok(())
    }

    /// Add a host from an OpenSSH-style public key string.
    ///
    /// Format: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI..."
    #[instrument(skip(self))]
    pub async fn add_host_from_openssh(
        &self,
        hostname: &str,
        port: u16,
        key_str: &str,
    ) -> Result<()> {
        let (key_type, key_data, _comment) =
            Self::parse_openssh_public_key(key_str).ok_or_else(|| {
                SshBridgeError::InvalidKeyFormat("Invalid OpenSSH public key format".to_string())
            })?;

        self.add_host_key(hostname, port, key_data, key_type).await
    }

    /// Remove a host from known_hosts.
    #[instrument(skip(self))]
    pub async fn remove_host(&self, hostname: &str, port: u16) -> Result<bool> {
        let full_host = format!("{}:{}", hostname, port);

        let mut hosts = self.known_hosts.write().await;
        let removed = hosts.remove(&full_host).is_some();

        if removed {
            info!(host = %full_host, "Host removed from known_hosts");
        }

        Ok(removed)
    }

    /// Get the stored key for a host (if any).
    pub async fn get_host_key(&self, hostname: &str, port: u16) -> Option<StoredHostKey> {
        let full_host = format!("{}:{}", hostname, port);
        let hosts = self.known_hosts.read().await;
        hosts.get(&full_host).cloned()
    }

    /// List all known hosts.
    pub async fn list_hosts(&self) -> Vec<(String, StoredHostKey)> {
        let hosts = self.known_hosts.read().await;
        hosts.iter().map(|(k, v)| (k.clone(), v.clone())).collect()
    }

    /// Verify a host's key from its config.
    ///
    /// If the config has a known_host_key, verify against it.
    /// If not, use the verifier's mode to decide.
    #[instrument(skip(self, remote_key_data))]
    pub async fn verify_from_config(
        &self,
        config: &SSHHostConfig,
        remote_key_data: &[u8],
    ) -> Result<VerifyResult> {
        let full_host = format!("{}:{}", config.host, config.port);

        // If config has a known_host_key, verify against it directly
        if let Some(known_key_str) = &config.known_host_key {
            let (_, known_key_data, _) =
                Self::parse_openssh_public_key(known_key_str).ok_or_else(|| {
                    SshBridgeError::InvalidKeyFormat("Invalid known_host_key format".to_string())
                })?;

            if remote_key_data == &known_key_data[..] {
                let fingerprint = Self::compute_fingerprint(remote_key_data);
                info!(
                    host = %full_host,
                    fingerprint = %fingerprint,
                    "Host key verified against config"
                );
                Ok(VerifyResult::Verified)
            } else {
                let remote_fingerprint = Self::compute_fingerprint(remote_key_data);
                let known_fingerprint = Self::compute_fingerprint(&known_key_data);
                Err(SshBridgeError::HostKeyMismatch {
                    expected: known_fingerprint,
                    actual: remote_fingerprint,
                })
            }
        } else {
            // Use the verifier's mode
            self.verify_host_key(
                &config.host,
                config.port,
                "unknown", // We don't know the key type until we verify
                remote_key_data,
                config.host_key_mode.clone(),
            )
            .await
        }
    }
}

/// Result of host key verification.
#[derive(Debug, Clone)]
pub enum VerifyResult {
    /// Key was verified against stored key
    Verified,
    /// Key was accepted and stored (AcceptFirst mode, first connection)
    Accepted,
}

impl Default for HostKeyVerifier {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_compute_fingerprint() {
        let key_data = b"test key data";
        let fingerprint = HostKeyVerifier::compute_fingerprint(key_data);
        assert!(!fingerprint.is_empty());
        assert_eq!(fingerprint.len(), 44); // Base64 encoded SHA256
    }

    #[test]
    fn test_parse_openssh_public_key() {
        let key_str = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl user@host";
        let (key_type, key_data, comment) =
            HostKeyVerifier::parse_openssh_public_key(key_str).unwrap();

        assert_eq!(key_type, "ssh-ed25519");
        assert!(!key_data.is_empty());
        assert_eq!(comment, "user@host");
    }

    #[test]
    fn test_parse_openssh_without_comment() {
        let key_str =
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl";
        let (key_type, key_data, comment) =
            HostKeyVerifier::parse_openssh_public_key(key_str).unwrap();

        assert_eq!(key_type, "ssh-ed25519");
        assert!(!key_data.is_empty());
        assert!(comment.is_empty());
    }

    #[tokio::test]
    async fn test_add_and_verify_host_key() {
        let verifier = HostKeyVerifier::new();
        let key_data = b"test public key data";
        let key_type = "ssh-ed25519".to_string();

        verifier
            .add_host_key("example.com", 22, key_data.to_vec(), key_type)
            .await
            .unwrap();

        let result = verifier
            .verify_host_key(
                "example.com",
                22,
                "ssh-ed25519",
                key_data,
                HostKeyMode::Strict,
            )
            .await
            .unwrap();

        assert!(matches!(result, VerifyResult::Verified));
    }

    #[tokio::test]
    async fn test_strict_mode_rejects_unknown() {
        let verifier = HostKeyVerifier::new();
        let key_data = b"test public key data";

        let result = verifier
            .verify_host_key(
                "unknown.example.com",
                22,
                "ssh-ed25519",
                key_data,
                HostKeyMode::Strict,
            )
            .await;

        assert!(matches!(result, Err(SshBridgeError::UnknownHostKey { .. })));
    }

    #[tokio::test]
    async fn test_acceptfirst_mode_accepts_unknown() {
        let verifier = HostKeyVerifier::new();
        let key_data = b"test public key data";

        let result = verifier
            .verify_host_key(
                "new.example.com",
                22,
                "ssh-ed25519",
                key_data,
                HostKeyMode::AcceptFirst,
            )
            .await
            .unwrap();

        assert!(matches!(result, VerifyResult::Accepted));

        // Second connection should verify
        let result = verifier
            .verify_host_key(
                "new.example.com",
                22,
                "ssh-ed25519",
                key_data,
                HostKeyMode::AcceptFirst,
            )
            .await
            .unwrap();

        assert!(matches!(result, VerifyResult::Verified));
    }

    #[tokio::test]
    async fn test_host_key_mismatch() {
        let verifier = HostKeyVerifier::new();
        let original_key = b"original public key";
        let different_key = b"different public key";

        verifier
            .add_host_key(
                "example.com",
                22,
                original_key.to_vec(),
                "ssh-ed25519".to_string(),
            )
            .await
            .unwrap();

        let result = verifier
            .verify_host_key(
                "example.com",
                22,
                "ssh-ed25519",
                different_key,
                HostKeyMode::Strict,
            )
            .await;

        assert!(matches!(
            result,
            Err(SshBridgeError::HostKeyMismatch { .. })
        ));
    }

    #[tokio::test]
    async fn test_remove_host() {
        let verifier = HostKeyVerifier::new();
        let key_data = b"test public key data";

        verifier
            .add_host_key(
                "example.com",
                22,
                key_data.to_vec(),
                "ssh-ed25519".to_string(),
            )
            .await
            .unwrap();
        assert!(verifier.list_hosts().await.len() == 1);

        let removed = verifier.remove_host("example.com", 22).await.unwrap();
        assert!(removed);
        assert!(verifier.list_hosts().await.is_empty());
    }

    #[tokio::test]
    async fn test_different_ports() {
        let verifier = HostKeyVerifier::new();
        let key_data = b"test public key data";

        verifier
            .add_host_key(
                "example.com",
                22,
                key_data.to_vec(),
                "ssh-ed25519".to_string(),
            )
            .await
            .unwrap();
        verifier
            .add_host_key(
                "example.com",
                2222,
                key_data.to_vec(),
                "ssh-ed25519".to_string(),
            )
            .await
            .unwrap();

        let hosts = verifier.list_hosts().await;
        assert_eq!(hosts.len(), 2);
    }
}
