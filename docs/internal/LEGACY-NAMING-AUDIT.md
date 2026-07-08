# Legacy Naming Audit — `nearai` / `near` / `ironclaw` / `nearcloud` / `nearagent` / `near::agent` Remaining References

**Date:** 2026-07-08
**Scope:** Full repository audit for all remaining references to legacy NearAI/IronClaw branding
**Method:** Regex search across all files (excluding `Cargo.lock`, `node_modules`, `.git`, vendored dirs) for patterns: `nearai`, `near_ai`, `NearAI`, `near.ai`, `ironclaw`, `IronClaw`, `IRONCLAW`, `iron_claw`, `nearcloud`, `near_cloud`, `nearagent`, `near_agent`, `NearCloud`, `NearAgent`, `near::agent`, `near:agent`

---

## Summary

| Category | Files | Matches | Classification |
|----------|------:|--------:|----------------|
| Source Code — Provider/LLM (`near.ai` URLs) | 13 | 33 | Operational dependency (NearAI cloud API) |
| Source Code — Env Var Aliases (`IRONCLAW_*`) | 22 | ~110 | Compatibility bridge (~40 distinct env vars) |
| Source Code — WebSocket Subprotocol | 3 | 6 | Compatibility alias |
| Source Code — Filesystem Paths (`.ironclaw`, `ironclaw.db`) | 7 | ~25 | Legacy default paths |
| Source Code — Keychain/Service Name | 1 | 1 | Service identifier |
| Source Code — Upstream References (comments/links) | 3 | 3 | Historical attribution |
| Scripts — Watchdog/Setup/Harness | 10 | 48 | Compatibility aliases + legacy cleanup |
| Systemd/OpenRC Units | 4 | 4 | Legacy env var injection |
| Deploy/Run Scripts | 3 | 5 | Var bridging |
| Tests | 7 | 19 | Compatibility regression tests + fixture docs |
| Worker Containers (nanocode/pebble/opencode) | 12 | ~20 | Protocol alias + docs |
| Infrastructure Health Check | 10 | ~30 | Compatibility aliases + self-heal |
| WASM Build Tools (gotify/darkirc/weechat) | 5 | ~12 | Legacy var aliases |
| TensorZero Proxy Configs | 2 | 59 | Function naming |
| Documentation (docs/) | 74 | — | Migration guides, historical references, specs |
| WIT/Protocol namespaces | 0 | 0 | ✅ Clean |
| Crates / `lunarwing_mt_onboard` | 0 | 0 | ✅ Clean |

**Total: ~200+ files containing legacy references across the repository.**

---

## 1. Source Code (`ic/src/`)

### 1.1 Provider/LLM — `near.ai` URLs & NearAI Provider (13 files, 33 matches)

These are **operational dependencies** — they reference the NearAI cloud API provider that LunarWing still supports as an LLM backend (`lunarwing_cloud`). Not pure legacy branding — actual external service endpoints.

| File | Matches | Nature |
|------|--------:|--------|
| `ic/src/setup/wizard.rs` | 7 | Default base URLs for `near.ai` cloud-api and private endpoints |
| `ic/src/setup/README.md` | 5 | Provider configuration documentation |
| `ic/src/config/llm.rs` | 3 | Default base URL constants |
| `ic/src/llm/session.rs` | 6 | Auth URL defaults, OAuth flow comments |
| `ic/src/cli/oauth_defaults.rs` | 2 | OAuth redirect URL template (`kind-deer.agent1.near.ai`) |
| `ic/src/sandbox/config.rs` | 2 | Credential mapping for `api.near.ai` |
| `ic/src/llm/models.rs` | 1 | Default auth base URL |
| `ic/src/llm/config.rs` | 3 | Default base URLs (cloud-api + private) |
| `ic/src/llm/CLAUDE.md` | 2 | Provider mode documentation |
| `ic/src/llm/mod.rs` | 1 | Default base URL for provider |
| `ic/src/tools/builtin/image_gen.rs` | 1 | Example URL in doc comment |
| `ic/src/tools/builtin/memory.rs` | 1 | Link to `github.com/nearai/ironclaw/pull/1118` |
| `ic/src/channels/web/static/app.js` | 2 | `nearai` listed as provider option in web UI |

**Classification:** External service integration, not removable without dropping the NearAI provider.

### 1.2 Environment Variable Compatibility Aliases (`IRONCLAW_*`)

These are **legacy env var bridges** — the code accepts `IRONCLAW_*` names as fallbacks when `LUNARWING_*` equivalents are unset. This is deliberate backward compatibility.

#### Config Var Mapping Table (`ic/src/config/helpers.rs`)

| LUNARWING Var | Legacy IronClaw Var |
|---------------|---------------------|
| `LUNARWING_OAUTH_CALLBACK_URL` | `IRONCLAW_OAUTH_CALLBACK_URL` |
| `LUNARWING_OAUTH_EXCHANGE_URL` | `IRONCLAW_OAUTH_EXCHANGE_URL` |
| `LUNARWING_OAUTH_PROXY_AUTH_TOKEN` | `IRONCLAW_OAUTH_PROXY_AUTH_TOKEN` |
| `LUNARWING_OWNER_ID` | `IRONCLAW_OWNER_ID` |
| `LUNARWING_IN_DOCKER` | `IRONCLAW_IN_DOCKER` |
| `LUNARWING_DISABLE_RESTART` | `IRONCLAW_DISABLE_RESTART` |
| `LUNARWING_RESTART_DELAY` | `IRONCLAW_RESTART_DELAY` |
| `LUNARWING_MAX_FAILURES` | `IRONCLAW_MAX_FAILURES` |
| `LUNARWING_SERVICE_MANAGER` | `IRONCLAW_SERVICE_MANAGER` |
| `LUNARWING_INSTANCE_ID` | `IRONCLAW_INSTANCE_ID` |
| `LUNARWING_INSTANCE_NAME` | `IRONCLAW_INSTANCE_NAME` |

#### Additional Env Var Aliases

| File | Var | Context |
|------|-----|---------|
| `bootstrap.rs` | `IRONCLAW_BASE_DIR` | Base dir fallback |
| `bootstrap.rs` | `ironclaw.db` | Default libSQL DB filename |
| `bootstrap.rs` | `.ironclaw` | Default base dir path |
| `config/mod.rs` | `IRONCLAW_OWNER_ID` | Owner scope resolution |
| `channels/wasm/bundled.rs` | `IRONCLAW_CHANNELS_SRC` | Channels source dir |
| `tools/wasm/loader.rs` | `IRONCLAW_TOOLS_SRC` | Tools source dir |
| `tools/builtin/restart.rs` | `IRONCLAW_IN_DOCKER` | Docker detection |
| `tools/builtin/restart.rs` | `IRONCLAW_RESTART_DELAY` | Restart timing |
| `tools/builtin/restart.rs` | `IRONCLAW_MAX_FAILURES` | Failure threshold |
| `llm/recording.rs` | `IRONCLAW_RECORD_TRACE` | Trace recording toggle |
| `llm/recording.rs` | `IRONCLAW_TRACE_OUTPUT` | Trace output path |
| `llm/recording.rs` | `IRONCLAW_TRACE_MODEL_NAME` | Trace model name |
| `orchestrator/job_manager.rs` | `IRONCLAW_WORKER_TOKEN` | Worker auth token |
| `orchestrator/job_manager.rs` | `IRONCLAW_JOB_ID` | Job ID injection |
| `orchestrator/job_manager.rs` | `IRONCLAW_ORCHESTRATOR_URL` | Orchestrator URL injection |
| `orchestrator/job_manager.rs` | `IRONCLAW_WORKSPACE` | Workspace path injection |
| `orchestrator/external_worker.rs` | `ironclaw-agent-v1` | WS subprotocol |
| `worker/api.rs` | `IRONCLAW_WORKER_TOKEN` | Worker token fallback |
| `worker/container.rs` | `IRONCLAW_WORKER_TOKEN` | Worker token (re-export) |
| `worker/acp_bridge.rs` | `IRONCLAW_WORKER_TOKEN` | Worker token (re-export) |
| `service.rs` | `com.ironclaw.daemon` | launchd service label |
| `service.rs` | `ironclaw.service` | Legacy systemd unit name |
| `main.rs` | `IRONCLAW_SOCKET` | REPL socket fallback |
| `cli/repl.rs` | `IRONCLAW_SOCKET` | REPL socket fallback |
| `cli/tool.rs` | `.ironclaw` | Default dir assertion |
| `channels/web/openai_compat.rs` | `x-ironclaw-streaming` | Legacy header check |
| `channels/web/server.rs` | `IRONCLAW_OAUTH_CALLBACK_URL` | OAuth callback |
| `channels/web/static/theme-init.js` | `ironclaw-theme` | localStorage migration |
| `bridge/auth_manager.rs` | `IRONCLAW_OAUTH_CALLBACK_URL` | OAuth bridge auth |
| `settings.rs` | `.ironclaw` | Default base dir assertions |

**Classification:** Compatibility layer. Requires migration path + deprecation window before removal.

### 1.3 WebSocket Subprotocol — `ironclaw-agent-v1` (3 files, 6 matches)

| File | Line | Context |
|------|-----|---------|
| `ic/src/orchestrator/external_worker.rs` | 32-33 | `SUBPROTOCOL_LEGACY: &str = "ironclaw-agent-v1"` constant |
| `ic/src/channels/web/openai_compat.rs` | 721 | Header `x-ironclaw-streaming` |
| `ic/src/llm/oauth_helpers.rs` | 39 | OAuth callback doc reference |

**Classification:** Compatibility alias for pre-rename workers. Shared with `pebble4lunarwing` and `opencode4lunarwing`.

### 1.4 Filesystem Paths — `.ironclaw` / `ironclaw.db` (7 files, ~25 matches)

| File | Matches | Context |
|------|--------:|---------|
| `bootstrap.rs` | 15 | `IRONCLAW_BASE_DIR` fallback, `.ironclaw` default, `ironclaw.db` default |
| `setup/wizard.rs` | 6 | `IRONCLAW_OWNER_ID` test fixtures |
| `settings.rs` | 2 | `.ironclaw` path assertions |
| `cli/tool.rs` | 1 | `.ironclaw` path assertion |
| `channels/wasm/wrapper.rs` | 3 | `.ironclaw` attachment dir fallback |
| `secrets/keychain.rs` | 1 | `SERVICE_NAME = "ironclaw"` keychain service |
| `tools/builtin/restart.rs` | 2 | `IRONCLAW_IN_DOCKER` in tests |

**Classification:** Legacy default paths. Migration requires runtime detection + data migration.

### 1.5 Keychain/Service Name

| File | Value | Impact |
|------|-------|--------|
| `ic/src/secrets/keychain.rs` | `SERVICE_NAME: &str = "ironclaw"` | OS keychain entry name; changing breaks existing secret retrieval |

**Classification:** User-facing credential migration required.

### 1.6 Upstream Attribution Links

| File | Reference | Nature |
|------|-----------|--------|
| `ic/src/tools/builtin/memory.rs:807` | `https://github.com/nearai/ironclaw/pull/1118` | Comment link to upstream PR |
| `ic/src/channels/web/static/app.js:5041` | `'nearai'` in provider select | Web UI provider option |
| `ic/clippy.toml:3` | `https://github.com/nearai/ironclaw/issues/338` | Lint config reference |

**Classification:** Historical attribution. Low priority.

---

## 2. Scripts (`ic/scripts/`)

| File | Matches | Nature |
|------|--------:|---------|
| `install-lunarwing-watchdog.sh` | 13 | Legacy service cleanup (`ironclaw-watchdog.timer`, `ironclaw-watchdog.service`, etc.) |
| `lunarwing-xmpp-test-env.sh` | 11 | Legacy env var seeding (`IRONCLAW_BASE_DIR`, `IRONCLAW_SOCKET`) |
| `reimport-fixes.sh` | 5 | Hardcoded `/home/cmc/kageho_old/.ironclaw/ironclaw.db` migration paths |
| `lunarwing-mt-admin.sh` | 5 | Legacy env vars, stale file detection |
| `lunarwing-watchdog.sh` | 4 | Legacy env var aliases (dual-prefix pattern) |
| `lunarwing-watchdog-openrc.sh` | 4 | Legacy env var aliases |
| `setup-instance.sh` | 2 | `IRONCLAW_BASE_DIR` fallback, `~/.ironclaw` default |
| `ci/quality_gate.sh` | 2 | `IRONCLAW_PREPUSH_TEST` legacy alias |
| `reorg_docs.sh` | 1 | `IRONCLAW_PORT_VERIFICATION.md` reference in file list |
| `export-tenant.sh` | 1 | Comment about "pre-rename source named ironclaw" |

**Classification:** Legacy compatibility paths and cleanup logic for pre-rename tenants.

---

## 3. Systemd/OpenRC Units (`ic/systemd/`)

| File | Reference | Purpose |
|------|-----------|---------|
| `lunarwing.service` | `IRONCLAW_BASE_DIR=/var/lib/lunarwing` | Legacy env var injection for bridge compatibility |
| `xmpp-bridge.service` | `IRONCLAW_BASE_DIR=/var/lib/lunarwing` | Bridge config (pre-rename compat) |
| `lunarwing.openrc` | `IRONCLAW_BASE_DIR="${lunarwing_base_dir}"` | OpenRC var bridge |
| `xmpp-bridge.openrc` | `IRONCLAW_BASE_DIR="${xmpp_bridge_base_dir}"` | OpenRC var bridge |

**Classification:** Bridge compat — XMPP bridge reads `IRONCLAW_BASE_DIR`; these keep older bridge configs working.

---

## 4. Deploy/Run Scripts

| File | Matches | Nature |
|------|--------:|---------|
| `ic/deploy/run.sh` | 2 | Bridges `LUNARWING_BASE_DIR` → `IRONCLAW_BASE_DIR` |
| `ic/deploy/env.example` | 1 | Comment noting legacy `IRONCLAW_*` names still work |
| `ic/run.sh` | 2 | Same bridging pattern |

**Classification:** Backward compat for older deployment configs.

---

## 5. Tests (`ic/tests/`)

| File | Matches | Nature |
|------|--------:|---------|
| `openai_compat_integration.rs` | 2 | `x-ironclaw-streaming` header assertion |
| `external_worker_integration.rs` | 6 | `ironclaw-agent-v1` subprotocol compat tests |
| `support/assertions.rs` | 1 | Comment: "Mirrors assertion types from `nearai/benchmarks`" |
| `e2e_spot_checks.rs` | 1 | Comment: "adapted from nearai/benchmarks SpotSuite" |
| `tool_schema_validation.rs` | 1 | Link to `github.com/nearai/ironclaw/issues/352` |
| `fixtures/llm_traces/README.md` | 3 | Legacy env var aliases documented |
| `e2e/conftest.py` | 3 | Intentional `IRONCLAW_*` env name testing |

**Classification:** Validates legacy compat (must keep until compat removed) + attribution comments.

---

## 6. Worker Containers

### Nanocode Worker (`lunarcode4lunarwing/`)

| File | Reference |
|------|-----------|
| `AGENTS.md` | `ironclaw-agent-v1` protocol alias notice |
| `scripts/lunarwing_runtime.ts` | `LEGACY_SUBPROTOCOL = "ironclaw-agent-v1"` constant |
| `scripts/lunarwing_bridge.ts` | Protocol alias comment |
| `scripts/smoke_test.ts` | Subprotocol negotiation test |
| `CLAUDE.md` | Worker protocol documentation |

### Pebble Worker (`pebble4lunarwing/`)

| File | Reference |
|------|-----------|
| `CLAUDE.md` | Protocol alias documentation |
| `src/bridge.rs` | Subprotocol negotiation tests (4 cases) |
| `src/protocol.rs` | `LEGACY_SUBPROTOCOL` constant |
| `README.md` | Protocol alias notice |

### Opencode Worker (`opencode4lunarwing/`)

| File | Reference |
|------|-----------|
| `AGENTS.md` | Protocol alias notice |
| `scripts/lunarwing_runtime.ts` | `LEGACY_SUBPROTOCOL` constant |
| `scripts/lunarwing_bridge.ts` | Protocol alias comment |
| `scripts/smoke_test.ts` | Subprotocol negotiation test |
| `CLAUDE.md` | Worker protocol documentation |
| `README.md` | Protocol alias notice |

**Classification:** Shared WS subprotocol alias across all workers. Must be lifted simultaneously.

---

## 7. Infrastructure Health Check (`ic-infrastructure-health-check/`)

| File | Matches | Nature |
|------|--------:|---------|
| `lunarwing-self-heal.sh` | 5 | `IRONCLAW_BASE_DIR`, `IRONCLAW_SERVICE_MANAGER` aliases; legacy proxy unit detection |
| `infrastructure-health-check.sh` | 1 | Base dir fallback |
| `config.sh.example` | 2 | Legacy alias config comments |
| `health-gateway.sh` | 1 | Base dir fallback |
| `health-xmpp.sh` | 2 | Base dir fallback |
| `health-omemo.sh` | 2 | Base dir fallback |
| `health-ratelimit.sh` | 1 | Base dir fallback |
| `tests/test-self-heal-matrix.sh` | 3 | `ironclaw-proxy-acme.service` test case |
| `README.md` | 4 | Legacy var documentation |

**Classification:** Runtime compat + legacy unit cleanup logic.

---

## 8. WASM Build Tools & Channels

### Gotify WASM Tool

| File | Reference | Nature |
|------|-----------|--------|
| `ic/lunarwing-gotify-tool/src/lib.rs` | `IronClaw WASM tool` | Module doc comment |
| `ic/lunarwing-gotify-tool/build.sh` | `Building...WASM tool for IronClaw` | Build output message |
| `gotify-wasm/lunarwing-gotify-tool/src/lib.rs` | `IronClaw WASM tool` | Module doc comment |
| `gotify-wasm/lunarwing-gotify-tool/build.sh` | `Building...WASM tool for IronClaw` | Build output message |

### DarkIRC Channel

| File | Reference |
|------|-----------|
| `darkirc_channel_for_lunarwing/darkirc/build.sh` | `IRONCLAW_HOME`, `IRONCLAW_REPO` legacy aliases |

### WeeChat Relay

| File | Reference |
|------|-----------|
| `lunarwing_weechat_wss/weechat_relay/src/lib.rs` | Guard check rejecting `ironclaw` in relay output |
| `lunarwing_weechat_wss/weechat_relay/build.sh` | `IRONCLAW_HOME`, `IRONCLAW_REPO` legacy aliases |

**Classification:** Build-time compat aliases + doc comments. The WeeChat guard is a runtime safety check, not legacy branding.

---

## 9. TensorZero Proxy Configs

| File | Matches | Key Sections |
|------|--------:|--------------|
| `tensorzero-proxy-configurations/tensorzero.toml` | 30 | `[functions.ironclaw]` + 15 variants, `[functions.ironclaw_hardened]` + 4 variants |
| `nanocode-config/tensorzero.toml` | 29 | Same pattern |

**Classification:** TensorZero function/variant naming — decoupled from Rust code but still user-facing config. Has its own migration path.

---

## 10. Documentation (`docs/`) — 74 files

The docs tree preserves historical references intentionally. Key subsections:

| Category | Examples |
|----------|----------|
| Migration guides (active) | `MIGRATE_IRONCLAW_TO_LUNARWING.md`, `MIGRATE_IRONCLAW_TO_MT.md`, `MIGRATE_IRONCLAW_LIBSQL_TO_MT.md` |
| Release notes (historical) | `RELEASE-v1.0.7.md` through `RELEASE-v1.1.8.md` — record history accurately |
| Goals/checklists (historical) | `GOALS_1.0.6.md`, `GOALS_1.1.8.md` — past checklists |
| Proposals (active reference) | `SSH_HARNESS_OPTION_2_3_IMPLEMENTATION.md`, `MT-ONBOARDING-CLI.md` |
| Active specs | `Near-Removal.md` (the removal feature spec), `Near-Removal.md` (plan) |
| Architecture review | `SWEETIE-ARCH-REVIEW.md` — references IronClaw for fork context |
| Worker docs | `PEBBLE-WORKER.md`, `NANOCODE-MULTITENANT.md`, `WORKER-CONTAINERS.md` |
| Internal/history | `internal/history/` archive — preserved for provenance |

**Classification:** Historical archive is preserved intentionally per repo convention. Migration guides are active instructions. Specs reference IronClaw for fork context.

---

## 11. WIT/Protocol Namespaces

**Status: ✅ Clean** — No `near::agent`, `near:agent`, or `near_agent` references found in any `.wit` or JSON protocol files.

---

## 12. `nearcloud` / `nearagent`

**Status: ✅ Clean** — No references to `nearcloud`, `near_cloud`, `nearagent`, or `near_agent` found anywhere in the repository.

---

## Prioritized Removal Guide

### Priority 1 — Quick Wins (Doc Comments / Build Output)
- `ic/src/tools/builtin/memory.rs:807` — comment link (keep as attribution)
- `ic/lunarwing-gotify-tool/` — doc comments + build WASM tool text
- `gotify-wasm/lunarwing-gotify-tool/` — doc comments + build text
- `ic/clippy.toml:3` — issue link (keep)

### Priority 2 — Env Var Bridges (Requires Deprecation Window)
- `bootstrap.rs` — `IRONCLAW_BASE_DIR` fallback
- `config/helpers.rs` — 11-var mapping table
- All scripts with dual-prefix pattern
- systemd/openrc unit env injection

### Priority 3 — Filesystem Default Migration
- `~/.ironclaw` → `~/.lunarwing` default path
- `ironclaw.db` → `lunarwing.db` default filename
- Requires runtime detection + migration code

### Priority 4 — WS Subprotocol Alias
- Coordinate across: core + nanocode + pebble + opencode workers
- `SUBPROTOCOL_LEGACY` constant + tests

### Priority 5 — Keychain Service Rename
- `SERVICE_NAME = "ironclaw"` → `"lunarwing"`
- Requires secret migration or read-old/read-new

### Priority 6 — NearAI Cloud Provider (`near.ai` URLs)
- Provider integration, not branding
- Only removable if NearAI provider is dropped
- Requires separate decision

### Priority 7 — TensorZero Config Naming
- Independent migration (config vs code)
- All `functions.ironclaw` → `functions.lunarwing`
- Coordinated with `tensorzero-proxy-configurations/` and `nanocode-config/`

---

## Notes

- The existing spec at `docs/specs/Near-Removal.md` and plan at `docs/plans/Near-Removal.md` define the full removal framework. This audit supplements those with the actual file-level inventory.
- `nearcloud` and `nearagent` have been fully purged already — they only appear in the Near-Removal spec as things to verify.
- The `near::agent` WIT namespace has been fully migrated (no remnants in `.wit` files).
- Historical docs under `internal/history/` and `docs/releases/` are preserved intentionally per repo convention — they document fork history accurately.
