# Port IronClaw 0.28.2 Changes to LunarWing

**Date:** 2026-05-15 (updated 2026-05-28, status audit 2026-06-05)
**Status:** Analysis complete. P1-F + P1-G implemented 2026-05-28 with pattern-fix expansion — see [Implementation Note](#implementation-note-2026-05-28-p1-f--p1-g-pattern-fix-expansion) below. P0-A, P1-H, P1-I, P2-C, P2-D remain open.

## Context

IronClaw v0.28.2 (tag `ironclaw-v0.28.2`, 4 substantive commits after the 0.28.1 release merge) shipped on ~2026-05-13. This document identifies which changes are worth porting to LunarWing, prioritized by security impact and alignment with LunarWing's self-hosted multi-tenant mission.

The release is smaller than 0.28.1 but contains a high-severity security fix in the tool permission system and a large LLM boundary refactor.

**Commits analyzed:**

| Commit | Description |
|--------|-------------|
| `34eeeaf0` | fix(extensions): restore chat-driven tool\_install + fix double-invoke + auto-approve footgun |
| `cfeae9e6` | refactor(llm): hide provider-specific auth, model fetch, and embeddings config behind facades |
| `0e3a2c75` | Make Skills E2E lifecycle deterministic |
| `e34309b9` | test(e2e): unxfail two auth-matrix tests now that contracts match |

---

## Changes NOT Applicable to LunarWing (Skip)

| Commit | Description | Why Skip |
|--------|-------------|----------|
| `0e3a2c75` | Skills E2E lifecycle deterministic | IronClaw E2E test infrastructure; LunarWing has its own harness |
| `e34309b9` | Unxfail two auth-matrix E2E tests | IronClaw E2E Playwright tests; not shared |
| `34eeeaf0` (partial) | Telegram registry `hidden: true` on `telegram_mtproto` | LunarWing doesn't ship `telegram_mtproto`; no competing registry entries |
| `34eeeaf0` (partial) | `tool_install` restored to agent callable surface | LunarWing never hid `tool_install` via `hidden_from_model_callable_surface`; the `action_projector.rs` file doesn't exist in LunarWing |
| `34eeeaf0` (partial) | `InlineGate` cached output + inline-await retry | LunarWing's structured executor doesn't have `execute_with_inline_gate_retry`; gates bubble up to the caller without inline retry. The double-invoke and lease-refund bugs are not reachable |
| `34eeeaf0` (partial) | OAuth callback double-fire guard | Requires inline-await `parked waiter` mechanism LunarWing doesn't have |
| `cfeae9e6` (partial) | `ironclaw_oauth` crate extraction | `oauth_helpers.rs` extraction into a standalone crate; LunarWing's OAuth listener is in `src/llm/oauth_helpers.rs` and has no downstream consumer outside the LLM module yet |
| `cfeae9e6` (partial) | `ironclaw_llm::auth` facade (Gemini OAuth, OpenAI Codex login, GitHub Copilot auth) | LunarWing's LLM module is not yet extracted (0.28.1 P1-D). Provider-specific auth facades are premature until the crate boundary exists |
| `cfeae9e6` (partial) | `ProviderProtocol` new variants (Bedrock, OpenAiCodex, GeminiOauth, NearAi) | LunarWing's `ProviderProtocol` has 4 variants (OpenAiCompletions, Anthropic, Ollama, GithubCopilot). Dedicated-config backends (Bedrock, NearAI, Gemini OAuth, OpenAI Codex) aren't LunarWing deployment targets |
| `cfeae9e6` (partial) | `SetupHint` credential-collection variants (AwsCredentials, OAuthDeviceCode, etc.) | Wizard UX for backends LunarWing doesn't support |
| `cfeae9e6` (partial) | `LlmBuiltinOverride` extras bag + bedrock migration | Bedrock-specific; LunarWing has no Bedrock users |
| `cfeae9e6` (partial) | `has_credentials` / `credential_kind` on web LLM providers payload | Frontend gating for dedicated-auth backends; not relevant until those backends are supported |
| `cfeae9e6` (partial) | Admin-key dotted-subpath write gate fix | Requires `llm_builtin_overrides` settings structure that LunarWing doesn't have |

## Already Present in LunarWing

**`resume_output` on `GatePaused`:** LunarWing's `EngineError::GatePaused` already carries `resume_output: Option<Box<serde_json::Value>>` (in `crates/lunarwing_engine/src/types/error.rs`). The field is threaded through `classify_exec_result` and `ThreadOutcome::GatePaused`.

**Post-install auth gate carries cached output:** LunarWing's `effect_adapter.rs:697-710` already passes `Some(output_value)` as `resume_output` in the `tool_install → NeedsAuth` path. This matches the IronClaw 0.28.2 fix for the specific `tool_install` flow.

---

## P0 — Security (Port Immediately)

### P0-A: Ghost-Seeded Tool Permission Rows — Latent Bypass Vector
**Commit:** `34eeeaf0` (the `#3559` security review portion) | **Complexity:** S | **Dependencies:** None | **Status:** Not implemented — `src/app.rs` still calls `seed_tool_permissions()` at line 952; no `cleanup_ghost_seeded_tool_permissions()` exists.

**Why:** LunarWing's `seed_tool_permissions()` in `src/app.rs:977-1034` writes DB rows for every built-in tool's seeded default at startup. These "ghost" rows are indistinguishable from user-explicit overrides because they share the same DB key format (`tool_permissions.<name>`).

Today this is harmless because LunarWing's `effective_permission()` returns a flat `PermissionState` without tracking provenance (explicit-vs-seeded), and `auto_approve_tools` is a binary config flag checked in `agent/dispatcher.rs:544` and `agent/thread_ops.rs:1169`. There is no `is_explicit_ask` check that could be confused.

**However:** If LunarWing ever adopts IronClaw's `ToolPermissionSnapshot::resolve_permission` pattern (which distinguishes explicit from seeded for fine-grained auto-approve gating), ghost rows become a **High-severity bypass**: a user who explicitly sets `tool_install = AskEachTime` (matching the seeded default) would have their choice silently dropped, and `AGENT_AUTO_APPROVE_TOOLS=true` would bypass the gate. IronClaw hit this exact bug in production.

**What to do:**
1. Replace `seed_tool_permissions()` with `cleanup_ghost_seeded_tool_permissions()` — a one-shot, sentinel-gated migration that deletes existing ghost-seeded rows at startup
2. Gate the migration with a sentinel setting key (e.g., `_internal.ghost_seed_cleanup_done`) so it runs once
3. Remove the seeding loop entirely; `effective_permission()` already falls back to `seeded_default_permission_canonical()` at runtime, making DB rows unnecessary for baseline defaults

**LunarWing files to modify:**
1. `src/app.rs` — Replace `seed_tool_permissions()` with `cleanup_ghost_seeded_tool_permissions()`; update the call site at line 940

**IronClaw reference:** `git show ironclaw-v0.28.2:src/app.rs` — search for `cleanup_ghost_seeded_tool_permissions`

---

## P1 — Core Architecture

### P1-F: `auth_gate_from_extension_result` Should Carry `resume_output`
**Commit:** `34eeeaf0` | **Complexity:** S | **Dependencies:** None | **Status:** Implemented 2026-05-28 (see [Implementation Note](#implementation-note-2026-05-28-p1-f--p1-g-pattern-fix-expansion))

**Why:** LunarWing's `auth_gate_from_extension_result()` at `src/bridge/effect_adapter.rs:140-171` passes `None` for `resume_output` on the `tool_activate`/`tool_auth` → `awaiting_authorization` path. The `tool_install` → `NeedsAuth` path at line 709 already passes `Some(output_value)` correctly.

When a tool activation succeeds but needs OAuth, the tool's output is discarded. After the user completes auth, the tool must be re-executed to regenerate the output. Passing `Some(output_value.clone())` preserves the already-computed result so the caller can use it after gate resolution without re-execution.

Today this causes unnecessary re-execution but no security issue. When LunarWing adds inline gate retry (0.28.1 P1-C or a future feature), this becomes the double-invoke bug IronClaw fixed.

**What to change:** In `auth_gate_from_extension_result()`, change the last argument from `None` to `Some(output_value.clone())`.

**LunarWing file:** `src/bridge/effect_adapter.rs:167` — change `None` to `Some(output_value.clone())`

**IronClaw reference:** `git show ironclaw-v0.28.2:src/bridge/effect_adapter.rs` (lines 612-620)

---

### P1-G: Lease Refund Guard for `resume_output`
**Commit:** `34eeeaf0` (the `#3559` lease accounting fix) | **Complexity:** S | **Dependencies:** P1-F | **Status:** Implemented 2026-05-28 — expanded to 5 sites across 3 executors (see [Implementation Note](#implementation-note-2026-05-28-p1-f--p1-g-pattern-fix-expansion))

**Why:** LunarWing's `interrupted_call_needs_refund()` at `crates/lunarwing_engine/src/executor/structured.rs:393-395` unconditionally returns `true` for all `GatePaused` errors. When `resume_output` is present, the action already executed successfully — the gate is a post-execution Authentication gate. Refunding the lease use nets a successful side-effecting action to zero lease consumption, breaking `max_uses` budget enforcement.

Currently, LunarWing doesn't have inline gate retry, so the refund is immediately followed by the action being reported as an error (gate\_paused). The lease accounting drift is observable but not directly exploitable. When inline retry lands, this becomes the lease bypass IronClaw's `#3559` review caught.

**What to change:** Update `interrupted_call_needs_refund` to check for `resume_output`:

```rust
fn interrupted_call_needs_refund(result: &Result<ActionResult, EngineError>) -> bool {
    matches!(result, Err(EngineError::GatePaused { resume_output: None, .. }))
}
```

**LunarWing file:** `crates/lunarwing_engine/src/executor/structured.rs:393-395`

**IronClaw reference:** `git show ironclaw-v0.28.2:crates/ironclaw_engine/src/executor/structured.rs` (lines 727-738 for the guard, lines 1475-1600 for the test)

---

### P1-H: Registry `hidden` Field on Extension Manifests
**Commit:** `34eeeaf0` | **Complexity:** S | **Dependencies:** None | **Status:** Not implemented — no `hidden` field in `src/registry/manifest.rs`, `src/registry/catalog.rs`, or `src/extensions/manager.rs`.

**Why:** IronClaw added `hidden: bool` to `ExtensionManifest` / `RegistryEntry` and filters hidden entries from the "available-but-not-installed" list and from `tool_search` results. Hidden entries remain installable by explicit name.

LunarWing doesn't have competing entries today, but this is a useful extension point for managing the registry catalog. It prevents deprecated or superseded entries from confusing the agent's tool selection without requiring deletion.

**What to change:**
1. Add `hidden: bool` (default `false`) to `ExtensionManifest` in `src/registry/manifest.rs`
2. Filter `hidden: true` entries from `ExtensionManager::list` (the available-but-not-installed appendix) in `src/extensions/manager.rs`
3. Filter `hidden: true` entries from `RegistryCatalog::search` in `src/registry/catalog.rs`

**IronClaw reference:**
- `git show ironclaw-v0.28.2:src/registry/manifest.rs` (hidden field + deserialization)
- `git show ironclaw-v0.28.2:src/extensions/manager.rs` (list filter)
- `git show ironclaw-v0.28.2:src/extensions/registry.rs` (search filter)

---

### P1-I: `fetch_models_for` Facade + Model Fetch Privatization
**Commit:** `cfeae9e6` | **Complexity:** M | **Dependencies:** None (standalone; does NOT require LLM crate extraction) | **Status:** Not implemented — no `fetch_models_for` or `FetchModelsOptions` in `src/llm/`. Callers still use per-backend model-list functions directly.

**Why:** LunarWing's setup wizard and CLI `models` subcommand both reach into provider-specific modules to list models (`fetch_anthropic_models`, `fetch_openai_models`, `fetch_ollama_models`, etc.). Each caller has a per-backend match arm. A single `fetch_models_for(provider_id, &opts)` facade collapses these to one call, and privatizing the per-provider fetchers removes public surface area from `src/llm/`.

This can be done within `src/llm/models.rs` without extracting the LLM crate (it's an internal boundary tightening, not a crate-level change).

**What to change:**
1. `src/llm/models.rs` — Add `pub fn fetch_models_for(provider_id: &str, opts: &FetchModelsOptions) -> Vec<String>` that dispatches internally
2. `src/setup/wizard.rs` — Replace per-backend model-list calls with `fetch_models_for`
3. `src/cli/models.rs` — Same replacement

**IronClaw reference:** `git show ironclaw-v0.28.2:crates/ironclaw_llm/src/models.rs` (the facade function + `FetchModelsOptions`)

---

## P2 — Nice-to-Have

### P2-C: Bug-Bash Regression-Snapshot Harness
**Commit:** `cfeae9e6` | **Complexity:** S-M | **Status:** Not implemented — no `e2e_bug_bash_snapshots.rs` or equivalent snapshot harness in `tests/`.

IronClaw 0.28.2 introduces a recorded-LLM-trace replay harness in `tests/e2e_bug_bash_snapshots.rs`. Bug-bash fixtures pin specific open bugs to a deterministic snapshot. When a bug is fixed, the snapshot diff is reviewable proof; when someone reintroduces the bug, the snapshot drifts and CI blocks the merge.

Uses `insta` YAML snapshots gated on `feature = "libsql"` and recorded traces via `IRONCLAW_RECORD_TRACE`.

This is a useful testing pattern for LunarWing's agent behavior regression. Port the harness skeleton and one fixture to validate the approach before recording more.

**IronClaw reference:**
- `git show ironclaw-v0.28.2:tests/e2e_bug_bash_snapshots.rs`
- `git show ironclaw-v0.28.2:tests/fixtures/llm_traces/bug_bash/README.md`

### P2-D: NearAI Default Model → `auto`
**Commit:** `cfeae9e6` | **Complexity:** Trivial | **Status:** Not applicable — LunarWing doesn't ship a `nearai` entry in `providers.json`.

IronClaw switched the `nearai` registry entry's `default_model` from `claude-sonnet-4-5` to `auto` (NEAR AI's server-side routing alias). LunarWing doesn't currently ship a `nearai` entry in `providers.json`, so this is a no-op unless NearAI support is added.

---

## Implementation Note (2026-05-28): P1-F + P1-G Pattern-Fix Expansion

Both items were implemented per the docs above, but the project's `review-discipline.md` rule ("Fix the pattern, not just the instance") expanded the change from the 2 sites the doc named to **5 sites across 4 files**. The same `refund-on-GatePaused-without-checking-resume_output` bug existed in all three LunarWing executors (Tier 0 structured, Tier 1 CodeAct, and the Python orchestrator with both an inline arm and a JSON-based predicate); fixing only `structured.rs` would have left the same latent bypass reachable through the other execution paths.

| File | Site | Kind | Change |
|------|------|------|--------|
| `crates/lunarwing_engine/src/executor/structured.rs:393` | `interrupted_call_needs_refund` | `Result`-based predicate | Now matches `Err(GatePaused { resume_output: None, .. })`. (P1-G as documented.) |
| `crates/lunarwing_engine/src/executor/scripting.rs:1282` | Tier 1 CodeAct GatePaused arm | Inline refund | Destructured `resume_output`; refund guarded on `is_none()`. |
| `crates/lunarwing_engine/src/executor/orchestrator.rs:932` | `__execute_action__` single-action arm | Inline refund | `resume_output` was already destructured; refund guarded on `is_none()`. |
| `crates/lunarwing_engine/src/executor/orchestrator.rs:1409` | `interrupted_result_needs_refund` | JSON-based predicate | Now also requires `resume_output` is null/absent (covers the parallel-action refund sites at lines 1245 / 1291). JSON results already carry the field at construction sites 718 / 960 / 1387, so no producer changes were needed. |
| `src/bridge/effect_adapter.rs:167` | `auth_gate_from_extension_result` | Gate output | Now passes `Some(output_value.clone())` instead of `None`. (P1-F as documented.) |

**Regression tests added (4):**

- `executor::structured::tests::post_execution_gate_does_not_refund_lease_use` — fails before the fix. Grants `max_uses: Some(2)`, returns `GatePaused { resume_output: Some(_) }` from `MockEffects`, asserts `uses_remaining == Some(1)` (consumed, not refunded).
- `executor::structured::tests::pre_execution_gate_refunds_lease_use` — control (`resume_output: None`); asserts `uses_remaining == Some(2)` (refunded).
- `executor::orchestrator::tests::interrupted_result_needs_refund_skips_post_execution_gate` — JSON predicate, four cases: pre-gate with `null` output, pre-gate with field absent, post-gate with output present, non-gate result.
- `bridge::effect_adapter::tests::auth_gate_carries_resume_output_for_resume_without_reexecution` — asserts the awaiting-auth gate carries the action's output in `resume_output`.

The two inline refund sites without their own regression tests (`scripting.rs:1282` and `orchestrator.rs:932`) are covered by structural symmetry to the `structured.rs` regression — the guard pattern is byte-identical — and by the predicate-level test for the orchestrator JSON path.

**Cross-reference:** Both P1-F and P1-G were "not exploitable today" in LunarWing because the inline gate-retry / provenance-aware auto-approve paths from IronClaw don't exist here yet. Implementing them now closes the latent vector before [0.28.1 P1-C (mission auto-resume + inline retry)](./ironclaw-0.28.1-port-analysis.md#p1-c-mission-auto-resume-after-gate-resolution) lands.

**Verification:** engine + main lib compile · 4/4 new regression tests pass · main-crate bridge module tests (67/67) pass · zero clippy warnings on the four touched files · `cargo fmt --check` clean · dual-backend `cargo check` (`libsql` + `postgres`) clean · `scripts/pre-commit-safety.sh` clean.

---

## Recommended Implementation Order

```
1. P0-A  Ghost-seeded permission cleanup   [S]   proactive security; prevent latent bypass       NOT DONE
2. P1-F  auth_gate resume_output            [S]   DONE 2026-05-28 (see Implementation Note)
3. P1-G  Lease refund guard                 [S]   DONE 2026-05-28 (expanded to 5 sites)
4. P1-H  Registry hidden field              [S]   small extension point                           NOT DONE
5. P1-I  fetch_models_for facade            [M]   code quality, reduces wizard complexity          NOT DONE
6. P2-C  Bug-bash snapshot harness          [S-M] testing infrastructure                           NOT DONE
```

Items 1-3 can be done in a single PR. Item 4 is standalone. Item 5 is a nice cleanup but not urgent. Item 6 is a test-infrastructure investment.

## Verification

After each item:
- `cargo fmt && cargo clippy --all --benches --tests --examples --all-features` (zero warnings)
- `cargo test`
- `cargo check --no-default-features --features libsql` (dual-backend)
- `scripts/pre-commit-safety.sh`

For P0-A specifically:
- Verify that `seed_tool_permissions` no longer writes rows on fresh startup
- Verify that `cleanup_ghost_seeded_tool_permissions` removes existing seeded rows
- Verify that `effective_permission("tool_install")` still returns `AskEachTime` (from the code-level fallback, not DB)
- Verify that a user-explicit `AlwaysAllow` override for `tool_install` survives the cleanup (it should — the cleanup deletes only rows matching the seeded default value)
