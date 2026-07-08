//! LLM integration for the agent.
//!
//! Supports multiple backends:
//! - **LunarWing Cloud** (default): Session token or API key auth via Chat Completions API
//! - **Ollama**: Local model inference
//! - **OpenAI-compatible**: Any endpoint that speaks the OpenAI Chat Completions API

pub mod circuit_breaker;
pub(crate) mod codex_auth;
mod codex_chatgpt;
pub mod config;
pub mod costs;
pub mod error;
pub mod failover;
mod lunarwing_cloud_chat;
pub mod oauth_helpers;
pub mod openai_codex_provider;
pub mod openai_codex_session;
mod provider;
mod reasoning;
pub mod recording;
pub mod registry;
pub mod response_cache;
pub mod retry;
mod rig_adapter;
pub mod session;
pub mod smart_routing;
mod timeout;
mod token_refreshing;
pub mod transcription;

#[cfg(test)]
mod codex_test_helpers;

pub mod image_models;
pub mod models;
pub mod reasoning_models;
pub mod vision_models;

pub use circuit_breaker::{CircuitBreakerConfig, CircuitBreakerProvider};
pub use config::{LlmConfig, LunarWingCloudConfig, OpenAiCodexConfig, RegistryProviderConfig};
pub use error::LlmError;
pub use failover::{CooldownConfig, FailoverProvider};
pub use lunarwing_cloud_chat::{
    DEFAULT_MODEL, LunarWingCloudChatProvider, ModelInfo, default_models,
};
pub use openai_codex_provider::OpenAiCodexProvider;
pub use openai_codex_session::{OpenAiCodexSession, OpenAiCodexSessionManager};
pub use provider::{
    ChatMessage, CompletionRequest, CompletionResponse, ContentPart, FinishReason, ImageUrl,
    LlmProvider, ModelMetadata, Role, ToolCall, ToolCompletionRequest, ToolCompletionResponse,
    ToolDefinition, ToolResult, generate_tool_call_id,
};
pub use reasoning::{
    ActionPlan, Reasoning, ReasoningContext, RespondOutput, RespondResult, SILENT_REPLY_TOKEN,
    TOOL_INTENT_NUDGE, TokenUsage, ToolSelection, is_silent_reply, llm_signals_tool_intent,
    user_signals_execution_intent,
};
pub use recording::RecordingLlm;
pub use registry::{ProviderDefinition, ProviderProtocol, ProviderRegistry};
pub use response_cache::{CachedProvider, ResponseCacheConfig};
pub use retry::{RetryConfig, RetryProvider};
pub use rig_adapter::RigAdapter;
pub use session::{SessionConfig, SessionManager, create_session_manager};
pub use smart_routing::{SmartRoutingConfig, SmartRoutingProvider, TaskComplexity};
pub use timeout::TimeoutProvider;
pub use token_refreshing::TokenRefreshingProvider;

use std::sync::Arc;

use rig::client::CompletionClient;
use secrecy::ExposeSecret;

// LlmConfig, LunarWingCloudConfig, RegistryProviderConfig, and LlmError are
// re-exported via `pub use` above from config and error submodules.

/// Create an LLM provider based on configuration.
///
/// - LunarWing Cloud backend: Uses session manager for authentication
/// - Registry providers: Looked up by protocol and constructed generically
pub async fn create_llm_provider(
    config: &LlmConfig,
    session: Arc<SessionManager>,
) -> Result<Arc<dyn LlmProvider>, LlmError> {
    let timeout = config.request_timeout_secs;

    if config.backend == "lunarwing_cloud" {
        return create_llm_provider_with_config(&config.lunarwing_cloud, session, timeout);
    }

    if config.backend == "openai_codex" {
        return Err(LlmError::RequestFailed {
            provider: "openai_codex".to_string(),
            reason:
                "OpenAI Codex uses a dedicated factory path. Use build_provider_chain() instead of create_llm_provider()."
                    .to_string(),
        });
    }

    let reg_config = config
        .provider
        .as_ref()
        .ok_or_else(|| LlmError::AuthFailed {
            provider: config.backend.clone(),
        })?;

    create_registry_provider(reg_config, timeout)
}

/// Create an LLM provider from a `LunarWingCloudConfig` directly.
///
/// This is useful when constructing additional providers for failover,
/// where only the model name differs from the primary config.
pub fn create_llm_provider_with_config(
    config: &LunarWingCloudConfig,
    session: Arc<SessionManager>,
    request_timeout_secs: u64,
) -> Result<Arc<dyn LlmProvider>, LlmError> {
    let auth_mode = if config.api_key.is_some() {
        "API key"
    } else {
        "session token"
    };
    tracing::debug!(
        model = %config.model,
        base_url = %config.base_url,
        auth = auth_mode,
        timeout_secs = request_timeout_secs,
        "Using LunarWing Cloud (Chat Completions API)"
    );
    Ok(Arc::new(LunarWingCloudChatProvider::new_with_timeout(
        config.clone(),
        session,
        request_timeout_secs,
    )?))
}

/// Create a provider from a registry-resolved config.
///
/// Dispatches on `RegistryProviderConfig::protocol` to build the appropriate
/// rig-core client. This single function replaces what used to be 5 separate
/// `create_*_provider` functions.
fn create_registry_provider(
    config: &RegistryProviderConfig,
    request_timeout_secs: u64,
) -> Result<Arc<dyn LlmProvider>, LlmError> {
    // Codex ChatGPT mode: use the Responses API provider
    if config.is_codex_chatgpt {
        return create_codex_chatgpt_from_registry(config, request_timeout_secs);
    }

    match config.protocol {
        ProviderProtocol::OpenAiCompletions => {
            create_openai_compat_from_registry(config, request_timeout_secs)
        }
        ProviderProtocol::Ollama => create_ollama_from_registry(config, request_timeout_secs),
    }
}

fn create_codex_chatgpt_from_registry(
    config: &RegistryProviderConfig,
    request_timeout_secs: u64,
) -> Result<Arc<dyn LlmProvider>, LlmError> {
    let api_key = config
        .api_key
        .as_ref()
        .cloned()
        .ok_or_else(|| LlmError::AuthFailed {
            provider: "codex_chatgpt".to_string(),
        })?;

    tracing::info!(
        configured_model = %config.model,
        base_url = %config.base_url,
        "Using Codex ChatGPT provider (Responses API) — model detection deferred to first call"
    );

    let provider = codex_chatgpt::CodexChatGptProvider::with_lazy_model(
        &config.base_url,
        api_key,
        &config.model,
        config.refresh_token.clone(),
        config.auth_path.clone(),
        request_timeout_secs,
    );

    Ok(Arc::new(provider))
}

fn create_openai_compat_from_registry(
    config: &RegistryProviderConfig,
    request_timeout_secs: u64,
) -> Result<Arc<dyn LlmProvider>, LlmError> {
    use rig::providers::openai;

    let mut extra_headers = reqwest::header::HeaderMap::new();
    for (key, value) in &config.extra_headers {
        let name = match reqwest::header::HeaderName::from_bytes(key.as_bytes()) {
            Ok(n) => n,
            Err(e) => {
                tracing::warn!(header = %key, error = %e, "Skipping extra header: invalid name");
                continue;
            }
        };
        let val = match reqwest::header::HeaderValue::from_str(value) {
            Ok(v) => v,
            Err(e) => {
                tracing::warn!(header = %key, error = %e, "Skipping extra header: invalid value");
                continue;
            }
        };
        extra_headers.insert(name, val);
    }

    let api_key = config
        .api_key
        .as_ref()
        .map(|k| k.expose_secret().to_string())
        .unwrap_or_else(|| {
            tracing::warn!(
                provider = %config.provider_id,
                "No API key configured for {}. Requests will likely fail with 401. \
                 Check your .env or secrets store.",
                config.provider_id,
            );
            "no-key".to_string()
        });

    let http_client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(request_timeout_secs))
        .build()
        .map_err(|e| LlmError::RequestFailed {
            provider: config.provider_id.clone(),
            reason: format!("Failed to create HTTP client: {e}"),
        })?;

    let mut builder = openai::Client::<reqwest::Client>::builder()
        .api_key(&api_key)
        .http_client(http_client);
    if !config.base_url.is_empty() {
        builder = builder.base_url(&config.base_url);
    }
    if !extra_headers.is_empty() {
        builder = builder.http_headers(extra_headers);
    }

    let client = builder.build().map_err(|e| LlmError::RequestFailed {
        provider: config.provider_id.clone(),
        reason: format!("Failed to create OpenAI-compatible client: {e}"),
    })?;

    let client = client.completions_api();
    let model = client.completion_model(&config.model);

    tracing::debug!(
        provider = %config.provider_id,
        model = %config.model,
        base_url = %config.base_url,
        timeout_secs = request_timeout_secs,
        "Using OpenAI-compatible provider"
    );

    let adapter = RigAdapter::new(model, &config.model)
        .with_unsupported_params(config.unsupported_params.clone());
    Ok(Arc::new(adapter))
}

fn create_ollama_from_registry(
    config: &RegistryProviderConfig,
    request_timeout_secs: u64,
) -> Result<Arc<dyn LlmProvider>, LlmError> {
    use rig::client::Nothing;
    use rig::providers::ollama;

    let http_client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(request_timeout_secs))
        .build()
        .map_err(|e| LlmError::RequestFailed {
            provider: config.provider_id.clone(),
            reason: format!("Failed to create HTTP client: {e}"),
        })?;

    let client = ollama::Client::<reqwest::Client>::builder()
        .base_url(&config.base_url)
        .api_key(Nothing)
        .http_client(http_client)
        .build()
        .map_err(|e| LlmError::RequestFailed {
            provider: config.provider_id.clone(),
            reason: format!("Failed to create Ollama client: {e}"),
        })?;

    let model = client.completion_model(&config.model);

    tracing::debug!(
        provider = %config.provider_id,
        model = %config.model,
        base_url = %config.base_url,
        timeout_secs = request_timeout_secs,
        "Using Ollama provider"
    );

    let adapter = RigAdapter::new(model, &config.model)
        .with_unsupported_params(config.unsupported_params.clone());
    Ok(Arc::new(adapter))
}

/// Create an OpenAI Codex provider with OAuth authentication.
///
/// This is async because it needs to ensure authentication before
/// creating the provider (which requires a valid Bearer token).
///
/// Uses the Responses API (`chatgpt.com/backend-api/codex/responses`)
/// instead of the Chat Completions API, matching OpenClaw's approach.
async fn create_openai_codex_provider(
    config: &LlmConfig,
) -> Result<Arc<dyn LlmProvider>, LlmError> {
    let codex = config
        .openai_codex
        .as_ref()
        .ok_or_else(|| LlmError::AuthFailed {
            provider: "openai_codex".to_string(),
        })?;

    let session_mgr = Arc::new(OpenAiCodexSessionManager::new(codex.clone())?);
    session_mgr.ensure_authenticated().await?;

    let token = session_mgr.get_access_token().await?;

    let provider = Arc::new(OpenAiCodexProvider::new(
        &codex.model,
        &codex.api_base_url,
        token.expose_secret(),
        config.request_timeout_secs,
    )?);

    tracing::info!(
        "Using OpenAI Codex (Responses API, model: {}, base: {})",
        codex.model,
        codex.api_base_url,
    );

    Ok(Arc::new(TokenRefreshingProvider::new(
        provider,
        session_mgr,
    )))
}

/// Create a cheap/fast LLM provider for lightweight tasks (heartbeat, routing, evaluation).
///
/// Resolution order:
/// 1. `LLM_CHEAP_MODEL` (generic, works with any backend)
/// 2. `LUNARWING_CLOUD_CHEAP_MODEL` (LunarWing Cloud-only, backward compatibility)
///
/// Returns `None` if no cheap model is configured.
pub fn create_cheap_llm_provider(
    config: &LlmConfig,
    session: Arc<SessionManager>,
) -> Result<Option<Arc<dyn LlmProvider>>, LlmError> {
    let Some(cheap_model) = config.cheap_model_name() else {
        return Ok(None);
    };

    create_cheap_provider_for_backend(config, session, cheap_model)
}

/// Create a cheap provider for a specific backend.
///
/// Handles backend-specific provider construction:
/// - `lunarwing_cloud` — clones LunarWingCloudConfig, swaps model, uses `create_llm_provider_with_config`
/// - All others — clones `RegistryProviderConfig`, swaps model, uses `create_registry_provider`
fn create_cheap_provider_for_backend(
    config: &LlmConfig,
    session: Arc<SessionManager>,
    cheap_model: &str,
) -> Result<Option<Arc<dyn LlmProvider>>, LlmError> {
    if config.backend == "lunarwing_cloud" {
        let mut cheap_config = config.lunarwing_cloud.clone();
        cheap_config.model = cheap_model.to_string();
        let provider =
            create_llm_provider_with_config(&cheap_config, session, config.request_timeout_secs)?;
        return Ok(Some(provider));
    }

    // Registry-based provider: clone config and swap model
    let reg_config = config.provider.as_ref().ok_or_else(|| LlmError::RequestFailed {
        provider: config.backend.clone(),
        reason: format!(
            "Cannot create cheap provider for backend '{}': no registry provider config available",
            config.backend
        ),
    })?;

    let mut cheap_reg_config = reg_config.clone();
    cheap_reg_config.model = cheap_model.to_string();
    let provider = create_registry_provider(&cheap_reg_config, config.request_timeout_secs)?;
    Ok(Some(provider))
}

/// Build the full LLM provider chain with all configured wrappers.
///
/// Applies decorators in this order:
/// 1. Raw provider (from config)
/// 2. RetryProvider (per-provider retry with exponential backoff)
/// 3. SmartRoutingProvider (cheap/primary split when cheap model is configured)
/// 4. FailoverProvider (fallback model when primary fails)
/// 5. CircuitBreakerProvider (fast-fail when backend is degraded)
/// 6. CachedProvider (in-memory response cache)
///
/// Also returns a separate cheap LLM provider for heartbeat/evaluation (not
/// part of the chain — it's a standalone provider for explicitly cheap tasks).
///
/// This is the single source of truth for provider chain construction,
/// called by both `main.rs` and `app.rs`.
#[allow(clippy::type_complexity)]
pub async fn build_provider_chain(
    config: &LlmConfig,
    session: Arc<SessionManager>,
) -> Result<
    (
        Arc<dyn LlmProvider>,
        Option<Arc<dyn LlmProvider>>,
        Option<Arc<RecordingLlm>>,
    ),
    LlmError,
> {
    let llm: Arc<dyn LlmProvider> = if config.backend == "openai_codex" {
        create_openai_codex_provider(config).await?
    } else {
        create_llm_provider(config, session.clone()).await?
    };
    tracing::debug!("LLM provider initialized: {}", llm.model_name());

    // 1. Retry
    let retry_config = RetryConfig {
        max_retries: config.max_retries,
    };
    let llm: Arc<dyn LlmProvider> = if retry_config.max_retries > 0 {
        tracing::debug!(
            max_retries = retry_config.max_retries,
            "LLM retry wrapper enabled"
        );
        Arc::new(RetryProvider::new(llm, retry_config.clone()))
    } else {
        llm
    };

    // 2. Smart routing (cheap/primary split)
    let llm: Arc<dyn LlmProvider> = if let Some(cheap_model) = config.cheap_model_name() {
        let cheap = create_cheap_provider_for_backend(config, session.clone(), cheap_model)?
            .ok_or_else(|| LlmError::RequestFailed {
                provider: config.backend.clone(),
                reason: format!(
                    "Failed to create cheap provider for model '{cheap_model}' on backend '{}'",
                    config.backend
                ),
            })?;
        let cheap: Arc<dyn LlmProvider> = if retry_config.max_retries > 0 {
            Arc::new(RetryProvider::new(cheap, retry_config.clone()))
        } else {
            cheap
        };
        tracing::debug!(
            primary = %llm.model_name(),
            cheap = %cheap.model_name(),
            "Smart routing enabled"
        );
        Arc::new(SmartRoutingProvider::new(
            llm,
            cheap,
            SmartRoutingConfig {
                cascade_enabled: config.smart_routing_cascade,
                ..SmartRoutingConfig::default()
            },
        ))
    } else {
        llm
    };

    // 3. Failover
    let llm: Arc<dyn LlmProvider> =
        if let Some(ref fallback_model) = config.lunarwing_cloud.fallback_model {
            if fallback_model == &config.lunarwing_cloud.model {
                tracing::warn!(
                    "fallback_model is the same as primary model, failover may not be effective"
                );
            }
            let mut fallback_config = config.lunarwing_cloud.clone();
            fallback_config.model = fallback_model.clone();
            let fallback = create_llm_provider_with_config(
                &fallback_config,
                session.clone(),
                config.request_timeout_secs,
            )?;
            tracing::debug!(
                primary = %llm.model_name(),
                fallback = %fallback.model_name(),
                "LLM failover enabled"
            );
            let fallback: Arc<dyn LlmProvider> = if retry_config.max_retries > 0 {
                Arc::new(RetryProvider::new(fallback, retry_config.clone()))
            } else {
                fallback
            };
            let cooldown_config = CooldownConfig {
                cooldown_duration: std::time::Duration::from_secs(
                    config.lunarwing_cloud.failover_cooldown_secs,
                ),
                failure_threshold: config.lunarwing_cloud.failover_cooldown_threshold,
            };
            Arc::new(FailoverProvider::with_cooldown(
                vec![llm, fallback],
                cooldown_config,
            )?)
        } else {
            llm
        };

    // 4. Circuit breaker
    let llm: Arc<dyn LlmProvider> = if let Some(threshold) = config.circuit_breaker_threshold {
        let cb_config = CircuitBreakerConfig {
            failure_threshold: threshold,
            recovery_timeout: std::time::Duration::from_secs(config.circuit_breaker_recovery_secs),
            ..CircuitBreakerConfig::default()
        };
        tracing::debug!(
            threshold,
            recovery_secs = config.circuit_breaker_recovery_secs,
            "LLM circuit breaker enabled"
        );
        Arc::new(CircuitBreakerProvider::new(llm, cb_config))
    } else {
        llm
    };

    // 5. Response cache
    let llm: Arc<dyn LlmProvider> = if config.response_cache_enabled {
        let rc_config = ResponseCacheConfig {
            ttl: std::time::Duration::from_secs(config.response_cache_ttl_secs),
            max_entries: config.response_cache_max_entries,
        };
        tracing::debug!(
            ttl_secs = config.response_cache_ttl_secs,
            max_entries = config.response_cache_max_entries,
            "LLM response cache enabled"
        );
        Arc::new(CachedProvider::new(llm, rc_config))
    } else {
        llm
    };

    // 5b. Total turn-budget timeout — caps the ENTIRE call (retries + failover)
    //     so a hung backend can't stack N × request_timeout past the agent's
    //     handle_message turn budget and trigger a hard-kill that drops queued
    //     follow-up messages. 0 disables. See llm/timeout.rs.
    let llm: Arc<dyn LlmProvider> = if config.llm_turn_budget_secs > 0 {
        tracing::debug!(
            budget_secs = config.llm_turn_budget_secs,
            "LLM total turn-budget timeout enabled"
        );
        Arc::new(TimeoutProvider::new(
            llm,
            std::time::Duration::from_secs(config.llm_turn_budget_secs),
        ))
    } else {
        llm
    };

    // 6. Recording (trace capture for replay testing)
    let recording_handle = RecordingLlm::from_env(llm.clone());
    let llm: Arc<dyn LlmProvider> = if let Some(ref recorder) = recording_handle {
        Arc::clone(recorder) as Arc<dyn LlmProvider>
    } else {
        llm
    };

    // Standalone cheap LLM for heartbeat/evaluation (not part of the chain)
    let cheap_llm = create_cheap_llm_provider(config, session)?;
    if let Some(ref cheap) = cheap_llm {
        tracing::debug!("Cheap LLM provider initialized: {}", cheap.model_name());
    }

    Ok((llm, cheap_llm, recording_handle))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::llm::config::LunarWingCloudConfig;

    fn test_lunarwing_cloud_config() -> LunarWingCloudConfig {
        LunarWingCloudConfig {
            model: "test-model".to_string(),
            cheap_model: None,
            base_url: "https://api.near.ai".to_string(),
            api_key: None,
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

    fn test_llm_config() -> LlmConfig {
        let lunarwing_cloud = test_lunarwing_cloud_config();
        LlmConfig {
            backend: "lunarwing_cloud".to_string(),
            session: SessionConfig::default(),
            max_retries: lunarwing_cloud.max_retries,
            circuit_breaker_threshold: lunarwing_cloud.circuit_breaker_threshold,
            circuit_breaker_recovery_secs: lunarwing_cloud.circuit_breaker_recovery_secs,
            response_cache_enabled: lunarwing_cloud.response_cache_enabled,
            response_cache_ttl_secs: lunarwing_cloud.response_cache_ttl_secs,
            response_cache_max_entries: lunarwing_cloud.response_cache_max_entries,
            lunarwing_cloud,
            provider: None,
            request_timeout_secs: 120,
            llm_turn_budget_secs: 270,
            cheap_model: None,
            smart_routing_cascade: true,
            openai_codex: None,
        }
    }

    #[test]
    fn test_create_cheap_llm_provider_returns_none_when_not_configured() {
        let config = test_llm_config();
        let session = Arc::new(SessionManager::new(SessionConfig::default()));

        let result = create_cheap_llm_provider(&config, session);
        assert!(result.is_ok());
        assert!(result.unwrap().is_none());
    }

    #[test]
    fn test_create_cheap_llm_provider_creates_provider_with_lunarwing_cloud_cheap_model() {
        let mut config = test_llm_config();
        config.lunarwing_cloud.cheap_model = Some("cheap-test-model".to_string());

        let session = Arc::new(SessionManager::new(SessionConfig::default()));
        let result = create_cheap_llm_provider(&config, session);

        assert!(result.is_ok());
        let provider = result.unwrap();
        assert!(provider.is_some());
        assert_eq!(provider.unwrap().model_name(), "cheap-test-model");
    }

    #[test]
    fn test_create_cheap_llm_provider_generic_overrides_lunarwing_cloud() {
        let mut config = test_llm_config();
        config.lunarwing_cloud.cheap_model = Some("lunarwing_cloud-cheap".to_string());
        config.cheap_model = Some("generic-cheap".to_string());

        let session = Arc::new(SessionManager::new(SessionConfig::default()));
        let result = create_cheap_llm_provider(&config, session);

        assert!(result.is_ok());
        let provider = result.unwrap();
        assert!(provider.is_some());
        assert_eq!(
            provider.unwrap().model_name(),
            "generic-cheap",
            "LLM_CHEAP_MODEL should take priority over LUNARWING_CLOUD_CHEAP_MODEL"
        );
    }

    #[test]
    fn test_create_cheap_llm_provider_lunarwing_cloud_cheap_ignored_for_non_lunarwing_cloud_backend()
     {
        let mut config = test_llm_config();
        config.backend = "openai_compatible".to_string();
        config.lunarwing_cloud.cheap_model = Some("cheap-test-model".to_string());

        let session = Arc::new(SessionManager::new(SessionConfig::default()));
        let result = create_cheap_llm_provider(&config, session);

        assert!(result.is_ok());
        assert!(
            result.unwrap().is_none(),
            "LUNARWING_CLOUD_CHEAP_MODEL should be ignored when backend is not lunarwing_cloud"
        );
    }

    #[test]
    fn test_cheap_model_name_resolution() {
        // Generic takes priority
        let mut config = test_llm_config();
        config.cheap_model = Some("generic".to_string());
        config.lunarwing_cloud.cheap_model = Some("lunarwing_cloud".to_string());
        assert_eq!(config.cheap_model_name(), Some("generic"));

        // LunarWing Cloud fallback when backend is lunarwing_cloud
        let mut config = test_llm_config();
        config.lunarwing_cloud.cheap_model = Some("lunarwing_cloud".to_string());
        assert_eq!(config.cheap_model_name(), Some("lunarwing_cloud"));

        // LunarWing Cloud ignored for non-lunarwing_cloud backend
        let mut config = test_llm_config();
        config.backend = "openai_compatible".to_string();
        config.lunarwing_cloud.cheap_model = Some("lunarwing_cloud".to_string());
        assert_eq!(config.cheap_model_name(), None);

        // None when nothing configured
        let config = test_llm_config();
        assert_eq!(config.cheap_model_name(), None);
    }
}
