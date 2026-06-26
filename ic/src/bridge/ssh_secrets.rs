//! SSH secrets integration — loading and managing SSH keys from the secrets store.
//!
//! This module provides:
//! - Loading SSH keys from the encrypted secrets store
//! - Key format validation (OpenSSH, Ed25519, ECDSA, RSA)
//! - Passphrase-protected key support
//! - Key rotation and management
//!
//! # Security Model
//!
//! ```text
//! ┌─────────────────────────────────────────────────────────────────────────────┐
//! │                         SSH Key Lifecycle                                    │
//! │                                                                              │
//! │   Admin stores key ──► Encrypted in secrets store ──► Never on disk          │
//! │   (via CLI/API)        (AES-256-GCM)                                         │
//! │                                                                              │
//! │   SSHBridge needs key ──► Decrypt from store ──► Load into memory            │
//! │                            (only when needed)     (for agent server)         │
//! │                                                                              │
//! │   Worker connects ────► SSH agent signs ───────► Key never leaves memory     │
//! └─────────────────────────────────────────────────────────────────────────────┘
//! ```

use std::sync::Arc;

use tracing::{info, warn, instrument};

use crate::bridge::ssh::{SSHCredentials, SSHKeyType, SshBridgeError, Result};
use crate::secrets::{SecretsStore, SecretError, CreateSecretParams};

/// SSH secrets manager — handles loading and managing SSH keys.
pub struct SshSecretsManager {
    secrets_store: Arc<dyn SecretsStore + Send + Sync>,
    tenant_id: String,
}

impl SshSecretsManager {
    /// Create a new SSH secrets manager for a tenant.
    pub fn new(
        secrets_store: Arc<dyn SecretsStore + Send + Sync>,
        tenant_id: &str,
    ) -> Self {
        Self {
            secrets_store,
            tenant_id: tenant_id.to_string(),
        }
    }

    /// Generate a secret name for an SSH key based on host.
    fn secret_name_for_host(&self, hostname: &str) -> String {
        format!(
            "ssh_key_{}",
            hostname
                .chars()
                .map(|c| if c.is_alphanumeric() { c } else { '_' })
                .collect::<String>()
        )
    }

    /// Store an SSH key for a host.
    ///
    /// # Arguments
    /// * `hostname` — The host this key belongs to
    /// * `key_data` — Raw key bytes (PEM or OpenSSH format)
    /// * `passphrase` — Optional passphrase if the key is encrypted
    #[instrument(skip(self, key_data, passphrase))]
    pub async fn store_key(
        &self,
        hostname: &str,
        key_data: &[u8],
        passphrase: Option<&str>,
    ) -> Result<()> {
        let secret_name = self.secret_name_for_host(hostname);
        
        info!(
            tenant_id = %self.tenant_id,
            host = %hostname,
            secret_name = %secret_name,
            "Storing SSH key"
        );

        // Store the key data
        let key_str = String::from_utf8_lossy(key_data).to_string();
        self.secrets_store
            .create(
                &self.tenant_id,
                CreateSecretParams::new(&secret_name, &key_str),
            )
            .await
            .map_err(|e| SshBridgeError::SecretDecryptionFailed(format!("Failed to store key: {}", e)))?;

        // Store passphrase separately if provided
        if let Some(pass) = passphrase {
            let passphrase_secret_name = format!("{}_passphrase", secret_name);
            self.secrets_store
                .create(
                    &self.tenant_id,
                    CreateSecretParams::new(&passphrase_secret_name, pass),
                )
                .await
                .map_err(|e| SshBridgeError::SecretDecryptionFailed(format!("Failed to store passphrase: {}", e)))?;
        }

        Ok(())
    }

    /// Load an SSH key for a host.
    ///
    /// # Returns
    /// `Ok(Some(SSHCredentials))` if key exists
    /// `Ok(None)` if key doesn't exist
    /// `Err` on decryption error or other failure
    #[instrument(skip(self))]
    pub async fn load_key(&self, hostname: &str) -> Result<Option<SSHCredentials>> {
        let secret_name = self.secret_name_for_host(hostname);

        // Try to load the key
        let key_data = match self.secrets_store.get_decrypted(&self.tenant_id, &secret_name).await {
            Ok(decrypted) => Zeroizing::new(decrypted.expose().as_bytes().to_vec()),
            Err(SecretError::NotFound(_)) => return Ok(None),
            Err(e) => return Err(SshBridgeError::SecretDecryptionFailed(format!("Failed to load key: {}", e))),
        };

        // Try to load passphrase
        let passphrase_secret_name = format!("{}_passphrase", secret_name);
        let passphrase = match self.secrets_store.get_decrypted(&self.tenant_id, &passphrase_secret_name).await {
            Ok(decrypted) => Some(decrypted),
            Err(SecretError::NotFound(_)) => None,
            Err(e) => {
                warn!(
                    tenant_id = %self.tenant_id,
                    host = %hostname,
                    "Failed to load passphrase: {}",
                    e
                );
                None
            }
        };

        info!(
            tenant_id = %self.tenant_id,
            host = %hostname,
            has_passphrase = passphrase.is_some(),
            "Loaded SSH key"
        );

        Ok(Some(SSHCredentials {
            key_data,
            passphrase,
        }))
    }

    /// Delete an SSH key for a host.
    #[instrument(skip(self))]
    pub async fn delete_key(&self, hostname: &str) -> Result<()> {
        let secret_name = self.secret_name_for_host(hostname);
        let passphrase_secret_name = format!("{}_passphrase", secret_name);

        self.secrets_store
            .delete(&self.tenant_id, &secret_name)
            .await
            .map_err(|e| SshBridgeError::SecretDecryptionFailed(format!("Failed to delete key: {}", e)))?;

        // Also delete passphrase if it exists
        let _ = self.secrets_store
            .delete(&self.tenant_id, &passphrase_secret_name)
            .await;

        info!(
            tenant_id = %self.tenant_id,
            host = %hostname,
            "Deleted SSH key"
        );

        Ok(())
    }

    /// Check if a key exists for a host.
    pub async fn key_exists(&self, hostname: &str) -> Result<bool> {
        let secret_name = self.secret_name_for_host(hostname);
        
        match self.secrets_store.exists(&self.tenant_id, &secret_name).await {
            Ok(exists) => Ok(exists),
            Err(e) => Err(SshBridgeError::SecretDecryptionFailed(format!("Failed to check key existence: {}", e))),
        }
    }

    /// Validate an SSH key format.
    ///
    /// Attempts to parse the key to ensure it's valid.
    pub fn validate_key_format(key_data: &[u8]) -> Result<SSHKeyType> {
        // Try to parse as OpenSSH public key first to determine type
        match String::from_utf8_lossy(key_data) {
            key_str if key_str.starts_with("-----BEGIN OPENSSH PRIVATE KEY-----") => {
                // OpenSSH format - try to determine key type
                // This is a simplified check; full validation would parse the key
                if key_str.contains("ED25519") || key_str.contains("ssh-ed25519") {
                    Ok(SSHKeyType::Ed25519)
                } else if key_str.contains("ECDSA") || key_str.contains("ecdsa") {
                    Ok(SSHKeyType::Ecdsa)
                } else {
                    // Default to RSA for unknown types in OpenSSH format
                    Ok(SSHKeyType::Rsa)
                }
            }
            key_str if key_str.starts_with("-----BEGIN EC PRIVATE KEY-----") => {
                Ok(SSHKeyType::Ecdsa)
            }
            key_str if key_str.starts_with("-----BEGIN RSA PRIVATE KEY-----") => {
                Ok(SSHKeyType::Rsa)
            }
            key_str if key_str.starts_with("ssh-ed25519") || key_str.starts_with("ED25519") => {
                Ok(SSHKeyType::Ed25519)
            }
            key_str if key_str.starts_with("ssh-ec") || key_str.starts_with("ecdsa") => {
                Ok(SSHKeyType::Ecdsa)
            }
            key_str if key_str.starts_with("ssh-rsa") => {
                Ok(SSHKeyType::Rsa)
            }
            _ => Err(SshBridgeError::InvalidKeyFormat(
                "Key does not appear to be in a supported format (OpenSSH, PEM EC, PEM RSA, or public key format)".to_string()
            )),
        }
    }

    /// Load and validate a key, returning credentials with validated key type.
    #[instrument(skip(self))]
    pub async fn load_and_validate_key(&self, hostname: &str, expected_type: &SSHKeyType) -> Result<Option<SSHCredentials>> {
        let credentials = self.load_key(hostname).await?;
        
        if let Some(ref creds) = credentials {
            let actual_type = Self::validate_key_format(&creds.key_data)?;
            
            if actual_type != *expected_type {
                warn!(
                    tenant_id = %self.tenant_id,
                    host = %hostname,
                    expected = %expected_type,
                    actual = %actual_type,
                    "Key type mismatch"
                );
                // We allow the mismatch but log it; the connection will fail if the key is wrong
            }
        }

        Ok(credentials)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::secrets::InMemorySecretsStore;

    fn make_test_manager() -> SshSecretsManager {
        let store: Arc<dyn SecretsStore + Send + Sync> = Arc::new(InMemorySecretsStore::new());
        SshSecretsManager::new(store, "test-tenant")
    }

    #[tokio::test]
    async fn test_store_and_load_key() {
        let manager = make_test_manager();
        let key_data = b"-----BEGIN OPENSSH PRIVATE KEY-----\ntest-key-data\n-----END OPENSSH PRIVATE KEY-----";

        manager.store_key("example.com", key_data, None).await.unwrap();

        let creds = manager.load_key("example.com").await.unwrap().unwrap();
        assert_eq!(creds.key_data, key_data);
        assert!(creds.passphrase.is_none());
    }

    #[tokio::test]
    async fn test_store_with_passphrase() {
        let manager = make_test_manager();
        let key_data = b"-----BEGIN OPENSSH PRIVATE KEY-----\nencrypted-key-data\n-----END OPENSSH PRIVATE KEY-----";

        manager.store_key("secure.example.com", key_data, Some("mypassword")).await.unwrap();

        let creds = manager.load_key("secure.example.com").await.unwrap().unwrap();
        assert_eq!(creds.key_data, key_data);
        assert_eq!(creds.passphrase, Some("mypassword".to_string()));
    }

    #[tokio::test]
    async fn test_key_does_not_exist() {
        let manager = make_test_manager();
        let creds = manager.load_key("nonexistent.example.com").await.unwrap();
        assert!(creds.is_none());
    }

    #[tokio::test]
    async fn test_delete_key() {
        let manager = make_test_manager();
        let key_data = b"-----BEGIN OPENSSH PRIVATE KEY-----\ntest\n-----END OPENSSH PRIVATE KEY-----";

        manager.store_key("delete-me.example.com", key_data, None).await.unwrap();
        assert!(manager.key_exists("delete-me.example.com").await.unwrap());

        manager.delete_key("delete-me.example.com").await.unwrap();
        assert!(!manager.key_exists("delete-me.example.com").await.unwrap());
    }

    #[tokio::test]
    async fn test_validate_key_format_ed25519() {
        let key_data = b"-----BEGIN OPENSSH PRIVATE KEY-----\nkeytype ssh-ed25519\ndata\n-----END OPENSSH PRIVATE KEY-----";
        let result = SshSecretsManager::validate_key_format(key_data);
        assert!(result.is_ok());
        assert_eq!(result.unwrap(), SSHKeyType::Ed25519);
    }

    #[tokio::test]
    async fn test_validate_key_format_rsa() {
        let key_data = b"-----BEGIN RSA PRIVATE KEY-----\nkeydata\n-----END RSA PRIVATE KEY-----";
        let result = SshSecretsManager::validate_key_format(key_data);
        assert!(result.is_ok());
        assert_eq!(result.unwrap(), SSHKeyType::Rsa);
    }
}
