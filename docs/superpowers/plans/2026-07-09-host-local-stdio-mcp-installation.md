# Host-Local stdio MCP Installation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make stdio MCP servers installable and manageable through registry, chat, API, and web settings surfaces.

**Architecture:** Preserve the existing `McpServerConfig` and transport factory as the runtime contract. Add a typed stdio registry source and route all new installation inputs through one `ExtensionManager::install_mcp_config` persistence boundary; keep existing URL installs additive and unchanged.

**Tech Stack:** Rust 2024, Serde, Axum, Tokio process management, vanilla JavaScript/CSS, MCP JSON-RPC transports

---

### Task 1: Model registry-defined stdio MCP servers

**Files:**
- Modify: `ic/src/extensions/mod.rs`
- Modify: `ic/src/registry/manifest.rs`

- [ ] Add a failing manifest test that parses a typed stdio transport and expects `ExtensionSource::McpStdio`.
- [ ] Run `taskset -c 0-5 cargo test -j6 registry::manifest::tests::test_parse_stdio_mcp_server_manifest -- --exact` from `ic/` and confirm the missing transport/source behavior fails.
- [ ] Add `McpStdio` to `ExtensionSource` and a tagged `McpManifestTransport::Stdio` manifest type.
- [ ] Convert stdio manifests to registry entries with `AuthHint::None`, preserving the existing URL fallback.
- [ ] Re-run the targeted manifest tests and confirm they pass.

### Task 2: Add validated MCP config installation

**Files:**
- Modify: `ic/src/tools/mcp/config.rs`
- Modify: `ic/src/extensions/manager.rs`
- Modify: `ic/src/extensions/mod.rs`

- [ ] Add failing tests for invalid stdio environment data, manager persistence, duplicate rejection, no-auth status, listing metadata, and process shutdown on removal.
- [ ] Run the targeted tests and confirm each fails for the intended missing behavior.
- [ ] Harden stdio configuration validation for command, arguments, and environment entries.
- [ ] Add `ExtensionManager::install_mcp_config` and route URL/registry sources through it.
- [ ] Report non-HTTP servers as no-auth-required and include transport/command metadata in installed extension listings.
- [ ] Shut down `McpProcessManager` entries during MCP removal.
- [ ] Re-run the targeted tests and confirm they pass.

### Task 3: Extend API and conversational installation contracts

**Files:**
- Modify: `ic/src/channels/web/types.rs`
- Modify: `ic/src/channels/web/server.rs`
- Modify: `ic/src/channels/web/handlers/extensions.rs`
- Modify: `ic/src/tools/builtin/extension_tools.rs`

- [ ] Add failing request conversion tests for stdio and invalid transport inputs.
- [ ] Extend the existing `tool_install` schema test to require `transport`, `command`, `args`, and `env`.
- [ ] Run the targeted tests and confirm failures.
- [ ] Add additive request fields and a shared request-to-MCP-config conversion helper.
- [ ] Route stdio requests to `install_mcp_config` in both active and modular extension handlers.
- [ ] Parse structured stdio inputs in `tool_install` and route them to the same manager boundary.
- [ ] Re-run targeted tests and confirm they pass.

### Task 4: Complete registry CLI support

**Files:**
- Modify: `ic/src/cli/mcp.rs`
- Modify: `ic/src/cli/registry.rs`

- [ ] Add failing tests for MCP kind parsing and stdio manifest-to-config conversion.
- [ ] Run the targeted CLI tests and confirm failures.
- [ ] Extract reusable MCP config persistence from `mcp add` while preserving upsert behavior.
- [ ] Teach registry list/info about MCP transport details.
- [ ] Branch single MCP registry installs away from `RegistryInstaller` and persist the resolved config with `--force` overwrite semantics.
- [ ] Re-run targeted CLI tests and confirm they pass.

### Task 5: Add the web stdio form

**Files:**
- Modify: `ic/src/channels/web/static/index.html`
- Modify: `ic/src/channels/web/static/app.js`
- Modify: `ic/src/channels/web/static/style.css`
- Modify: `ic/src/channels/web/static/i18n/en.js`
- Modify: `ic/src/channels/web/static/i18n/zh-CN.js`

- [ ] Add HTTP/stdio segmented mode controls and stable mode-specific fields.
- [ ] Parse argument and non-secret environment lines into structured request data.
- [ ] Reset fields and mode after a successful installation.
- [ ] Render stdio transport and command metadata for installed MCP entries.
- [ ] Run `node --check src/channels/web/static/app.js` from `ic/`.

### Task 6: Documentation and full verification

**Files:**
- Modify: `ic/src/tools/README.md`
- Modify: `docs/proposals/SUPERGATEWAY_MCP.md`
- Modify: `docs/proposals/V2_MCP_EXTENSION_ARCHITECTURE_EXPLORATION.md`

- [ ] Document host-local stdio installation and the non-secret environment rule.
- [ ] Mark the old no-stdio finding as superseded while retaining supergateway as an operational option.
- [ ] Run `taskset -c 0-5 cargo fmt --all -- --check` from `ic/`.
- [ ] Run targeted MCP, extension manager, registry, web type, and tool tests with `taskset -c 0-5` and `-j6`.
- [ ] Run `taskset -c 0-5 cargo check -j6` from `ic/`.
- [ ] Run `git diff --check` from the repository root and inspect the final scoped diff.

