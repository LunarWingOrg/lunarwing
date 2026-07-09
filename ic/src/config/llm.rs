use std::path::PathBuf;

use secrecy::SecretString;

use crate::bootstrap::lunarwing_base_dir;
use crate::config::helpers::{optional_env, parse_optional_env, validate_base_url};
use crate::error::ConfigError;
use crate::llm::config::*;
use crate::llm::registry::{ProviderProtocol, ProviderRegistry};
use crate::llm::session::SessionConfig;
use crate::settings::Settings;

impl LlmConfig {
    /// Create a test-friendly config without reading env vars.
    #[cfg(feature = "libsql")]
    pub fn for_testing() -> Self {
        Self {
            backend: "lunarwing_cloud".to_string(),
            session: SessionConfig {
                auth_base_url: "http://localhost:0".to_string(),
                session_path: std::env::temp_dir().join("lunarwing-test-session.json"),
            },
            lunarwing_cloud: LunarWingCloudConfig {
                model: "test-model".to_string(),
                cheap_model: None,
                base_url: "http://localhost:0".to_string(),
                api_key: None,
                fallback_model: None,
                max_retries: 0,
                circuit_breaker_threshold: None,
                circuit_breaker_recovery_secs: 30,
                response_cache_enabled: false,
                response_cache_ttl_secs: 3600,
                response_cache_max_entries: 100,
                failover_cooldown_secs: 300,
                failover_cooldown_threshold: 3,
                smart_routing_cascade: false,
            },
            provider: None,
            request_timeout_secs: 120,
            llm_turn_budget_secs: 370,
            cheap_model: None,
            smart_routing_cascade: false,
            max_retries: 0,
            circuit_breaker_threshold: None,
            circuit_breaker_recovery_secs: 30,
            response_cache_enabled: false,
            response_cache_ttl_secs: 3600,
            response_cache_max_entries: 100,
        }
    }

    /// Resolve a model name from env var -> settings.selected_model -> hardcoded default.
    fn resolve_model(
        env_var: &str,
        settings: &Settings,
        default: &str,
    ) -> Result<String, ConfigError> {
        Ok(optional_env(env_var)?
            .or_else(|| settings.selected_model.clone())
            .unwrap_or_else(|| default.to_string()))
    }

    pub(crate) fn resolve(settings: &Settings) -> Result<Self, ConfigError> {
        let registry = ProviderRegistry::load();

        // Determine backend: env var > settings > default ("lunarwing_cloud")
        let backend = if let Some(b) = optional_env("LLM_BACKEND")? {
            b
        } else if let Some(ref b) = settings.llm_backend {
            b.clone()
        } else {
            "lunarwing_cloud".to_string()
        };

        // Validate the backend is known
        let backend_lower = backend.to_lowercase();
        let is_lunarwing_cloud = backend_lower == "lunarwing_cloud";
        if matches!(backend_lower.as_str(), "openai" | "open_ai") {
            return Err(ConfigError::InvalidValue {
                key: "LLM_BACKEND".to_string(),
                message: format!(
                    "LLM_BACKEND={backend} is no longer a built-in provider. Use \
                     LLM_BACKEND=openai_compatible with LLM_BASE_URL and LLM_API_KEY instead."
                ),
            });
        }

        if !is_lunarwing_cloud && registry.find(&backend_lower).is_none() {
            tracing::warn!(
                "Unknown LLM backend '{}'. Will attempt as openai_compatible fallback.",
                backend
            );
        }

        // Session config (used by LunarWing Cloud provider for OAuth/session-token auth)
        let lunarwing_cloud_auth_url = optional_env("LUNARWING_CLOUD_AUTH_URL")?
            .unwrap_or_else(|| "https://private.lunarwing.org".to_string());
        // Only validate LunarWing Cloud URLs when LunarWing Cloud is actually being used or
        // the user explicitly set the URL. Prevents startup failures in
        // air-gapped environments that use a different backend.
        let lunarwing_cloud_api_key =
            optional_env("LUNARWING_CLOUD_API_KEY")?.map(SecretString::from);
        let lunarwing_cloud_url_explicitly_set =
            optional_env("LUNARWING_CLOUD_AUTH_URL")?.is_some();
        if is_lunarwing_cloud
            || lunarwing_cloud_url_explicitly_set
            || lunarwing_cloud_api_key.is_some()
        {
            validate_base_url(&lunarwing_cloud_auth_url, "LUNARWING_CLOUD_AUTH_URL")?;
        }
        let session = SessionConfig {
            auth_base_url: lunarwing_cloud_auth_url,
            session_path: optional_env("LUNARWING_CLOUD_SESSION_PATH")?
                .map(PathBuf::from)
                .unwrap_or_else(default_session_path),
        };

        // Always resolve LunarWing Cloud config (used for embeddings even when not the primary backend)
        let lunarwing_cloud = LunarWingCloudConfig {
            model: Self::resolve_model(
                "LUNARWING_CLOUD_MODEL",
                settings,
                crate::llm::DEFAULT_MODEL,
            )?,
            cheap_model: optional_env("LUNARWING_CLOUD_CHEAP_MODEL")?,
            base_url: {
                let url = optional_env("LUNARWING_CLOUD_BASE_URL")?.unwrap_or_else(|| {
                    if lunarwing_cloud_api_key.is_some() {
                        "https://lunarwing.org".to_string()
                    } else {
                        "https://private.lunarwing.org".to_string()
                    }
                });
                let lunarwing_cloud_base_url_explicitly_set =
                    optional_env("LUNARWING_CLOUD_BASE_URL")?.is_some();
                if is_lunarwing_cloud
                    || lunarwing_cloud_base_url_explicitly_set
                    || lunarwing_cloud_api_key.is_some()
                {
                    validate_base_url(&url, "LUNARWING_CLOUD_BASE_URL")?;
                }
                url
            },
            api_key: lunarwing_cloud_api_key,
            fallback_model: optional_env("LUNARWING_CLOUD_FALLBACK_MODEL")?,
            max_retries: parse_optional_env("LUNARWING_CLOUD_MAX_RETRIES", 3)?,
            circuit_breaker_threshold: optional_env("CIRCUIT_BREAKER_THRESHOLD")?
                .map(|s| s.parse())
                .transpose()
                .map_err(|e| ConfigError::InvalidValue {
                    key: "CIRCUIT_BREAKER_THRESHOLD".to_string(),
                    message: format!("must be a positive integer: {e}"),
                })?,
            circuit_breaker_recovery_secs: parse_optional_env("CIRCUIT_BREAKER_RECOVERY_SECS", 30)?,
            response_cache_enabled: parse_optional_env("RESPONSE_CACHE_ENABLED", false)?,
            response_cache_ttl_secs: parse_optional_env("RESPONSE_CACHE_TTL_SECS", 3600)?,
            response_cache_max_entries: parse_optional_env("RESPONSE_CACHE_MAX_ENTRIES", 1000)?,
            failover_cooldown_secs: parse_optional_env("LLM_FAILOVER_COOLDOWN_SECS", 300)?,
            failover_cooldown_threshold: parse_optional_env("LLM_FAILOVER_THRESHOLD", 3)?,
            smart_routing_cascade: parse_optional_env("SMART_ROUTING_CASCADE", true)?,
        };

        // Resolve registry provider config (for non-LunarWing Cloud backends)
        let provider = if is_lunarwing_cloud {
            None
        } else {
            Some(Self::resolve_registry_provider(
                &backend_lower,
                &registry,
                settings,
            )?)
        };

        let request_timeout_secs = parse_optional_env("LLM_REQUEST_TIMEOUT_SECS", 120)?;
        // Total budget for one logical LLM call (all internal retries included).
        // Defaults to 270s — deliberately below the 300s agent `handle_message`
        // turn timeout — so a hung backend fails gracefully instead of being
        // hard-killed mid-turn (which clears the thread's pending queue and drops
        // the user's queued follow-up). See ic/src/llm/timeout.rs. 0 disables.
        let llm_turn_budget_secs = parse_optional_env("LLM_TURN_BUDGET_SECS", 370)?;

        // Generic cheap model (works with any backend).
        // Falls back to LunarWing Cloud-specific cheap_model in provider chain logic.
        let cheap_model = optional_env("LLM_CHEAP_MODEL")?;

        // Generic smart routing cascade flag.
        // Defaults to true. Overrides LunarWing Cloud-specific smart_routing_cascade.
        let smart_routing_cascade = parse_optional_env("SMART_ROUTING_CASCADE", true)?;

        // Decorator chain settings — top-level `LLM_*` vars with fallback to
        // existing backend-specific vars for backward compatibility.
        let max_retries = optional_env("LLM_MAX_RETRIES")?
            .map(|s| s.parse::<u32>())
            .transpose()
            .map_err(|e| ConfigError::InvalidValue {
                key: "LLM_MAX_RETRIES".to_string(),
                message: format!("must be a non-negative integer: {e}"),
            })?
            .unwrap_or(lunarwing_cloud.max_retries);

        let circuit_breaker_threshold = optional_env("LLM_CIRCUIT_BREAKER_THRESHOLD")?
            .map(|s| s.parse::<u32>())
            .transpose()
            .map_err(|e| ConfigError::InvalidValue {
                key: "LLM_CIRCUIT_BREAKER_THRESHOLD".to_string(),
                message: format!("must be a positive integer: {e}"),
            })?
            .or(lunarwing_cloud.circuit_breaker_threshold);

        let circuit_breaker_recovery_secs = optional_env("LLM_CIRCUIT_BREAKER_RECOVERY_SECS")?
            .map(|s| s.parse::<u64>())
            .transpose()
            .map_err(|e| ConfigError::InvalidValue {
                key: "LLM_CIRCUIT_BREAKER_RECOVERY_SECS".to_string(),
                message: format!("must be a non-negative integer: {e}"),
            })?
            .unwrap_or(lunarwing_cloud.circuit_breaker_recovery_secs);

        let response_cache_enabled = optional_env("LLM_RESPONSE_CACHE_ENABLED")?
            .map(|s| s.parse::<bool>())
            .transpose()
            .map_err(|e| ConfigError::InvalidValue {
                key: "LLM_RESPONSE_CACHE_ENABLED".to_string(),
                message: format!("must be true or false: {e}"),
            })?
            .unwrap_or(lunarwing_cloud.response_cache_enabled);

        let response_cache_ttl_secs = optional_env("LLM_RESPONSE_CACHE_TTL_SECS")?
            .map(|s| s.parse::<u64>())
            .transpose()
            .map_err(|e| ConfigError::InvalidValue {
                key: "LLM_RESPONSE_CACHE_TTL_SECS".to_string(),
                message: format!("must be a non-negative integer: {e}"),
            })?
            .unwrap_or(lunarwing_cloud.response_cache_ttl_secs);

        let response_cache_max_entries = optional_env("LLM_RESPONSE_CACHE_MAX_ENTRIES")?
            .map(|s| s.parse::<usize>())
            .transpose()
            .map_err(|e| ConfigError::InvalidValue {
                key: "LLM_RESPONSE_CACHE_MAX_ENTRIES".to_string(),
                message: format!("must be a non-negative integer: {e}"),
            })?
            .unwrap_or(lunarwing_cloud.response_cache_max_entries);

        Ok(Self {
            backend: if is_lunarwing_cloud {
                "lunarwing_cloud".to_string()
            } else if let Some(ref p) = provider {
                p.provider_id.clone()
            } else {
                backend_lower
            },
            session,
            lunarwing_cloud,
            provider,
            request_timeout_secs,
            llm_turn_budget_secs,
            cheap_model,
            smart_routing_cascade,
            max_retries,
            circuit_breaker_threshold,
            circuit_breaker_recovery_secs,
            response_cache_enabled,
            response_cache_ttl_secs,
            response_cache_max_entries,
        })
    }

    /// Resolve a `RegistryProviderConfig` from the registry and env vars.
    fn resolve_registry_provider(
        backend: &str,
        registry: &ProviderRegistry,
        settings: &Settings,
    ) -> Result<RegistryProviderConfig, ConfigError> {
        // Look up provider definition. Fall back to openai_compatible if unknown.
        let def = registry
            .find(backend)
            .or_else(|| registry.find("openai_compatible"));

        let (
            canonical_id,
            protocol,
            api_key_env,
            base_url_env,
            model_env,
            default_model,
            default_base_url,
            extra_headers_env,
            api_key_required,
            base_url_required,
            unsupported_params,
        ) = if let Some(def) = def {
            (
                def.id.as_str(),
                def.protocol,
                def.api_key_env.as_deref(),
                def.base_url_env.as_deref(),
                def.model_env.as_str(),
                def.default_model.as_str(),
                def.default_base_url.as_deref(),
                def.extra_headers_env.as_deref(),
                def.api_key_required,
                def.base_url_required,
                def.unsupported_params.clone(),
            )
        } else {
            // Absolute fallback: treat as generic openai_completions
            (
                backend,
                ProviderProtocol::OpenAiCompletions,
                Some("LLM_API_KEY"),
                Some("LLM_BASE_URL"),
                "LLM_MODEL",
                "default",
                None,
                Some("LLM_EXTRA_HEADERS"),
                false,
                true,
                Vec::new(),
            )
        };

        // Resolve API key from env (including secrets store overlay)
        let api_key = if let Some(env_var) = api_key_env {
            optional_env(env_var)?.map(SecretString::from)
        } else {
            None
        };

        if api_key_required && api_key.is_none() {
            // Don't hard-fail here. The key might be injected later from the secrets store
            // via inject_llm_keys_from_secrets(). Log a warning instead.
            if let Some(env_var) = api_key_env {
                tracing::debug!(
                    "API key not found in {env_var} for backend '{backend}'. \
                     Will be injected from secrets store if available."
                );
            }
        }

        // Resolve base URL: env var > settings (backward compat) > registry default
        let base_url = None
            .or_else(|| {
                if let Some(env_var) = base_url_env {
                    optional_env(env_var).ok().flatten()
                } else {
                    None
                }
            })
            .or_else(|| {
                // Backward compat: check legacy settings fields
                match backend {
                    "ollama" => settings.ollama_base_url.clone(),
                    "openai_compatible" | "openrouter" => {
                        settings.openai_compatible_base_url.clone()
                    }
                    _ => None,
                }
            })
            .or_else(|| default_base_url.map(String::from))
            .unwrap_or_default();

        if base_url_required
            && base_url.is_empty()
            && let Some(env_var) = base_url_env
        {
            return Err(ConfigError::MissingRequired {
                key: env_var.to_string(),
                hint: format!("Set {env_var} when LLM_BACKEND={backend}"),
            });
        }

        // Validate base URL to prevent SSRF (#1103).
        if !base_url.is_empty() {
            let field = base_url_env.unwrap_or("LLM_BASE_URL");
            validate_base_url(&base_url, field)?;
        }

        // Resolve model
        let model = Self::resolve_model(model_env, settings, default_model)?;

        // Resolve extra headers
        let extra_headers = if let Some(env_var) = extra_headers_env {
            optional_env(env_var)?
                .map(|val| parse_extra_headers_with_key(&val, env_var))
                .transpose()?
                .unwrap_or_default(         provider_id: canonical_id.to_string(),
            api_key,
            base_url,
            model,
            extra_headers