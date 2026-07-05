//! Application builder for initializing core LunarWing components.
//!
//! Extracts the mechanical initialization phases from `main.rs` into a
//! reusable builder so that:
//!
//! - Tests can construct a full `AppComponents` without wiring channels
//! - Main stays focused on CLI dispatch and channel setup
//! - Each init phase is independently testable

use std::sync::Arc;

use crate::agent::SessionManager as AgentSessionManager;
use crate::bridge::ssh::SSHBridge;
use crate::channels::web::log_layer::LogBroadcaster;
use crate::config::Config;
use crate::context::ContextManager;
use crate::db::Database;
use crate::extensions::ExtensionManager;
use crate::hooks::HookRegistry;
use crate::llm::{LlmProvider, RecordingLlm, SessionManager};
use crate::safety::SafetyLayer;
use crate::secrets::SecretsStore;
use crate::skills::SkillRegistry;
use crate::skills::catalog::SkillCatalog;
use crate::tools::ToolRegistry;
use crate::tools::mcp::{McpProcessManager, McpSessionManager};
use crate::tools::wasm::SharedCredentialRegistry;
use crate::tools::wasm::WasmToolRuntime;
use crate::workspace::{EmbeddingCacheConfig, EmbeddingProvider, Workspace};

/// Fully initialized application components, ready for channel wiring
/// and agent construction.
pub struct AppComponents {
    /// The (potentially mutated) config after DB reload and secret injection.
    pub config: Config,
    pub db: Option<Arc<dyn Database>>,
    pub secrets_store: Option<Arc<dyn SecretsStore + Send + Sync>>,
    pub llm: Arc<dyn LlmProvider>,
    pub cheap_llm: Option<Arc<dyn LlmProvider>>,
    pub safety: Arc<SafetyLayer>,
    pub tools: Arc<ToolRegistry>,
    pub embeddings: Option<Arc<dyn EmbeddingProvider>>,
    pub workspace: Option<Arc<Workspace>>,
    pub extension_manager: Option<Arc<ExtensionManager>>,
    pub mcp_session_manager: Arc<McpSessionManager>,
    pub mcp_process_manager: Arc<McpProcessManager>,
    pub wasm_tool_runtime: Option<Arc<WasmToolRuntime>>,
    pub log_broadcaster: Arc<LogBroadcaster>,
    pub context_manager: Arc<ContextManager>,
    pub hooks: Arc<HookRegistry>,
    /// Shared thread/session manager used by the standard agent runtime.
    pub agent_session_manager: Arc<AgentSessionManager>,
    pub skill_registry: Option<Arc<std::sync::RwLock<SkillRegistry>>>,
    pub skill_catalog: Option<Arc<SkillCatalog>>,
    pub cost_guard: Arc<crate::agent::cost_guard::CostGuard>,
    pub recording_handle: Option<Arc<RecordingLlm>>,
    pub session: Arc<SessionManager>,
    pub catalog_entries: Vec<crate::extensions::RegistryEntry>,
    pub dev_loaded_tool_names: Vec<String>,
    pub builder: Option<Arc<dyn crate::tools::SoftwareBuilder>>,
    /// SSH bridge — centralized host config + agent socket (Phase 4+)
    /// Wrapped in `RwLock` so the API layer can perform mutable operations
    /// (add/remove host) while other consumers hold shared read access.
    pub ssh_bridge: Option<Arc<tokio::sync::RwLock<SSHBridge>>>,
}

/// Options that control optional init phases.
#[derive(Default)]
pub struct AppBuilderFlags {
    pub no_db: bool,
}

/// Builder that orchestrates the 5 mechanical init phases.
pub struct AppBuilder {
    config: Config,
    flags: AppBuilderFlags,
    toml_path: Option<std::path::PathBuf>,
    session: Arc<SessionManager>,
    log_broadcaster: Arc<LogBroadcaster>,

    // Accumulated state
    db: Option<Arc<dyn Database>>,
    secrets_store: Option<Arc<dyn SecretsStore + Send + Sync>>,

    // Test overrides
    llm_override: Option<Arc<dyn LlmProvider>>,

    // Backend-specific handles needed by secrets store
    handles: Option<crate::db::DatabaseHandles>,
}

/// Outcome of reconciling the configured LLM turn budget against the agent's
/// `handle_message` turn timeout. The `TimeoutProvider` must fire before the
/// hard-kill (soft timeout + grace), otherwise a hung backend can ride past the
/// turn budget into the message-dropping hard-kill path
/// (see `llm/timeout.rs`, `agent/agent_loop.rs`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum TurnBudgetOutcome {
    /// Budget is safe as configured (or `0` = `TimeoutProvider` disabled).
    Ok,
    /// Budget sits too close to / over the timeout; clamp down to this ceiling.
    Clamp(u64),
    /// `handle_message_timeout` is below the hard-kill grace, so no positive
    /// budget can be positioned to fire first — left unchanged; the operator
    /// must raise the timeout (or disable the budget).
    TimeoutTooSmall,
}

impl AppBuilder {
    /// Create a new builder.
    ///
    /// The `session` and `log_broadcaster` are created before the builder
    /// because tracing must be initialized before any init phase runs,
    /// and the log broadcaster is part of the tracing layer.
    pub fn new(
        config: Config,
        flags: AppBuilderFlags,
        toml_path: Option<std::path::PathBuf>,
        session: Arc<SessionManager>,
        log_broadcaster: Arc<LogBroadcaster>,
    ) -> Self {
        Self {
            config,
            flags,
            toml_path,
            session,
            log_broadcaster,
            db: None,
            secrets_store: None,
            llm_override: None,
            handles: None,
        }
    }

    /// Reconcile the configured LLM turn budget against the agent's
    /// `handle_message` turn timeout so the `TimeoutProvider` is guaranteed to
    /// fire before the hard-kill.
    ///
    /// The budget must leave at least `MARGIN` (the hard-kill grace) of headroom
    /// below the timeout, i.e. `budget <= timeout - MARGIN` (the "ceiling").
    /// A budget of `0` disables the cap and is always [`TurnBudgetOutcome::Ok`].
    /// Otherwise:
    /// - `budget <= ceiling` → [`Ok`] (the default 270 vs 300 sits exactly at
    ///   the ceiling and is safe — no spurious warning);
    /// - `budget > ceiling`  → [`Clamp`] down to `ceiling`;
    /// - `timeout <= MARGIN` (ceiling saturates to 0) → [`TimeoutTooSmall`].
    ///
    /// Pure / side-effect free for testability; `build_all` applies the result.
    ///
    /// [`Ok`]: TurnBudgetOutcome::Ok
    /// [`Clamp`]: TurnBudgetOutcome::Clamp
    /// [`TimeoutTooSmall`]: TurnBudgetOutcome::TimeoutTooSmall
    fn resolve_turn_budget(
        budget_secs: u64,
        handle_message_timeout: std::time::Duration,
    ) -> TurnBudgetOutcome {
        // Hard-kill grace after the soft `handle_message` timeout. Sourced
        // directly from `agent::HARD_KILL_GRACE_SECS` (re-exported from
        // `agent_loop`) so the two files can't drift if the grace changes.
        const MARGIN: u64 = crate::agent::HARD_KILL_GRACE_SECS;
        if budget_secs == 0 {
            return TurnBudgetOutcome::Ok; // TimeoutProvider disabled
        }
        let ceiling = handle_message_timeout.as_secs().saturating_sub(MARGIN);
        if ceiling == 0 {
            return TurnBudgetOutcome::TimeoutTooSmall;
        }
        if budget_secs > ceiling {
            TurnBudgetOutcome::Clamp(ceiling)
        } else {
            TurnBudgetOutcome::Ok
        }
    }

    /// Inject a pre-created database, skipping `init_database()`.
    pub fn with_database(&mut self, db: Arc<dyn Database>) {
        self.db = Some(db);
    }

    /// Inject a pre-created LLM provider, skipping `init_llm()`.
    pub fn with_llm(&mut self, llm: Arc<dyn LlmProvider>) {
        self.llm_override = Some(llm);
    }

    /// Phase 1: Initialize database backend.
    ///
    /// Creates the database connection, runs migrations, reloads config
    /// from DB, attaches DB to session manager, and cleans up stale jobs.
    pub async fn init_database(&mut self) -> Result<(), anyhow::Error> {
        if self.db.is_some() {
            tracing::debug!("Database already provided, skipping init_database()");
            return Ok(());
        }

        if self.flags.no_db {
            tracing::warn!("Running without database connection");
            return Ok(());
        }

        let (db, handles) = crate::db::connect_with_handles(&self.config.database)
            .await
            .map_err(|e| anyhow::anyhow!("{}", e))?;
        self.handles = Some(handles);

        // Post-init: migrate disk config, reload config from DB, attach session, cleanup
        if let Err(e) =
            crate::bootstrap::migrate_disk_to_db(db.as_ref(), &self.config.owner_id).await
        {
            tracing::warn!("Disk-to-DB settings migration failed: {}", e);
        }

        let toml_path = self.toml_path.as_deref();
        match Config::from_db_with_toml(db.as_ref(), &self.config.owner_id, toml_path).await {
            Ok(db_config) => {
                self.config = db_config;
                tracing::debug!("Configuration reloaded from database");
            }
            Err(e) => {
                tracing::warn!(
                    "Failed to reload config from DB, keeping env-based config: {}",
                    e
                );
            }
        }

        self.session
            .attach_store(db.clone(), &self.config.owner_id)
            .await;

        // Fire-and-forget housekeeping — no need to block startup.
        let db_cleanup = db.clone();
        tokio::spawn(async move {
            if let Err(e) = db_cleanup.cleanup_stale_sandbox_jobs().await {
                tracing::warn!("Failed to cleanup stale sandbox jobs: {}", e);
            }
        });

        self.db = Some(db);
        Ok(())
    }

    /// Phase 2: Create secrets store.
    ///
    /// Requires a master key and a backend-specific DB handle. After creating
    /// the store, injects any encrypted LLM API keys into the config overlay
    /// and re-resolves config.
    pub async fn init_secrets(&mut self) -> Result<(), anyhow::Error> {
        let master_key = match self.config.secrets.master_key() {
            Some(k) => k,
            None => {
                // No secrets DB available, but we can still load tokens from
                // OS credential stores (e.g., Anthropic OAuth via Claude Code's
                // macOS Keychain / Linux ~/.claude/.credentials.json).
                crate::config::inject_os_credentials();

                // Consume unused handles
                self.handles.take();

                // Re-resolve only the LLM config with OS credentials.
                let store: Option<&(dyn crate::db::SettingsStore + Sync)> =
                    self.db.as_ref().map(|db| db.as_ref() as _);
                let toml_path = self.toml_path.as_deref();
                let owner_id = self.config.owner_id.clone();
                if let Err(e) = self
                    .config
                    .re_resolve_llm(store, &owner_id, toml_path)
                    .await
                {
                    tracing::warn!(
                        "Failed to re-resolve LLM config after OS credential injection: {e}"
                    );
                }

                return Ok(());
            }
        };

        let crypto = match crate::secrets::SecretsCrypto::new(master_key.clone()) {
            Ok(c) => Arc::new(c),
            Err(e) => {
                tracing::warn!("Failed to initialize secrets crypto: {}", e);
                self.handles.take();
                return Ok(());
            }
        };

        // Fallback covers the no-database path where `init_database` returned
        // early before populating `self.handles`.
        let empty_handles = crate::db::DatabaseHandles::default();
        let handles = self.handles.as_ref().unwrap_or(&empty_handles);
        let store = crate::secrets::create_secrets_store(crypto, handles);

        if let Some(ref secrets) = store {
            // Inject LLM API keys from encrypted storage
            crate::config::inject_llm_keys_from_secrets(secrets.as_ref(), &self.config.owner_id)
                .await;

            // Re-resolve only the LLM config with newly available keys.
            let store: Option<&(dyn crate::db::SettingsStore + Sync)> =
                self.db.as_ref().map(|db| db.as_ref() as _);
            let toml_path = self.toml_path.as_deref();
            let owner_id = self.config.owner_id.clone();
            if let Err(e) = self
                .config
                .re_resolve_llm(store, &owner_id, toml_path)
                .await
            {
                tracing::warn!("Failed to re-resolve LLM config after secret injection: {e}");
            }
        }

        self.secrets_store = store;
        Ok(())
    }

    /// Phase 3: Initialize LLM provider chain.
    ///
    /// Delegates to `build_provider_chain` which applies all decorators
    /// (retry, smart routing, failover, circuit breaker, response cache).
    #[allow(clippy::type_complexity)]
    pub async fn init_llm(
        &self,
    ) -> Result<
        (
            Arc<dyn LlmProvider>,
            Option<Arc<dyn LlmProvider>>,
            Option<Arc<RecordingLlm>>,
        ),
        anyhow::Error,
    > {
        let (llm, cheap_llm, recording_handle) =
            crate::llm::build_provider_chain(&self.config.llm, self.session.clone()).await?;
        Ok((llm, cheap_llm, recording_handle))
    }

    /// Phase 4: Initialize safety, tools, embeddings, and workspace.
    pub async fn init_tools(
        &self,
        llm: &Arc<dyn LlmProvider>,
    ) -> Result<
        (
            Arc<SafetyLayer>,
            Arc<ToolRegistry>,
            Option<Arc<dyn EmbeddingProvider>>,
            Option<Arc<Workspace>>,
            Option<Arc<dyn crate::tools::SoftwareBuilder>>,
        ),
        anyhow::Error,
    > {
        let safety = Arc::new(SafetyLayer::new(&self.config.safety));
        tracing::debug!("Safety layer initialized");

        // Initialize tool registry with credential injection support
        let credential_registry = Arc::new(SharedCredentialRegistry::new());
        let tools = if let Some(ref ss) = self.secrets_store {
            Arc::new(
                ToolRegistry::new()
                    .with_credentials(Arc::clone(&credential_registry), Arc::clone(ss)),
            )
        } else {
            Arc::new(ToolRegistry::new())
        };
        tools.register_builtin_tools();
        tools.register_tool_info();

        if let Some(ref ss) = self.secrets_store {
            tools.register_secrets_tools(Arc::clone(ss));
        }

        // Create embeddings provider using the unified method
        let embeddings = self
            .config
            .embeddings
            .create_provider(&self.config.llm.nearai.base_url, self.session.clone());

        // Register memory tools if database is available
        let workspace_user_id = self.config.owner_id.as_str();
        let workspace = if let Some(ref db) = self.db {
            let emb_cache_config = EmbeddingCacheConfig {
                max_entries: self.config.embeddings.cache_size,
            };
            let mut ws = Workspace::new_with_db(workspace_user_id, db.clone())
                .with_search_config(&self.config.search);

            if let Some(ref emb) = embeddings {
                ws = ws.with_embeddings_cached(emb.clone(), emb_cache_config.clone());
            }

            // Wire workspace-level settings (read scopes, memory layers)
            if !self.config.workspace.read_scopes.is_empty() {
                ws = ws.with_additional_read_scopes(self.config.workspace.read_scopes.clone());
                tracing::info!(
                    user_id = workspace_user_id,
                    read_scopes = ?ws.read_user_ids(),
                    "Workspace configured with multi-scope reads"
                );
            }
            ws = ws.with_memory_layers(self.config.workspace.memory_layers.clone());
            let ws = Arc::new(ws);

            // Detect multi-tenant mode: when GATEWAY_USER_TOKENS is configured,
            // each authenticated user needs their own workspace scope. Use
            // WorkspacePool (which implements WorkspaceResolver) to create
            // per-user workspaces on demand instead of sharing the startup
            // workspace across all users.
            let is_multi_tenant = self
                .config
                .channels
                .gateway
                .as_ref()
                .is_some_and(|gw| gw.user_tokens.is_some());

            if is_multi_tenant {
                let pool = Arc::new(crate::channels::web::server::WorkspacePool::new(
                    Arc::clone(db),
                    embeddings.clone(),
                    emb_cache_config,
                    self.config.search.clone(),
                    self.config.workspace.clone(),
                ));
                tools.register_memory_tools_with_resolver(pool);
                tracing::info!(
                    "Memory tools configured with per-user workspace resolver (multi-tenant mode)"
                );
            } else {
                tools.register_memory_tools(Arc::clone(&ws));
            }

            Some(ws)
        } else {
            None
        };

        // Register image/vision tools if we have a workspace and LLM API credentials
        if workspace.is_some() {
            let (api_base, api_key_opt) = if let Some(ref provider) = self.config.llm.provider {
                (
                    provider.base_url.clone(),
                    provider.api_key.as_ref().map(|s| {
                        use secrecy::ExposeSecret;
                        s.expose_secret().to_string()
                    }),
                )
            } else {
                (
                    self.config.llm.nearai.base_url.clone(),
                    self.config.llm.nearai.api_key.as_ref().map(|s| {
                        use secrecy::ExposeSecret;
                        s.expose_secret().to_string()
                    }),
                )
            };

            if let Some(api_key) = api_key_opt {
                // Check for image generation models
                let model_name = self
                    .config
                    .llm
                    .provider
                    .as_ref()
                    .map(|p| p.model.clone())
                    .unwrap_or_else(|| self.config.llm.nearai.model.clone());
                let models = vec![model_name.clone()];
                let gen_model = crate::llm::image_models::suggest_image_model(&models)
                    .unwrap_or("flux-1.1-pro")
                    .to_string();
                tools.register_image_tools(api_base.clone(), api_key.clone(), gen_model, None);

                // Check for vision models
                let vision_model = crate::llm::vision_models::suggest_vision_model(&models)
                    .unwrap_or(&model_name)
                    .to_string();
                tools.register_vision_tools(api_base, api_key, vision_model, None);
            }
        }

        // Register builder tool if enabled
        let builder = if self.config.builder.enabled
            && (self.config.agent.allow_local_tools || !self.config.sandbox.enabled)
        {
            let b = tools
                .register_builder_tool(llm.clone(), Some(self.config.builder.to_builder_config()))
                .await;
            tracing::debug!("Builder mode enabled");
            Some(b)
        } else {
            None
        };

        Ok((safety, tools, embeddings, workspace, builder))
    }

    /// Phase 5: Load WASM tools, MCP servers, and create extension manager.
    pub async fn init_extensions(
        &self,
        tools: &Arc<ToolRegistry>,
        hooks: &Arc<HookRegistry>,
        workspace: &Option<Arc<Workspace>>,
        ssh_bridge_slot: Arc<
            std::sync::OnceLock<Arc<tokio::sync::RwLock<crate::bridge::ssh::SSHBridge>>>,
        >,
    ) -> Result<
        (
            Arc<McpSessionManager>,
            Arc<McpProcessManager>,
            Option<Arc<WasmToolRuntime>>,
            Option<Arc<ExtensionManager>>,
            Vec<crate::extensions::RegistryEntry>,
            Vec<String>,
        ),
        anyhow::Error,
    > {
        use crate::tools::mcp::config::load_mcp_servers_from_db;
        use crate::tools::wasm::{WasmToolLoader, load_dev_tools};

        let mcp_session_manager = Arc::new(McpSessionManager::new());
        let mcp_process_manager = Arc::new(McpProcessManager::new());

        // Create WASM tool runtime eagerly so extensions installed after startup
        // (e.g. via the web UI) can still be activated. The tools directory is only
        // needed when loading modules, not for engine initialisation.
        let wasm_tool_runtime: Option<Arc<WasmToolRuntime>> = if self.config.wasm.enabled {
            WasmToolRuntime::new(self.config.wasm.to_runtime_config())
                .map(Arc::new)
                .map_err(|e| tracing::warn!("Failed to initialize WASM runtime: {}", e))
                .ok()
        } else {
            None
        };

        // Load WASM tools and MCP servers concurrently
        let wasm_tools_future = {
            let wasm_tool_runtime = wasm_tool_runtime.clone();
            let secrets_store = self.secrets_store.clone();
            let tools = Arc::clone(tools);
            let wasm_config = self.config.wasm.clone();
            let workspace = workspace.clone();
            let ssh_bridge_slot = ssh_bridge_slot.clone();
            async move {
                let mut dev_loaded_tool_names: Vec<String> = Vec::new();

                if let Some(ref runtime) = wasm_tool_runtime {
                    let mut loader = WasmToolLoader::new(Arc::clone(runtime), Arc::clone(&tools));
                    if let Some(ref secrets) = secrets_store {
                        loader = loader.with_secrets_store(Arc::clone(secrets));
                    }
                    if let Some(ref ws) = workspace {
                        loader = loader.with_workspace(Arc::clone(ws));
                    }
                    loader = loader.with_ssh_bridge(ssh_bridge_slot.clone());

                    match loader.load_from_dir(&wasm_config.tools_dir).await {
                        Ok(results) => {
                            if !results.loaded.is_empty() {
                                tracing::debug!(
                                    "Loaded {} WASM tools from {}",
                                    results.loaded.len(),
                                    wasm_config.tools_dir.display()
                                );
                            }
                            for (path, err) in &results.errors {
                                tracing::warn!(
                                    "Failed to load WASM tool {}: {}",
                                    path.display(),
                                    err
                                );
                            }
                        }
                        Err(e) => {
                            tracing::warn!("Failed to scan WASM tools directory: {}", e);
                        }
                    }

                    match load_dev_tools(&loader, &wasm_config.tools_dir).await {
                        Ok(results) => {
                            dev_loaded_tool_names.extend(results.loaded.iter().cloned());
                            if !dev_loaded_tool_names.is_empty() {
                                tracing::debug!(
                                    "Loaded {} dev WASM tools from build artifacts",
                                    dev_loaded_tool_names.len()
                                );
                            }
                        }
                        Err(e) => {
                            tracing::debug!("No dev WASM tools found: {}", e);
                        }
                    }
                }

                dev_loaded_tool_names
            }
        };

        let mcp_servers_future = {
            let secrets_store = self.secrets_store.clone();
            let db = self.db.clone();
            let tools = Arc::clone(tools);
            let mcp_sm = Arc::clone(&mcp_session_manager);
            let pm = Arc::clone(&mcp_process_manager);
            let owner_id = self.config.owner_id.clone();
            async move {
                let servers_result = if let Some(ref d) = db {
                    load_mcp_servers_from_db(d.as_ref(), &owner_id).await
                } else {
                    crate::tools::mcp::config::load_mcp_servers().await
                };
                match servers_result {
                    Ok(servers) => {
                        let enabled: Vec<_> = servers.enabled_servers().cloned().collect();
                        if !enabled.is_empty() {
                            tracing::debug!(
                                "Loading {} configured MCP server(s)...",
                                enabled.len()
                            );
                        }

                        let mut join_set = tokio::task::JoinSet::new();
                        for server in enabled {
                            let mcp_sm = Arc::clone(&mcp_sm);
                            let secrets = secrets_store.clone();
                            let tools = Arc::clone(&tools);
                            let pm = Arc::clone(&pm);
                            let owner_id = owner_id.clone();

                            join_set.spawn(async move {
                                let server_name = server.name.clone();

                                let client = match crate::tools::mcp::create_client_from_config(
                                    server,
                                    &mcp_sm,
                                    &pm,
                                    secrets,
                                    &owner_id,
                                )
                                .await
                                {
                                    Ok(c) => c,
                                    Err(e) => {
                                        tracing::warn!(
                                            "Failed to create MCP client for '{}': {}",
                                            server_name,
                                            e
                                        );
                                        return None;
                                    }
                                };

                                match client.list_tools().await {
                                    Ok(mcp_tools) => {
                                        let tool_count = mcp_tools.len();
                                        match client.create_tools().await {
                                            Ok(tool_impls) => {
                                                for tool in tool_impls {
                                                    tools.register(tool).await;
                                                }
                                                tracing::debug!(
                                                    "Loaded {} tools from MCP server '{}'",
                                                    tool_count,
                                                    server_name
                                                );
                                                return Some((
                                                    server_name,
                                                    Arc::new(client),
                                                ));
                                            }
                                            Err(e) => {
                                                tracing::warn!(
                                                    "Failed to create tools from MCP server '{}': {}",
                                                    server_name,
                                                    e
                                                );
                                            }
                                        }
                                    }
                                    Err(e) => {
                                        let err_str = e.to_string();
                                        if err_str.contains("401")
                                            || err_str.contains("authentication")
                                        {
                                            tracing::warn!(
                                                "MCP server '{}' requires authentication. \
                                                 Run: lunarwing mcp auth {}",
                                                server_name,
                                                server_name
                                            );
                                        } else {
                                            tracing::warn!(
                                                "Failed to connect to MCP server '{}': {}",
                                                server_name,
                                                e
                                            );
                                        }
                                    }
                                }
                                None
                            });
                        }

                        let mut startup_clients = Vec::new();
                        while let Some(result) = join_set.join_next().await {
                            match result {
                                Ok(Some(client_pair)) => {
                                    startup_clients.push(client_pair);
                                }
                                Ok(None) => {}
                                Err(e) => {
                                    if e.is_panic() {
                                        tracing::error!("MCP server loading task panicked: {}", e);
                                    } else {
                                        tracing::warn!("MCP server loading task failed: {}", e);
                                    }
                                }
                            }
                        }
                        return startup_clients;
                    }
                    Err(e) => {
                        if matches!(
                            e,
                            crate::tools::mcp::config::ConfigError::InvalidConfig { .. }
                                | crate::tools::mcp::config::ConfigError::Json(_)
                        ) {
                            tracing::warn!(
                                "MCP server configuration is invalid: {}. \
                                 Fix or remove the corrupted config.",
                                e
                            );
                        } else {
                            tracing::debug!("No MCP servers configured ({})", e);
                        }
                    }
                }
                Vec::new()
            }
        };

        let (dev_loaded_tool_names, startup_mcp_clients) =
            tokio::join!(wasm_tools_future, mcp_servers_future);

        // Load registry catalog entries for extension discovery
        let mut catalog_entries = match crate::registry::RegistryCatalog::load_or_embedded() {
            Ok(catalog) => {
                let entries: Vec<_> = catalog
                    .all()
                    .iter()
                    .filter_map(|m| m.to_registry_entry())
                    .collect();
                tracing::debug!(
                    count = entries.len(),
                    "Loaded registry catalog entries for extension discovery"
                );
                entries
            }
            Err(e) => {
                tracing::warn!("Failed to load registry catalog: {}", e);
                Vec::new()
            }
        };

        // Append builtin entries (e.g. channel-relay integrations) so they appear
        // in the web UI's available extensions list.
        let builtin = crate::extensions::registry::builtin_entries();
        for entry in builtin {
            if !catalog_entries.iter().any(|e| e.name == entry.name) {
                catalog_entries.push(entry);
            }
        }

        // Create extension manager. Use ephemeral in-memory secrets if no
        // persistent store is configured (listing/install/activate still work).
        let ext_secrets: Arc<dyn crate::secrets::SecretsStore + Send + Sync> = if let Some(ref s) =
            self.secrets_store
        {
            Arc::clone(s)
        } else {
            use crate::secrets::{InMemorySecretsStore, SecretsCrypto};
            let ephemeral_key =
                secrecy::SecretString::from(crate::secrets::keychain::generate_master_key_hex());
            let crypto = Arc::new(SecretsCrypto::new(ephemeral_key).expect("ephemeral crypto"));
            tracing::debug!("Using ephemeral in-memory secrets store for extension manager");
            Arc::new(InMemorySecretsStore::new(crypto))
        };
        let extension_manager = {
            let manager = Arc::new(ExtensionManager::new(
                Arc::clone(&mcp_session_manager),
                Arc::clone(&mcp_process_manager),
                ext_secrets,
                Arc::clone(tools),
                Some(Arc::clone(hooks)),
                wasm_tool_runtime.clone(),
                self.config.wasm.tools_dir.clone(),
                self.config.channels.wasm_channels_dir.clone(),
                self.config.tunnel.public_url.clone(),
                self.config.owner_id.clone(),
                self.db.clone(),
                catalog_entries.clone(),
            ));
            tools.register_extension_tools(Arc::clone(&manager));
            tracing::debug!("Extension manager initialized with in-chat discovery tools");

            if !startup_mcp_clients.is_empty() {
                tracing::info!(
                    count = startup_mcp_clients.len(),
                    "Injecting startup MCP clients into extension manager"
                );
                for (name, client) in startup_mcp_clients {
                    manager.inject_mcp_client(name, client).await;
                }
            }

            Some(manager)
        };

        // Validate ACP agent configs at startup (lightweight — no connections, just config check).
        {
            let acp_agents = if let Some(ref d) = self.db {
                crate::config::acp::load_acp_agents_from_db(d.as_ref(), &self.config.owner_id).await
            } else {
                crate::config::acp::load_acp_agents().await
            };
            match acp_agents {
                Ok(file) => {
                    let enabled: Vec<_> = file.enabled_agents().collect();
                    if !enabled.is_empty() {
                        let names: Vec<&str> = enabled.iter().map(|a| a.name.as_str()).collect();
                        tracing::info!(
                            "ACP agents configured: {} ({} enabled)",
                            names.join(", "),
                            enabled.len()
                        );
                    }
                }
                Err(e) => {
                    tracing::debug!("No ACP agents configured ({})", e);
                }
            }
        }

        // register_builder_tool() already calls register_dev_tools() internally,
        // so only register them here when the builder didn't already do it.
        let builder_registered_dev_tools = self.config.builder.enabled
            && (self.config.agent.allow_local_tools || !self.config.sandbox.enabled);
        if self.config.agent.allow_local_tools && !builder_registered_dev_tools {
            tools.register_dev_tools();
        }

        Ok((
            mcp_session_manager,
            mcp_process_manager,
            wasm_tool_runtime,
            extension_manager,
            catalog_entries,
            dev_loaded_tool_names,
        ))
    }

    /// Run all init phases in order and return the assembled components.
    pub async fn build_all(mut self) -> Result<AppComponents, anyhow::Error> {
        self.init_database().await?;
        self.init_secrets().await?;

        // Post-init validation: backends with dedicated config (nearai, gemini_oauth,
        // bedrock, openai_codex) handle their own credential resolution. For registry-based
        // backends, fail early if no provider config was resolved.
        if !matches!(
            self.config.llm.backend.as_str(),
            "nearai" | "gemini_oauth" | "bedrock" | "openai_codex"
        ) && self.config.llm.provider.is_none()
        {
            let backend = &self.config.llm.backend;
            anyhow::bail!(
                "LLM_BACKEND={backend} is configured but no credentials were found. \
                 Set the appropriate API key environment variable or run the setup wizard."
            );
        }

        // Reconcile the LLM turn budget with the agent's handle_message timeout.
        // The TimeoutProvider caps total LLM time at `llm_turn_budget_secs` so
        // stacked retries/failover can't exceed the turn budget and trigger the
        // message-dropping hard-kill. If the configured budget sits too close to
        // (or over) the timeout, clamp it down to a safe ceiling so the cap is
        // GUARANTEED to fire first — self-correcting rather than warn-only.
        // See: llm/timeout.rs, config/llm.rs (`LLM_TURN_BUDGET_SECS`, default 270),
        // config/agent.rs (`HANDLE_MESSAGE_TIMEOUT_SECS`, default 300).
        let budget = self.config.llm.llm_turn_budget_secs;
        let timeout_secs = self.config.agent.handle_message_timeout.as_secs();
        match Self::resolve_turn_budget(budget, self.config.agent.handle_message_timeout) {
            TurnBudgetOutcome::Ok => {}
            TurnBudgetOutcome::Clamp(safe) => {
                tracing::warn!(
                    configured_budget_secs = budget,
                    effective_budget_secs = safe,
                    handle_message_timeout_secs = timeout_secs,
                    "LLM_TURN_BUDGET_SECS was too close to/over the handle_message \
                     timeout; clamped to the safe ceiling so the TimeoutProvider fires \
                     before the hard-kill. Raise HANDLE_MESSAGE_TIMEOUT_SECS for a larger budget."
                );
                self.config.llm.llm_turn_budget_secs = safe;
            }
            TurnBudgetOutcome::TimeoutTooSmall => {
                tracing::warn!(
                    budget_secs = budget,
                    handle_message_timeout_secs = timeout_secs,
                    "HANDLE_MESSAGE_TIMEOUT_SECS is below the hard-kill grace; the LLM \
                     turn budget can't be positioned to fire first. Raise the timeout \
                     or set LLM_TURN_BUDGET_SECS=0 to disable the cap."
                );
            }
        }

        let (llm, cheap_llm, recording_handle) = if let Some(llm) = self.llm_override.take() {
            (llm, None, None)
        } else {
            self.init_llm().await?
        };
        let (safety, tools, embeddings, workspace, builder) = self.init_tools(&llm).await?;

        // Create hook registry early so runtime extension activation can register hooks.
        let hooks = Arc::new(HookRegistry::new());
        let agent_session_manager =
            Arc::new(AgentSessionManager::new().with_hooks(Arc::clone(&hooks)));

        // Shared slot for the SSH bridge, populated after the bridge is built
        // (below) so WASM ssh tools (Option 3) registered during init_extensions
        // can reach it at run time.
        let ssh_bridge_slot: Arc<
            std::sync::OnceLock<Arc<tokio::sync::RwLock<crate::bridge::ssh::SSHBridge>>>,
        > = Arc::new(std::sync::OnceLock::new());

        let (
            mcp_session_manager,
            mcp_process_manager,
            wasm_tool_runtime,
            extension_manager,
            catalog_entries,
            dev_loaded_tool_names,
        ) = self
            .init_extensions(&tools, &hooks, &workspace, ssh_bridge_slot.clone())
            .await?;

        // Load bootstrap-completed flag from settings so that existing users
        // who already completed onboarding don't re-get bootstrap injection.
        // Also check ONBOARD_COMPLETED env var — MT tenants set this to skip
        // the setup wizard, and should not get bootstrap seeding either.
        if let Some(ref ws) = workspace {
            let onboard_env = std::env::var("ONBOARD_COMPLETED")
                .map(|v| v == "true")
                .unwrap_or(false);
            let toml_path = crate::settings::Settings::default_toml_path();
            let profile_done = matches!(
                crate::settings::Settings::load_toml(&toml_path),
                Ok(Some(ref s)) if s.profile_onboarding_completed
            );
            if onboard_env || profile_done {
                ws.mark_bootstrap_completed();
            }
        }

        // Seed workspace and backfill embeddings
        if let Some(ref ws) = workspace {
            // Import workspace files from disk FIRST if WORKSPACE_IMPORT_DIR is set.
            // This lets Docker images / deployment scripts ship customized
            // workspace templates (e.g., AGENTS.md, TOOLS.md) that override
            // the generic seeds. Only imports files that don't already exist
            // in the database — never overwrites user edits.
            //
            // If WORKSPACE_IMPORT_DIR is unset, fall back to
            // $LUNARWING_BASE_DIR/workspace-template/ when it exists.
            //
            // Runs before seed_if_empty() so that custom templates take priority
            // over generic seeds. seed_if_empty() then fills any remaining gaps.
            let import_dir = std::env::var("WORKSPACE_IMPORT_DIR")
                .ok()
                .map(std::path::PathBuf::from)
                .or_else(|| {
                    let default_dir = crate::bootstrap::lunarwing_workspace_template_dir();
                    if default_dir.is_dir() {
                        Some(default_dir)
                    } else {
                        None
                    }
                });

            if let Some(import_path) = import_dir {
                match ws.import_from_directory(&import_path).await {
                    Ok(count) if count > 0 => {
                        tracing::debug!(
                            "Imported {} workspace file(s) from {}",
                            count,
                            import_path.display()
                        );
                    }
                    Ok(_) => {}
                    Err(e) => {
                        tracing::warn!(
                            "Failed to import workspace files from {}: {}",
                            import_path.display(),
                            e
                        );
                    }
                }
            }

            match ws.seed_if_empty().await {
                Ok(_) => {}
                Err(e) => {
                    tracing::warn!("Failed to seed workspace: {}", e);
                }
            }

            if embeddings.is_some() {
                let ws_bg = Arc::clone(ws);
                tokio::spawn(async move {
                    match ws_bg.backfill_embeddings().await {
                        Ok(count) if count > 0 => {
                            tracing::debug!("Backfilled embeddings for {} chunks", count);
                        }
                        Ok(_) => {}
                        Err(e) => {
                            tracing::warn!("Failed to backfill embeddings: {}", e);
                        }
                    }
                });
            }
        }

        // Skills system
        let (skill_registry, skill_catalog) = if self.config.skills.enabled {
            let mut registry = SkillRegistry::new(self.config.skills.local_dir.clone())
                .with_installed_dir(self.config.skills.installed_dir.clone())
                .with_bundled_content(crate::skills::bundled::load_bundled_skills())
                .with_max_scan_depth(self.config.skills.max_scan_depth);
            let loaded = registry.discover_all().await;
            if !loaded.is_empty() {
                tracing::debug!("Loaded {} skill(s): {}", loaded.len(), loaded.join(", "));
            }
            let registry = Arc::new(std::sync::RwLock::new(registry));
            let catalog = crate::skills::catalog::shared_catalog();
            tools.register_skill_tools(Arc::clone(&registry), Arc::clone(&catalog));
            (Some(registry), Some(catalog))
        } else {
            (None, None)
        };

        let context_manager = Arc::new(ContextManager::new(self.config.agent.max_parallel_jobs));
        let cost_guard = Arc::new(crate::agent::cost_guard::CostGuard::new(
            crate::agent::cost_guard::CostGuardConfig {
                max_cost_per_day_cents: self.config.agent.max_cost_per_day_cents,
                max_actions_per_hour: self.config.agent.max_actions_per_hour,
                max_cost_per_user_per_day_cents: None,
            },
        ));

        tracing::debug!(
            "Tool registry initialized with {} total tools",
            tools.count()
        );

        // One-shot cleanup of ghost-seeded tool permission rows from a previous
        // version that wrote baseline defaults into the database.  After the
        // cleanup, no new seed rows are created — effective_permission() falls
        // back to seeded_default_permission_canonical() at runtime, eliminating
        // the latent bypass vector where ghost rows could be mistaken for
        // user-explicit overrides (see port analysis P0-A in IronClaw 0.28.2).
        cleanup_ghost_seeded_tool_permissions(&tools, self.db.as_ref(), &self.config.owner_id)
            .await;

        // ── SSH bridge (Phase 4) ───────────────────────────────────────
        let ssh_bridge = if !self.config.ssh.hosts.is_empty() {
            if let Some(ref secrets) = self.secrets_store {
                let host_map = self.config.ssh.to_host_map();
                let tenant_id =
                    uuid::Uuid::new_v5(&uuid::Uuid::NAMESPACE_DNS, self.config.owner_id.as_bytes());
                let tenant_name = self.config.owner_id.clone();
                let audit_logger = Arc::new(crate::bridge::ssh::NullAuditLogger);
                match SSHBridge::new(
                    tenant_id,
                    tenant_name,
                    host_map,
                    Arc::clone(secrets),
                    audit_logger,
                )
                .await
                {
                    Ok(mut bridge) => {
                        if let Err(e) = bridge.validate().await {
                            tracing::warn!(error = %e, "SSH bridge validation failed");
                        }
                        // Start the SSH agent server so workers can use it via
                        // SSH_AUTH_SOCK. The socket path is predictable:
                        // /home/<owner_id>/lunarwing/run/ssh-agent.sock
                        // (not /tmp — the daemon runs PrivateTmp=true, so the
                        // socket lives in the tenant run dir to be bind-mountable
                        // into worker containers).
                        if let Err(e) = bridge.start_agent_server().await {
                            tracing::warn!(error = %e, "SSH agent server failed to start");
                        } else {
                            tracing::info!(
                                socket = ?bridge.get_agent_socket_path(),
                                "SSH agent server started"
                            );
                        }
                        tracing::info!(
                            hosts = self.config.ssh.hosts.len(),
                            "SSH bridge initialized"
                        );
                        Some(Arc::new(tokio::sync::RwLock::new(bridge)))
                    }
                    Err(e) => {
                        tracing::warn!(error = %e, "Failed to create SSH bridge");
                        None
                    }
                }
            } else {
                tracing::debug!(
                    "SSH hosts configured but no secrets store available, skipping SSH bridge"
                );
                None
            }
        } else {
            None
        };

        // Register the built-in SSH tool now that the bridge exists (Option 2).
        // The SSH bridge is built late (above), so registration happens here
        // rather than alongside the other builtins; `tools` is still owned (it is
        // moved into AppComponents below), and `register_ssh_tool` borrows it.
        if let Some(ref bridge) = ssh_bridge {
            tools.register_ssh_tool(Arc::clone(bridge));
            tools.register_ssh_git_tool(Arc::clone(bridge), crate::bootstrap::lunarwing_base_dir());
            // Populate the shared slot so WASM ssh tools (Option 3) registered
            // earlier during init_extensions can reach the bridge at run time.
            let _ = ssh_bridge_slot.set(Arc::clone(bridge));
        }

        Ok(AppComponents {
            config: self.config,
            db: self.db,
            secrets_store: self.secrets_store,
            llm,
            cheap_llm,
            safety,
            tools,
            embeddings,
            workspace,
            extension_manager,
            mcp_session_manager,
            mcp_process_manager,
            wasm_tool_runtime,
            log_broadcaster: self.log_broadcaster,
            context_manager,
            hooks,
            agent_session_manager,
            skill_registry,
            skill_catalog,
            cost_guard,
            recording_handle,
            session: self.session,
            catalog_entries,
            dev_loaded_tool_names,
            builder,
            ssh_bridge,
        })
    }
}

/// One-shot cleanup of ghost-seeded tool permission rows from a previous
/// version that wrote baseline defaults into the database.
///
/// This is called once at startup after the full tool registry is built.
/// It deletes any `tool_permissions.<name>` rows whose value matches the
/// seeded default for that tool, then records a sentinel so it does not run
/// again.  After this cleanup, no new seed rows are created — `effective_permission()`
/// in `src/tools/permissions.rs` falls back to `seeded_default_permission_canonical()`
/// at runtime, so user-visible behavior is unchanged.
///
/// This closes a latent bypass vector: ghost-seeded rows are indistinguishable
/// from user-explicit overrides.  If LunarWing ever adopts provenance-aware
/// auto-approve gating (where explicit-vs-seeded matters), ghost rows would
/// silently bypass user intent.  See port analysis P0-A (IronClaw 0.28.2).
async fn cleanup_ghost_seeded_tool_permissions(
    tools: &crate::tools::ToolRegistry,
    db: Option<&Arc<dyn crate::db::Database>>,
    owner_id: &str,
) {
    use crate::tools::permissions::seeded_default_permission;

    let db = match db {
        Some(db) => db,
        None => {
            tracing::debug!("cleanup_ghost_seeded: no database available, skipping");
            return;
        }
    };

    // Sentinel gate: skip if already done.
    match db
        .get_setting(owner_id, "_internal.ghost_seed_cleanup_done")
        .await
    {
        Ok(Some(_)) => {
            tracing::debug!("cleanup_ghost_seeded: already completed, skipping");
            return;
        }
        Ok(None) => {} // proceed
        Err(e) => {
            tracing::warn!("cleanup_ghost_seeded: failed to check sentinel: {}", e);
            return;
        }
    }

    // Ignore `tools` param on purpose — we iterate the DB keys directly,
    // deleting only rows whose value exactly matches the seeded default.
    // Unknown tools and non-matching values (user overrides) are left alone.
    let _ = tools;

    let db_map = match db.get_all_settings(owner_id).await {
        Ok(m) => m,
        Err(e) => {
            tracing::warn!("cleanup_ghost_seeded: failed to load settings: {}", e);
            return;
        }
    };

    let prefix = "tool_permissions.";
    let mut cleaned = 0u32;
    let mut errors = 0u32;

    for (key, value) in &db_map {
        if !key.starts_with(prefix) {
            continue;
        }
        let tool_name = &key[prefix.len()..];
        let Some(default_state) = seeded_default_permission(tool_name) else {
            continue;
        };
        let Ok(default_json) = serde_json::to_value(default_state) else {
            continue;
        };
        if *value != default_json {
            // User has an explicit override — leave it alone.
            continue;
        }

        if let Err(e) = db.delete_setting(owner_id, key).await {
            tracing::warn!("cleanup_ghost_seeded: failed to delete '{}': {}", key, e);
            errors += 1;
        } else {
            tracing::debug!(tool = tool_name, "Removed ghost-seeded tool permission row");
            cleaned += 1;
        }
    }

    // Record sentinel regardless of outcome — we don't want to retry on
    // transient errors and risk partial re-cleanup on next startup.
    if let Err(e) = db
        .set_setting(
            owner_id,
            "_internal.ghost_seed_cleanup_done",
            &serde_json::json!(true),
        )
        .await
    {
        tracing::warn!(
            "cleanup_ghost_seeded: failed to set sentinel (cleanup already ran): {}",
            e
        );
    }

    if cleaned > 0 {
        tracing::info!(
            count = cleaned,
            errors,
            "Removed ghost-seeded tool permission rows"
        );
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use super::{AppBuilder, TurnBudgetOutcome};

    use async_trait::async_trait;
    use tokio::sync::mpsc;

    use crate::agent::SessionManager as AgentSessionManager;
    use crate::hooks::{
        Hook, HookContext, HookError, HookEvent, HookOutcome, HookPoint, HookRegistry,
    };

    struct SessionStartHook {
        tx: mpsc::UnboundedSender<(String, String)>,
    }

    #[async_trait]
    impl Hook for SessionStartHook {
        fn name(&self) -> &str {
            "session-start-test"
        }

        fn hook_points(&self) -> &[HookPoint] {
            &[HookPoint::OnSessionStart]
        }

        async fn execute(
            &self,
            event: &HookEvent,
            _ctx: &HookContext,
        ) -> Result<HookOutcome, HookError> {
            if let HookEvent::SessionStart {
                user_id,
                session_id,
            } = event
            {
                self.tx
                    .send((user_id.clone(), session_id.clone()))
                    .expect("test channel receiver should be alive");
            } else {
                panic!("SessionStartHook received an unexpected event: {event:?}");
            }
            Ok(HookOutcome::ok())
        }
    }

    #[tokio::test]
    async fn agent_session_manager_runs_session_start_hooks() {
        let hooks = Arc::new(HookRegistry::new());
        let (tx, mut rx) = mpsc::unbounded_channel();
        hooks.register(Arc::new(SessionStartHook { tx })).await;

        let manager = AgentSessionManager::new().with_hooks(Arc::clone(&hooks));
        manager.get_or_create_session("user-123").await;

        let (user_id, session_id) =
            tokio::time::timeout(std::time::Duration::from_secs(1), rx.recv())
                .await
                .expect("session start hook should fire")
                .expect("session start payload should be present");

        assert_eq!(user_id, "user-123");
        assert!(!session_id.is_empty());
    }

    /// Verify that `cleanup_ghost_seeded_tool_permissions`:
    /// 1. Removes rows whose value matches the seeded default (ghost rows).
    /// 2. Preserves rows with non-seeded values (user overrides).
    /// 3. Is idempotent after sentinel is set.
    #[cfg(feature = "libsql")]
    #[tokio::test]
    async fn cleanup_ghost_seeded_tool_permissions_behavior() {
        use crate::db::Database;
        use crate::db::libsql::LibSqlBackend;
        use crate::tools::ToolRegistry;
        use crate::tools::permissions::{PermissionState, seeded_default_permission};

        let dir = tempfile::tempdir().unwrap();
        let db_path = dir.path().join("test_cleanup.db");
        let backend = LibSqlBackend::new_local(&db_path).await.unwrap();
        backend.run_migrations().await.unwrap();
        let db: Arc<dyn Database> = Arc::new(backend);

        let registry = ToolRegistry::new();
        registry.register_builtin_tools();

        let owner = "test-user";

        // --- Phase 1: verify cleanup removes ghost-seeded rows ---

        // Manually insert a ghost row: "echo" with AlwaysAllow (its seeded default).
        let echo_default = seeded_default_permission("echo").unwrap();
        db.set_setting(
            owner,
            "tool_permissions.echo",
            &serde_json::to_value(echo_default).unwrap(),
        )
        .await
        .unwrap();

        // Verify it's there before cleanup.
        let map_before = db.get_all_settings(owner).await.unwrap();
        assert!(
            map_before.contains_key("tool_permissions.echo"),
            "echo should exist before cleanup"
        );

        // Run cleanup.
        super::cleanup_ghost_seeded_tool_permissions(&registry, Some(&db), owner).await;

        // Verify ghost row is gone.
        let map_after = db.get_all_settings(owner).await.unwrap();
        assert!(
            !map_after.contains_key("tool_permissions.echo"),
            "echo ghost row should be removed by cleanup"
        );

        // Verify sentinel is set.
        let sentinel = db
            .get_setting(owner, "_internal.ghost_seed_cleanup_done")
            .await
            .unwrap();
        assert!(sentinel.is_some(), "sentinel should be set after cleanup");

        // --- Phase 2: verify cleanup preserves user overrides ---

        // User sets echo to Disabled (not the seeded default).
        let disabled_json = serde_json::to_value(PermissionState::Disabled).unwrap();
        db.set_setting(owner, "tool_permissions.echo", &disabled_json)
            .await
            .unwrap();

        // Re-run cleanup (sentinel is already set — should be no-op).
        super::cleanup_ghost_seeded_tool_permissions(&registry, Some(&db), owner).await;

        // Override must survive.
        let map_recheck = db.get_all_settings(owner).await.unwrap();
        assert_eq!(
            map_recheck.get("tool_permissions.echo"),
            Some(&disabled_json),
            "user override to Disabled must survive re-cleanup"
        );

        // --- Phase 3: verify cleanup is idempotent after sentinel ---

        // Run cleanup a third time — should not error and should not change anything.
        super::cleanup_ghost_seeded_tool_permissions(&registry, Some(&db), owner).await;

        let map_final = db.get_all_settings(owner).await.unwrap();
        assert_eq!(
            map_final.get("tool_permissions.echo"),
            Some(&disabled_json),
            "state should be unchanged after second re-cleanup"
        );
    }

    #[test]
    fn turn_budget_default_is_safe() {
        // Defaults: budget=270, timeout=300s, margin=30 → ceiling=270.
        // 270 sits exactly AT the ceiling (not over), so it is safe — no clamp,
        // no warning. (The prior warn-only check flagged this on every startup.)
        assert_eq!(
            AppBuilder::resolve_turn_budget(270, std::time::Duration::from_secs(300)),
            TurnBudgetOutcome::Ok
        );
    }

    #[test]
    fn turn_budget_healthy_gap_is_safe() {
        // budget=180, timeout=300s → 120s headroom → safe.
        assert_eq!(
            AppBuilder::resolve_turn_budget(180, std::time::Duration::from_secs(300)),
            TurnBudgetOutcome::Ok
        );
    }

    #[test]
    fn turn_budget_zero_is_disabled_and_safe() {
        // budget=0 disables the TimeoutProvider → always Ok.
        assert_eq!(
            AppBuilder::resolve_turn_budget(0, std::time::Duration::from_secs(300)),
            TurnBudgetOutcome::Ok
        );
    }

    #[test]
    fn turn_budget_just_over_ceiling_clamps() {
        // budget=271, timeout=300s → ceiling=270 → 271 > 270 → clamp to 270.
        assert_eq!(
            AppBuilder::resolve_turn_budget(271, std::time::Duration::from_secs(300)),
            TurnBudgetOutcome::Clamp(270)
        );
    }

    #[test]
    fn turn_budget_over_timeout_clamps_to_ceiling() {
        // budget=400 > timeout=300s (nonsensical) → clamp to ceiling 270.
        assert_eq!(
            AppBuilder::resolve_turn_budget(400, std::time::Duration::from_secs(300)),
            TurnBudgetOutcome::Clamp(270)
        );
    }

    #[test]
    fn turn_budget_timeout_below_margin_is_unpositionable() {
        // timeout=10s < margin=30s → ceiling saturates to 0 → can't position.
        assert_eq!(
            AppBuilder::resolve_turn_budget(5, std::time::Duration::from_secs(10)),
            TurnBudgetOutcome::TimeoutTooSmall
        );
    }
}
