# IronClaw Addition Candidates for LunarWing

## Status

- Compiled as a follow-up to the IronClaw/LunarWing comparison pass.
- No code changes are implied by this document.
- Existing detailed port analyses remain in `docs/proposals/OLDPROJECT_PORT_ANALYSES/`.
- This document is a filtered candidate list: it calls out the additions that still look useful after checking the current LunarWing tree, and it marks broad or duplicate work accordingly.

## Scope

This covers the topics discussed in the latest IronClaw investigation:

- the `serde_yml` -> `serde_norway` port,
- fresh current-source parity gaps found after the old analyses,
- still-useful items already captured in `OLDPROJECT_PORT_ANALYSES`,
- items that look low-fit, duplicate, or not worth prioritizing.

The main filter is: prefer concrete improvements that map to LunarWing's current monolith and existing multi-tenant/self-hosted shape. Do not adopt Reborn architecture wholesale.

## Baseline Already Done

### `serde_yml` -> `serde_norway`

**Status:** done in the current LunarWing tree.

Current LunarWing references:

- `ic/Cargo.toml` uses `serde_norway = "0.9"`.
- `ic/crates/lunarwing_skills/Cargo.toml` uses `serde_norway = "0.9"`.
- Skill manifest parsing in `ic/src/skills/parser.rs` and `ic/crates/lunarwing_skills/src/parser.rs` already calls `serde_norway::from_str`.
- The remaining YAML-ish conversion in `ic/src/bridge/store_adapter.rs` also uses `serde_norway`.

**Effect:** this removes the deprecated `serde_yml` dependency from the LunarWing skill/frontmatter parsing path. It mostly affects YAML frontmatter parsing and tests, not channel runtime behavior.

## Highest-Value New Candidates

These were not cleanly captured by the old proposal backlog, or they are narrower than the old backlog made them look.

### 1. Harden WASM channel HTTP egress like WASM tool HTTP egress

**Priority:** P1
**Size:** small to medium
**IronClaw reference:** `792357b7b` (`fix: WASM channel HTTP SSRF protections`)
**LunarWing fit:** strong

LunarWing's WASM tool host already has the hardening pattern:

- pre-request private/internal IP rejection unless `ALLOW_PRIVATE_IPS=1`,
- `reqwest::redirect::Policy::none()`,
- dedicated runtime inside `spawn_blocking`.

Current tool-side reference:

- `ic/src/tools/wasm/wrapper.rs` around the HTTP request path.

The WASM channel host does not match that posture:

- `ic/src/channels/wasm/wrapper.rs` builds a plain `reqwest::Client::builder()` with no redirect policy,
- channel HTTP does not perform the same private/internal IP rejection before sending.

**Why it matters:** WASM channels are extension-supplied network surfaces. A channel callback that can follow redirects or resolve private/internal targets is an SSRF path distinct from the built-in `http` tool and from the sandbox proxy item already documented in the Reborn analysis.

**Adaptation notes:**

- Reuse or factor the tool-side HTTP security helper instead of duplicating logic.
- Preserve LunarWing's `ALLOW_PRIVATE_IPS=1` local/multi-tenant escape hatch where appropriate.
- Add channel-side regression tests for redirect blocking and private/internal target rejection.

### 2. Fix WASM channel leak-scan ordering

**Priority:** P1
**Size:** small
**IronClaw reference:** `14333e4a0` (`fix(wasm): run leak scan on pre-injection headers in channel callbacks`)
**LunarWing fit:** strong

LunarWing's tool WASM path scans raw caller-provided URL/headers/body before host credential injection. The channel WASM path has comments claiming that behavior, but currently constructs `headers` after placeholder credential injection and then scans those injected values.

Current references:

- Correct tool-side pattern: `ic/src/tools/wasm/wrapper.rs`.
- Channel-side gap: `ic/src/channels/wasm/wrapper.rs`.

**Why it matters:** host-injected credentials can trip the leak detector even though the WASM guest never saw the real secret. That is a false-positive availability bug and a security-boundary confusion.

**What to change:**

- Parse `raw_headers` once.
- Scan the raw WASM-provided URL/header/body values.
- Only then inject placeholder and host credentials.
- Add a regression test with a token-shaped host credential to prove the injected token does not self-block, while a token supplied by the guest still blocks.

### 3. UTF-8-safe CLI truncation sweep

**Priority:** P1/P2
**Size:** small
**IronClaw reference:** `90a6dadb4` (`fix(cli): prevent UTF-8 panic in MCP tool description truncation`)
**LunarWing fit:** strong

The exact byte-slicing bug remains in:

- `ic/src/cli/mcp.rs` (`&tool.description[..57]`).

Similar byte-index truncations also exist in:

- `ic/src/cli/config.rs`,
- `ic/src/cli/reflex.rs`,
- `ic/src/cli/memory.rs`.

LunarWing already has `floor_char_boundary()` in `ic/src/util.rs`, and some CLI modules already use char-based truncation helpers correctly.

**Why it matters:** non-ASCII descriptions, config values, reflex patterns, or memory previews can panic at runtime when a truncation byte offset lands inside a multi-byte character.

**What to change:**

- Introduce or reuse one local `truncate_for_display()` helper.
- Replace byte-slice truncation with char-boundary-safe truncation.
- Add CJK/emoji regression tests at least for `mcp.rs` and the shared helper.

### 4. Promote `JobResult.status` from `String` to `JobResultStatus`

**Priority:** P2
**Size:** medium
**IronClaw reference:** `e88236ab0` (`refactor(events): replace JobResult.status String with JobResultStatus enum`)
**LunarWing fit:** good

Current LunarWing still has stringly job-result status:

- `ic/crates/lunarwing_common/src/event.rs` has `JobResult { status: String }`.
- `ic/src/agent/job_monitor.rs` matches raw strings.
- Producers emit `"completed"`, `"failed"`, `"stuck"`, and legacy `"error"` from worker/container/orchestrator paths.

**Why it matters:** producer/consumer drift in job status handling is easy to miss, especially around `stuck`, `approval_required`, and legacy `error`.

**What to change:**

- Add a `JobResultStatus` enum in `lunarwing_common`.
- Preserve snake_case wire format.
- Accept legacy `"error"` as `Failed`.
- Decide whether `"approval_required"` is a real status or just a monitor-side alias for `Stuck`.
- Update producers to emit the enum and consumers to match exhaustively.

**Risk:** mostly serialization compatibility and fixture churn. Keep wire strings stable.

### 5. Add `ExternalThreadId` as a narrow channel-boundary newtype

**Priority:** P2
**Size:** medium
**IronClaw reference:** `833cb4844` (`refactor(channels): introduce ExternalThreadId newtype at channel boundary`)
**LunarWing fit:** good if kept narrow

The older proposal backlog mentions a broad `lunarwing_common` identity expansion. That is too broad for this pass. The useful part is just the external channel thread ID boundary.

Current raw-string surfaces include:

- `ic/src/channels/channel.rs` (`thread_id: Option<String>`, `conversation_scope_id: Option<String>`),
- `ic/src/agent/session_manager.rs` (`ThreadKey.external_thread_id: Option<String>`),
- `ic/src/agent/thread_ops.rs` hydration paths,
- web, XMPP, WASM, bridge, and gate call sites.

**Why it matters:** external channel IDs and internal UUID thread IDs are different concepts. Raw strings let code accidentally treat one as the other.

**What to change:**

- Add a validated `ExternalThreadId` newtype.
- Mint it at channel ingress.
- Keep conversion to `&str` cheap for map keys and persistence.
- Do not attempt a whole-repo identity migration in one PR.

**Important adaptation:** conversation-scope strings can legitimately include JID/channel syntax. Validation must reject dangerous/control/path-ish values without rejecting normal channel identifiers.

### 6. Bound concurrent WASM prepare/execute/callback work

**Priority:** P2/P3
**Size:** medium
**IronClaw reference:** `799eb1540` (`fix(reborn): stop WASM execution from starving the tokio worker pool`)
**LunarWing fit:** partial

LunarWing already does the most important thing: synchronous Wasmtime work is offloaded through `spawn_blocking` in both tool and channel paths. The Reborn failure mode was worse because synchronous Wasmtime calls ran directly on async workers.

Remaining LunarWing gap:

- no shared semaphore bounds on concurrent WASM prepare/execute/channel callback storms,
- prepare and execution can contend through the blocking pool under bursty extension load.

**What to change if pursued:**

- Add process-wide semaphores for WASM execution and preparation.
- Consider separate prepare and execute limits so cold compile storms do not starve already-prepared execution.
- Preserve current panic-to-error behavior.
- Add cancellation/permit-release tests.

**Recommendation:** do after the channel HTTP/leak-scan work unless production has evidence of WASM storms.

## Existing Proposal Items Still Worth Carrying

These are already documented in `OLDPROJECT_PORT_ANALYSES`; they remain useful but should not be rediscovered as new work.

### Wasmtime sandbox upgrade

**Source doc:** `OLDPROJECT_PORT_ANALYSES/ironclaw-0.29.0-port-analysis.md`
**Priority:** security workstream
**Size:** large

Still one of the most important old-analysis items because Wasmtime is LunarWing's sandbox boundary for third-party WASM tools/channels. Keep it as a dedicated workstream, not bundled with smaller hardening changes.

### Sandbox proxy redirect SSRF

**Source doc:** `OLDPROJECT_PORT_ANALYSES/ironclaw-reborn-port-analysis.md`
**Priority:** P1
**Size:** small

Distinct from the WASM channel egress gap above. This concerns container sandbox proxy egress and redirect revalidation.

### Embeddings SSRF hardening

**Source doc:** `OLDPROJECT_PORT_ANALYSES/ironclaw-0.29.0-port-analysis.md`
**Priority:** P2
**Size:** medium

Do not copy IronClaw's private-IP denial verbatim. LunarWing intentionally supports local/private embedding endpoints. The useful adaptation is scheme validation plus always-block cloud metadata, integrated with LunarWing's network policy.

### CodeAct kill-switch

**Source doc:** `OLDPROJECT_PORT_ANALYSES/ironclaw-0.29.0-port-analysis.md`
**Priority:** P1/P2
**Size:** medium

Still a good operator-safety feature: `LUNARWING_DISABLE_CODEACT=1` should route the model toward structured tool calls and avoid interpreter execution.

### Durable chat/SSE event log with replay

**Source doc:** `OLDPROJECT_PORT_ANALYSES/ironclaw-reborn-port-analysis.md`
**Priority:** P2
**Size:** large

Useful if gateway/mobile reconnect drift is painful. This is larger than the other items because it touches DB schema, SSE replay, frontend reconnect behavior, and event persistence policy.

### WASM credential authority ceiling

**Source doc:** `OLDPROJECT_PORT_ANALYSES/ironclaw-reborn-port-analysis.md`
**Priority:** P1/P2 after verification
**Size:** medium

Still plausible, but verify current residual surface first. The useful shape is not Reborn's whole trust system; it is a LunarWing-specific ceiling for which secrets and wildcard hosts a user-trust WASM tool can request.

### Validated `UserId` newtype

**Source doc:** `OLDPROJECT_PORT_ANALYSES/ironclaw-reborn-port-analysis.md`
**Priority:** P2
**Size:** small to medium, if incremental

Good hardening because `user_id` flows into DB queries and filesystem-ish scopes. Keep it separate from `ExternalThreadId`; they solve different confusion classes.

### Project static-file ownership check

**Source doc:** `OLDPROJECT_PORT_ANALYSES/ironclaw-reborn-port-analysis.md`
**Priority:** verify first
**Size:** small

The old analysis flagged project static-file handlers that may not take `AuthenticatedUser`. This is worth verifying directly before treating it as a vulnerability.

### Architecture boundary checks in CI

**Source doc:** `OLDPROJECT_PORT_ANALYSES/ironclaw-reborn-port-analysis.md` and `ironclaw-0.28.1-port-analysis.md`
**Priority:** P2/P3
**Size:** small

The useful part is not crate-graph purity. It is source-level checks that channels/handlers do not bypass dispatcher or network policy boundaries.

### `fetch_models_for` facade

**Source doc:** `OLDPROJECT_PORT_ANALYSES/ironclaw-0.28.2-port-analysis.md`
**Priority:** P3
**Size:** medium

Still a reasonable LLM API cleanup. Lower priority than security and correctness items.

### Gateway logs download UI button

**Source doc:** `OLDPROJECT_PORT_ANALYSES/ironclaw-0.29.0-port-analysis.md`
**Priority:** P3
**Size:** small

Backend route is documented as already implemented; the remaining useful bit is the gateway button and clear labeling that the export is recent-buffer only.

## Secondary Backlog from the Existing Analyses

These are not top picks from the latest investigation, but they are still valid enough to keep visible.

### WASM selective channel activation

**Source doc:** `OLDPROJECT_PORT_ANALYSES/ironclaw-0.28.1-port-analysis.md`
**Priority:** P2
**Size:** medium

Useful for headless deployments that should not load every discovered WASM channel. Keep this as an operational hardening item, especially if unconfigured channels continue to create noise or unnecessary credential exposure.

### `scoped_to_user` workspace isolation

**Source doc:** `OLDPROJECT_PORT_ANALYSES/ironclaw-0.28.1-port-analysis.md`
**Priority:** P2
**Size:** small to medium

Still conceptually aligned with multi-tenant LunarWing, but verify whether current owner-scope and tenant import/export work has changed the need before implementing. This is a workspace isolation/efficiency improvement, not a direct security patch until a concrete cross-user flow depends on it.

### Mission auto-resume after gate resolution

**Source doc:** `OLDPROJECT_PORT_ANALYSES/ironclaw-0.28.1-port-analysis.md`
**Priority:** P2
**Size:** large

Potentially useful for routines/missions that pause on an approval or auth gate and need to continue without manual babysitting. It should not be attempted until the current routine/retry behavior is rechecked, because LunarWing has since grown its own routine retry and stuck-run handling.

### Built-in HTTP tool leak-scan ordering

**Source doc:** `OLDPROJECT_PORT_ANALYSES/ironclaw-reborn-port-analysis.md`
**Priority:** P2
**Size:** small

Separate from the WASM channel leak-scan item above. The old analysis claimed the built-in `http` tool scans after credential injection and can self-block legitimate host-injected credentials. Re-verify current `ic/src/tools/builtin/http.rs` before implementing.

### Failure/recoverability matrix tests

**IronClaw reference:** Reborn no-run-borking/failure-matrix work
**Priority:** P2/P3
**Size:** medium to large

The full Reborn recoverability stack is too large and too Reborn-specific. The useful LunarWing adaptation is a smaller failure matrix that pins current behavior around model errors, tool errors, gate pauses, denied actions, job failures, and retryable routine failures.

### Bug-bash regression snapshot harness

**Source doc:** `OLDPROJECT_PORT_ANALYSES/ironclaw-0.28.2-port-analysis.md`
**Priority:** P3
**Size:** small to medium

Useful if LunarWing starts collecting reproducible agent-behavior regressions. Do not build a large harness speculatively; start with one real recorded trace or one known regression.

### Pre-commit / architecture safety checks

**Source doc:** `OLDPROJECT_PORT_ANALYSES/ironclaw-0.28.1-port-analysis.md` and Reborn boundary-check notes
**Priority:** P3
**Size:** small

Worth doing if the checks run in normal CI. Avoid shell-only checks that drift unused; prefer a Rust test or a CI step that fails reliably.

## Candidates to Deprioritize

These came up in the broader comparison, but should not lead the next work queue.

### Broad LLM crate extraction

This may eventually be useful, but it is XL and mostly boundary cleanup. Do it only if the LLM module is actively blocking other work.

### Whole `lunarwing_common` expansion

Do not port a large common-types bundle just to get one identity type. Take `ExternalThreadId` and `UserId` independently.

### WIT `websocket-send-text`

Only worth adopting if a real LunarWing WASM channel, probably WeeChat-WSS, needs host-managed websocket sends. A speculative WIT bump creates binding churn across channels/tools.

### Reborn topology, product adapters, WebUI v2, Slack/Telegram/WeCom surfaces

Low fit. LunarWing's model is different and does not benefit from importing these surfaces.

### Event projection cursor machinery wholesale

The durable SSE idea is useful. The full Reborn projection/keying machinery is too heavy for LunarWing's monolith.

### Scheduled-trigger self-mutation denial

Already mostly handled by LunarWing's autonomous/routine denylist and approval gates. Keep tests if desired, but this is not a top port.

### Missing outbound target semantics

LunarWing already has explicit missing-target handling and targeted-notification fallback behavior. Revisit only if there is a concrete bug.

## Suggested Implementation Order

Recommended near-term sequence:

1. **WASM channel HTTP hardening**
   Confined security improvement. Implement with tests.

2. **WASM channel leak-scan ordering**
   Same file family as item 1. Cheap correctness fix.

3. **UTF-8-safe CLI truncation sweep**
   Small cleanup with clear panic regression tests.

4. **Sandbox proxy redirect SSRF**
   Already documented, still high value. Keep separate from WASM channel egress tests.

5. **Typed `JobResultStatus`**
   Medium correctness refactor; stabilizes job monitor/worker contract.

6. **`ExternalThreadId` newtype**
   Medium boundary-hardening refactor. Keep the first PR narrow.

7. **Embeddings SSRF audit/hardening**
   Useful but requires care not to break private/local endpoints.

8. **CodeAct kill-switch**
   Operator safety feature; needs end-to-end verification that structured tool calls still work.

9. **Wasmtime upgrade workstream**
   Important but large; should have its own plan and staged verification.

10. **Durable chat/SSE event log**
    Valuable if reconnect drift is a real pain point; large enough for its own design.

## Verification Notes

Default verification for implementation PRs should run from `ic/`:

```bash
cargo fmt --check
cargo test
cargo check --no-default-features --features libsql
cargo check --no-default-features --features postgres
```

Use heavier checks for riskier items:

- WASM/Wasmtime changes: run WASM channel/tool build and conformance paths.
- Network hardening: add negative tests for redirect/private/metadata targets and positive tests for allowed local/private LunarWing configurations.
- Serialization changes: add wire-format round-trip tests and legacy alias tests.
- Boundary newtypes: add ingress validation tests and at least one real channel/session-manager integration test.

## Summary

The useful next work is not "catch up to IronClaw." It is mostly:

- close duplicate-path hardening gaps inside LunarWing,
- pull small correctness fixes with clear regressions,
- keep the existing old-analysis security workstreams alive,
- avoid broad Reborn or product-surface imports unless they solve a current LunarWing problem.
