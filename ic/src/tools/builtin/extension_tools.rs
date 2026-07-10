//! Agent-callable tools for managing extensions (MCP servers and WASM tools).
//!
//! These six tools let the LLM search, install, authenticate, activate, list,
//! and remove extensions entirely through conversation.

use std::sync::Arc;

use async_trait::async_trait;

use crate::context::JobContext;
use crate::extensions::{ExtensionKind, ExtensionManager};
use crate::tools::mcp::McpServerConfig;
use crate::tools::tool::{ApprovalRequirement, Tool, ToolError, ToolOutput, require_str};

// ── tool_search ──────────────────────────────────────────────────────────

pub struct ToolSearchTool {
    manager: Arc<ExtensionManager>,
}

impl ToolSearchTool {
    pub fn new(manager: Arc<ExtensionManager>) -> Self {
        Self { manager }
    }
}

#[async_trait]
impl Tool for ToolSearchTool {
    fn name(&self) -> &str {
        "tool_search"
    }

    fn description(&self) -> &str {
        "Search for available extensions to add new capabilities. Extensions include \
         channels (XMPP — for messaging), tools, and MCP servers. \
         Use discover:true to search online if the built-in registry has no results."
    }

    fn parameters_schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "properties": {
                "query": {
                    "type": "string",
                    "description": "Search query (name, keyword, or description fragment)"
                },
                "discover": {
                    "type": "boolean",
                    "description": "If true, also search online (slower, 5-15s). Try without first.",
                    "default": false
                }
            },
            "required": ["query"]
        })
    }

    async fn execute(
        &self,
        params: serde_json::Value,
        _ctx: &JobContext,
    ) -> Result<ToolOutput, ToolError> {
        let start = std::time::Instant::now();

        let query = params.get("query").and_then(|v| v.as_str()).unwrap_or("");
        let discover = params
            .get("discover")
            .and_then(|v| v.as_bool())
            .unwrap_or(false);

        let results = self
            .manager
            .search(query, discover)
            .await
            .map_err(|e| ToolError::ExecutionFailed(e.to_string()))?;

        let output = serde_json::json!({
            "results": results,
            "count": results.len(),
            "searched_online": discover,
        });

        Ok(ToolOutput::success(output, start.elapsed()))
    }
}

// ── tool_install ─────────────────────────────────────────────────────────

pub struct ToolInstallTool {
    manager: Arc<ExtensionManager>,
}

impl ToolInstallTool {
    pub fn new(manager: Arc<ExtensionManager>) -> Self {
        Self { manager }
    }

    fn mcp_config(
        params: &serde_json::Value,
        name: &str,
    ) -> Result<Option<McpServerConfig>, ToolError> {
        let kind = params.get("kind").and_then(|v| v.as_str());
        let transport = params.get("transport").and_then(|v| v.as_str());
        if kind != Some("mcp_server") && transport.is_none() {
            return Ok(None);
        }
        let config = match transport {
            Some("stdio") => {
                let command = params
                    .get("command")
                    .and_then(|v| v.as_str())
                    .ok_or_else(|| {
                        ToolError::InvalidParameters(
                            "MCP server command is required for stdio transport".to_string(),
                        )
                    })?;
                let args = params
                    .get("args")
                    .map(|value| serde_json::from_value(value.clone()))
                    .transpose()
                    .map_err(|e| {
                        ToolError::InvalidParameters(format!(
                            "MCP stdio args must be an array of strings: {e}"
                        ))
                    })?
                    .unwrap_or_default();
                let env = params
                    .get("env")
                    .map(|value| serde_json::from_value(value.clone()))
                    .transpose()
                    .map_err(|e| {
                        ToolError::InvalidParameters(format!(
                            "MCP stdio env must be an object of string values: {e}"
                        ))
                    })?
                    .unwrap_or_default();
                McpServerConfig::new_stdio(name, command, args, env)
            }
            Some("http") => {
                if params.get("url").and_then(|v| v.as_str()).is_none() {
                    return Err(ToolError::InvalidParameters(
                        "MCP server URL is required for HTTP transport".to_string(),
                    ));
                }
                return Ok(None);
            }
            Some(other) => {
                return Err(ToolError::InvalidParameters(format!(
                    "Unsupported MCP transport '{other}'"
                )));
            }
            None if params.get("command").is_some()
                || params.get("args").is_some()
                || params.get("env").is_some() =>
            {
                return Err(ToolError::InvalidParameters(
                    "MCP transport must be 'stdio' when command, args, or env are provided"
                        .to_string(),
                ));
            }
            None => return Ok(None),
        };

        config
            .validate()
            .map_err(|e| ToolError::InvalidParameters(e.to_string()))?;
        Ok(Some(config))
    }
}

#[async_trait]
impl Tool for ToolInstallTool {
    fn name(&self) -> &str {
        "tool_install"
    }

    fn description(&self) -> &str {
        "Install an extension (channel, tool, or MCP server). \
         Use the name from tool_search results, provide an explicit URL, or configure \
         a host-local stdio MCP server with a command and structured arguments."
    }

    fn parameters_schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "properties": {
                "name": {
                    "type": "string",
                    "description": "Extension name (from search results or custom)"
                },
                "url": {
                    "type": "string",
                    "description": "Explicit URL (for extensions not in the registry)"
                },
                "transport": {
                    "type": "string",
                    "enum": ["http", "stdio"],
                    "description": "MCP transport. Defaults to http when url is provided."
                },
                "command": {
                    "type": "string",
                    "description": "Executable command for a host-local stdio MCP server"
                },
                "args": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "Structured command arguments for a stdio MCP server"
                },
                "env": {
                    "type": "object",
                    "additionalProperties": {"type": "string"},
                    "description": "Non-secret environment variables for a stdio MCP server"
                },
                "kind": {
                    "type": "string",
                    "enum": ["mcp_server", "wasm_tool", "wasm_channel"],
                    "description": "Extension type (auto-detected if omitted)"
                }
            },
            "required": ["name"]
        })
    }

    async fn execute(
        &self,
        params: serde_json::Value,
        ctx: &JobContext,
    ) -> Result<ToolOutput, ToolError> {
        let start = std::time::Instant::now();

        let name = require_str(&params, "name")?;

        let url = params.get("url").and_then(|v| v.as_str());

        let kind_hint = params
            .get("kind")
            .and_then(|v| v.as_str())
            .and_then(|k| match k {
                "mcp_server" => Some(ExtensionKind::McpServer),
                "wasm_tool" => Some(ExtensionKind::WasmTool),
                "wasm_channel" => Some(ExtensionKind::WasmChannel),
                _ => None,
            })
            .or_else(|| {
                params
                    .get("transport")
                    .and_then(|v| v.as_str())
                    .map(|_| ExtensionKind::McpServer)
            });

        let result = match Self::mcp_config(&params, name)? {
            Some(config) => self.manager.install_mcp_config(config, &ctx.user_id).await,
            None => {
                self.manager
                    .install(name, url, kind_hint, &ctx.user_id)
                    .await
            }
        }
        .map_err(|e| ToolError::ExecutionFailed(e.to_string()))?;

        let output = serde_json::to_value(&result)
            .unwrap_or_else(|_| serde_json::json!({"error": "serialization failed"}));

        Ok(ToolOutput::success(output, start.elapsed()))
    }

    fn requires_approval(&self, _params: &serde_json::Value) -> ApprovalRequirement {
        ApprovalRequirement::UnlessAutoApproved
    }
}

// ── tool_auth ────────────────────────────────────────────────────────────

pub struct ToolAuthTool {
    manager: Arc<ExtensionManager>,
}

impl ToolAuthTool {
    pub fn new(manager: Arc<ExtensionManager>) -> Self {
        Self { manager }
    }
}

#[async_trait]
impl Tool for ToolAuthTool {
    fn name(&self) -> &str {
        "tool_auth"
    }

    fn description(&self) -> &str {
        "Initiate authentication for an extension. For OAuth, returns a URL. \
         For manual auth, returns instructions. The user provides their token \
         through a secure channel, never through this tool."
    }

    fn parameters_schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "properties": {
                "name": {
                    "type": "string",
                    "description": "Extension name to authenticate"
                }
            },
            "required": ["name"]
        })
    }

    async fn execute(
        &self,
        params: serde_json::Value,
        ctx: &JobContext,
    ) -> Result<ToolOutput, ToolError> {
        let start = std::time::Instant::now();

        let name = require_str(&params, "name")?;

        let result = self
            .manager
            .auth(name, &ctx.user_id)
            .await
            .map_err(|e| ToolError::ExecutionFailed(e.to_string()))?;

        // Auto-activate after successful auth so tools are available immediately
        if result.is_authenticated() {
            match self.manager.activate(name, &ctx.user_id).await {
                Ok(activate_result) => {
                    let output = serde_json::json!({
                        "status": "authenticated_and_activated",
                        "name": name,
                        "tools_loaded": activate_result.tools_loaded,
                        "message": activate_result.message,
                    });
                    return Ok(ToolOutput::success(output, start.elapsed()));
                }
                Err(e) => {
                    tracing::warn!(
                        "Extension '{}' authenticated but activation failed: {}",
                        name,
                        e
                    );
                    let output = serde_json::json!({
                        "status": "authenticated",
                        "name": name,
                        "activation_error": e.to_string(),
                        "message": format!(
                            "Authenticated but activation failed: {}. Try tool_activate.",
                            e
                        ),
                    });
                    return Ok(ToolOutput::success(output, start.elapsed()));
                }
            }
        }

        let output = serde_json::to_value(&result)
            .unwrap_or_else(|_| serde_json::json!({"error": "serialization failed"}));

        Ok(ToolOutput::success(output, start.elapsed()))
    }

    fn requires_approval(&self, _params: &serde_json::Value) -> ApprovalRequirement {
        // In gateway mode, tool_auth only returns an auth URL for the frontend
        // to open — no browser is launched server-side, so no approval needed.
        if self.manager.should_use_gateway_mode() {
            ApprovalRequirement::Never
        } else {
            ApprovalRequirement::UnlessAutoApproved
        }
    }
}

// ── tool_activate ────────────────────────────────────────────────────────

pub struct ToolActivateTool {
    manager: Arc<ExtensionManager>,
}

impl ToolActivateTool {
    pub fn new(manager: Arc<ExtensionManager>) -> Self {
        Self { manager }
    }
}

#[async_trait]
impl Tool for ToolActivateTool {
    fn name(&self) -> &str {
        "tool_activate"
    }

    fn description(&self) -> &str {
        "Activate an installed extension — starts channels, loads tools, or connects to MCP servers."
    }

    fn parameters_schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "properties": {
                "name": {
                    "type": "string",
                    "description": "Extension name to activate"
                }
            },
            "required": ["name"]
        })
    }

    async fn execute(
        &self,
        params: serde_json::Value,
        ctx: &JobContext,
    ) -> Result<ToolOutput, ToolError> {
        let start = std::time::Instant::now();

        let name = require_str(&params, "name")?;

        match self.manager.activate(name, &ctx.user_id).await {
            Ok(result) => {
                let output = serde_json::to_value(&result)
                    .unwrap_or_else(|_| serde_json::json!({"error": "serialization failed"}));
                Ok(ToolOutput::success(output, start.elapsed()))
            }
            Err(activate_err) => {
                let err_str = activate_err.to_string();
                let needs_auth = err_str.contains("authentication")
                    || err_str.contains("401")
                    || err_str.contains("Unauthorized")
                    || err_str.contains("not authenticated");

                if !needs_auth {
                    return Err(ToolError::ExecutionFailed(err_str));
                }

                // Activation failed due to missing auth; initiate auth flow
                // so the agent loop can show the auth card.
                match self.manager.auth(name, &ctx.user_id).await {
                    Ok(auth_result) if auth_result.is_authenticated() => {
                        // Auth succeeded (e.g. env var was set); retry activation.
                        let result = self
                            .manager
                            .activate(name, &ctx.user_id)
                            .await
                            .map_err(|e| ToolError::ExecutionFailed(e.to_string()))?;
                        let output = serde_json::to_value(&result).unwrap_or_else(
                            |_| serde_json::json!({"error": "serialization failed"}),
                        );
                        Ok(ToolOutput::success(output, start.elapsed()))
                    }
                    Ok(auth_result) => {
                        // Auth needs user input (awaiting_token). Return the auth
                        // result so detect_auth_awaiting picks it up.
                        let output = serde_json::to_value(&auth_result).unwrap_or_else(
                            |_| serde_json::json!({"error": "serialization failed"}),
                        );
                        Ok(ToolOutput::success(output, start.elapsed()))
                    }
                    Err(auth_err) => Err(ToolError::ExecutionFailed(format!(
                        "Activation failed ({}), and authentication also failed: {}",
                        err_str, auth_err
                    ))),
                }
            }
        }
    }
}

// ── tool_list ────────────────────────────────────────────────────────────

pub struct ToolListTool {
    manager: Arc<ExtensionManager>,
}

impl ToolListTool {
    pub fn new(manager: Arc<ExtensionManager>) -> Self {
        Self { manager }
    }
}

#[async_trait]
impl Tool for ToolListTool {
    fn name(&self) -> &str {
        "tool_list"
    }

    fn description(&self) -> &str {
        "List extensions with their authentication and activation status. \
         Set include_available:true to also show registry entries not yet installed."
    }

    fn parameters_schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "properties": {
                "kind": {
                    "type": "string",
                    "enum": ["mcp_server", "wasm_tool", "wasm_channel"],
                    "description": "Filter by extension type (omit to list all)"
                },
                "include_available": {
                    "type": "boolean",
                    "description": "If true, also include registry entries that are not yet installed",
                    "default": false
                }
            }
        })
    }

    async fn execute(
        &self,
        params: serde_json::Value,
        ctx: &JobContext,
    ) -> Result<ToolOutput, ToolError> {
        let start = std::time::Instant::now();

        let kind_filter = params
            .get("kind")
            .and_then(|v| v.as_str())
            .and_then(|k| match k {
                "mcp_server" => Some(ExtensionKind::McpServer),
                "wasm_tool" => Some(ExtensionKind::WasmTool),
                "wasm_channel" => Some(ExtensionKind::WasmChannel),
                _ => None,
            });

        let include_available = params
            .get("include_available")
            .and_then(|v| v.as_bool())
            .unwrap_or(false);

        let extensions = self
            .manager
            .list(kind_filter, include_available, &ctx.user_id)
            .await
            .map_err(|e| ToolError::ExecutionFailed(e.to_string()))?;

        let output = serde_json::json!({
            "extensions": extensions,
            "count": extensions.len(),
        });

        Ok(ToolOutput::success(output, start.elapsed()))
    }
}

// ── tool_remove ──────────────────────────────────────────────────────────

pub struct ToolRemoveTool {
    manager: Arc<ExtensionManager>,
}

impl ToolRemoveTool {
    pub fn new(manager: Arc<ExtensionManager>) -> Self {
        Self { manager }
    }
}

#[async_trait]
impl Tool for ToolRemoveTool {
    fn name(&self) -> &str {
        "tool_remove"
    }

    fn description(&self) -> &str {
        "Permanently remove an installed extension (channel, tool, or MCP server) from disk. \
         This action cannot be undone — the WASM binary and configuration files will be deleted."
    }

    fn parameters_schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "properties": {
                "name": {
                    "type": "string",
                    "description": "Extension name to remove"
                }
            },
            "required": ["name"]
        })
    }

    async fn execute(
        &self,
        params: serde_json::Value,
        ctx: &JobContext,
    ) -> Result<ToolOutput, ToolError> {
        let start = std::time::Instant::now();

        let name = require_str(&params, "name")?;

        let message = self
            .manager
            .remove(name, &ctx.user_id)
            .await
            .map_err(|e| ToolError::ExecutionFailed(e.to_string()))?;

        let output = serde_json::json!({
            "name": name,
            "message": message,
        });

        Ok(ToolOutput::success(output, start.elapsed()))
    }

    fn requires_approval(&self, _params: &serde_json::Value) -> ApprovalRequirement {
        ApprovalRequirement::Always
    }
}

// ── tool_upgrade ─────────────────────────────────────────────────────

pub struct ToolUpgradeTool {
    manager: Arc<ExtensionManager>,
}

impl ToolUpgradeTool {
    pub fn new(manager: Arc<ExtensionManager>) -> Self {
        Self { manager }
    }
}

#[async_trait]
impl Tool for ToolUpgradeTool {
    fn name(&self) -> &str {
        "tool_upgrade"
    }

    fn description(&self) -> &str {
        "Upgrade installed WASM extensions (channels and tools) to match the current \
         host WIT version. If name is omitted, checks and upgrades all installed WASM \
         extensions. Authentication and secrets are preserved."
    }

    fn parameters_schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "properties": {
                "name": {
                    "type": "string",
                    "description": "Extension name to upgrade (omit to upgrade all)"
                }
            }
        })
    }

    async fn execute(
        &self,
        params: serde_json::Value,
        ctx: &JobContext,
    ) -> Result<ToolOutput, ToolError> {
        let start = std::time::Instant::now();

        let name = params.get("name").and_then(|v| v.as_str());

        let result = self
            .manager
            .upgrade(name, &ctx.user_id)
            .await
            .map_err(|e| ToolError::ExecutionFailed(e.to_string()))?;

        let output = serde_json::to_value(&result)
            .unwrap_or_else(|_| serde_json::json!({"error": "serialization failed"}));

        Ok(ToolOutput::success(output, start.elapsed()))
    }

    fn requires_approval(&self, _params: &serde_json::Value) -> ApprovalRequirement {
        ApprovalRequirement::UnlessAutoApproved
    }
}

// ── extension_info ────────────────────────────────────────────────────

pub struct ExtensionInfoTool {
    manager: Arc<ExtensionManager>,
}

impl ExtensionInfoTool {
    pub fn new(manager: Arc<ExtensionManager>) -> Self {
        Self { manager }
    }
}

#[async_trait]
impl Tool for ExtensionInfoTool {
    fn name(&self) -> &str {
        "extension_info"
    }

    fn description(&self) -> &str {
        "Show detailed information about an installed extension, including version \
         and WIT version compatibility."
    }

    fn parameters_schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "properties": {
                "name": {
                    "type": "string",
                    "description": "Extension name to get info about"
                }
            },
            "required": ["name"]
        })
    }

    async fn execute(
        &self,
        params: serde_json::Value,
        ctx: &JobContext,
    ) -> Result<ToolOutput, ToolError> {
        let start = std::time::Instant::now();

        let name = require_str(&params, "name")?;

        let info = self
            .manager
            .extension_info(name, &ctx.user_id)
            .await
            .map_err(|e| ToolError::ExecutionFailed(e.to_string()))?;

        Ok(ToolOutput::success(info, start.elapsed()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_tool_search_schema() {
        let tool = ToolSearchTool {
            manager: test_manager_stub(),
        };
        assert_eq!(tool.name(), "tool_search");
        let schema = tool.parameters_schema();
        assert!(schema.get("properties").is_some());
        assert!(schema["properties"].get("query").is_some());
    }

    #[test]
    fn test_tool_install_schema() {
        use crate::tools::tool::ApprovalRequirement;
        let tool = ToolInstallTool {
            manager: test_manager_stub(),
        };
        assert_eq!(tool.name(), "tool_install");
        assert_eq!(
            tool.requires_approval(&serde_json::json!({})),
            ApprovalRequirement::UnlessAutoApproved
        );
        let schema = tool.parameters_schema();
        assert!(schema["properties"].get("name").is_some());
        assert!(schema["properties"].get("url").is_some());
        assert!(schema["properties"].get("transport").is_some());
        assert!(schema["properties"].get("command").is_some());
        assert!(schema["properties"].get("args").is_some());
        assert!(schema["properties"].get("env").is_some());
    }

    #[test]
    fn test_tool_install_builds_stdio_mcp_config() {
        use crate::tools::mcp::config::EffectiveTransport;

        let params = serde_json::json!({
            "name": "local-files",
            "kind": "mcp_server",
            "transport": "stdio",
            "command": "npx",
            "args": ["-y", "@modelcontextprotocol/server-filesystem", "/srv/data"],
            "env": {"LOG_LEVEL": "warn"}
        });

        let config = ToolInstallTool::mcp_config(&params, "local-files")
            .expect("valid request")
            .expect("MCP config");
        match config.effective_transport() {
            EffectiveTransport::Stdio { command, args, env } => {
                assert_eq!(command, "npx");
                assert_eq!(
                    args,
                    ["-y", "@modelcontextprotocol/server-filesystem", "/srv/data"]
                );
                assert_eq!(env.get("LOG_LEVEL").map(String::as_str), Some("warn"));
            }
            other => panic!("expected stdio transport, got {other:?}"),
        }
    }

    #[test]
    fn test_tool_install_rejects_non_string_stdio_env_values() {
        let params = serde_json::json!({
            "name": "local-files",
            "kind": "mcp_server",
            "transport": "stdio",
            "command": "local-files-mcp",
            "env": {"PORT": 3000}
        });

        let err = ToolInstallTool::mcp_config(&params, "local-files")
            .expect_err("numeric env value must fail");
        assert!(err.to_string().contains("object of string values"));
    }

    #[test]
    fn test_tool_install_defers_registry_mcp_install() {
        let params = serde_json::json!({
            "name": "local-files",
            "kind": "mcp_server"
        });

        assert!(
            ToolInstallTool::mcp_config(&params, "local-files")
                .expect("valid registry request")
                .is_none()
        );
    }

    #[test]
    fn test_tool_install_defers_http_mcp_install() {
        let params = serde_json::json!({
            "name": "hosted-server",
            "kind": "mcp_server",
            "transport": "http",
            "url": "https://example.com/mcp"
        });

        assert!(
            ToolInstallTool::mcp_config(&params, "hosted-server")
                .expect("valid HTTP request")
                .is_none()
        );
    }

    #[test]
    fn test_tool_auth_schema() {
        use crate::tools::tool::ApprovalRequirement;
        let tool = ToolAuthTool {
            manager: test_manager_stub(),
        };
        assert_eq!(tool.name(), "tool_auth");
        assert_eq!(
            tool.requires_approval(&serde_json::json!({})),
            ApprovalRequirement::UnlessAutoApproved
        );
        let schema = tool.parameters_schema();
        assert!(schema["properties"].get("name").is_some());
        // token param must NOT be in schema (security: tokens never go through LLM)
        assert!(
            schema["properties"].get("token").is_none(),
            "tool_auth must not have a token parameter"
        );
    }

    #[test]
    fn test_tool_activate_schema() {
        use crate::tools::tool::ApprovalRequirement;
        let tool = ToolActivateTool {
            manager: test_manager_stub(),
        };
        assert_eq!(tool.name(), "tool_activate");
        assert_eq!(
            tool.requires_approval(&serde_json::json!({})),
            ApprovalRequirement::Never
        );
    }

    #[test]
    fn test_tool_list_schema() {
        use crate::tools::tool::ApprovalRequirement;
        let tool = ToolListTool {
            manager: test_manager_stub(),
        };
        assert_eq!(tool.name(), "tool_list");
        assert_eq!(
            tool.requires_approval(&serde_json::json!({})),
            ApprovalRequirement::Never
        );
        let schema = tool.parameters_schema();
        assert!(schema["properties"].get("kind").is_some());
    }

    #[test]
    fn test_tool_remove_schema() {
        use crate::tools::tool::ApprovalRequirement;
        let tool = ToolRemoveTool {
            manager: test_manager_stub(),
        };
        assert_eq!(tool.name(), "tool_remove");
        assert_eq!(
            tool.requires_approval(&serde_json::json!({})),
            ApprovalRequirement::Always
        );
    }

    #[test]
    fn tool_remove_always_requires_approval_regardless_of_params() {
        use crate::tools::tool::ApprovalRequirement;
        let tool = ToolRemoveTool {
            manager: test_manager_stub(),
        };

        let test_cases = vec![
            ("no params", serde_json::json!({})),
            ("empty name", serde_json::json!({"name": ""})),
            ("gotify", serde_json::json!({"name": "gotify"})),
            ("github-cli", serde_json::json!({"name": "github-cli"})),
            (
                "with extra fields",
                serde_json::json!({"name": "tool", "extra": "field"}),
            ),
        ];

        for (case_name, params) in test_cases {
            assert_eq!(
                tool.requires_approval(&params),
                ApprovalRequirement::Always,
                "tool_remove must always require approval for case: {}",
                case_name
            );
        }
    }

    #[tokio::test]
    async fn tool_auth_no_approval_in_gateway_mode() {
        let manager = test_manager_stub();
        manager
            .enable_gateway_mode("http://localhost:3000".to_string())
            .await;
        let tool = ToolAuthTool {
            manager: manager.clone(),
        };
        assert_eq!(
            tool.requires_approval(&serde_json::json!({})),
            ApprovalRequirement::Never,
            "tool_auth should not require approval in gateway mode"
        );
    }

    #[test]
    fn test_tool_upgrade_schema() {
        use crate::tools::tool::ApprovalRequirement;
        let tool = ToolUpgradeTool {
            manager: test_manager_stub(),
        };
        assert_eq!(tool.name(), "tool_upgrade");
        assert_eq!(
            tool.requires_approval(&serde_json::json!({})),
            ApprovalRequirement::UnlessAutoApproved
        );
        let schema = tool.parameters_schema();
        // name is optional (omit to upgrade all)
        assert!(schema["properties"].get("name").is_some());
        assert!(
            schema.get("required").is_none(),
            "tool_upgrade should have no required params"
        );
    }

    #[test]
    fn test_extension_info_schema() {
        let tool = ExtensionInfoTool {
            manager: test_manager_stub(),
        };
        assert_eq!(tool.name(), "extension_info");
        let schema = tool.parameters_schema();
        assert!(schema["properties"].get("name").is_some());
        let required = schema["required"].as_array().unwrap();
        assert!(required.iter().any(|v| v.as_str() == Some("name")));
    }

    /// Create a stub manager for schema tests (these don't call execute).
    fn test_manager_stub() -> Arc<ExtensionManager> {
        use crate::secrets::{InMemorySecretsStore, SecretsCrypto};
        use crate::testing::credentials::TEST_CRYPTO_KEY;
        use crate::tools::ToolRegistry;
        use crate::tools::mcp::session::McpSessionManager;

        let master_key = secrecy::SecretString::from(TEST_CRYPTO_KEY.to_string());
        let crypto = Arc::new(SecretsCrypto::new(master_key).unwrap());

        Arc::new(ExtensionManager::new(
            Arc::new(McpSessionManager::new()),
            Arc::new(crate::tools::mcp::process::McpProcessManager::new()),
            Arc::new(InMemorySecretsStore::new(crypto)),
            Arc::new(ToolRegistry::new()),
            None,
            None,
            std::env::temp_dir().join("lunarwing-test-tools"),
            std::env::temp_dir().join("lunarwing-test-channels"),
            None,
            "test".to_string(),
            None,
            Vec::new(),
        ))
    }
}
