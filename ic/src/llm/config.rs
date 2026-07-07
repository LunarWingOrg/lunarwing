//! LLM configuration types.
//!
//! These types define the configuration for LLM providers. They are defined
//! here (in the `llm` module) so that the module is self-contained and can be
//! extracted into a standalone crate. Resolution logic (reading env vars,
//! settings) lives in `crate::config::llm`.

use std::path::PathBuf;

use secrecy::SecretString;

use crate::bootstrap::lunarwing_base_dir;
use crate::llm::registry::ProviderProtocol;
use crate::llm::session::SessionConfig;

/// Resolved configuration for a registry-based provider.
///
/// This single struct replaces what used to be five separate config types
/// (`OpenAiDirectConfig`, `OllamaConfig`, `OpenAiCompatibleConfig`,
/// `TinfoilConfig`). The `protocol` field determines which rig-core client
/// constructor to use.
#[derive(Debug, Clone)]
pub struct RegistryProviderConfig {
    /// Which API protocol to use (determines the rig-core client).
    pub protocol: ProviderProtocol,
    /// Provider identifier (e.g., "groq", "openai", "tinfoil").
    pub provider_id: String,
    /// API key (optional for some providers like Ollama).
    pub api_key: Option<SecretString>,
    /// Base URL for the API endpoint.
    pub base_url: String,
    /// Model identifier.
    pub model: String,
    /// Extra HTTP headers injected into every request.
    pub extra_headers: Vec<(String, String)>,
    /// When true, route OpenAI-compatible traffic to the Codex ChatGPT
    /// Responses API provider instead of rig-core's Chat Completions path.
    pub is_codex_chatgpt: bool,
    /// OAuth refresh token for Codex ChatGPT token refresh.
    pub refresh_token: Option<SecretString>,
    /// Path to Codex auth.json for persisting refreshed tokens.
    pub auth_path: Option<PathBuf>,
    /// Parameter names that this provider does not support (e.g., `["temperature"]`).
    /// Supported keys: `"temperature"`, `"max_tokens"`, `"stop_sequences"`.
    /// Listed parameters are stripped from requests before sending to avoid 400 errors.
    pub unsupported_params: Vec<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum CacheRetention {
    #[default]
    None,
    Short,
    Long,
}

/// Configuration for OpenAI Codex (ChatGPT subscription OAuth).
#[derive(Debug, Clone)]
pub struct OpenAiCodexConfig {
    /// Model to use (default: "gpt-5.3-codex").
    pub model: String,
    /// OAuth authorization server (default: "https://auth.openai.com").
    pub auth_endpoint: String,
    /// Responses API base URL (default: "https://chatgpt.com/backend-api/codex").
    pub api_base_url: String,
    /// OAuth client ID (default: OpenAI's public Codex client).
    pub client_id: String,
    /// Path to session file (default: ~/.lunarwing/openai_codex_session.json).
    pub session_path: PathBuf,
    /// Seconds before expiry to proactively refresh (default: 300).
    pub token_refresh_margin_secs: u64,
}

impl Default for OpenAiCodexConfig {
    fn default() -> Self {
        Self {
            model: "gpt-5.3-codex".to_string(),
            auth_endpoint: "https://auth.openai.com".to_string(),
            api_base_url: "https://chatgpt.com/backend-api/codex".to_string(),
            client_id: "app_EMoamEEZ73f0CkXaXp7hrann".to_string(),
            session_path: lunarwing_base_dir().join("openai_codex_session.json"),
            token_refresh_margin_secs: 300,
        }
    }
}

/// LLM provider configuration.
///
/// LunarWing Cloud remains the default backend with its own config struct (session auth).
/// All other providers are resolved through the provider registry, producing
/// a generic `RegistryProviderConfig`.
#[derive(Debug, Clone)]
pub struct LlmConfig {
    /// Backend identifier (e.g., "lunarwing_cloud", "openai", "groq", "tinfoil").
    pub backend: String,
    /// Session manager configuration (auth URL, token persistence path).
    /// Used by the LunarWing Cloud provider for OAuth/session-token auth.
    pub session: SessionConfig,
    /// LunarWing Cloud config (always populated, also used for embeddings).
    pub lunarwing_cloud: LunarWingCloudConfig,
    /// Resolved provider config for registry-based providers.
    /// `None` when backend is "lunarwing_cloud".
    pub provider: Option<RegistryProviderConfig>,
    /// OpenAI Codex config (populated when backend=openai_codex).
    pub openai_codex: Option<OpenAiCodexConfig>,
    /// HTTP request timeout in seconds for LLM API calls.
    /// Default: 120. Increase for local LLMs (Ollama, vLLM, LM Studio) that
    /// need more time for prompt evaluation on consumer hardware.
    pub request_timeout_secs: u64,
    /// Total wall-clock budget (seconds) for ONE logical LLM call, *including*
    /// all internal retries/backoff/failover. Keeps the call below the agent's
    /// `handle_message` turn timeout (300s) so a hung backend fails gracefully
    /// instead of stacking retries past the turn budget and triggering a
    /// hard-kill that drops the user's queued follow-up. Default: 270. 0 disables.
    /// Set via `LLM_TURN_BUDGET_SECS`. Must stay below the turn timeout.
    pub llm_turn_budget_secs: u64,
    /// Generic cheap/fast model for lightweight tasks (heartbeat, routing, evaluation).
    /// Works with any backend. Set via `LLM_CHEAP_MODEL` env var.
    /// When set, takes priority over the LunarWing Cloud-specific `LUNARWING_CLOUD_CHEAP_MODEL`.
    pub cheap_model: Option<String>,
    /// Enable cascade mode for smart routing (retry with primary if cheap model
    /// response seems uncertain). Default: true. Set via `SMART_ROUTING_CASCADE`.
    pub smart_routing_cascade: bool,
    /// Maximum retries for transient LLM errors.
    /// Set via `LLM_MAX_RETRIES`, falls back to LunarWing Cloud config value.
    pub max_retries: u32,
    /// Consecutive failures before circuit breaker opens. None = disabled.
    /// Set via `LLM_CIRCUIT_BREAKER_THRESHOLD`, falls back to LunarWing Cloud config value.
    pub circuit_breaker_threshold: Option<u32>,
    /// Seconds the circuit stays open before probing.
    /// Set via `LLM_CIRCUIT_BREAKER_RECOVERY_SECS`, falls back to LunarWing Cloud config value.
    pub circuit_breaker_recovery_secs: u64,
    /// Enable in-memory response caching.
    /// Set via `LLM_RESPONSE_CACHE_ENABLED`, falls back to LunarWing Cloud config value.
    pub response_cache_enabled: bool,
    /// TTL in seconds for cached responses.
    /// Set via `LLM_RESPONSE_CACHE_TTL_SECS`, falls back to LunarWing Cloud config value.
    pub response_cache_ttl_secs: u64,
    /// Max cached responses before LRU eviction.
    /// Set via `LLM_RESPONSE_CACHE_MAX_ENTRIES`, falls back to LunarWing Cloud config value.
    pub response_cache_max_entries: usize,
}

impl LlmConfig {
    /// Resolve the effective cheap model name.
    ///
    /// Resolution order:
    /// 1. `LLM_CHEAP_MODEL` (generic, works with any backend)
    /// 2. `LUNARWING_CLOUD_CHEAP_MODEL` (LunarWing Cloud-only, backward compatibility)
    pub fn cheap_model_name(&self) -> Option<&str> {
        self.cheap_model.as_deref().or_else(|| {
            if self.backend == "lunarwing_cloud" {
                self.lunarwing_cloud.cheap_model.as_deref()
            } else {
                None
            }
        })
    }
}

/// LunarWing Cloud configuration.
#[derive(Debug, Clone)]
pub struct LunarWingCloudConfig {
    /// Model to use (e.g., "claude-3-5-sonnet-20241022", "gpt-4o")
    pub model: String,
    /// Cheap/fast model for lightweight tasks (heartbeat, routing, evaluation).
    pub cheap_model: Option<String>,
    /// Base URL for the LunarWing Cloud API.
    pub base_url: String,
    /// API key for LunarWing Cloud Cloud.
    pub api_key: Option<SecretString>,
    /// Optional fallback model for failover.
    pub fallback_model: Option<String>,
    /// Maximum number of retries for transient errors (default: 3).
    pub max_retries: u32,
    /// Consecutive failures before circuit breaker opens. None = disabled.
    pub circuit_breaker_threshold: Option<u32>,
    /// Seconds the circuit stays open before probing (default: 30).
    pub circuit_breaker_recovery_secs: u64,
    /// Enable in-memory response caching. Default: false.
    pub response_cache_enabled: bool,
    /// TTL in seconds for cached responses (default: 3600).
    pub response_cache_ttl_secs: u64,
    /// Max cached responses before LRU eviction (default: 1000).
    pub response_cache_max_entries: usize,
    /// Cooldown duration in seconds for failover (default: 300).
    pub failover_cooldown_secs: u64,
    /// Consecutive failures before failover cooldown (default: 3).
    pub failover_cooldown_threshold: u32,
    /// Enable cascade mode for smart routing. Default: true.
    pub smart_routing_cascade: bool,
}

impl LunarWingCloudConfig {
    /// Create a minimal config suitable for listing available models.
    ///
    /// Reads `LUNARWING_CLOUD_API_KEY` from the environment and selects the
    /// appropriate base URL (cloud-api when API key is present,
    /// private.near.ai for session-token auth).
    pub(crate) fn for_model_discovery() -> Self {
        let api_key = crate::config::helpers::env_or_override("LUNARWING_CLOUD_API_KEY")
            .filter(|k| !k.is_empty())
            .map(SecretString::from);

        let default_base = if api_key.is_some() {
            "https://cloud-api.near.ai"
        } else {
            "https://private.near.ai"
        };
        let base_url = crate::config::helpers::env_or_override("LUNARWING_CLOUD_BASE_URL")
            .unwrap_or_else(|| default_base.to_string());

        Self {
            model: String::new(),
            cheap_model: None,
            base_url,
            api_key,
            fallback_model: None,
            max_retries: 3,
            circuit_breaker_threshold: None,
            circuit_breaker_recovery_secs: 30,
            response_cache_enabled: false,
            response_cache_ttl_secs: 3600,
            response_cache_max_entries: 1000,
            failover_cooldown_secs: 300,
            failover_cooldown_threshold: 3,
            smart_routing_cascade: true,
        }
    }
}
