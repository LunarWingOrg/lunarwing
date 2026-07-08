# Legacy Branding References Report

**Date:** 2026-07-08
**Prepared for:** v1.1.9 (`Kiyome きよめ`) pre-release checklist, item #2
**Purpose:** Comprehensive catalog of all remaining `nearai`, `near`, `ironclaw`, `nearcloud`, `nearagent`, `near::agent`, and `telegram` references in the LunarWing source code and documentation.

---

## Executive Summary

LunarWing is a hard fork of NearAI's IronClaw, diverging since February 2026. The binary, Cargo package, and internal crates have been renamed from `ironclaw` to `lunarwing`. A formal Near-Removal feature (see `docs/specs/Near-Removal.md`, `docs/plans/Near-Removal.md`) has been completed for the Rust provider/config/WIT ABI surfaces. However, numerous legacy references remain — most are **intentionally retained** as backward-compatibility aliases, historical/provenance records, or configuration references that cannot be changed without breaking deployed tenants.

| Term | Source Code References | Documentation References | Total |
|------|----------------------|------------------------|-------|
| `nearai` / `near.ai` / `near_ai` | ~25 across `ic/src/` | ~15 files | ~40 |
| `ironclaw` / `iron_claw` | ~80+ across `ic/src/`, scripts, configs | ~60+ files (incl. history) | ~140+ |
| `telegram` | ~12 (import tests + parity) | ~20 files | ~32 |
| `near::agent` / `nearagent` / `near-agent` | ~6 | ~4 files | ~10 |
| `nearcloud` / `near_cloud` | 0 (only in this checklist) | 1 file (this checklist) | 1 |
| `near` (standalone, meaningful) | ~40 across `ic/src/` | ~20 files | ~60 |

---

## 1. NEAR AI / nearai / near.ai / near_ai

These references relate to the NEAR AI infrastructure that LunarWing's cloud provider (`lunarwing_cloud`) connects to. The cloud provider was renamed from `nearai` to `lunarwing_cloud` at the config/provider level, but the underlying API endpoints (`*.near.ai`) remain because LunarWing still connects to NEAR AI's cloud infrastructure for the `lunarwing_cloud` backend.

### 1.1 Source Code (Active — Cannot Remove Without Breaking Cloud Provider)

These are the API endpoints for the `lunarwing_cloud` backend. The provider was renamed, but it still talks to NEAR AI infrastructure.

| File | Lines | Reference | Classification |
|------|-------|-----------|----------------|
| `ic/src/config/llm.rs` | 102, 134, 136 | `https://private.near.ai`, `https://cloud-api.near.ai` | **Active** — default URLs for `lunarwing_cloud` backend |
| `ic/src/llm/config.rs` | 199, 206, 208 | `https://cloud-api.near.ai`, `https://private.near.ai` | **Active** — provider config defaults |
| `ic/src/llm/session.rs` | 32, 41, 231, 381, 392, 732 | `https://private.near.ai`, `cloud.near.ai` | **Active** — session-token auth flow, API key setup instructions |
| `ic/src/llm/mod.rs` | 595 | `https://api.near.ai` | **Active** — test fixture for cloud provider |
| `ic/src/llm/models.rs` | 111 | `https://private.near.ai` | **Active** — default base URL |
| `ic/src/setup/wizard.rs` | 3989, 3991, 4009, 4011, 4062, 4088 | `https://cloud-api.near.ai`, `https://private.near.ai` | **Active** — onboarding wizard tests |
| `ic/src/sandbox/config.rs` | 175, 186 | `api.near.ai` | **Active** — network allowlist for cloud provider |
| `ic/src/tools/builtin/image_gen.rs` | 12 | `https://cloud-api.near.ai` | **Active** — doc comment for image generation tool |
| `ic/src/cli/oauth_defaults.rs` | 1445 | `https://kind-deer.agent1.near.ai` | **Active** — OAuth redirect test fixture |
| `ic/src/llm/oauth_helpers.rs` | 1, 144 | "NEAR AI" in comments | **Active** — OAuth callback infrastructure |

### 1.2 Source Code (Leak Detection / Migrations)

| File | Lines | Reference | Classification |
|------|-------|-----------|----------------|
| `ic/migrations/V2__wasm_secure_api.sql` | 174 | `nearai_session` leak pattern | **Migration** — historical; already renamed in V22 |
| `ic/migrations/V22__rename_leak_pattern.sql` | 1, 6 | `nearai_session` → `lunarwing_cloud_session` | **Migration** — the rename migration itself (must stay) |

### 1.3 Configuration Files (Active — Reference Configs)

| File | Lines | Reference | Classification |
|------|-------|-----------|----------------|
| `tensorzero-proxy-configurations/tensorzero.toml` | 230, 246-301 | `NEAR_AI_API_KEY`, `cloud-api.near.ai` | **Reference config** — TensorZero proxy pointing to NEAR AI cloud models |
| `nanocode-config/tensorzero.toml` | 367, 383-438 | `NEAR_AI_API_KEY`, `cloud-api.near.ai` | **Reference config** — same, for nanocode worker |

### 1.4 Documentation

| File | References | Classification |
|------|-----------|----------------|
| `ic/src/llm/CLAUDE.md` | NEAR AI provider docs | **Active** — provider documentation |
| `ic/src/setup/README.md` | NEAR AI in setup context | **Active** — onboarding docs |
| `ic/docs/LLM_PROVIDERS.md` | Provider list | **Active** — LLM provider reference |
| `ic/docs/IRONCLAW_PORT_VERIFICATION.md` | Port analysis | **Historical** — verification doc from rename |
| `ic/skills/local-test/SKILL.md` | Test skill | **Historical** — test artifact |
| `docs/releases/RELEASE-v1.0.7.md` through `v1.1.6.md` | Various | **Immutable** — release notes |
| `docs/specs/Near-Removal.md` | Feature spec | **Completed feature** — must remain for reference |
| `docs/plans/Near-Removal.md` | Implementation plan | **Completed plan** — must remain for reference |
| `docs/ops/AGENT_GOALS_1.1.9.md` | This checklist | **Active** — self-referential |
| `docs/proposals/OLDPROJECT_PORT_ANALYSES/*.md` | Port analyses | **Historical** — pre-fork IronClaw analysis |
| `docs/internal/history/**` | Various | **Archived** — historical provenance |
| `PEBBLE.md`, `MANIFESTO.md`, `README.md`, `CLAUDE.md` | Fork history references | **Active** — describes fork relationship |

### 1.5 Recommendation

The `*.near.ai` URLs in the cloud provider code are **legitimate active endpoints** — the `lunarwing_cloud` backend connects to NEAR AI's infrastructure. These cannot be removed unless the cloud provider is discontinued. The leak detection migration rename is already done. The TensorZero config files are reference configs that operators customize.

---

## 2. IronClaw / ironclaw / iron_claw

The IronClaw references are the most numerous. They fall into several categories.

### 2.1 Backward-Compatibility Aliases (Intentionally Retained for 1.1.9)

These are deliberately kept so existing tenants, deployed service units, and legacy scripts continue working after the `ironclaw → lunarwing` rename.

#### Environment Variables
| File | Env Var | Notes |
|------|---------|-------|
| `ic/src/bootstrap.rs` | `IRONCLAW_BASE_DIR` | Legacy alias for `LUNARWING_BASE_DIR`. Falls back to `~/.ironclaw` when neither is set. |
| `ic/src/worker/api.rs` | `IRONCLAW_WORKER_TOKEN` | Legacy alias for `LUNARWING_WORKER_TOKEN` |
| `ic/scripts/lunarwing-watchdog.sh` | `IRONCLAW_WATCHDOG_*` (4 vars) | Legacy aliases for watchdog config |
| `ic/scripts/lunarwing-watchdog-openrc.sh` | `IRONCLAW_WATCHDOG_*` (4 vars) | Same, OpenRC variant |
| `ic/scripts/ci/quality_gate.sh` | `IRONCLAW_PREPUSH_TEST` | Legacy alias for `LUNARWING_PREPUSH_TEST` |
| `ic/scripts/install-lunarwing-watchdog.sh` | `IRONCLAW_SERVICE_MANAGER` | Legacy alias |
| `ic-infrastructure-health-check/*.sh` | `IRONCLAW_BASE_DIR` | Legacy alias in health-check scripts |
| `ic-infrastructure-health-check/config.sh.example` | `IRONCLAW_BASE_DIR` | Documented legacy alias |

#### Service Units & Scripts
| File | Reference | Notes |
|------|-----------|-------|
| `ic/systemd/lunarwing.service` | `IRONCLAW_BASE_DIR=/var/lib/lunarwing` | Env in service unit (sets legacy var for back-compat) |
| `ic/systemd/lunarwing.openrc` | `IRONCLAW_BASE_DIR` export | Same, OpenRC |
| `ic/systemd/xmpp-bridge.service` | `IRONCLAW_BASE_DIR=/var/lib/lunarwing` | Bridge service |
| `ic/systemd/xmpp-bridge.openrc` | `IRONCLAW_BASE_DIR` export | Bridge service, OpenRC |
| `ic/run.sh` | Bridges `LUNARWING_BASE_DIR` → `IRONCLAW_BASE_DIR` | Developer convenience |
| `ic/scripts/lunarwing-xmpp-test-env.sh` | Seeds `IRONCLAW_BASE_DIR`, `IRONCLAW_SOCKET` | Test harness back-compat |
| `ic/scripts/setup-instance.sh` | `IRONCLAW_BASE_DIR` fallback | Legacy setup script |
| `ic/scripts/lunarwing-mt-admin.sh` | `IRONCLAW_BASE_DIR`, `IRONCLAW_SOCKET` in rendered env | MT admin renders legacy env for back-compat |
| `ic/scripts/export-tenant.sh` | Handles legacy `ironclaw` DB role | Export back-compat |

#### WebSocket Subprotocol
| File | Reference | Notes |
|------|-----------|-------|
| `pebble4lunarwing/src/protocol.rs` | `LEGACY_SUBPROTOCOL = "ironclaw-agent-v1"` | Constant |
| `pebble4lunarwing/src/bridge.rs` | Offers `ironclaw-agent-v1` in negotiation | Back-compat for old workers |
| `opencode4lunarwing/scripts/lunarwing_runtime.ts` | `LEGACY_SUBPROTOCOL = "ironclaw-agent-v1"` | Same, TS |
| `lunarcode4lunarwing/scripts/lunarwing_runtime.ts` | `LEGACY_SUBPROTOCOL = "ironclaw-agent-v1"` | Same, TS |
| `opencode4lunarwing/scripts/lunarwing_bridge.ts` | Subprotocol negotiation | Back-compat |
| `lunarcode4lunarwing/scripts/lunarwing_bridge.ts` | Subprotocol negotiation | Back-compat |
| `opencode4lunarwing/scripts/smoke_test.ts` | Offers both subprotocols | Test |
| `lunarcode4lunarwing/scripts/smoke_test.ts` | Offers both subprotocols | Test |
| `ic/tests/external_worker_integration.rs` | Regression tests for ironclaw→lunarwing rename | Intentional regression coverage |
| `ic/tests/openai_compat_integration.rs` | `x-ironclaw-streaming` header | Legacy header back-compat |

#### Watchdog Cleanup
| File | Reference | Notes |
|------|-----------|-------|
| `ic/scripts/install-lunarwing-watchdog.sh` | Cleans up old `ironclaw-watchdog` units, plist, cron entries | Intentional cleanup code |

#### Self-Heal
| File | Reference | Notes |
|------|-----------|-------|
| `ic-infrastructure-health-check/lunarwing-self-heal.sh` | `ironclaw-proxy-*` unit pattern matching | Handles legacy proxy unit names |

### 2.2 Default Database/File Paths (Intentionally Retained)

| File | Reference | Notes |
|------|-----------|-------|
| `ic/src/bootstrap.rs` | `~/.ironclaw` fallback, `ironclaw.db` detection | Back-compat: detects old libSQL DB for auto-migration |
| `ic/migrations/V8__settings.sql` | Comment about `~/.ironclaw/settings.json` | Historical migration comment |
| `ic/scripts/reimport-fixes.sh` | `/home/cmc/kageho_old/.ironclaw/ironclaw.db` | Hardcoded path in a one-off utility script |
| `ic/docker-compose.yml` | Comment about old `ironclaw` DB/role in pgdata | Informational comment |

### 2.3 TensorZero Function Names (Reference Configs)

| File | Lines | Reference | Classification |
|------|-------|-----------|----------------|
| `tensorzero-proxy-configurations/tensorzero.toml` | 778, 1147-1244 | `[functions.ironclaw]`, `[functions.ironclaw_hardened]` | **Reference config** — TensorZero function names. These are external config references that match what deployed TensorZero gateways use. |
| `nanocode-config/tensorzero.toml` | 920, 1343-1384 | Same pattern | **Reference config** |
| `CLAUDE.md` | 47 | `tensorzero::function_name::ironclaw` | **Active** — documents the TensorZero function name |

### 2.4 WASM Tool/Channel Build Scripts (Comments Only)

| File | Reference | Classification |
|------|-----------|----------------|
| `ic/lunarwing-gotify-tool/src/lib.rs` | "IronClaw WASM tool" doc comment | **Cosmetic** — should say LunarWing |
| `ic/lunarwing-gotify-tool/build.sh` | "Building ... for IronClaw" + `~/.ironclaw/tools/` path | **Cosmetic** — should say LunarWing |
| `gotify-wasm/lunarwing-gotify-tool/src/lib.rs` | Same (duplicate) | **Cosmetic** |
| `gotify-wasm/lunarwing-gotify-tool/build.sh` | Same (duplicate) | **Cosmetic** |
| `darkirc_channel_for_lunarwing/darkirc/build.sh` | `IRONCLAW_HOME`, `IRONCLAW_REPO` legacy aliases | **Back-compat** — intentional |
| `lunarwing_weechat_wss/weechat_relay/build.sh` | Same pattern | **Back-compat** |
| `lunarwing_weechat_wss/weechat_relay/src/lib.rs` | Stale `ironclaw` reference assertion test | **Active test** — verifies no stale references in messages |

### 2.5 Secret Manager Scripts (Legacy)

| File | References | Classification |
|------|-----------|----------------|
| `ic_sm/scripts_4_db/insert_secret_pg.py` | `IRONCLAW_MASTER_KEY`, `ironclaw` service names, `IRONCLAW_OWNER_ID`, `IRONCLAW_USER_ID` | **Legacy** — should be updated to support `SECRETS_MASTER_KEY` / `LUNARWING_*` |
| `ic_sm/scripts_4_db/insert_secret_postgres.py` | Same pattern + `postgresql://ironclaw:ironclaw@...` | **Legacy** |
| `ic_sm/scripts_4_db/insert_secret_libsql.py` | Same pattern + `ironclaw.db` path | **Legacy** |

### 2.6 Source Code Comments (Cosmetic / Historical)

| File | Reference | Classification |
|------|-----------|----------------|
| `ic/src/app.rs` | "port analysis P0-A in IronClaw 0.28.2" | **Historical reference** — cites upstream analysis |
| `ic/src/agent/commands.rs` | `ironclaw` reference | **Cosmetic** |
| `ic/src/channels/wasm/bundled.rs` | `ironclaw` reference | **Cosmetic** |
| `ic/src/channels/wasm/wrapper.rs` | `ironclaw` reference | **Cosmetic** |
| `ic/src/channels/web/openai_compat.rs` | `ironclaw` reference | **Cosmetic** |
| `ic/src/channels/web/server.rs` | `ironclaw` reference | **Cosmetic** |
| `ic/src/cli/repl.rs` | `ironclaw` reference | **Cosmetic** |
| `ic/src/cli/tool.rs` | `ironclaw` reference | **Cosmetic** |
| `ic/src/config/helpers.rs` | `ironclaw` reference | **Cosmetic** |
| `ic/src/config/mod.rs` | `ironclaw` reference | **Cosmetic** |
| `ic/src/extensions/manager.rs` | `ironclaw` reference | **Cosmetic** |
| `ic/src/main.rs` | `ironclaw` reference | **Cosmetic** |
| `ic/src/orchestrator/external_worker.rs` | `ironclaw` reference | **Cosmetic** |
| `ic/src/orchestrator/job_manager.rs` | `ironclaw` reference | **Cosmetic** |
| `ic/src/secrets/keychain.rs` | `ironclaw` service name | **Cosmetic** — keychain entry name |
| `ic/src/service.rs` | `ironclaw` reference | **Cosmetic** |
| `ic/src/settings.rs` | `ironclaw` reference | **Cosmetic** |
| `ic/src/skills/registry.rs` | `ironclaw` reference | **Cosmetic** |
| `ic/src/tools/builtin/restart.rs` | `ironclaw` reference | **Cosmetic** |
| `ic/src/tools/wasm/loader.rs` | `ironclaw` reference | **Cosmetic** |
| `ic/src/worker/acp_bridge.rs` | `ironclaw` reference | **Cosmetic** |
| `ic/src/worker/container.rs` | `ironclaw` reference | **Cosmetic** |
| `ic/src/bridge/auth_manager.rs` | `ironclaw` reference | **Cosmetic** |
| `ic/src/channels/web/static/theme-init.js` | `ironclaw` reference | **Cosmetic** |

### 2.7 Documentation

Extensive references in documentation. Key categories:

- **Release notes** (`docs/releases/*.md`): Immutable historical records — **must not change**
- **Migration guides** (`docs/guides/MIGRATE_IRONCLAW_*.md`): Active guides for migrating from IronClaw — **must keep `ironclaw` in titles/content**
- **Port analyses** (`docs/proposals/OLDPROJECT_PORT_ANALYSES/`): Historical pre-fork analysis — **archival**
- **Ops docs** (`docs/ops/*.md`): Various references in upgrade/migration docs — **active**
- **History archive** (`docs/internal/history/`): Archived documents — **provenance only**
- `CLAUDE.md`, `README.md`, `MANIFESTO.md`: Fork history — **active, intentional**

### 2.8 External Repositories (Staging Areas)

| Directory | References | Classification |
|-----------|-----------|----------------|
| `git-lunarwing-unix-socket-client-repo/` | Extensive `ironclaw` in source, AGENTS.md | **Staging** — separate repo, needs its own rename pass |
| `git-lunarwing-unix-socket-repl-server-repo/` | Extensive `ironclaw` in source | **Staging** — separate repo |
| `replv2git/` | Same as above (duplicate staging) | **Staging** — duplicate |
| `tensorzero-proxy-configurations/experimental-ironclaw-proxy-*.py` | IronClaw proxy scripts | **Experimental** — legacy proxy (removed in v1.1.9) |

---

## 3. near::agent / nearagent / near-agent

### 3.1 Source Code

| File | Reference | Classification |
|------|-----------|----------------|
| `ic/src/secrets/crypto.rs` | `HKDF_INFO = b"near-agent-secrets-v1"` | **Active** — HKDF info string for key derivation. Changing this would break all existing encrypted secrets. **Must remain as-is** unless a full secrets migration is implemented. |
| `ic_sm/scripts_4_db/insert_secret_pg.py` | `HKDF_INFO = b"near-agent-secrets-v1"` | **Legacy** — must match `crypto.rs` |
| `ic_sm/scripts_4_db/insert_secret_postgres.py` | Same | **Legacy** |
| `ic_sm/scripts_4_db/insert_secret_libsql.py` | Same | **Legacy** |
| `ic/src/tools/wasm/wrapper.rs.ALLOW_PRIVATE_IPS.patch` | `impl near::agent::host::Host for StoreData` | **Patch file** — references old WIT namespace in a diff context |

### 3.2 Documentation

| File | Reference | Classification |
|------|-----------|----------------|
| `docs/specs/Near-Removal.md` | `near::agent`, `near:agent` | **Feature spec** — describes what was renamed |
| `docs/plans/Near-Removal.md` | `near::agent`, `near-agent` | **Implementation plan** — completed |
| `docs/proposals/SSH_HARNESS_OPTION_2_3_IMPLEMENTATION.md` | `near::agent` | **Historical** — proposal reference |
| `docs/superpowers/plans/2026-06-30-vision-analyze-tool-wiring.md` | `near::agent` | **Historical** — plan reference |
| `docs/reviews/SWEETIE-ARCH-REVIEW.md` | `nearagent` | **Historical** — review document |

### 3.3 Recommendation

The `near-agent-secrets-v1` HKDF info string in `crypto.rs` is a **critical invariant** — it must match across all secret encryption/decryption or existing tenant secrets become unreadable. It should be documented as a permanent compatibility constant. The WIT namespace rename (`near::agent` → LunarWing-owned) was part of the completed Near-Removal feature; the `.patch` file is a historical diff artifact.

---

## 4. nearcloud / near_cloud / near-cloud

**No references found** in source code or documentation. The only occurrence is in `docs/ops/AGENT_GOALS_1.1.9.md` item #2 (this report's originating checklist), which lists it as a search term. There is no `nearcloud` branding anywhere in the LunarWing codebase.

---

## 5. Telegram

LunarWing intentionally does not support Telegram (proprietary channel). References exist in:

### 5.1 Source Code

| File | Reference | Classification |
|------|-----------|----------------|
| `ic/src/import/openclaw/history.rs` | `channel: "telegram"` in import test fixtures | **Test data** — OpenClaw import tests use telegram as a sample channel name |
| `ic/tests/import_openclaw_e2e.rs` | `"telegram"` in test data | **Test data** |
| `ic/tests/import_openclaw_comprehensive.rs` | `"telegram"` in test data | **Test data** |
| `ic/tests/import_openclaw_errors.rs` | `"telegram"` in test data | **Test data** |

### 5.2 Configuration / WIT

| File | Reference | Classification |
|------|-----------|----------------|
| `lunarwing_weechat_wss/channel.wit` | "e.g., Telegram getUpdates" in doc comment | **Cosmetic** — example in timeout doc |
| `lunarwing_weechat_wss/oldchannel.wit` | Same | **Cosmetic** — old WIT file |
| `lunarwing_weechat_wss/weechat_relay/channel.wit` | Same | **Cosmetic** |

### 5.3 Documentation

| File | Reference | Classification |
|------|-----------|----------------|
| `ic/FEATURE_PARITY.md` | Telegram feature comparison table | **Active** — documents that Telegram was removed |
| `README.md` | "No Slack, Discord, or Telegram — by design" | **Active** — intentional design statement |
| `CLAUDE.md` | "Proprietary channels (Slack, Discord, Telegram) are intentionally unsupported" | **Active** — design statement |
| `PEBBLE.md` | Same pattern | **Active** — design statement |
| `docs/releases/RELEASE-v1.0.7.md` through `v1.1.4.md` | Various | **Immutable** — release notes |
| `docs/proposals/MT-WEECHAT-CONSISTENCY-AND-CHANNEL-PRUNING.md` | Channel pruning proposal | **Historical** |
| `docs/proposals/OLDPROJECT_PORT_ANALYSES/*.md` | IronClaw had Telegram | **Historical** |
| `docs/bugs/*.md` | Various | **Historical** — bug reports |
| `docs/ops/ROADMAP_2026.md`, `docs/ops/PRE-RELEASE-TESTING.md` | Design statements | **Active** |

### 5.4 Recommendation

Telegram references in import tests are **legitimate test data** (the OpenClaw import tool must handle conversations that originated on Telegram). Documentation references stating "Telegram is intentionally unsupported" are **correct and should remain**. The WIT comment is cosmetic and could be reworded but is harmless.

---

## 6. "near" (Standalone Meaningful References)

Beyond the compound terms above, standalone `near` appears in several contexts:

### 6.1 NEAR Blockchain / Auth (Active Feature — If Supported)

| File | Reference | Classification |
|------|-----------|----------------|
| `ic/src/config/oauth.rs` | `NearAuthConfig`, `pub near: Option<NearAuthConfig>`, NEAR RPC endpoints | **Active** — NEAR wallet authentication configuration. `NEAR_AUTH_ENABLED`, `rpc.testnet.near.org`, `rpc.mainnet.near.org` |
| `ic/src/llm/session.rs` | "NEAR Wallet (coming soon)", `auth_provider: "near"` | **Active** — unimplemented NEAR wallet auth flow |
| `ic/src/llm/oauth_helpers.rs` | "NEAR AI" in OAuth display context | **Active** |
| `ic/src/db/mod.rs` | `near` as auth provider name | **Active** — auth provider enum |
| `ic/src/llm/smart_routing.rs` | NEAR ecosystem keywords for smart routing | **Active** — model routing heuristics |
| `ic/src/context/state.rs` | "NEAR" as budget token example | **Cosmetic** — doc comment example |

### 6.2 NEAR Pattern References (Architecture Comments)

| File | Reference | Classification |
|------|-----------|----------------|
| `ic/src/channels/wasm/mod.rs` | "NEAR Pattern" for fresh instance per callback | **Cosmetic** — describes WASM isolation pattern origin |
| `ic/src/channels/wasm/wrapper.rs` | "NEAR pattern" | **Cosmetic** |
| `ic/src/tools/wasm/wrapper.rs` | "NEAR pattern" (multiple) | **Cosmetic** |
| `ic/src/tools/wasm/runtime.rs` | "NEAR blockchain patterns" | **Cosmetic** |
| `ic/src/tools/wasm/host.rs` | "NEAR blockchain" capability model | **Cosmetic** |
| `ic/src/tools/wasm/limits.rs` | "NEAR blockchain patterns" | **Cosmetic** |
| `ic/src/tools/wasm/mod.rs` | "NEAR blockchain" | **Cosmetic** |

### 6.3 Provenance Comments

| File | Reference | Classification |
|------|-----------|----------------|
| `ic/src/lib.rs` | "NEAR AI Agentic Worker Framework", "NEAR AI marketplace" | **Cosmetic** — module-level doc comment, should be updated |
| `ic/src/klib.rs` | Same | **Cosmetic** — duplicate |
| `ic/src/util.rs` | "NEAR AI rejects conversations..." | **Cosmetic** — explains a workaround |
| `ic/src/cli/oauth_defaults.rs` | "NEAR AI login" | **Cosmetic** |

### 6.4 English Language "near" (Not Applicable)

Many instances of `near` are standard English (proximity, "near expiry", "near the boundary", "syntax error near SELECT", etc.). These are **not** branding references and require no action.

---

## Summary Classification

### Must Keep (Breaking If Changed)
- `near-agent-secrets-v1` HKDF info string — **critical crypto invariant**
- `*.near.ai` API endpoints — **active cloud provider endpoints**
- `IRONCLAW_BASE_DIR` env alias — **deployed tenants depend on it**
- `IRONCLAW_WORKER_TOKEN` env alias — **worker back-compat**
- `ironclaw-agent-v1` WebSocket subprotocol — **worker back-compat**
- `ironclaw.db` detection in bootstrap.rs — **auto-migration back-compat**
- `ironclaw-proxy-*` unit pattern in self-heal — **deployed unit back-compat**
- `ironclaw` DB role in docker-compose/export-tenant — **pgdata back-compat**
- TensorZero `[functions.ironclaw]` names — **match deployed TensorZero gateways**
- `ironclaw` in migration SQL files — **immutable database migrations**

### Should Update (Cosmetic / Non-Breaking)
- WASM tool build scripts: `~/.ironclaw/tools/` → `~/.lunarwing/tools/` in `build.sh` echo statements
- WASM tool doc comments: "IronClaw WASM tool" → "LunarWing WASM tool"
- `ic/src/lib.rs` and `ic/src/klib.rs` module doc comments: "NEAR AI Agentic Worker Framework"
- `ic_sm/scripts_4_db/*.py`: Legacy `IRONCLAW_*` env var names (should support `SECRETS_MASTER_KEY` / `LUNARWING_*` as primary)
- WIT doc comments referencing "Telegram getUpdates" (cosmetic example)
- "NEAR Pattern" comments in WASM code (could say "LunarWing pattern" or just describe the pattern)

### Must Not Change (Immutable Records)
- Release notes (`docs/releases/*.md`)
- Database migration files (`ic/migrations/*.sql`)
- Historical archive documents (`docs/internal/history/`)
- Port analysis documents (`docs/proposals/OLDPROJECT_PORT_ANALYSES/`)
- Near-Removal spec and plan documents

### Active Design Statements (Correct As-Is)
- "Telegram is intentionally unsupported" in README, CLAUDE.md, etc.
- "No Slack, Discord, or Telegram — by design"
- IronClaw fork history references
- `FEATURE_PARITY.md` Telegram comparison rows

---

## Methodology

Searches performed using `ripgrep` (case-insensitive) across the entire repository excluding `.git/`, `target/`, and `node_modules/`. Search terms:
- `nearai`, `near_ai`, `near-ai`, `near.ai`
- `nearagent`, `near::agent`, `near_agent`, `near-agent`
- `nearcloud`, `near_cloud`, `near-cloud`
- `ironclaw`, `iron_claw`, `iron-claw`
- `telegram`
- `near` (standalone, filtered for false positives)

Each result was classified by: active code, backward-compatibility alias, test data, cosmetic comment, migration/immutable record, historical archive, or design statement.
