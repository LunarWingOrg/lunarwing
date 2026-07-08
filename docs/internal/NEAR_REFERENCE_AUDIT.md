# Remaining Near/IronClaw Reference Audit
**Date**: 2026-07-08
**Scope**: Full repository scan for nearai/near/ironclaw/nearcloud/nearagent/near::agent
**Method**: Cross-referenced grep results against the active feature spec (`docs/specs/Near-Removal.md`), compatibility plan (`docs/plans/Near-Removal.md`), and file-by-file classification.

---

## Executive Summary

Total files with references: **~170** (excluding historical archives and unrelated NEAR blockchain usage).

| Category | Count | Action |
|----------|-------|--------|
| Active Rust code (provider/config/LLM) | ~25 | Rename or reclassify |
| Legacy env var aliases (`IRONCLAW_*`) | ~40 | Document as compat bridge; plan removal |
| WIT/ABI namespaces (near::agent) | 0 active | Already migrated to lunarwing-named WIT |
| Historical archive docs | ~25 | Out of scope (kept as history) |
| Worker containers (sub-repos) | ~15 | Legacy subprotocol alias only |
| Test fixtures, mock data, e2e traces | ~20 | Keep (test compatibility) |
| Git history links (rust docs) | ~8 | Informational only |
| Unrelated (NEAR token, "nearest", NEAR blockchain pattern) | ~10 | Out of scope |

---

## 1. Active Rust Code (High Priority Rename Targets)

### 1.1 LLM Provider & Config (the biggest remaining concentration)

| File | Line | Reference | Classification |
|------|------|-----------|----------------|
| `ic/src/lib.rs` | 1-3 | `//! NEAR AI Agentic Worker Framework` | **ACTIVE** — module-level branding |
| `ic/src/llm/mod.rs` | 596 | `base_url: "https://api.near.ai"` | **ACTIVE** — default API endpoint |
| `ic/src/llm/config.rs` | 199, 206, 208 | `https://cloud-api.near.ai`, `https://private.near.ai` | **ACTIVE** — provider base URLs |
| `ic/src/llm/session.rs` | 32, 41, 231, 249, 273, 277, 381, 392, 732 | private.near.ai, cloud.near.ai, NEAR Wallet, "near" auth_provider | **ACTIVE** — LLM session auth |
| `ic/src/llm/models.rs` | 251 | `https://private.near.ai` | **ACTIVE** — default base URL |
| `ic/src/llm/CLAUDE.md` | 28, 66, 67, 188, 224 | NEAR AI provider names, IRONCLAW_RECORD_TRACE | **DOC + LEGACY** |
| `ic/src/llm/oauth_helpers.rs` | 1 | `//! OAuth callback infrastructure used by the NEAR AI session login flow` | **ACTIVE** |
| `ic/src/llm/smart_routing.rs` | 196-199, 217-218 | "near", "near.?sdk", "cargo.?near" | **ACTIVE** — routing keywords |
| `ic/src/setup/wizard.rs` | 3671-3707, 4074-4173 | IRONCLAW_OWNER_ID, private.near.ai, cloud-api.near.ai | **ACTIVE + LEGACY** |
| `ic/src/setup/README.md` | 91, 339, 341, 749, 755 | NEAR AI provider mentions | **DOC** |
| `ic/src/config/llm.rs` | 93, 125, 127 | `https://private.near.ai`, `https://cloud-api.near.ai` | **ACTIVE** |
| `ic/src/config/oauth.rs` | 13, 33, 72-82 | NEAR wallet auth config | **ACTIVE** — external auth concept |
| `ic/src/klib.rs` | 1-3 | NEAR AI Agentic Worker Framework | **ACTIVE** — module-level |
| `ic/src/tools/builtin/image_gen.rs` | 12 | `https://cloud-api.near.ai` | **ACTIVE** — example URL |
| `ic/src/sandbox/config.rs` | 175, 186 | `api.near.ai`, "LUNARWING_CLOUD_API_KEY" | **ACTIVE** |
| `ic/src/cli/oauth_defaults.rs` | 3, 1445 | nearai agent URLs, OAuth | **ACTIVE** |

### 1.2 WASM Tool/Channel Active Code (NEAR pattern references)

These reference "NEAR pattern" (i.e., fresh-instance-per-call isolation pattern). These are architectural descriptions, not NEAR AI branding. **Reclassify as architectural comment rather than Near branding.**

| File | Line | Reference |
|------|------|-----------|
| `ic/src/tools/wasm/wrapper.rs` | 7, 152, 1103 | "NEAR pattern: fresh instance per call" |
| `ic/src/tools/wasm/mod.rs` | 46 | "Fresh Instance Per Callback (NEAR Pattern)" |
| `ic/src/tools/wasm/host.rs` | 4 | "from NEAR blockchain" — deny-by-default |
| `ic/src/tools/wasm/limits.rs` | 3 | "NEAR blockchain patterns" |
| `ic/src/tools/wasm/runtime.rs` | 4 | "NEAR blockchain patterns" |
| `ic/src/channels/wasm/mod.rs` | 46 | "NEAR Pattern" |
| `ic/src/channels/wasm/wrapper.rs` | 1083 | "NEAR pattern: fresh instance per call" |

**Recommendation**: These are architectural comments referencing NEAR's execution isolation pattern, not NearAI vendor branding. Reclassify as documentation/wording preference — could be renamed to "fresh instance pattern" for vendor neutrality.

---

## 2. Legacy Env Var Aliases (Compatibility Bridges)

These are intentional compat aliases — old `IRONCLAW_*` env vars still read as fallbacks. All should be documented with a removal window.

| File | Aliases |
|------|---------|
| `ic/src/bootstrap.rs` | `IRONCLAW_BASE_DIR`, `ironclaw.db` default path |
| `ic/src/main.rs` | `IRONCLAW_SOCKET` |
| `ic/src/service.rs` | `com.ironclaw.daemon`, `ironclaw.service`, `IRONCLAW_SERVICE_MANAGER` |
| `ic/src/settings.rs` | `IRONCLAW_OWNER_ID` path assertions |
| `ic/src/cli/oauth_defaults.rs` | `IRONCLAW_GOOGLE_CLIENT_ID`, `IRONCLAW_GOOGLE_CLIENT_SECRET`, `IRONCLAW_OAUTH_CALLBACK_URL`, etc. |
| `ic/src/cli/repl.rs` | `IRONCLAW_SOCKET` |
| `ic/src/cli/tool.rs` | `.ironclaw` path assertions |
| `ic/src/config/helpers.rs` | Maps ALL `IRONCLAW_*` to `LUNARWING_*` |
| `ic/src/extensions/manager.rs` | `IRONCLAW_OAUTH_CALLBACK_URL`, `IRONCLAW_OAUTH_EXCHANGE_URL`, `IRONCLAW_OAUTH_PROXY_AUTH_TOKEN` |
| `ic/src/channels/wasm/bundled.rs` | `IRONCLAW_CHANNELS_SRC` |
| `ic/src/channels/web/server.rs` | `IRONCLAW_OAUTH_CALLBACK_URL` |
| `ic/src/channels/web/openai_compat.rs` | `x-ironclaw-streaming` header |
| `ic/src/channels/web/static/theme-init.js` | `ironclaw-theme` localStorage key |
| `ic/src/worker/api.rs` | `IRONCLAW_WORKER_TOKEN` |
| `ic/src/worker/container.rs` | `IRONCLAW_WORKER_TOKEN` |
| `ic/src/worker/acp_bridge.rs` | `IRONCLAW_WORKER_TOKEN` |
| `ic/src/orchestrator/external_worker.rs` | `ironclaw-agent-v1` subprotocol |
| `ic/src/orchestrator/job_manager.rs` | `IRONCLAW_WORKER_TOKEN`, `IRONCLAW_JOB_ID`, `IRONCLAW_ORCHESTRATOR_URL`, `IRONCLAW_WORKSPACE` |
| `ic/src/llm/recording.rs` | `IRONCLAW_RECORD_TRACE`, `IRONCLAW_TRACE_OUTPUT`, `IRONCLAW_TRACE_MODEL_NAME` |
| `ic/src/llm/oauth_helpers.rs` | `IRONCLAW_OAUTH_CALLBACK_URL` |
| `ic/scripts/lunarwing-watchdog.sh` | `IRONCLAW_WATCHDOG_SERVICE`, `IRONCLAW_WATCHDOG_LOG`, etc. |
| `ic/scripts/lunarwing-watchdog-openrc.sh` | Same as above |
| `ic/scripts/install-lunarwing-watchdog.sh` | `ironclaw-watchdog.timer`, `ironclaw-watchdog.service`, `com.ironclaw.watchdog.plist` |
| `ic/scripts/lunarwing-xmpp-test-env.sh` | `IRONCLAW_BASE_DIR`, `IRONCLAW_SOCKET` |
| `ic/scripts/setup-instance.sh` | `IRONCLAW_BASE_DIR`, `IRONCLAW_SOCKET` |
| `ic/scripts/export-tenant.sh` | "ironclaw" role/db handling |
| `ic/scripts/lunarwing-mt-admin.sh` | `IRONCLAW_BASE_DIR`, `IRONCLAW_SOCKET` |
| `ic/scripts/reimport-fixes.sh` | `/home/cmc/kageho_old/.ironclaw/ironclaw.db` |
| `ic/scripts/reorg_docs.sh` | `IRONCLAW_PORT_VERIFICATION.md` filename filter |
| `ic/scripts/ci/quality_gate.sh` | `IRONCLAW_PREPUSH_TEST` |
| `ic-infrastructure-health-check/lunarwing-self-heal.sh` | `IRONCLAW_BASE_DIR`, `IRONCLAW_SERVICE_MANAGER`, `ironclaw-proxy-*` |
| `ic-infrastructure-health-check/infrastructure-health-check.sh` | `IRONCLAW_BASE_DIR` |
| `ic-infrastructure-health-check/config.sh.example` | `IRONCLAW_BASE_DIR` |
| `ic-infrastructure-health-check/health-gateway.sh` | `IRONCLAW_BASE_DIR` |
| `ic-infrastructure-health-check/health-xmpp.sh` | `IRONCLAW_BASE_DIR` |
| `ic-infrastructure-health-check/health-omemo.sh` | `IRONCLAW_BASE_DIR` |
| `ic-infrastructure-health-check/tests/test-self-heal-matrix.sh` | `ironclaw-proxy-acme.service` |
| `ic/src/channels/wasm/wrapper.rs` | `~/.ironclaw` default path |
| `ic/deploy/run.sh` | Bridges `LUNARWING_BASE_DIR` → `IRONCLAW_BASE_DIR` for legacy |
| `ic/deploy/env.example` | Documents IRONCLAW_* compat aliases |

---

## 3. Web Frontend (UI Dropdowns)

| File | Line | Reference |
|------|------|-----------|
| `ic/src/channels/web/static/app.js` | 5041, 5061 | `'nearai'` in provider selector dropdown arrays |

**Note**: The `nearai` UI option at line 5041 lives along with `anthropic`, `openai` etc. in the general provider list. The one at 5061 is in a different component. These need a value-mapping (ui-key → internal provider id) to decouple from branding.

---

## 4. Worker Container Repos (Legacy Subprotocol)

All use the same **`ironclaw-agent-v1`** WebSocket subprotocol legacy alias. Documented for "one deprecation cycle."

| File | Reference |
|------|-----------|
| `opencode4lunarwing/AGENTS.md` | `ironclaw-agent-v1` alias |
| `opencode4lunarwing/scripts/lunarwing_runtime.ts` | `LEGACY_SUBPROTOCOL = "ironclaw-agent-v1"` |
| `opencode4lunarwing/scripts/lunarwing_bridge.ts` | IronClaw alias mentions |
| `opencode4lunarwing/scripts/smoke_test.ts` | Subprotocol test with `ironclaw-agent-v1` |
| `opencode4lunarwing/CLAUDE.md` | Subprotocol documentation |
| `opencode4lunarwing/README.md` | Subprotocol documentation |
| `pebble4lunarwing/CLAUDE.md` | Subprotocol documentation |
| `pebble4lunarwing/src/bridge.rs` | `ironclaw-agent-v1` negotiation |
| `pebble4lunarwing/src/protocol.rs` | `pub const LEGACY_SUBPROTOCOL: &str = "ironclaw-agent-v1"` |
| `pebble4lunarwing/README.md` | Subprotocol documentation |
| `lunarcode4lunarwing/AGENTS.md` | Subprotocol documentation |
| `lunarcode4lunarwing/scripts/lunarwing_runtime.ts` | `LEGACY_SUBPROTOCOL = "ironclaw-agent-v1"` |
| `lunarcode4lunarwing/scripts/lunarwing_bridge.ts` | IronClaw alias mentions |
| `lunarcode4lunarwing/scripts/smoke_test.ts` | Subprotocol test |
| `lunarcode4lunarwing/CLAUDE.md` | Subprotocol documentation |

---

## 5. Tests, Fixtures, Mock Data (Informational / Test Compatibility)

| File | Line | Context |
|------|------|---------|
| `ic/tests/openai_compat_integration.rs` | 397-400 | `x-ironclaw-streaming` header test |
| `ic/tests/external_worker_integration.rs` | 4, 19, 631-632 | Protocol rename regression tests |
| `ic/tests/support/assertions.rs` | 4 | `nearai/benchmarks` reference |
| `ic/tests/e2e_advanced_traces.rs` | 325 | Fixture JSON: "NEAR AI Agent Framework" text |
| `ic/tests/e2e_spot_checks.rs` | 1 | `nearai/benchmarks SpotSuite` reference |
| `ic/tests/tool_schema_validation.rs` | 7 | `github.com/nearai/ironclaw/issues/352` link |
| `ic/tests/fixtures/llm_traces/README.md` | 439-441 | IRONCLAW_* env var aliases documented |
| `ic/tests/fixtures/llm_traces/advanced/routine_news_digest.json` | 101, 119 | Mock news: "NEAR AI Agent Framework launched" |
| `ic/tests/e2e/conftest.py` | 368-399 | Test env with IRONCLAW_BASE_DIR, IRONCLAW_OWNER_ID, etc. |
| `ic/tests/e2e_spot_checks.rs` | 1 | SpotSuite branding from nearai/benchmarks |

---

## 6. Database Schema (Hard to Migrate Without Migration)

| File | Line | Reference |
|------|------|-----------|
| `ic/migrations/V1__initial.sql` | 1 | `-- NEAR Agent Database Schema` |
| `ic/migrations/V2__wasm_secure_api.sql` | 173-174 | `nearai_session` pattern definition |
| `ic/migrations/V8__settings.sql` | 3 | `~/.ironclaw/settings.json` historical note |

**Note**: Historical migration comments cannot be altered retroactively. New migrations should not repeat the pattern. The `nearai_session` regex pattern is a credential detection signature, not branding — it should be preserved.

---

## 7. Git History Links in Rust Docs (Informational Only)

These link to the upstream `nearai/ironclaw` upstream GitHub repo for issue tracking context. They are **not** active code references and should be preserved as provenance.

| File | Line | Link |
|------|------|------|
| `ic/crates/lunarwing_safety/src/validator.rs` | 474 | `https://github.com/nearai/ironclaw/issues/1025` |
| `ic/crates/lunarwing_safety/src/leak_detector.rs` | 842 | Same |
| `ic/crates/lunarwing_safety/src/credential_detect.rs` | 384 | Same |
| `ic/crates/lunarwing_safety/src/policy.rs` | 305 | Same |
| `ic/crates/lunarwing_safety/src/sanitizer.rs` | 436 | Same |
| `ic/crates/lunarwing_safety/src/lib.rs` | 509 | Same |
| `ic/clippy.toml` | 3 | `https://github.com/nearai/ironclaw/issues/338` |
| `ic/src/tools/builtin/memory.rs` | 807 | `https://github.com/nearai/ironclaw/pull/1118` |

---

## 8. Keychain Credential System Name (Migration Candidate)

| File | Line | Reference |
|------|------|-----------|
| `ic/src/secrets/keychain.rs` | 24 | `const SERVICE_NAME: &str = "ironclaw"` |

This is the OS keychain service name for secrets. Changing it breaks existing tenants' secret retrieval. Requires migration: read from old "ironclaw" first, then write to new "lunarwing" keychain entry.

---

## 9. Helper Scripts (Active References)

| File | Line | Context |
|------|------|---------|
| `ic_sm/scripts_4_db/insert_secret_pg.py` | 3, 38, 47, 57-58, 129-178 | IronClaw-named IRONCLAW_MASTER_KEY, "service": "ironclaw" |
| `ic_sm/scripts_4_db/insert_secret_postgres.py` | 3, 5, 16, 19, 44, 56, 66, 77 | IronClaw DB constants |
| `ic_sm/scripts_4_db/insert_secret_libsql.py` | 3, 5, 29, 35, 40, 46, 57-59, 84, 99 | IronClaw DB constants + ironclaw.db path |
| `ic_sm/scripts_4_db/insert_secret_pg.py` | 129-178 | IRONCLAW_OWNER_ID, IRONCLAW_USER_ID |

These are developer utilities for inserting test credentials. They should be migrated to LUNARWING_* naming.

---

## 10. Out of Scope (Historical Archives + Unrelated)

### Historical Archives (do not touch)
- All under `docs/internal/history/archive/`
- `docs/proposals/OLDPROJECT_PORT_ANALYSES/`
- All under `docs/internal/history/archive/internal/`
- `docs/internal/history/archive/ops/`
- `docs/internal/history/archive/proposals/`
- `docs/releases/` (historical release notes)
- `docs/ops/history/` (historical goals)

### Unrelated NEAR References (NEAR token, blockchain, proximity English)
| File | Reference |
|------|-----------|
| `ic/src/tools/builtin/message.rs` | "NEAR token price $5" (test stub) |
| `ic/src/channels/web/static/app.js` | CSS `nearest` layout helper |
| `ic/lunarwing-gotify-tool/build.sh` | Build script comment |
| Various docs | "NEAR AI Agent Framework" as historical product reference |

---

## 11. Known Near-Removal Progress

The previous Near-Removal work (tracked in `docs/plans/Near-Removal.md`, status `done`) completed:
- ✅ Witenamespace migration (near::agent → lunarwing:*)
- ✅ Provider source-file renaming (nearai_chat.rs → lunarwing_cloud_*.rs)
- ✅ Rust type renaming (NearAiChatProvider → LunarWingCloudChatProvider, etc.)
- ✅ WIT guest bindings regenerated

What **remains** (captured in the plan's final audit checklist):
- ☐ Active default base URLs (`https://api.near.ai`, `https://private.near.ai`, `https://cloud-api.near.ai`)
- ☐ NEAR wallet auth config in `config/oauth.rs`
- ☐ `api.near.ai` pattern in sandbox credential mapping
- ☐ `api.near.ai` in `session.rs` auth defaults
- ☐ Web UI `'nearai'` provider value
- ☐ `IRONCLAW_*` env var aliases (40+ locations) — compat bridge to document
- ☐ `ironclaw-agent-v1` WebSocket subprotocol legacy alias
- ☐ Keychain service name `"ironclaw"`
- ☐ NEAR pattern wording in WASM code comments
- ☐ `ic_sm/` helper scripts using IRONCLAW_MASTER_KEY etc.

---

## 12. Recommended Next Steps (for a future item #7 or similar)

1. **Active LLM provider URLs** — Decide: keep `api.near.ai`/`private.near.ai`/`cloud-api.near.ai` as external endpoints (out of our control) vs. rebranding references. These URLs belong to an external service; we cannot rename them.
2. **Env var aliases** — Add a tracking issue for each `IRONCLAW_*` alias with a planned removal version (likely 2.0.0 given potential tenant impact).
3. **Keychain migration** — Write a one-time migration that reads from old `"ironclaw"` keychain entry and writes to `"lunarwing"` entry.
4. **Web UI dropdown** — Map internal IDs to display names; replace `'nearai'` key with a vendor-neutral identifier.
5. **NEAR pattern comments** — Clean-up wording: replace "NEAR blockchain pattern" with "fresh instance isolation pattern" for vendor neutrality.
6. **`ic_sm/` helper scripts** — Migrate to LUNARWING_MASTER_KEY / new keychain service name.
7. **Worker subprotocol** — Remove `ironclaw-agent-v1` from codebase in v2.0.0; offer migration window for pre-rename workers.

---

## 13. Summary of Reference Counts by Stem

| Search term | Files | Primarily |
|-------------|-------|-----------|
| `nearai` | 25 | LLM + safety crate + test infra |
| `nearcloud` | 1 | AGENT_GOALS_1.1.9 file only |
| `nearagent` | 1 | AGENT_GOALS_1.1.9 file only |
| `near::agent` | 6 | Spec/plans + historical doc (no active code) |
| `ironclaw` | 142 | All categories above |
| `\bNEAR\b` | 31 | Mix of NEAR AI, NEAR token, NEAR pattern, nearest-English |
| `NearAI\|near\.ai\|near_ai` | 26 | Primarily LLM provider/config |

---

## 14. Critical Distinctions for Decision-Makers

The report distinguishes:
- **Active code decisions**: NEAR AI provider URLs, base URLs, auth config (we control the Rust code)
- **External endpoints**: `api.near.ai`, `private.near.ai`, `cloud-api.near.ai` (URLs we cannot change without a different provider — but references to them could be mapped behind a config constant)
- **Compat aliases**: `IRONCLAW_*` env vars (must remain functional or be removed via a migration announcement)
- **Test/legacy data**: Should be kept or updated atomically, never silently
- **Historical archives**: Out of scope for — provenance preference
- **WASM pattern references**: "NEAR pattern" wording is architectural, not branding — judgment call

End of audit.
