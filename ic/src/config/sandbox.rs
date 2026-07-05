use crate::config::helpers::{optional_env, parse_bool_env, parse_optional_env, parse_string_env};
use crate::error::ConfigError;
use secrecy::SecretString;
use serde::{Deserialize, Serialize};
use tracing;

/// Docker sandbox configuration.
#[derive(Debug, Clone)]
pub struct SandboxModeConfig {
    /// Whether the Docker sandbox is enabled.
    pub enabled: bool,
    /// Sandbox policy: "readonly", "workspace_write", or "full_access".
    pub policy: String,
    /// Explicit opt-in for `FullAccess` policy.
    ///
    /// When `policy` is `full_access` but this is `false`, the policy is
    /// downgraded to `workspace_write` with a loud error log. This prevents
    /// accidental host-level command execution from a single misconfigured
    /// env var.
    pub allow_full_access: bool,
    /// Command timeout in seconds.
    pub timeout_secs: u64,
    /// Memory limit in megabytes.
    pub memory_limit_mb: u64,
    /// CPU shares (relative weight).
    pub cpu_shares: u32,
    /// Docker image for the sandbox.
    pub image: String,
    /// Whether to auto-pull the image if not found.
    pub auto_pull_image: bool,
    /// Additional domains to allow through the network proxy.
    pub extra_allowed_domains: Vec<String>,
    /// How often the reaper scans for orphaned containers (seconds). Default: 300 (5 min).
    pub reaper_interval_secs: u64,
    /// Containers older than this with no active job are reaped (seconds). Default: 600 (10 min).
    pub orphan_threshold_secs: u64,
}

impl Default for SandboxModeConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            policy: "readonly".to_string(),
            allow_full_access: false,
            timeout_secs: 120,
            memory_limit_mb: 2048,
            cpu_shares: 1024,
            image: "lunarwing-worker:latest".to_string(),
            auto_pull_image: true,
            extra_allowed_domains: Vec::new(),
            reaper_interval_secs: 300,
            orphan_threshold_secs: 600,
        }
    }
}

impl SandboxModeConfig {
    pub(crate) fn resolve(settings: &crate::settings::Settings) -> Result<Self, ConfigError> {
        let ss = &settings.sandbox;

        let extra_domains = optional_env("SANDBOX_EXTRA_DOMAINS")?
            .map(|s| s.split(',').map(|d| d.trim().to_string()).collect())
            .unwrap_or_else(|| {
                if ss.extra_allowed_domains.is_empty() {
                    Vec::new()
                } else {
                    ss.extra_allowed_domains.clone()
                }
            });

        // reaper/orphan fields have no Settings counterpart — env > default only.
        let reaper_interval_secs: u64 = parse_optional_env("SANDBOX_REAPER_INTERVAL_SECS", 300)?;
        let orphan_threshold_secs: u64 = parse_optional_env("SANDBOX_ORPHAN_THRESHOLD_SECS", 600)?;

        // Validate that reaper timings are non-zero to prevent tokio::time::interval panics
        if reaper_interval_secs == 0 {
            return Err(ConfigError::InvalidValue {
                key: "SANDBOX_REAPER_INTERVAL_SECS".to_string(),
                message: "must be greater than 0".to_string(),
            });
        }

        if orphan_threshold_secs == 0 {
            return Err(ConfigError::InvalidValue {
                key: "SANDBOX_ORPHAN_THRESHOLD_SECS".to_string(),
                message: "must be greater than 0".to_string(),
            });
        }

        Ok(Self {
            enabled: parse_bool_env("SANDBOX_ENABLED", ss.enabled)?,
            policy: parse_string_env("SANDBOX_POLICY", ss.policy.clone())?,
            // allow_full_access has no Settings counterpart — env > default only.
            allow_full_access: parse_bool_env("SANDBOX_ALLOW_FULL_ACCESS", false)?,
            timeout_secs: parse_optional_env("SANDBOX_TIMEOUT_SECS", ss.timeout_secs)?,
            memory_limit_mb: parse_optional_env("SANDBOX_MEMORY_LIMIT_MB", ss.memory_limit_mb)?,
            cpu_shares: parse_optional_env("SANDBOX_CPU_SHARES", ss.cpu_shares)?,
            image: parse_string_env("SANDBOX_IMAGE", ss.image.clone())?,
            auto_pull_image: parse_bool_env("SANDBOX_AUTO_PULL", ss.auto_pull_image)?,
            extra_allowed_domains: extra_domains,
            reaper_interval_secs,
            orphan_threshold_secs,
        })
    }

    /// Convert to SandboxConfig for the sandbox module.
    ///
    /// If `policy` is `FullAccess` but `allow_full_access` is `false`,
    /// the policy is downgraded to `WorkspaceWrite` and an error is logged.
    pub fn to_sandbox_config(&self) -> crate::sandbox::SandboxConfig {
        use crate::sandbox::SandboxPolicy;
        use std::time::Duration;

        let mut policy = self.policy.parse().unwrap_or(SandboxPolicy::ReadOnly);

        // Double opt-in guard: FullAccess requires SANDBOX_ALLOW_FULL_ACCESS=true
        if policy == SandboxPolicy::FullAccess && !self.allow_full_access {
            tracing::error!(
                "SANDBOX_POLICY=full_access is set but SANDBOX_ALLOW_FULL_ACCESS is not \
                 set to 'true'. FullAccess bypasses Docker and runs commands directly on \
                 the host. Downgrading to WorkspaceWrite for safety. Set \
                 SANDBOX_ALLOW_FULL_ACCESS=true to explicitly enable FullAccess."
            );
            policy = SandboxPolicy::WorkspaceWrite;
        }

        let mut allowlist = crate::sandbox::default_allowlist();
        allowlist.extend(self.extra_allowed_domains.clone());

        crate::sandbox::SandboxConfig {
            enabled: self.enabled,
            policy,
            allow_full_access: self.allow_full_access,
            timeout: Duration::from_secs(self.timeout_secs),
            memory_limit_mb: self.memory_limit_mb,
            cpu_shares: self.cpu_shares,
            network_allowlist: allowlist,
            image: self.image.clone(),
            auto_pull_image: self.auto_pull_image,
            proxy_port: 0, // Auto-assign
        }
    }
}

/// A single endpoint for a named external worker (URL + optional auth).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkerEndpoint {
    pub url: String,
    // Secret-bearing: never serialized out (`SecretString` has no `Serialize`
    // impl by design). `Debug` auto-redacts via secrecy's `[REDACTED]`.
    // merge_from preserves auth_token via a direct post-merge fixup in
    // Settings::merge_from because skip_serializing drops it during the
    // serde_json transport.
    #[serde(skip_serializing, default)]
    pub auth_token: Option<SecretString>,
    pub weight: Option<u32>,
}

/// Load balancing strategy for multi-instance workers.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum LoadBalanceStrategy {
    #[default]
    RoundRobin,
    LeastConnections,
}

/// Configuration for a named external worker endpoint.
#[derive(Debug, Clone)]
pub struct ExternalWorkerConfig {
    pub name: String,
    pub url: String,
    pub auth_token: Option<SecretString>,
    pub timeout_ms: u64,
    /// Multiple endpoints for load-balanced workers.
    /// When non-empty, `url`/`auth_token` are treated as fallback only.
    pub endpoints: Vec<WorkerEndpoint>,
    /// Load balancing strategy (defaults to RoundRobin).
    pub load_balance: LoadBalanceStrategy,
}

impl ExternalWorkerConfig {
    pub fn resolve_from_settings(settings: &crate::settings::Settings) -> Vec<Self> {
        settings
            .sandbox
            .external_workers
            .iter()
            .map(|ew| Self {
                name: ew.name.clone(),
                url: ew.url.clone(),
                auth_token: ew.auth_token.clone(),
                timeout_ms: ew.timeout_ms,
                endpoints: ew.endpoints.clone(),
                load_balance: ew.load_balance.clone(),
            })
            .collect()
    }

    /// Returns the canonical endpoint list for this worker.
    ///
    /// When `endpoints` is non-empty those are used directly; otherwise a
    /// single `WorkerEndpoint` is synthesized from the legacy `url` and
    /// `auth_token` fields.
    pub fn endpoints(&self) -> Vec<WorkerEndpoint> {
        if !self.endpoints.is_empty() {
            self.endpoints.clone()
        } else {
            vec![WorkerEndpoint {
                url: self.url.clone(),
                auth_token: self.auth_token.clone(),
                weight: None,
            }]
        }
    }
}

/// ACP (Agent Client Protocol) mode configuration.
#[derive(Debug, Clone)]
pub struct AcpModeConfig {
    pub enabled: bool,
    pub memory_limit_mb: u64,
    pub timeout_secs: u64,
}

impl Default for AcpModeConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            memory_limit_mb: 4096,
            timeout_secs: 1800,
        }
    }
}

impl AcpModeConfig {
    pub fn from_env() -> Self {
        match Self::resolve_env_only() {
            Ok(c) => c,
            Err(e) => {
                tracing::warn!("Failed to resolve AcpModeConfig: {e}, using defaults");
                Self::default()
            }
        }
    }

    pub(crate) fn resolve(settings: &crate::settings::Settings) -> Result<Self, ConfigError> {
        let defaults = Self::default();
        Ok(Self {
            enabled: parse_bool_env("ACP_ENABLED", settings.sandbox.acp_enabled)?,
            memory_limit_mb: parse_optional_env("ACP_MEMORY_LIMIT_MB", defaults.memory_limit_mb)?,
            timeout_secs: parse_optional_env("ACP_TIMEOUT_SECS", defaults.timeout_secs)?,
        })
    }

    fn resolve_env_only() -> Result<Self, ConfigError> {
        let defaults = Self::default();
        Ok(Self {
            enabled: parse_bool_env("ACP_ENABLED", defaults.enabled)?,
            memory_limit_mb: parse_optional_env("ACP_MEMORY_LIMIT_MB", defaults.memory_limit_mb)?,
            timeout_secs: parse_optional_env("ACP_TIMEOUT_SECS", defaults.timeout_secs)?,
        })
    }
}

#[cfg(test)]
mod tests {
    use crate::config::sandbox::*;
    use crate::testing::credentials::*;
    use secrecy::ExposeSecret;

    // ── SandboxModeConfig defaults ──────────────────────────────────

    #[test]
    fn sandbox_mode_config_default_values() {
        let cfg = SandboxModeConfig::default();
        assert!(cfg.enabled);
        assert_eq!(cfg.policy, "readonly");
        assert_eq!(cfg.timeout_secs, 120);
        assert_eq!(cfg.memory_limit_mb, 2048);
        assert_eq!(cfg.cpu_shares, 1024);
        assert_eq!(cfg.image, "lunarwing-worker:latest");
        assert!(cfg.auto_pull_image);
        assert!(cfg.extra_allowed_domains.is_empty());
    }

    #[test]
    fn sandbox_mode_config_custom_values() {
        let cfg = SandboxModeConfig {
            enabled: false,
            policy: "full_access".to_string(),
            timeout_secs: 600,
            memory_limit_mb: 4096,
            cpu_shares: 512,
            image: "custom-worker:v2".to_string(),
            auto_pull_image: false,
            extra_allowed_domains: vec!["example.com".to_string()],
            reaper_interval_secs: 300,
            orphan_threshold_secs: 600,
            allow_full_access: false,
        };
        assert!(!cfg.enabled);
        assert_eq!(cfg.policy, "full_access");
        assert_eq!(cfg.timeout_secs, 600);
        assert_eq!(cfg.memory_limit_mb, 4096);
        assert_eq!(cfg.cpu_shares, 512);
        assert_eq!(cfg.image, "custom-worker:v2");
        assert!(!cfg.auto_pull_image);
        assert_eq!(cfg.extra_allowed_domains, vec!["example.com"]);
    }

    #[test]
    fn sandbox_mode_to_sandbox_config_propagates_fields() {
        let mode = SandboxModeConfig {
            enabled: true,
            policy: "workspace_write".to_string(),
            timeout_secs: 300,
            memory_limit_mb: 1024,
            cpu_shares: 2048,
            image: "test:latest".to_string(),
            auto_pull_image: false,
            extra_allowed_domains: vec!["custom.example.com".to_string()],
            reaper_interval_secs: 300,
            orphan_threshold_secs: 600,
            allow_full_access: false,
        };
        let sc = mode.to_sandbox_config();
        assert!(sc.enabled);
        assert_eq!(sc.policy, crate::sandbox::SandboxPolicy::WorkspaceWrite);
        assert_eq!(sc.timeout, std::time::Duration::from_secs(300));
        assert_eq!(sc.memory_limit_mb, 1024);
        assert_eq!(sc.cpu_shares, 2048);
        assert_eq!(sc.image, "test:latest");
        assert!(!sc.auto_pull_image);
        // extra domain should be in the allowlist
        assert!(
            sc.network_allowlist
                .contains(&"custom.example.com".to_string()),
            "expected custom domain in allowlist"
        );
    }

    #[test]
    fn sandbox_mode_to_sandbox_config_invalid_policy_falls_back_to_readonly() {
        let mode = SandboxModeConfig {
            policy: "garbage_value".to_string(),
            ..SandboxModeConfig::default()
        };
        let sc = mode.to_sandbox_config();
        assert_eq!(sc.policy, crate::sandbox::SandboxPolicy::ReadOnly);
    }

    #[test]
    fn sandbox_mode_to_sandbox_config_includes_default_allowlist() {
        let mode = SandboxModeConfig::default();
        let sc = mode.to_sandbox_config();
        // The default allowlist from sandbox module should be non-empty
        assert!(
            !sc.network_allowlist.is_empty(),
            "default allowlist should not be empty"
        );
    }

    #[test]
    fn test_full_access_downgraded_without_allow() {
        let config = SandboxModeConfig {
            policy: "full_access".to_string(),
            allow_full_access: false,
            ..Default::default()
        };
        let sandbox = config.to_sandbox_config();
        // Should have been downgraded to WorkspaceWrite
        assert_eq!(
            sandbox.policy,
            crate::sandbox::SandboxPolicy::WorkspaceWrite
        );
        assert!(!sandbox.allow_full_access);
    }

    #[test]
    fn test_full_access_allowed_with_explicit_opt_in() {
        let config = SandboxModeConfig {
            policy: "full_access".to_string(),
            allow_full_access: true,
            ..Default::default()
        };
        let sandbox = config.to_sandbox_config();
        assert_eq!(sandbox.policy, crate::sandbox::SandboxPolicy::FullAccess);
        assert!(sandbox.allow_full_access);
    }

    #[test]
    fn test_non_full_access_policy_unaffected() {
        let config = SandboxModeConfig {
            policy: "workspace_write".to_string(),
            allow_full_access: false,
            ..Default::default()
        };
        let sandbox = config.to_sandbox_config();
        assert_eq!(
            sandbox.policy,
            crate::sandbox::SandboxPolicy::WorkspaceWrite
        );
    }

    // ── Settings fallback tests ──────────────────────────────────────

    #[test]
    fn sandbox_resolve_falls_back_to_settings() {
        let _guard = crate::config::helpers::lock_env();
        let mut settings = crate::settings::Settings::default();
        settings.sandbox.cpu_shares = 99;
        settings.sandbox.auto_pull_image = false;
        settings.sandbox.enabled = false;

        let cfg = SandboxModeConfig::resolve(&settings).expect("resolve");
        assert!(!cfg.enabled);
        assert_eq!(cfg.cpu_shares, 99);
        assert!(!cfg.auto_pull_image);
    }

    #[test]
    fn sandbox_env_overrides_settings() {
        let _guard = crate::config::helpers::lock_env();
        let mut settings = crate::settings::Settings::default();
        settings.sandbox.timeout_secs = 999;

        // SAFETY: Under ENV_MUTEX, no concurrent env access.
        unsafe { std::env::set_var("SANDBOX_TIMEOUT_SECS", "5") };
        let cfg = SandboxModeConfig::resolve(&settings).expect("resolve");
        unsafe { std::env::remove_var("SANDBOX_TIMEOUT_SECS") };

        assert_eq!(cfg.timeout_secs, 5);
    }

    #[test]
    fn test_readonly_policy_unaffected() {
        let config = SandboxModeConfig {
            policy: "readonly".to_string(),
            allow_full_access: false,
            ..Default::default()
        };
        let sandbox = config.to_sandbox_config();
        assert_eq!(sandbox.policy, crate::sandbox::SandboxPolicy::ReadOnly);
    }

    // ── External worker config (mt-admin config.toml contract) ───────────

    /// The exact `config.toml` block `lunarwing-mt-admin.sh` writes for a
    /// tenant's nanocode worker must deserialize into an `ExternalWorkerConfig`
    /// the daemon can route to. Guards the script↔daemon contract: if a field
    /// name (`external_workers`, `auth_token`, `timeout_ms`) or the nesting
    /// (`[[sandbox.external_workers]]`) drifts, the worker would silently fail
    /// to load and `create_job(mode: "nanocode")` would have nothing to route
    /// to — the exact bug in docs/bugs/MISSING-CONFIG-FOR-NANOCODE.md.
    #[test]
    fn external_worker_config_matches_mt_admin_output() {
        // Mirrors ensure_external_worker_config() — including the minimal
        // fresh-file form add-tenant writes (only the external-workers block;
        // every other Settings field falls back to its default).
        let generated = r#"
# LunarWing tenant configuration (auto-generated by lunarwing-mt-admin.sh).

# External worker: nanocode — create_job(mode: "nanocode")
[[sandbox.external_workers]]
name = "nanocode"
url = "ws://127.0.0.1:10007/ws/agent"
auth_token = "deadbeefcafe1234"
timeout_ms = 300000
"#;

        let settings: crate::settings::Settings =
            toml::from_str(generated).expect("mt-admin config.toml must parse");

        let workers = ExternalWorkerConfig::resolve_from_settings(&settings);
        assert_eq!(workers.len(), 1, "exactly one external worker expected");
        assert_eq!(workers[0].name, "nanocode");
        assert_eq!(workers[0].url, "ws://127.0.0.1:10007/ws/agent");
        assert_eq!(
            workers[0].auth_token.as_ref().map(|s| s.expose_secret()),
            Some("deadbeefcafe1234")
        );
        assert_eq!(workers[0].timeout_ms, 300_000);
    }

    /// Multiple `[[sandbox.external_workers]]` blocks in one file (e.g. nanocode
    /// plus pebble) must all resolve. Mirrors a tenant config that has had a
    /// second worker appended, guarding the array-of-tables append path the
    /// script relies on.
    #[test]
    fn external_worker_config_supports_multiple_workers() {
        let generated = r#"
[[sandbox.external_workers]]
name = "nanocode"
url = "ws://127.0.0.1:10007/ws/agent"
auth_token = "tok-nano"
timeout_ms = 300000

[[sandbox.external_workers]]
name = "pebble"
url = "ws://127.0.0.1:10008/ws/agent"
auth_token = "tok-pebble"
timeout_ms = 300000
"#;

        let settings: crate::settings::Settings =
            toml::from_str(generated).expect("multi-worker config.toml must parse");

        let workers = ExternalWorkerConfig::resolve_from_settings(&settings);
        let names: Vec<&str> = workers.iter().map(|w| w.name.as_str()).collect();
        assert_eq!(workers.len(), 2);
        assert!(names.contains(&"nanocode"));
        assert!(names.contains(&"pebble"));
    }

    #[test]
    fn external_worker_config_multi_endpoint() {
        let toml_str = r#"
[[sandbox.external_workers]]
name = "nanocode"
url = "ws://127.0.0.1:10007/ws/agent"
auth_token = "tok-legacy"
timeout_ms = 300000

[[sandbox.external_workers.endpoints]]
url = "ws://10.0.0.1:9090/ws/agent"
auth_token = "tok-1"

[[sandbox.external_workers.endpoints]]
url = "ws://10.0.0.2:9090/ws/agent"
auth_token = "tok-2"
"#;

        let settings: crate::settings::Settings =
            toml::from_str(toml_str).expect("multi-endpoint config must parse");
        let workers = ExternalWorkerConfig::resolve_from_settings(&settings);
        assert_eq!(workers.len(), 1);
        assert_eq!(workers[0].endpoints.len(), 2);
        assert_eq!(workers[0].endpoints[0].url, "ws://10.0.0.1:9090/ws/agent");
        assert_eq!(workers[0].endpoints[1].url, "ws://10.0.0.2:9090/ws/agent");
        assert!(matches!(
            workers[0].load_balance,
            LoadBalanceStrategy::RoundRobin
        ));
    }

    #[test]
    fn external_worker_config_legacy_fallback() {
        let toml_str = r#"
[[sandbox.external_workers]]
name = "pebble"
url = "ws://127.0.0.1:8443/ws/agent"
auth_token = "tok-legacy"
timeout_ms = 300000
"#;

        let settings: crate::settings::Settings =
            toml::from_str(toml_str).expect("legacy config must parse");
        let workers = ExternalWorkerConfig::resolve_from_settings(&settings);
        assert_eq!(workers.len(), 1);
        assert!(workers[0].endpoints.is_empty());

        let endpoints = workers[0].endpoints();
        assert_eq!(endpoints.len(), 1);
        assert_eq!(endpoints[0].url, "ws://127.0.0.1:8443/ws/agent");
        assert_eq!(
            endpoints[0].auth_token.as_ref().map(|s| s.expose_secret()),
            Some("tok-legacy")
        );
    }
}
