//! Model discovery and fetching for multiple LLM providers.

/// Fetch installed models from a local Ollama instance.
///
/// Returns `(model_name, display_label)` pairs. Falls back to static defaults on error.
pub(crate) async fn fetch_ollama_models(base_url: &str) -> Vec<(String, String)> {
    let static_defaults = vec![
        ("llama3".into(), "llama3".into()),
        ("mistral".into(), "mistral".into()),
        ("codellama".into(), "codellama".into()),
    ];

    let url = format!("{}/api/tags", base_url.trim_end_matches('/'));
    let client = reqwest::Client::new();

    let resp = match client
        .get(&url)
        .timeout(std::time::Duration::from_secs(5))
        .send()
        .await
    {
        Ok(r) if r.status().is_success() => r,
        Ok(_) => return static_defaults,
        Err(_) => {
            tracing::warn!(
                "Could not connect to Ollama at {base_url}. Is it running? Using static defaults."
            );
            return static_defaults;
        }
    };

    #[derive(serde::Deserialize)]
    struct ModelEntry {
        name: String,
    }
    #[derive(serde::Deserialize)]
    struct TagsResponse {
        models: Vec<ModelEntry>,
    }

    match resp.json::<TagsResponse>().await {
        Ok(body) => {
            let models: Vec<(String, String)> = body
                .models
                .into_iter()
                .map(|m| {
                    let label = m.name.clone();
                    (m.name, label)
                })
                .collect();
            if models.is_empty() {
                return static_defaults;
            }
            models
        }
        Err(_) => static_defaults,
    }
}

/// Fetch models from a generic OpenAI-compatible /v1/models endpoint.
///
/// Used for registry providers like Groq, NVIDIA NIM, etc.
pub(crate) async fn fetch_openai_compatible_models(
    base_url: &str,
    cached_key: Option<&str>,
) -> Vec<(String, String)> {
    if base_url.is_empty() {
        return vec![];
    }

    let url = format!("{}/models", base_url.trim_end_matches('/'));
    let client = reqwest::Client::new();
    let mut req = client.get(&url).timeout(std::time::Duration::from_secs(5));
    if let Some(key) = cached_key {
        req = req.bearer_auth(key);
    }

    let resp = match req.send().await {
        Ok(r) if r.status().is_success() => r,
        _ => return vec![],
    };

    #[derive(serde::Deserialize)]
    struct Model {
        id: String,
    }
    #[derive(serde::Deserialize)]
    struct ModelsResponse {
        data: Vec<Model>,
    }

    match resp.json::<ModelsResponse>().await {
        Ok(body) => body
            .data
            .into_iter()
            .map(|m| {
                let label = m.id.clone();
                (m.id, label)
            })
            .collect(),
        Err(_) => vec![],
    }
}

/// Build the `LlmConfig` used by `fetch_lunarwing_cloud_models` to list available models.
///
/// Uses [`LunarWingCloudConfig::for_model_discovery()`] to construct a minimal LunarWing Cloud
/// config, then wraps it in an `LlmConfig` with session config for auth.
pub(crate) fn build_lunarwing_cloud_model_fetch_config() -> crate::config::LlmConfig {
    let auth_base_url = crate::config::helpers::env_or_override("LUNARWING_CLOUD_AUTH_URL")
        .unwrap_or_else(|| "https://private.lunarwing.org".to_string());

    let lunarwing_cloud = crate::config::LunarWingCloudConfig::for_model_discovery();
    crate::config::LlmConfig {
        backend: "lunarwing_cloud".to_string(),
        session: crate::llm::session::SessionConfig {
            auth_base_url,
            session_path: crate::config::llm::default_session_path(),
        },
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
        smart_routing_cascade: false,
        openai_codex: None,
    }
}
