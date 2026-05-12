# Port IronClaw 0.28.1 Changes to LunarWing

**Date:** 2026-05-12
**Status:** Analysis complete, no items selected for immediate implementation

## Context

IronClaw v0.28.1 (tag `ironclaw-v0.28.1`, 14 substantive commits) shipped on ~2026-05-08. This document identifies which changes are worth porting to LunarWing, prioritized by security impact and alignment with LunarWing's self-hosted multi-tenant mission.

**Note:** The IronClaw working tree is on the `staging` branch, but the 0.28.1 changes live on the `ironclaw-v0.28.1` tag. Reference files via `git show ironclaw-v0.28.1:<path>` when porting.

---

## Changes NOT Applicable to LunarWing (Skip)

| Commit | Description | Why Skip |
|--------|-------------|----------|
| `09d3ebb3` | Telegram pairing UX + OAuth recovery | LunarWing uses XMPP, not Telegram |
| `60eb74fd` | Slack `pairing_approve` tool | LunarWing doesn't use Slack |
| `762a8b3b` | WeChat registry metadata | Not relevant |
| `4bd6c10d` | Web bug bash (restart modal, HTTP defaults) | LunarWing's web frontend is different |
| `dc6b67cb` | Canary script for github_token_scopes | IronClaw CI-specific |
| `6e6eca77` / `26c8b677` | E2E test fixes | IronClaw test infrastructure-specific |

## Already Present in LunarWing

**Approval gate clamping** (commit `3fab297c`): LunarWing already has the security fix inline at `src/bridge/router.rs:1343-1347`. The `always` flag is clamped to `ResumeKind::Approval { allow_always: true }`. No vulnerability.

**SSE tenant isolation** (`ScopedEvent`): Already in `src/channels/web/sse.rs`.

**Gate store atomicity** (`take_verified` + Mutex): Already in `src/gate/store.rs`.

---

## P0 — Security (Port Immediately)

**No outstanding P0 items.** The only security-critical change (approval gate clamping) is already in LunarWing.

---

## P1 — Core Architecture

### P1-A: WASM Selective Channel Activation for Headless Deployments
**Commit:** `37b62f8b` | **Complexity:** M | **Dependencies:** None

**Why:** LunarWing's headless self-hosted deployments (systemd/OpenRC) currently load ALL discovered WASM channels unconditionally, wasting memory, injecting credentials for unconfigured channels, and expanding attack surface.

**What IronClaw changed:**
- Two-phase channel loading: discover first, filter, then load
- `startup_active_channel_names: Option<&HashSet<String>>` — when `Some`, only listed channels load
- `registered_channel_names: &[String]` — collision rejection against built-in channels
- Reserved name blocklist (`cli`, `repl`, `http`, `signal`, etc.)

**LunarWing files to modify:**
1. `src/channels/wasm/setup.rs` — Add filtering parameters, reserved name check, two-phase loading
2. `src/channels/wasm/loader.rs` — Add `discover_channels()` + `load_from_files()` (keep `load_from_dir()` as convenience)
3. `src/main.rs` — Pass `registered_channel_names` and `startup_active_channel_names` at the call site

**IronClaw reference:** `git show ironclaw-v0.28.1:src/channels/wasm/setup.rs` (lines 30-238)

**Adaptation:** Replace Telegram/Slack reserved names with `xmpp`, `weechat`, `darkirc`. Verify `TRUSTED_APPROVAL_CHANNELS` / `BOOTSTRAP_SOURCE_CHANNEL` constants exist in LunarWing's `src/agent/session.rs`.

---

### P1-B: Multi-Tenant Workspace Memory Isolation (`scoped_to_user`)
**Commit:** `875387fc` | **Complexity:** S-M | **Dependencies:** None

**Why:** Multi-tenancy is LunarWing's key differentiator. `scoped_to_user()` enables efficient per-request workspace cloning for a different tenant while preserving shared resources (search config, embeddings, storage backend, shared memory layers). Without it, each tenant workspace must be constructed from scratch.

**What IronClaw added:**
- `Workspace::scoped_to_user(&self, user_id) -> Self` method
- Rebinds private memory layers from old user scope to new user scope
- Preserves shared layer scopes in the read list
- Resets bootstrap flags for new users (preserves for same user)
- Write-only user_id vs read-only `read_user_ids` separation ensures no cross-tenant writes

**LunarWing files to modify:**
1. `src/workspace/mod.rs` — Add `scoped_to_user()` method (~80 lines + tests)
2. `src/workspace/layer.rs` — Verify `MemoryLayer::read_scopes()` exists, add if not

**IronClaw reference:** `git show ironclaw-v0.28.1:src/workspace/mod.rs` (lines 746-800), `tests/workspace_scoped_rebind.rs` (7 test contracts)

---

### P1-C: Mission Auto-Resume After Gate Resolution
**Commit:** `4696a0a5` | **Complexity:** L | **Dependencies:** Benefits from P1-B

**Why:** LunarWing's `resume_mission()` (line 189 of `crates/lunarwing_engine/src/runtime/mission.rs`) does a naive status flip without fire-cooldown, cron recomputation, event dedup, or max-iteration protection. Routines that pause on an approval gate stay paused forever unless manually resumed.

**What IronClaw added:**
1. **Fire cooldown** — 90s in-memory `last_fire_attempt` per mission prevents rapid re-triggering
2. **State validation** — Resume only from `Paused` or `Failed`, not `Active`/`Completed`
3. **Atomic mutate-and-save** — Single load-mutate-save prevents concurrent overwrites
4. **Cron recomputation** — `next_fire_at` recalculated via `next_cron_fire_required()` on resume
5. **Event dedup** — SHA-256 payload hashing with configurable `dedup_window_secs`
6. **MaxIterations terminal** — `ThreadOutcome::MaxIterations` treated as terminal for the run
7. **`fire_on_system_event()`** — Matches missions by `SystemEvent` cadence type

**LunarWing files to modify:**
1. `crates/lunarwing_engine/src/runtime/mission.rs` — Primary target (~500 lines of additions)
2. `crates/lunarwing_engine/src/types/mission.rs` — Add `dedup_window_secs`, `cooldown_secs` fields

**IronClaw reference:** `git show ironclaw-v0.28.1:crates/ironclaw_engine/src/runtime/mission.rs` (key sections: lines 211-224, 540-622, 1007-1060)

---

### P1-D: LLM Crate Extraction
**Commit:** `1ecb1690` | **Complexity:** XL (144 files) | **Dependencies:** P1-E

**Why:** The monolithic `src/llm/` module (39 files, all providers + decorators + session management) is tightly coupled to the binary's database, secrets, and bootstrap layers. Extracting it into `lunarwing_llm` creates clean boundaries, enables independent testing with `StubLlm`, and prevents circular dependencies as the engine grows.

**What IronClaw did:**
- Moved `src/llm/` → `crates/ironclaw_llm/src/` (39 provider/decorator/session files)
- Created `Host` trait abstraction in `crates/ironclaw_llm/src/host.rs`:
  - `SessionDb` — JSON settings persistence
  - `SessionSecrets` — Encrypted secrets store
  - `SessionRenewer` — Interactive OAuth login (headless uses `NoopSessionRenewer`)
  - `SessionKeyPersistor` — Runtime env overlay + .env upsert
- Created binary-side adapters in `src/llm_host.rs` (`DatabaseSessionDb`, `SecretsStoreSessionSecrets`, `BootstrapKeyPersistor`)
- Moved shared types to `ironclaw_common`: `IncomingAttachment`, env helpers, platform info, path helpers
- Import rewrites across 100+ files: `use crate::llm::` → `use ironclaw_llm::`
- Tracing target change: `ironclaw::llm::reasoning` → `ironclaw_llm::reasoning`

**LunarWing approach:**
1. Create `crates/lunarwing_llm/` with Cargo.toml, src/lib.rs, src/host.rs
2. Move `src/llm/*.rs` → `crates/lunarwing_llm/src/`
3. Implement Host traits in `src/llm_host.rs`
4. Update imports across the codebase
5. Add `testing` feature gate with `StubLlm`

**IronClaw reference:** `git show ironclaw-v0.28.1:crates/ironclaw_llm/` (entire crate), `git show ironclaw-v0.28.1:src/llm_host.rs`

**Risk:** This is the largest change. Consider doing it as a standalone effort after the smaller P1 items are stable.

---

### P1-E: `lunarwing_common` Expansion
**Commit:** `1ecb1690` (part of LLM extraction) | **Complexity:** M | **Dependencies:** None (but prerequisite for P1-D)

**Why:** Shared types needed by both the main binary and the extracted LLM crate. Also enables the `identity.rs` newtypes that prevent identity-confusion bugs.

**What IronClaw added to `ironclaw_common`:**
- `attachment.rs` — `IncomingAttachment`, `AttachmentKind` (channel-agnostic file/media types)
- `env_helpers.rs` — Thread-safe runtime env overlay (`set_runtime_env`, `env_or_override`, `register_secondary_fallback`)
- `paths.rs` — `ironclaw_base_dir()`, `compute_ironclaw_base_dir()`
- `platform.rs` — `PlatformInfo` for injecting runtime metadata into system prompts
- `identity.rs` — `CredentialName`, `ExtensionName`, `ExternalThreadId`, `McpServerName` newtypes
- `timezone.rs` — `ValidTimezone` newtype

**LunarWing files to create/modify:**
1. `crates/lunarwing_common/src/attachment.rs` — Port attachment types
2. `crates/lunarwing_common/src/env_helpers.rs` — Port thread-safe env overlay
3. `crates/lunarwing_common/src/paths.rs` — Port with `lunarwing_base_dir()` naming
4. `crates/lunarwing_common/src/platform.rs` — Port PlatformInfo
5. `crates/lunarwing_common/src/identity.rs` — Port identity newtypes
6. `crates/lunarwing_common/src/timezone.rs` — Port ValidTimezone
7. `crates/lunarwing_common/src/lib.rs` — Add module declarations + re-exports

**IronClaw reference:** `git show ironclaw-v0.28.1:crates/ironclaw_common/src/`

---

## P2 — Nice-to-Have

### P2-A: Pre-Commit Safety Checks 7-9
**Commit:** `21e27b22` | **Complexity:** S-M

LunarWing already has checks 1-6. Port checks 7 (dispatch bypass detection) and 9 (SSE broadcast sourcing) with LunarWing-specific names. Skip check 8 (CredentialName) until P1-E identity types land.

**File:** `scripts/pre-commit-safety.sh` (~120 lines of bash additions)

### P2-B: Approval Gate Clamping Refactor
**Complexity:** S

Extract inline clamping at `src/bridge/router.rs:1343-1347` into a named `clamp_always_to_resume_kind()` helper with unit tests. Pure readability improvement, no behavior change.

---

## Recommended Implementation Order

```
1. P1-A  WASM selective activation     [M]   standalone, immediate headless benefit
2. P1-B  scoped_to_user workspace      [S-M] standalone, enables multi-tenant
3. P1-C  Mission auto-resume           [L]   benefits from P1-B
4. P1-E  lunarwing_common expansion    [M]   foundation for P1-D
5. P1-D  LLM crate extraction         [XL]  largest change, do last
6. P2-B  Clamp refactor               [S]   quick cleanup
7. P2-A  Pre-commit checks 7-9        [S-M] after P1-E for check 8
```

## Verification

After each P1 item:
- `cargo fmt && cargo clippy --all --benches --tests --examples --all-features` (zero warnings)
- `cargo test`
- `cargo check --no-default-features --features libsql` (dual-backend)
- `scripts/pre-commit-safety.sh` (existing checks pass)

For P1-D specifically:
- Verify `RUST_LOG=lunarwing_llm=debug` captures LLM reasoning traces (not old `lunarwing::llm::reasoning`)
- Verify `StubLlm` works in integration tests via `testing` feature gate
