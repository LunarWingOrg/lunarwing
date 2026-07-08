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
            openai_codex: None,
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
        let is_openai_codex = backend_lower == "openai_codex"
            || backend_lower == "openai-codex"
            || backend_lower == "codex";
        if matches!(backend_lower.as_str(), "openai" | "open_ai") {
            return Err(ConfigError::InvalidValue {
                key: "LLM_BACKEND".to_string(),
                message: format!(
                    "LLM_BACKEND={backend} is no longer a built-in provider. Use \
                     LLM_BACKEND=openai_compatible with LLM_BASE_URL and LLM_API_KEY instead."
                ),
            });
        }

        if !is_lunarwing_cloud && !is_openai_codex && registry.find(&backend_lower).is_none() {
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

        // Resolve registry provider config (for non-LunarWing Cloud, non-Codex backends)
        let provider = if is_lunarwing_cloud || is_openai_codex {
            None
        } else {
            Some(Self::resolve_registry_provider(
                &backend_lower,
                &registry,
                settings,
            )?)
        };

        // Resolve OpenAI Codex config
        let openai_codex = if is_openai_codex {
            // Model: OPENAI_CODEX_MODEL > OPENAI_MODEL > settings.selected_model > default
            let model = optional_env("OPENAI_CODEX_MODEL")?
                .or(optional_env("OPENAI_MODEL")?)
                .or_else(|| settings.selected_model.clone())
                .unwrap_or_else(|| "gpt-5.3-codex".to_string());
            let auth_endpoint = optional_env("OPENAI_CODEX_AUTH_URL")?
                .unwrap_or_else(|| "https://auth.openai.com".to_string());
            validate_base_url(&auth_endpoint, "OPENAI_CODEX_AUTH_URL")?;
            let api_base_url = optional_env("OPENAI_CODEX_API_URL")?
                .unwrap_or_else(|| "https://chatgpt.com/backend-api/codex".to_string());
            validate_base_url(&api_base_url, "OPENAI_CODEX_API_URL")?;
            let client_id = optional_env("OPENAI_CODEX_CLIENT_ID")?
                .unwrap_or_else(|| "app_EMoamEEZ73f0CkXaXp7hrann".to_string());
            let session_path = optional_env("OPENAI_CODEX_SESSION_PATH")?
                .map(PathBuf::from)
                .unwrap_or_else(|| lunarwing_base_dir().join("openai_codex_session.json"));
            let token_refresh_margin_secs =
                parse_optional_env("OPENAI_CODEX_REFRESH_MARGIN_SECS", 300)?;
            Some(OpenAiCodexConfig {
                model,
                auth_endpoint,
                api_base_url,
                client_id,
                session_path,
                token_refresh_margin_secs,
            })
        } else {
            None
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
            } else if is_openai_codex {
                "openai_codex".to_string()
            } else if let Some(ref p) = provider {
                p.provider_id.clone()
            } else {
                backend_lower
            },
            session,
            lunarwing_cloud,
            provider,
            openai_codex,
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

        // Codex auth.json override: when LLM_USE_CODEX_AUTH=true,
        // credentials from the Codex CLI's auth.json take highest priority
        // (over env vars AND secrets store). In ChatGPT mode, the base URL
        // is also overridden to the private ChatGPT backend endpoint.
        let mut codex_base_url_override: Option<String> = None;
        let codex_creds = if parse_optional_env("LLM_USE_CODEX_AUTH", false)? {
            let path = optional_env("CODEX_AUTH_PATH")?
                .map(std::path::PathBuf::from)
                .unwrap_or_else(crate::llm::codex_auth::default_codex_auth_path);
            crate::llm::codex_auth::load_codex_credentials(&path)
        } else {
            None
        };

        let codex_refresh_token = codex_creds.as_ref().and_then(|c| c.refresh_token.clone());
        let codex_auth_path = codex_creds.as_ref().and_then(|c| c.auth_path.clone());

        let api_key = if let Some(creds) = codex_creds {
            if creds.is_chatgpt_mode {
                codex_base_url_override = Some(creds.base_url().to_string());
            }
            Some(creds.token)
        } else if let Some(env_var) = api_key_env {
            // Resolve API key from env (including secrets store overlay)
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

        // Resolve base URL: codex override > env var > settings (backward compat) > registry default
        let is_codex_chatgpt = codex_base_url_override.is_some();
        let base_url = codex_base_url_override
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
                .unwrap_or_default()
        } else {
            Vec::new()
        };

        Ok(RegistryProviderConfig {
            protocol,
            provider_id: canonical_id.to_string(),
            api_key,
            base_url,
            model,
            extra_headers,
            is_codex_chatgpt,
            refresh_token: codex_refresh_token,
            auth_path: codex_auth_path,
            unsupported_params,
        })
    }
}

/// Parse `LLM_EXTRA_HEADERS` value into a list of (key, value) pairs.
///
/// Format: `Key1:Value1,Key2:Value2` (colon-separated, not `=`, because
/// header values often contain `=`).
fn parse_extra_headers_with_key(
    val: &str,
    env_var_name: &str,
) -> Result<Vec<(String, String)>, ConfigError> {
    if val.trim().is_empty() {
        return Ok(Vec::new());
    }

    let mut headers = Vec::new();
    for pair in val.split(',') {
        let pair = pair.trim();
        if pair.is_empty() {
            continue;
        }
        let Some((key, value)) = pair.split_once(':') else {
            return Err(ConfigError::InvalidValue {
                key: env_var_name.to_string(),
                message: format!("malformed header entry '{}', expected Key:Value", pair),
            });
        };
        let key = key.trim();
        if key.is_empty() {
            return Err(ConfigError::InvalidValue {
                key: env_var_name.to_string(),
                message: format!("empty header name in entry '{}'", pair),
            });
        }
        headers.push((key.to_string(), value.trim().to_string()));
    }
    Ok(headers)
}

/// Get the default session file path (~/.lunarwing/session.json).
pub fn default_session_path() -> PathBuf {
    lunarwing_base_dir().join("session.json")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::helpers::lock_env;
    use crate::settings::Settings;
    use crate::testing::credentials::*;

    /// Convenience wrapper for tests — uses "TEST_HEADERS" as the env var name.
    fn parse_extra_headers(val: &str) -> Result<Vec<(String, String)>, ConfigError> {
        parse_extra_headers_with_key(val, "TEST_HEADERS")
    }

    /// Clear all openai-compatible-related env vars.
    fn clear_openai_compatible_env() {
        // SAFETY: Only called under ENV_MUTEX in tests.
        unsafe {
            std::env::remove_var("LLM_BACKEND");
            std::env::remove_var("LLM_BASE_URL");
            std::env::remove_var("LLM_MODEL");
        }
    }

    #[test]
    fn openai_compatible_uses_selected_model_when_llm_model_unset() {
        let _guard = lock_env();
        clear_openai_compatible_env();

        let settings = Settings {
            llm_backend: Some("openai_compatible".to_string()),
            openai_compatible_base_url: Some("https://openrouter.ai/api/v1".to_string()),
            selected_model: Some("openai/gpt-5.1-codex".to_string()),
            ..Default::default()
        };

        let cfg = LlmConfig::resolve(&settings).expect("resolve should succeed");
        let provider = cfg.provider.expect("provider config should be present");

        assert_eq!(provider.model, "openai/gpt-5.1-codex");
    }

    #[test]
    fn openai_compatible_llm_model_env_overrides_selected_model() {
        let _guard = lock_env();
        clear_openai_compatible_env();
        // SAFETY: Under ENV_MUTEX.
        unsafe {
            std::env::set_var("LLM_MODEL", "openai/gpt-5-codex");
        }

        let settings = Settings {
            llm_backend: Some("openai_compatible".to_string()),
            openai_compatible_base_url: Some("https://openrouter.ai/api/v1".to_string()),
            selected_model: Some("openai/gpt-5.1-codex".to_string()),
            ..Default::default()
        };

        let cfg = LlmConfig::resolve(&settings).expect("resolve should succeed");
        let provider = cfg.provider.expect("provider config should be present");

        assert_eq!(provider.model, "openai/gpt-5-codex");

        // SAFETY: Under ENV_MUTEX.
        unsafe {
            std::env::remove_var("LLM_MODEL");
        }
    }

    #[test]
    fn test_extra_headers_parsed() {
        let result = parse_extra_headers("HTTP-Referer:https://myapp.com,X-Title:MyApp").unwrap();
        assert_eq!(
            result,
            vec![
                ("HTTP-Referer".to_string(), "https://myapp.com".to_string()),
                ("X-Title".to_string(), "MyApp".to_string()),
            ]
        );
    }

    #[test]
    fn test_extra_headers_empty_string() {
        let result = parse_extra_headers("").unwrap();
        assert!(result.is_empty());
    }

    #[test]
    fn test_extra_headers_whitespace_only() {
        let result = parse_extra_headers("  ").unwrap();
        assert!(result.is_empty());
    }

    #[test]
    fn test_extra_headers_malformed() {
        let result = parse_extra_headers("NoColonHere");
        assert!(result.is_err());
    }

    #[test]
    fn test_extra_headers_empty_key() {
        let result = parse_extra_headers(":value");
        assert!(result.is_err());
    }

    #[test]
    fn test_extra_headers_value_with_colons() {
        let result = parse_extra_headers("Authorization:Bearer abc:def").unwrap();
        assert_eq!(
            result,
            vec![("Authorization".to_string(), "Bearer abc:def".to_string())]
        );
    }

    #[test]
    fn test_extra_headers_trailing_comma() {
        let result = parse_extra_headers("X-Title:MyApp,").unwrap();
        assert_eq!(result, vec![("X-Title".to_string(), "MyApp".to_string())]);
    }

    #[test]
    fn test_extra_headers_with_spaces() {
        let result =
            parse_extra_headers(" HTTP-Referer : https://myapp.com , X-Title : MyApp ").unwrap();
        assert_eq!(
            result,
            vec![
                ("HTTP-Referer".to_string(), "https://myapp.com".to_string()),
                ("X-Title".to_string(), "MyApp".to_string()),
            ]
        );
    }

    /// Clear all ollama-related env vars.
    fn clear_ollama_env() {
        // SAFETY: Only called under ENV_MUTEX in tests.
        unsafe {
            std::env::remove_var("LLM_BACKEND");
            std::env::remove_var("OLLAMA_BASE_URL");
            std::env::remove_var("OLLAMA_MODEL");
        }
    }

    #[test]
    fn ollama_uses_selected_model_when_ollama_model_unset() {
        let _guard = lock_env();
        clear_ollama_env();

        let settings = Settings {
            llm_backend: Some("ollama".to_string()),
            selected_model: Some("llama3.2".to_string()),
            ..Default::default()
        };

        let cfg = LlmConfig::resolve(&settings).expect("resolve should succeed");
        let provider = cfg.provider.expect("provider config should be present");

        assert_eq!(provider.model, "llama3.2");
    }

    #[test]
    fn ollama_model_env_overrides_selected_model() {
        let _guard = lock_env();
        clear_ollama_env();
        // SAFETY: Under ENV_MUTEX.
        unsafe {
            std::env::set_var("OLLAMA_MODEL", "mistral:latest");
        }

        let settings = Settings {
            llm_backend: Some("ollama".to_string()),
            selected_model: Some("llama3.2".to_string()),
            ..Default::default()
        };

        let cfg = LlmConfig::resolve(&settings).expect("resolve should succeed");
        let provider = cfg.provider.expect("provider config should be present");

        assert_eq!(provider.model, "mistral:latest");

        // SAFETY: Under ENV_MUTEX.
        unsafe {
            std::env::remove_var("OLLAMA_MODEL");
        }
    }

    #[test]
    fn openai_compatible_preserves_dotted_model_name() {
        let _guard = lock_env();
        clear_openai_compatible_env();

        let settings = Settings {
            llm_backend: Some("openai_compatible".to_string()),
            openai_compatible_base_url: Some("http://localhost:11434/v1".to_string()),
            selected_model: Some("llama3.2".to_string()),
            ..Default::default()
        };

        let cfg = LlmConfig::resolve(&settings).expect("resolve should succeed");
        let provider = cfg.provider.expect("provider config should be present");

        assert_eq!(
            provider.model, "llama3.2",
            "model name with dot must not be truncated"
        );
    }

    #[test]
    fn direct_openai_backend_is_rejected_even_when_compatible_config_exists() {
        let _guard = lock_env();
        clear_openai_compatible_env();

        let settings = Settings {
            llm_backend: Some("openai".to_string()),
            ..Default::default()
        };

        // SAFETY: Under ENV_MUTEX.
        unsafe {
            std::env::set_var("LLM_BASE_URL", "http://localhost:8080/v1");
            std::env::set_var("LLM_API_KEY", TEST_API_KEY);
        }

        let err = LlmConfig::resolve(&settings).expect_err("openai backend must be rejected");
        let message = err.to_string();
        assert!(message.contains("LLM_BACKEND=openai"), "{message}");
        assert!(message.contains("openai_compatible"), "{message}");
    }

    #[test]
    fn registry_provider_resolves_ollama() {
        let _guard = lock_env();
        // SAFETY: Under ENV_MUTEX.
        unsafe {
            std::env::remove_var("LLM_BACKEND");
            std::env::remove_var("OLLAMA_BASE_URL");
            std::env::remove_var("OLLAMA_MODEL");
        }

        let settings = Settings {
            llm_backend: Some("ollama".to_string()),
            ..Default::default()
        };

        let cfg = LlmConfig::resolve(&settings).expect("resolve should succeed");
        assert_eq!(cfg.backend, "ollama");
        let provider = cfg.provider.expect("provider config should be present");
        assert_eq!(provider.base_url, "http://localhost:11434");
        assert_eq!(provider.model, "llama3");
    }

    #[test]
    fn direct_openai_alias_is_rejected_even_when_compatible_config_exists() {
        let _guard = lock_env();
        clear_openai_compatible_env();

        let settings = Settings {
            llm_backend: Some("open_ai".to_string()),
            ..Default::default()
        };

        // SAFETY: Under ENV_MUTEX.
        unsafe {
            std::env::set_var("LLM_BASE_URL", "http://localhost:8080/v1");
            std::env::set_var("LLM_API_KEY", TEST_API_KEY);
        }

        let err = LlmConfig::resolve(&settings).expect_err("open_ai alias must be rejected");
        let message = err.to_string();
        assert!(message.contains("LLM_BACKEND=open_ai"), "{message}");
        assert!(message.contains("openai_compatible"), "{message}");
    }

    #[test]
    fn lunarwing_cloud_backend_has_no_registry_provider() {
        let _guard = lock_env();
        // SAFETY: Under ENV_MUTEX.
        unsafe {
            std::env::remove_var("LLM_BACKEND");
        }

        let settings = Settings::default();
        let cfg = LlmConfig::resolve(&settings).expect("resolve should succeed");
        assert_eq!(cfg.backend, "lunarwing_cloud");
        assert!(cfg.provider.is_none());
    }

    #[test]
    fn backend_alias_normalized_to_canonical_id() {
        let _guard = lock_env();
        clear_openai_compatible_env();
        // SAFETY: Under ENV_MUTEX.
        unsafe {
            std::env::set_var("LLM_BACKEND", "compatible");
            std::env::set_var("LLM_BASE_URL", "http://localhost:8080/v1");
        }

        let settings = Settings::default();
        let cfg = LlmConfig::resolve(&settings).expect("resolve should succeed");
        assert_eq!(
            cfg.backend, "openai_compatible",
            "alias 'compatible' should be normalized to canonical 'openai_compatible'"
        );
        let provider = cfg.provider.expect("should have provider config");
        assert_eq!(provider.provider_id, "openai_compatible");

        // SAFETY: Under ENV_MUTEX.
        unsafe {
            std::env::remove_var("LLM_BACKEND");
            std::env::remove_var("LLM_BASE_URL");
        }
    }

    #[test]
    fn unknown_backend_falls_back_to_openai_compatible() {
        let _guard = lock_env();
        clear_openai_compatible_env();
        // SAFETY: Under ENV_MUTEX.
        unsafe {
            std::env::set_var("LLM_BACKEND", "some_custom_provider");
            std::env::set_var("LLM_BASE_URL", "http://localhost:8080/v1");
        }

        let settings = Settings::default();
        let cfg = LlmConfig::resolve(&settings).expect("resolve should succeed");
        assert_eq!(cfg.backend, "openai_compatible");
        let provider = cfg.provider.expect("should have provider config");
        assert_eq!(provider.provider_id, "openai_compatible");
        assert_eq!(provider.base_url, "http://localhost:8080/v1");

        // SAFETY: Under ENV_MUTEX.
        unsafe {
            std::env::remove_var("LLM_BACKEND");
            std::env::remove_var("LLM_BASE_URL");
        }
    }

    #[test]
    fn lunarwing_cloud_backend_resolves_to_lunarwing_cloud() {
        let _guard = lock_env();

        // SAFETY: Under ENV_MUTEX.
        unsafe {
            std::env::set_var("LLM_BACKEND", "lunarwing_cloud");
        }
        let settings = Settings::default();
        let cfg = LlmConfig::resolve(&settings).expect("resolve should succeed");
        assert_eq!(cfg.backend, "lunarwing_cloud");
        assert!(
            cfg.provider.is_none(),
            "lunarwing_cloud should not have a registry provider"
        );

        // SAFETY: Under ENV_MUTEX.
        unsafe {
            std::env::remove_var("LLM_BACKEND");
        }
    }

    #[test]
    fn base_url_resolution_priority() {
        let _guard = lock_env();
        clear_openai_compatible_env();

        // SAFETY: Under ENV_MUTEX.
        unsafe {
            std::env::set_var("LLM_BACKEND", "openai_compatible");
            std::env::set_var("LLM_BASE_URL", "http://localhost:8000/v1");
        }

        let settings = Settings {
            llm_backend: Some("openai_compatible".to_string()),
            openai_compatible_base_url: Some("http://localhost:9000/v1".to_string()),
            ..Default::default()
        };

        let cfg = LlmConfig::resolve(&settings).expect("resolve should succeed");
        let provider = cfg.provider.expect("should have provider config");
        assert_eq!(
            provider.base_url, "http://localhost:8000/v1",
            "env var should take priority over settings"
        );

        // Now without env var, settings should win over registry default
        unsafe {
            std::env::remove_var("LLM_BASE_URL");
        }

        let cfg = LlmConfig::resolve(&settings).expect("resolve should succeed");
        let provider = cfg.provider.expect("should have provider config");
        assert_eq!(
            provider.base_url, "http://localhost:9000/v1",
            "settings should take priority over registry default"
        );

        // SAFETY: Under ENV_MUTEX.
        unsafe {
            std::env::remove_var("LLM_BACKEND");
        }
    }

    #[test]
    fn test_request_timeout_default() {
        let _guard = lock_env();
        // SAFETY: Under ENV_MUTEX.
        unsafe {
            std::env::remove_var("LLM_REQUEST_TIMEOUT_SECS");
        }
        let config = LlmConfig::resolve(&Settings::default()).expect("resolve");
        assert_eq!(config.request_timeout_secs, 120);
    }

    #[test]
    fn test_request_timeout_configurable() {
        let _guard = lock_env();
        // SAFETY: Under ENV_MUTEX.
        unsafe {
            std::env::set_var("LLM_REQUEST_TIMEOUT_SECS", "300");
        }
        let config = LlmConfig::resolve(&Settings::default()).expect("resolve");
        assert_eq!(config.request_timeout_secs, 300);
        // SAFETY: Cleanup
        unsafe {
            std::env::remove_var("LLM_REQUEST_TIMEOUT_SECS");
        }
    }

    // ── OpenAI Codex tests ──────────────────────────────────────────

    /// Clear all openai-codex-related env vars.
    fn clear_openai_codex_env() {
        // SAFETY: Only called under ENV_MUTEX in tests.
        unsafe {
            std::env::remove_var("LLM_BACKEND");
            std::env::remove_var("OPENAI_CODEX_MODEL");
            std::env::remove_var("OPENAI_MODEL");
        }
    }

    #[test]
    fn openai_codex_resolves_config() {
        let _guard = lock_env();
        clear_openai_codex_env();

        let settings = Settings {
            llm_backend: Some("openai_codex".to_string()),
            ..Default::default()
        };

        let cfg = LlmConfig::resolve(&settings).expect("resolve should succeed");
        assert_eq!(cfg.backend, "openai_codex");
        let codex = cfg.openai_codex.expect("codex config should be present");
        assert_eq!(codex.model, "gpt-5.3-codex"); // default
        assert!(
            cfg.provider.is_none(),
            "codex should not use registry provider"
        );
    }

    #[test]
    fn openai_codex_model_env_resolution() {
        let _guard = lock_env();
        clear_openai_codex_env();
        // SAFETY: Under ENV_MUTEX.
        unsafe {
            std::env::set_var("OPENAI_CODEX_MODEL", "o3-pro");
        }

        let settings = Settings {
            llm_backend: Some("openai_codex".to_string()),
            ..Default::default()
        };

        let cfg = LlmConfig::resolve(&settings).expect("resolve should succeed");
        let codex = cfg.openai_codex.expect("codex config should be present");
        assert_eq!(codex.model, "o3-pro");

        // SAFETY: Under ENV_MUTEX.
        unsafe {
            std::env::remove_var("OPENAI_CODEX_MODEL");
        }
    }

    #[test]
    fn openai_codex_falls_back_to_openai_model() {
        let _guard = lock_env();
        clear_openai_codex_env();
        // SAFETY: Under ENV_MUTEX.
        unsafe {
            std::env::set_var("OPENAI_MODEL", "gpt-4o");
        }

        let settings = Settings {
            llm_backend: Some("openai_codex".to_string()),
            ..Default::default()
        };

        let cfg = LlmConfig::resolve(&settings).expect("resolve should succeed");
        let codex = cfg.openai_codex.expect("codex config should be present");
        assert_eq!(codex.model, "gpt-4o");

        // SAFETY: Under ENV_MUTEX.
        unsafe {
            std::env::remove_var("OPENAI_MODEL");
        }
    }

    #[test]
    fn openai_codex_falls_back_to_selected_model() {
        let _guard = lock_env();
        clear_openai_codex_env();

        let settings = Settings {
            llm_backend: Some("openai_codex".to_string()),
            selected_model: Some("gpt-4o-mini".to_string()),
            ..Default::default()
        };

        let cfg = LlmConfig::resolve(&settings).expect("resolve should succeed");
        let codex = cfg.openai_codex.expect("codex config should be present");
        assert_eq!(codex.model, "gpt-4o-mini");
    }

    /// Regression: SSRF validation on OPENAI_CODEX_API_URL (#1103).
    #[test]
    fn openai_codex_rejects_ssrf_api_url() {
        let _guard = lock_env();
        clear_openai_codex_env();
        // SAFETY: Under ENV_MUTEX.
        unsafe {
            std::env::set_var(
                "OPENAI_CODEX_API_URL",
                "http://169.254.169.254/latest/meta-data",
            );
        }

        let settings = Settings {
            llm_backend: Some("openai_codex".to_string()),
            ..Default::default()
        };

        let err = LlmConfig::resolve(&settings).unwrap_err();
        let msg = err.to_string();
        assert!(
            msg.contains("OPENAI_CODEX_API_URL"),
            "error should reference the field name: {msg}"
        );

        // SAFETY: Under ENV_MUTEX.
        unsafe {
            std::env::remove_var("OPENAI_CODEX_API_URL");
        }
    }

    /// Regression: SSRF validation on OPENAI_CODEX_AUTH_URL (#1103).
    #[test]
    fn openai_codex_rejects_ssrf_auth_url() {
        let _guard = lock_env();
        clear_openai_codex_env();
        // SAFETY: Under ENV_MUTEX.
        unsafe {
            std::env::set_var("OPENAI_CODEX_AUTH_URL", "http://10.0.0.1");
        }

        let settings = Settings {
            llm_backend: Some("openai_codex".to_string()),
            ..Default::default()
        };

        let err = LlmConfig::resolve(&settings).unwrap_err();
        let msg = err.to_string();
        assert!(
            msg.contains("OPENAI_CODEX_AUTH_URL"),
            "error should reference the field name: {msg}"
        );

        // SAFETY: Under ENV_MUTEX.
        unsafe {
            std::env::remove_var("OPENAI_CODEX_AUTH_URL");
        }
    }

    // ── Decorator chain LLM_* env var tests ────────────────────────

    #[test]
    fn llm_max_retries_overrides_lunarwing_cloud_default() {
        let _guard = lock_env();
        // SAFETY: Under ENV_MUTEX.
        unsafe {
            std::env::remove_var("LLM_BACKEND");
            std::env::set_var("LLM_MAX_RETRIES", "7");
        }

        let cfg = LlmConfig::resolve(&Settings::default()).expect("resolve");
        assert_eq!(cfg.max_retries, 7);

        // SAFETY: Under ENV_MUTEX.
        unsafe {
            std::env::remove_var("LLM_MAX_RETRIES");
        }
    }

    #[test]
    fn llm_max_retries_falls_back_to_lunarwing_cloud() {
        let _guard = lock_env();
        // SAFETY: Under ENV_MUTEX.
        unsafe {
            std::env::remove_var("LLM_BACKEND");
            std::env::remove_var("LLM_MAX_RETRIES");
        }

        let cfg = LlmConfig::resolve(&Settings::default()).expect("resolve");
        assert_eq!(
            cfg.max_retries, 3,
            "should fall back to LUNARWING_CLOUD_MAX_RETRIES default"
        );
    }

    #[test]
    fn llm_max_retries_rejects_invalid() {
        let _guard = lock_env();
        // SAFETY: Under ENV_MUTEX.
        unsafe {
            std::env::remove_var("LLM_BACKEND");
            std::env::set_var("LLM_MAX_RETRIES", "not_a_number");
        }

        let err = LlmConfig::resolve(&Settings::default()).unwrap_err();
        let msg = err.to_string();
        assert!(
            msg.contains("LLM_MAX_RETRIES"),
            "error should name the var: {msg}"
        );

        // SAFETY: Under ENV_MUTEX.
        unsafe {
            std::env::remove_var("LLM_MAX_RETRIES");
        }
    }

    #[test]
    fn llm_response_cache_enabled_overrides_lunarwing_cloud() {
        let _guard = lock_env();
        // SAFETY: Under ENV_MUTEX.
        unsafe {
            std::env::remove_var("LLM_BACKEND");
            std::env::set_var("LLM_RESPONSE_CACHE_ENABLED", "true");
        }

        let cfg = LlmConfig::resolve(&Settings::default()).expect("resolve");
        assert!(cfg.response_cache_enabled);

        // SAFETY: Under ENV_MUTEX.
        unsafe {
            std::env::remove_var("LLM_RESPONSE_CACHE_ENABLED");
        }
    }

    #[test]
    fn llm_circuit_breaker_threshold_overrides_lunarwing_cloud() {
        let _guard = lock_env();
        // SAFETY: Under ENV_MUTEX.
        unsafe {
            std::env::remove_var("LLM_BACKEND");
            std::env::set_var("LLM_CIRCUIT_BREAKER_THRESHOLD", "10");
        }

        let cfg = LlmConfig::resolve(&Settings::default()).expect("resolve");
        assert_eq!(cfg.circuit_breaker_threshold, Some(10));

        // SAFETY: Under ENV_MUTEX.
        unsafe {
            std::env::remove_var("LLM_CIRCUIT_BREAKER_THRESHOLD");
        }
    }

    // ── Conditional LunarWing Cloud URL validation tests ────────────────────

    #[test]
    fn non_lunarwing_cloud_backend_skips_lunarwing_cloud_url_validation() {
        let _guard = lock_env();
        clear_openai_compatible_env();
        // SAFETY: Under ENV_MUTEX.
        unsafe {
            std::env::remove_var("LUNARWING_CLOUD_AUTH_URL");
            std::env::remove_var("LUNARWING_CLOUD_BASE_URL");
            std::env::remove_var("LUNARWING_CLOUD_API_KEY");
        }

        let settings = Settings {
            llm_backend: Some("openai_compatible".to_string()),
            openai_compatible_base_url: Some("http://localhost:8000/v1".to_string()),
            ..Default::default()
        };

        // Should succeed even though LunarWing Cloud default URLs point to external hosts.
        // Previously this could fail in air-gapped environments.
        let result = LlmConfig::resolve(&settings);
        assert!(
            result.is_ok(),
            "non-LunarWing Cloud backend should not fail due to LunarWing Cloud URL validation: {:?}",
            result.err()
        );
    }
}
