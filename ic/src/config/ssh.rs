//! SSH bridge configuration — non-sensitive host definitions.
//!
//! Sensitive data (SSH keys) are stored in the secrets store, not here.
//!
//! # Example `config.toml`
//!
//! ```toml
//! [ssh]
//! # Global defaults
//! connect_timeout_secs = 10
//! operation_timeout_secs = 30
//! keepalive_interval_secs = 60
//! keepalive_max_misses = 3
//!
//! [[ssh.hosts]]
//! host = "prod-server.example.com"
//! port = 22
//! user = "deploy"
//! key_type = "ed25519"
//! host_key_mode = "Strict"
//! known_host_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI..."
//!
//! [[ssh.hosts]]
//! host = "192.168.1.100"
//! port = 2222
//! user = "admin"
//! key_type = "ecdsa"
//! host_key_mode = "AcceptFirst"
//! ```

use serde::{Deserialize, Serialize};
use std::collections::HashMap;

use crate::bridge::ssh::{HostKeyMode, SSHKeyType};

/// SSH bridge configuration.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct SshConfig {
    /// Host configurations
    #[serde(default)]
    pub hosts: Vec<SshHostEntry>,

    /// Global connection timeout in seconds (default: 10)
    #[serde(default = "default_connect_timeout")]
    pub connect_timeout_secs: u64,

    /// Global operation timeout in seconds (default: 30)
    #[serde(default = "default_operation_timeout")]
    pub operation_timeout_secs: u64,

    /// Global keepalive interval in seconds (default: 60, 0 = disabled)
    #[serde(default = "default_keepalive_interval")]
    pub keepalive_interval_secs: u64,

    /// Max missed keepalives before disconnect (default: 3)
    #[serde(default = "default_keepalive_max_misses")]
    pub keepalive_max_misses: u32,
}

fn default_connect_timeout() -> u64 {
    10
}
fn default_operation_timeout() -> u64 {
    30
}
fn default_keepalive_interval() -> u64 {
    60
}
fn default_keepalive_max_misses() -> u32 {
    3
}

/// SSH host entry with optional per-host overrides.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SshHostEntry {
    /// Hostname or IP address
    pub host: String,

    /// SSH port (default: 22, or global default)
    #[serde(default = "default_ssh_port")]
    pub port: u16,

    /// Username to connect as
    pub user: String,

    /// Key type for identification (ed25519, ecdsa, rsa)
    pub key_type: SSHKeyType,

    /// Host key verification mode (default: Strict)
    #[serde(default)]
    pub host_key_mode: HostKeyMode,

    /// Known host key for verification (optional)
    #[serde(default)]
    pub known_host_key: Option<String>,

    /// Per-host timeout override (optional)
    #[serde(default)]
    pub connect_timeout_secs: Option<u64>,

    /// Per-host operation timeout override (optional)
    #[serde(default)]
    pub operation_timeout_secs: Option<u64>,

    /// Per-host keepalive override (optional)
    #[serde(default)]
    pub keepalive_interval_secs: Option<u64>,

    /// Per-host keepalive max misses override (optional)
    #[serde(default)]
    pub keepalive_max_misses: Option<u32>,
}

fn default_ssh_port() -> u16 {
    22
}

impl SshConfig {
    /// Convert to a HashMap of host configurations.
    ///
    /// Applies global defaults to per-host overrides.
    pub fn to_host_map(&self) -> HashMap<String, crate::bridge::ssh::SSHHostConfig> {
        self.hosts
            .iter()
            .map(|entry| {
                let config = crate::bridge::ssh::SSHHostConfig {
                    host: entry.host.clone(),
                    port: entry.port,
                    user: entry.user.clone(),
                    key_type: entry.key_type.clone(),
                    host_key_mode: entry.host_key_mode.clone(),
                    known_host_key: entry.known_host_key.clone(),
                    connect_timeout_secs: entry
                        .connect_timeout_secs
                        .unwrap_or(self.connect_timeout_secs),
                    operation_timeout_secs: entry
                        .operation_timeout_secs
                        .unwrap_or(self.operation_timeout_secs),
                    keepalive_interval_secs: entry
                        .keepalive_interval_secs
                        .unwrap_or(self.keepalive_interval_secs),
                    keepalive_max_misses: entry
                        .keepalive_max_misses
                        .unwrap_or(self.keepalive_max_misses),
                };
                (entry.host.clone(), config)
            })
            .collect()
    }

    /// Get configuration for a specific host.
    pub fn get_host(&self, hostname: &str) -> Option<crate::bridge::ssh::SSHHostConfig> {
        self.hosts
            .iter()
            .find(|entry| entry.host == hostname)
            .map(|entry| crate::bridge::ssh::SSHHostConfig {
                host: entry.host.clone(),
                port: entry.port,
                user: entry.user.clone(),
                key_type: entry.key_type.clone(),
                host_key_mode: entry.host_key_mode.clone(),
                known_host_key: entry.known_host_key.clone(),
                connect_timeout_secs: entry
                    .connect_timeout_secs
                    .unwrap_or(self.connect_timeout_secs),
                operation_timeout_secs: entry
                    .operation_timeout_secs
                    .unwrap_or(self.operation_timeout_secs),
                keepalive_interval_secs: entry
                    .keepalive_interval_secs
                    .unwrap_or(self.keepalive_interval_secs),
                keepalive_max_misses: entry
                    .keepalive_max_misses
                    .unwrap_or(self.keepalive_max_misses),
            })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_ssh_config() {
        let toml = r#"
            connect_timeout_secs = 15
            operation_timeout_secs = 45

            [[hosts]]
            host = "example.com"
            port = 22
            user = "admin"
            key_type = "ed25519"
            host_key_mode = "Strict"
        "#;

        let config: SshConfig = toml::from_str(toml).unwrap();

        assert_eq!(config.connect_timeout_secs, 15);
        assert_eq!(config.operation_timeout_secs, 45);
        assert_eq!(config.hosts.len(), 1);
        assert_eq!(config.hosts[0].host, "example.com");
        assert_eq!(config.hosts[0].user, "admin");
        assert_eq!(config.hosts[0].key_type, SSHKeyType::Ed25519);
    }

    #[test]
    fn test_to_host_map() {
        let toml = r#"
            connect_timeout_secs = 10

            [[hosts]]
            host = "server1.example.com"
            port = 22
            user = "deploy"
            key_type = "ed25519"

            [[hosts]]
            host = "server2.example.com"
            port = 2222
            user = "admin"
            key_type = "ecdsa"
            connect_timeout_secs = 20
        "#;

        let config: SshConfig = toml::from_str(toml).unwrap();
        let hosts = config.to_host_map();

        assert_eq!(hosts.len(), 2);

        let h1 = hosts.get("server1.example.com").unwrap();
        assert_eq!(h1.connect_timeout_secs, 10); // Uses global default

        let h2 = hosts.get("server2.example.com").unwrap();
        assert_eq!(h2.connect_timeout_secs, 20); // Uses per-host override
        assert_eq!(h2.port, 2222);
    }
}
