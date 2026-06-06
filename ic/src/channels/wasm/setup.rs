//! WASM channel setup and credential injection.
//!
//! Encapsulates the logic for loading WASM channels, registering their
//! webhook routes, and injecting credentials from the secrets store.

use std::collections::HashSet;
use std::sync::Arc;

use crate::channels::wasm::{
    LoadedChannel, RegisteredEndpoint, SharedWasmChannel, TELEGRAM_CHANNEL_NAME, WasmChannel,
    WasmChannelLoader, WasmChannelRouter, WasmChannelRuntime, WasmChannelRuntimeConfig,
    bot_username_setting_key, create_wasm_channel_router,
};
use crate::config::Config;
use crate::db::Database;
use crate::extensions::ExtensionManager;
use crate::pairing::PairingStore;
use crate::secrets::SecretsStore;

/// Result of WASM channel setup.
pub struct WasmChannelSetup {
    pub channels: Vec<(String, Box<dyn crate::channels::Channel>)>,
    pub channel_names: Vec<String>,
    pub webhook_routes: Option<axum::Router>,
    /// Runtime objects needed for hot-activation via ExtensionManager.
    pub wasm_channel_runtime: Arc<WasmChannelRuntime>,
    pub pairing_store: Arc<PairingStore>,
    pub wasm_channel_router: Arc<WasmChannelRouter>,
}

/// Load WASM channels and register their webhook routes.
pub async fn setup_wasm_channels(
    config: &Config,
    secrets_store: &Option<Arc<dyn SecretsStore + Send + Sync>>,
    extension_manager: Option<&Arc<ExtensionManager>>,
    database: Option<&Arc<dyn Database>>,
) -> Option<WasmChannelSetup> {
    let runtime = match WasmChannelRuntime::new(WasmChannelRuntimeConfig::default()) {
        Ok(r) => Arc::new(r),
        Err(e) => {
            tracing::warn!("Failed to initialize WASM channel runtime: {}", e);
            return None;
        }
    };

    let pairing_store = Arc::new(PairingStore::new());
    let settings_store: Option<Arc<dyn crate::db::SettingsStore>> =
        database.map(|db| Arc::clone(db) as Arc<dyn crate::db::SettingsStore>);
    let mut loader = WasmChannelLoader::new(
        Arc::clone(&runtime),
        Arc::clone(&pairing_store),
        settings_store.clone(),
        config.owner_id.clone(),
    );
    if let Some(secrets) = secrets_store {
        loader = loader.with_secrets_store(Arc::clone(secrets));
    }

    let results = match loader
        .load_from_dir(&config.channels.wasm_channels_dir)
        .await
    {
        Ok(r) => r,
        Err(e) => {
            tracing::warn!("Failed to scan WASM channels directory: {}", e);
            return None;
        }
    };

    let wasm_router = Arc::new(WasmChannelRouter::new());
    let mut channels: Vec<(String, Box<dyn crate::channels::Channel>)> = Vec::new();
    let mut channel_names: Vec<String> = Vec::new();

    for loaded in results.loaded {
        let (name, channel) = register_channel(
            loaded,
            config,
            secrets_store,
            settings_store.as_ref(),
            &wasm_router,
        )
        .await;
        channel_names.push(name.clone());
        channels.push((name, channel));
    }

    for (path, err) in &results.errors {
        tracing::warn!("Failed to load WASM channel {}: {}", path.display(), err);
    }

    // Always create webhook routes (even with no channels loaded) so that
    // channels hot-added at runtime can receive webhooks without a restart.
    let webhook_routes = {
        Some(create_wasm_channel_router(
            Arc::clone(&wasm_router),
            extension_manager.map(Arc::clone),
        ))
    };

    Some(WasmChannelSetup {
        channels,
        channel_names,
        webhook_routes,
        wasm_channel_runtime: runtime,
        pairing_store,
        wasm_channel_router: wasm_router,
    })
}

/// Process a single loaded WASM channel: retrieve secrets, inject config,
/// register with the router, and set up signing keys and credentials.
async fn register_channel(
    loaded: LoadedChannel,
    config: &Config,
    secrets_store: &Option<Arc<dyn SecretsStore + Send + Sync>>,
    settings_store: Option<&Arc<dyn crate::db::SettingsStore>>,
    wasm_router: &Arc<WasmChannelRouter>,
) -> (String, Box<dyn crate::channels::Channel>) {
    let channel_name = loaded.name().to_string();
    tracing::debug!("Loaded WASM channel: {}", channel_name);
    let owner_actor_id = config
        .channels
        .wasm_channel_owner_ids
        .get(channel_name.as_str())
        .map(ToString::to_string);

    let secret_name = loaded.webhook_secret_name();
    let sig_key_secret_name = loaded.signature_key_secret_name();
    let hmac_secret_name = loaded.hmac_secret_name();

    let webhook_secret = if let Some(secrets) = secrets_store {
        secrets
            .get_decrypted(&config.owner_id, &secret_name)
            .await
            .ok()
            .map(|s| s.expose().to_string())
    } else {
        None
    };

    let secret_header = loaded.webhook_secret_header().map(|s| s.to_string());

    let webhook_path = format!("/webhook/{}", channel_name);
    let endpoints = vec![RegisteredEndpoint {
        channel_name: channel_name.clone(),
        path: webhook_path,
        methods: vec!["POST".to_string()],
        require_secret: webhook_secret.is_some(),
    }];

    let channel_arc = Arc::new(loaded.channel.with_owner_actor_id(owner_actor_id.clone()));

    // Inject runtime config (tunnel URL, webhook secret, owner_id).
    {
        let mut config_updates = std::collections::HashMap::new();

        if let Some(ref tunnel_url) = config.tunnel.public_url {
            config_updates.insert(
                "tunnel_url".to_string(),
                serde_json::Value::String(tunnel_url.clone()),
            );
        }

        if let Some(ref secret) = webhook_secret {
            config_updates.insert(
                "webhook_secret".to_string(),
                serde_json::Value::String(secret.clone()),
            );
        }

        if let Some(&owner_id) = config
            .channels
            .wasm_channel_owner_ids
            .get(channel_name.as_str())
        {
            config_updates.insert("owner_id".to_string(), serde_json::json!(owner_id));
        }

        if channel_name == TELEGRAM_CHANNEL_NAME
            && let Some(store) = settings_store
            && let Ok(Some(serde_json::Value::String(username))) = store
                .get_setting("default", &bot_username_setting_key(&channel_name))
                .await
            && !username.trim().is_empty()
        {
            config_updates.insert("bot_username".to_string(), serde_json::json!(username));
        }

        config_updates.extend(
            load_channel_setup_field_overrides(
                settings_store,
                &config.owner_id,
                &channel_name,
                loaded.capabilities_file.as_ref(),
            )
            .await,
        );
        // Inject channel-specific secrets into config for channels that need
        // credentials as runtime config values rather than HTTP placeholders
        // (e.g., XMPP password).
        inject_channel_secrets_into_config(
            &channel_name,
            secrets_store,
            &config.owner_id,
            &mut config_updates,
        )
        .await;

        if !config_updates.is_empty() {
            channel_arc.update_config(config_updates).await;
            tracing::info!(
                channel = %channel_name,
                has_tunnel = config.tunnel.public_url.is_some(),
                has_webhook_secret = webhook_secret.is_some(),
                "Injected runtime config into channel"
            );
        }
    }

    tracing::info!(
        channel = %channel_name,
        has_webhook_secret = webhook_secret.is_some(),
        secret_header = ?secret_header,
        "Registering channel with router"
    );

    wasm_router
        .register(
            Arc::clone(&channel_arc),
            endpoints,
            webhook_secret.clone(),
            secret_header,
        )
        .await;

    // Register Ed25519 signature key if declared in capabilities.
    if let Some(ref sig_key_name) = sig_key_secret_name
        && let Some(secrets) = secrets_store
        && let Ok(key_secret) = secrets.get_decrypted(&config.owner_id, sig_key_name).await
    {
        match wasm_router
            .register_signature_key(&channel_name, key_secret.expose())
            .await
        {
            Ok(()) => {
                tracing::info!(channel = %channel_name, "Registered Ed25519 signature key")
            }
            Err(e) => {
                tracing::error!(channel = %channel_name, error = %e, "Invalid signature key in secrets store")
            }
        }
    }

    // Register HMAC signing secret if declared in capabilities.
    if let Some(ref hmac_secret_name) = hmac_secret_name
        && let Some(secrets) = secrets_store
        && let Ok(secret) = secrets
            .get_decrypted(&config.owner_id, hmac_secret_name)
            .await
    {
        wasm_router
            .register_hmac_secret(&channel_name, secret.expose())
            .await;
        tracing::info!(channel = %channel_name, "Registered HMAC signing secret");
    }

    // Inject credentials from secrets store / environment.
    match inject_channel_credentials(
        &channel_arc,
        secrets_store
            .as_ref()
            .map(|s| s.as_ref() as &dyn SecretsStore),
        &channel_name,
        &config.owner_id,
    )
    .await
    {
        Ok(count) => {
            if count > 0 {
                tracing::info!(
                    channel = %channel_name,
                    credentials_injected = count,
                    "Channel credentials injected"
                );
            }
        }
        Err(e) => {
            tracing::error!(
                channel = %channel_name,
                error = %e,
                "Failed to inject channel credentials"
            );
        }
    }

    (channel_name, Box::new(SharedWasmChannel::new(channel_arc)))
}

/// Inject credentials for a channel based on naming convention.
///
/// Looks for secrets matching the pattern `{channel_name}_*` and injects them
/// as credential placeholders (e.g., `telegram_bot_token` -> `{TELEGRAM_BOT_TOKEN}`).
///
/// Falls back to environment variables starting with the uppercase channel name
/// prefix (e.g., `TELEGRAM_` for channel `telegram`) for missing credentials.
///
/// Returns the number of credentials injected.
pub async fn inject_channel_credentials(
    channel: &Arc<WasmChannel>,
    secrets: Option<&dyn SecretsStore>,
    channel_name: &str,
    owner_id: &str,
) -> anyhow::Result<usize> {
    if channel_name.trim().is_empty() {
        return Ok(0);
    }

    let mut count = 0;
    let mut injected_placeholders = HashSet::new();

    // 1. Try injecting from persistent secrets store if available
    if let Some(secrets) = secrets {
        let all_secrets = secrets
            .list(owner_id)
            .await
            .map_err(|e| anyhow::anyhow!("Failed to list secrets: {}", e))?;

        let prefix = format!("{}_", channel_name.to_ascii_lowercase());

        for secret_meta in all_secrets {
            if !secret_meta.name.to_ascii_lowercase().starts_with(&prefix) {
                continue;
            }

            let decrypted = match secrets.get_decrypted(owner_id, &secret_meta.name).await {
                Ok(d) => d,
                Err(e) => {
                    tracing::warn!(
                        secret = %secret_meta.name,
                        error = %e,
                        "Failed to decrypt secret for channel credential injection"
                    );
                    continue;
                }
            };

            let placeholder = secret_meta.name.to_uppercase();

            tracing::debug!(
                channel = %channel_name,
                secret = %secret_meta.name,
                placeholder = %placeholder,
                "Injecting credential"
            );

            channel
                .set_credential(&placeholder, decrypted.expose().to_string())
                .await;
            injected_placeholders.insert(placeholder);
            count += 1;
        }
    }

    // 2. Fall back to environment variables for credentials not in the secrets store.
    // Only env vars starting with the channel's uppercase prefix are allowed
    // (e.g., TELEGRAM_ for channel "telegram") to prevent reading unrelated host
    // credentials like AWS_SECRET_ACCESS_KEY.
    let prefix = format!("{}_", channel_name.to_ascii_uppercase());
    let caps = channel.capabilities();
    if let Some(ref http_cap) = caps.tool_capabilities.http {
        for cred_mapping in http_cap.credentials.values() {
            let placeholder = cred_mapping.secret_name.to_uppercase();
            if injected_placeholders.contains(&placeholder) {
                continue;
            }
            if !placeholder.starts_with(&prefix) {
                tracing::warn!(
                    channel = %channel_name,
                    placeholder = %placeholder,
                    "Ignoring non-prefixed credential placeholder in environment fallback"
                );
                continue;
            }
            if let Ok(env_value) = std::env::var(&placeholder)
                && !env_value.is_empty()
            {
                tracing::debug!(
                    channel = %channel_name,
                    placeholder = %placeholder,
                    "Injecting credential from environment variable"
                );
                channel.set_credential(&placeholder, env_value).await;
                count += 1;
            }
        }
    }

    Ok(count)
}

async fn load_channel_setup_field_overrides(
    settings_store: Option<&Arc<dyn crate::db::SettingsStore>>,
    owner_id: &str,
    channel_name: &str,
    capabilities_file: Option<&crate::channels::wasm::ChannelCapabilitiesFile>,
) -> std::collections::HashMap<String, serde_json::Value> {
    let mut overrides = std::collections::HashMap::new();
    let Some(cap_file) = capabilities_file else {
        return overrides;
    };

    // Explicit per-channel setup fields saved in the settings store (if a
    // store is configured). Env-sourcing below works even without a store.
    let saved_fields = match settings_store {
        Some(store) => {
            let key = format!("extensions.{channel_name}.setup_fields");
            match store.get_setting(owner_id, &key).await {
                Ok(Some(value)) => {
                    serde_json::from_value::<std::collections::HashMap<String, String>>(value)
                        .unwrap_or_default()
                }
                _ => std::collections::HashMap::new(),
            }
        }
        None => std::collections::HashMap::new(),
    };

    let env_config_allowed = channel_env_config_allowed(channel_name);

    for field in &cap_file.setup.required_fields {
        // 1. Explicit saved setup field (highest precedence).
        if let Some(value) = saved_fields.get(&field.name)
            && !value.trim().is_empty()
        {
            overrides.insert(field.name.clone(), serde_json::Value::String(value.clone()));
            continue;
        }

        // 2. A value persisted at an approved setting path.
        if let Some(store) = settings_store
            && let Some(setting_path) = field.setting_path.as_deref()
            && let Ok(Some(value)) = store.get_setting(owner_id, setting_path).await
            && setting_value_is_present(&value)
        {
            overrides.insert(field.name.clone(), value);
            continue;
        }

        // 3. An environment variable, for deployment-time config such as
        //    per-tenant ports/URLs in multi-tenant setups. Restricted to
        //    first-party (bundled) channels so an untrusted extension cannot
        //    exfiltrate arbitrary host environment variables into its config.
        if env_config_allowed
            && let Some(env_var) = field.env.as_deref()
            && let Ok(value) = std::env::var(env_var)
            && !value.trim().is_empty()
        {
            overrides.insert(field.name.clone(), serde_json::Value::String(value));
        }
    }

    overrides
}

/// Whether a channel may source setup-field values from the process
/// environment (via the `env` field in its capabilities).
///
/// Only first-party (bundled) channels are trusted to do this. A malicious
/// third-party capabilities file could otherwise declare `"env":
/// "SECRETS_MASTER_KEY"` (or any other sensitive host variable) and have its
/// value injected into the extension's own config, where the WASM module
/// could read and exfiltrate it.
fn channel_env_config_allowed(channel_name: &str) -> bool {
    crate::channels::wasm::bundled_channel_names().contains(&channel_name)
}

fn setting_value_is_present(value: &serde_json::Value) -> bool {
    match value {
        serde_json::Value::Null => false,
        serde_json::Value::String(s) => !s.trim().is_empty(),
        serde_json::Value::Array(a) => !a.is_empty(),
        serde_json::Value::Object(o) => !o.is_empty(),
        _ => true,
    }
}

/// Inject channel-specific secrets into the config JSON.
///
/// Some channels (e.g., XMPP) need raw credential values in their config
/// rather than HTTP header/URL placeholders. This function fills config
/// fields that map to secret names.
async fn inject_channel_secrets_into_config(
    channel_name: &str,
    secrets_store: &Option<Arc<dyn SecretsStore + Send + Sync>>,
    owner_id: &str,
    config_updates: &mut std::collections::HashMap<String, serde_json::Value>,
) {
    // Map of (config_key, secret_name, env_var) tuples per channel. The
    // env var is the deployment-time fallback when the secret is not in the
    // store — e.g. multi-tenant setups inject the WeeChat relay password via
    // `RELAY_PASSWORD` rather than the per-owner secrets store.
    let secret_config_mappings: &[(&str, &str, &str)] = match channel_name {
        "xmpp" => &[("xmpp_password", "xmpp_password", "XMPP_PASSWORD")],
        "weechat" => &[("relay_password", "weechat_relay_password", "RELAY_PASSWORD")],
        _ => return,
    };

    for &(config_key, secret_name, env_var) in secret_config_mappings {
        // Prefer the per-owner secrets store when available.
        if let Some(secrets) = secrets_store
            && let Ok(decrypted) = secrets.get_decrypted(owner_id, secret_name).await
        {
            config_updates.insert(
                config_key.to_string(),
                serde_json::Value::String(decrypted.expose().to_string()),
            );
            tracing::debug!(
                channel = %channel_name,
                config_key = %config_key,
                "Injected secret into channel config"
            );
            continue;
        }

        // Fall back to the environment variable (works without a store).
        if let Ok(val) = std::env::var(env_var)
            && !val.is_empty()
        {
            config_updates.insert(config_key.to_string(), serde_json::Value::String(val));
            tracing::debug!(
                channel = %channel_name,
                config_key = %config_key,
                "Injected secret from env into channel config"
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::channels::wasm::ChannelCapabilitiesFile;

    fn caps_with_env_fields() -> ChannelCapabilitiesFile {
        // Two env-sourced fields plus one without `env` (must be ignored).
        ChannelCapabilitiesFile::from_json(
            r#"{
                "name": "weechat",
                "setup": {
                    "required_fields": [
                        { "name": "relay_url", "prompt": "WeeChat relay URL", "optional": true, "env": "LW_TEST_RELAY_URL" },
                        { "name": "ws_adapter_url", "prompt": "WS adapter URL", "optional": true, "env": "LW_TEST_WS_ADAPTER_URL" },
                        { "name": "connection_mode", "prompt": "Connection mode", "optional": true }
                    ]
                }
            }"#,
        )
        .expect("valid capabilities JSON")
    }

    #[test]
    fn env_config_gate_allows_only_bundled_channels() {
        // First-party (bundled) channels are trusted.
        assert!(channel_env_config_allowed("weechat"));
        assert!(channel_env_config_allowed("xmpp"));
        // Anything not in the bundled set is rejected (security boundary).
        assert!(!channel_env_config_allowed("totally-not-a-real-channel"));
        assert!(!channel_env_config_allowed(""));
    }

    #[tokio::test]
    async fn env_sourced_fields_inject_for_bundled_channel() {
        // Regression: the WeeChat WASM channel polled hardcoded ports because
        // per-tenant relay/adapter URLs were never injected. With `env`
        // declared on the fields, the values must flow from the environment.
        unsafe {
            std::env::set_var("LW_TEST_RELAY_URL", "http://127.0.0.1:10005");
            std::env::set_var("LW_TEST_WS_ADAPTER_URL", "http://127.0.0.1:10009");
        }

        let caps = caps_with_env_fields();
        let overrides =
            load_channel_setup_field_overrides(None, "test-owner", "weechat", Some(&caps)).await;

        unsafe {
            std::env::remove_var("LW_TEST_RELAY_URL");
            std::env::remove_var("LW_TEST_WS_ADAPTER_URL");
        }

        assert_eq!(
            overrides.get("relay_url"),
            Some(&serde_json::Value::String("http://127.0.0.1:10005".to_string()))
        );
        assert_eq!(
            overrides.get("ws_adapter_url"),
            Some(&serde_json::Value::String("http://127.0.0.1:10009".to_string()))
        );
        // Fields without an `env` declaration are not touched.
        assert!(!overrides.contains_key("connection_mode"));
    }

    #[tokio::test]
    async fn env_sourced_fields_blocked_for_untrusted_channel() {
        // Security: a non-bundled channel must not be able to pull host env
        // vars into its config even if its capabilities declare `env`.
        unsafe {
            std::env::set_var("LW_TEST_UNTRUSTED_RELAY_URL", "http://127.0.0.1:10005");
        }

        let caps = ChannelCapabilitiesFile::from_json(
            r#"{
                "name": "evil",
                "setup": {
                    "required_fields": [
                        { "name": "relay_url", "prompt": "x", "optional": true, "env": "LW_TEST_UNTRUSTED_RELAY_URL" }
                    ]
                }
            }"#,
        )
        .expect("valid capabilities JSON");

        let overrides = load_channel_setup_field_overrides(
            None,
            "test-owner",
            "evil-third-party-channel",
            Some(&caps),
        )
        .await;

        unsafe {
            std::env::remove_var("LW_TEST_UNTRUSTED_RELAY_URL");
        }

        assert!(
            overrides.is_empty(),
            "untrusted channel must not source config from env"
        );
    }

    #[tokio::test]
    async fn weechat_relay_password_injected_from_env() {
        // Regression: once the port is correct, the adapter's auth becomes the
        // next blocker. mt-admin sets a per-tenant RELAY_PASSWORD that must be
        // injected as `relay_password` so the WASM authenticates to the adapter.
        unsafe {
            std::env::set_var("RELAY_PASSWORD", "tenant-secret-pw");
        }

        let no_store: Option<Arc<dyn SecretsStore + Send + Sync>> = None;
        let mut updates = std::collections::HashMap::new();
        inject_channel_secrets_into_config("weechat", &no_store, "test-owner", &mut updates).await;

        unsafe {
            std::env::remove_var("RELAY_PASSWORD");
        }

        assert_eq!(
            updates.get("relay_password"),
            Some(&serde_json::Value::String("tenant-secret-pw".to_string()))
        );
    }

    #[tokio::test]
    async fn xmpp_secret_env_fallback_preserved() {
        // Guard the pre-existing XMPP behavior while generalizing the mapping.
        unsafe {
            std::env::set_var("XMPP_PASSWORD", "xmpp-pw");
        }

        let no_store: Option<Arc<dyn SecretsStore + Send + Sync>> = None;
        let mut updates = std::collections::HashMap::new();
        inject_channel_secrets_into_config("xmpp", &no_store, "test-owner", &mut updates).await;
        // Unknown channels are a no-op.
        inject_channel_secrets_into_config("telegram", &no_store, "test-owner", &mut updates).await;

        unsafe {
            std::env::remove_var("XMPP_PASSWORD");
        }

        assert_eq!(
            updates.get("xmpp_password"),
            Some(&serde_json::Value::String("xmpp-pw".to_string()))
        );
        assert_eq!(updates.len(), 1, "telegram has no secret mapping");
    }
}
