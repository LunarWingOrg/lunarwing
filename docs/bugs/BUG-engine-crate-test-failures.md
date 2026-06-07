# BUG: 5 pre-existing test failures in lunarwing_engine crate

**Severity:** Low (tests only, no production impact)
**Found:** 2026-06-02 during v1.1.0 release validation
**Status:** FIXED (verified 2026-06-07) — `cargo test -p lunarwing_engine` is green (271 passed, 0 failed). Original report retained below.
**Affects:** `cargo test -p lunarwing_engine`

## Summary

Five unit tests in `lunarwing_engine` fail consistently. All are test bugs caused by tests not being updated after production code refactors. No production code is broken.

---

## Failure 1: `executor::loop_engine::tests::action_then_text`

**Location:** `ic/crates/lunarwing_engine/src/executor/loop_engine.rs:621`
**Panic:** `assertion failed: exec.thread.messages.len() >= 3`

**Root cause:** Test was written for the old Rust-driven execution loop. After the migration to the Python orchestrator, intermediate messages (action calls, action results) are stored in `thread.internal_messages`, not `thread.messages`. The visible `thread.messages` now only contains the system prompt + final response (2 messages), not >= 3.

**Fix:** Assert on `internal_messages` or lower the bound to `>= 2`.

---

## Failure 2: `executor::loop_engine::tests::codeact_multi_step`

**Location:** `ic/crates/lunarwing_engine/src/executor/loop_engine.rs:877`
**Panic:** `assertion failed: exec.thread.messages.iter().any(|m| m.content.contains("x = 30"))`

**Root cause:** Same as failure 1. The code step output (`x = 30`) is part of the orchestrator's working transcript stored in `thread.internal_messages`, not the user-visible `thread.messages`.

**Fix:** Search `exec.thread.internal_messages` for `"x = 30"` instead of `exec.thread.messages`.

---

## Failure 3: `executor::loop_engine::tests::tool_intent_nudge_injected`

**Location:** `ic/crates/lunarwing_engine/src/executor/loop_engine.rs:739`
**Panic:** `assertion failed: exec.thread.messages.iter().any(|m| m.content.contains("did not include any tool calls"))`

**Root cause:** Same as failures 1-2. The tool intent nudge is injected by the Python orchestrator into its working transcript (`internal_messages`), not the user-visible `messages`.

**Fix:** Search `exec.thread.internal_messages` for the nudge text. The wording may also differ between the old Rust implementation and the Python orchestrator.

---

## Failure 4: `executor::trace::tests::trace_serializes_approval_request_payload`

**Location:** `ic/crates/lunarwing_engine/src/executor/trace.rs:606`
**Panic:** `unexpected event kind: MessageAdded { role: "System", content_preview: "sys" }`

**Root cause:** `Thread::add_message()` now emits a `MessageAdded` event for every message added. The test adds 2 messages (system + assistant) then manually pushes an `ApprovalRequested` event, then asserts `trace.events[0]` is `ApprovalRequested`. But the actual event order is:

- `[0]` = `MessageAdded { role: "System" }`
- `[1]` = `MessageAdded { role: "Assistant" }`
- `[2]` = `ApprovalRequested { ... }`

**Fix:** Access `trace.events[2]` or find the event by type:
```rust
let event = trace.events.iter()
    .find(|e| matches!(e.kind, EventKind::ApprovalRequested { .. }))
    .expect("should have an ApprovalRequested event");
```

---

## Failure 5: `runtime::mission::tests::system_mission_requires_system_user_to_manage`

**Location:** `ic/crates/lunarwing_engine/src/runtime/mission.rs:2546`
**Panic:** `called Result::unwrap_err() on an Ok value: ()`

**Root cause:** The test creates a mission owned by `"system"` and expects that user `"alice"` will be denied access when pausing it. However, `"system"` maps to `OwnerId::Shared` (it matches `LEGACY_SHARED_OWNER_ID`), and shared missions intentionally bypass per-user access checks at the engine level. The `pause_mission` guard:

```rust
if !mission.is_owned_by(user_id) && !mission.owner_id().is_shared() {
    return Err(EngineError::AccessDenied { ... });
}
```

...evaluates to `false` because `is_shared()` is `true`, so the method returns `Ok(())` and the test's `unwrap_err()` panics.

Per the docstring: "For shared missions, the caller (web handler) must verify admin role before calling this. The engine only checks ownership."

**Fix:** Use a non-shared user_id (e.g., `"admin-user"`) as the mission owner to test the ownership guard, or adjust the test expectation to match the documented shared-mission semantics.

---

## Common Theme

Failures 1-3 share a single root cause: the execution loop tests were written against the pre-orchestrator Rust loop and never updated when `ExecutionLoop::run()` was refactored to delegate to the Python orchestrator via Monty. The orchestrator maintains its own working transcript in `thread.internal_messages` and only syncs the final response to `thread.messages`.

## Impact

These failures do not indicate broken production behavior. The 266 passing engine tests cover the actual orchestrator logic, capability system, gate pipeline, memory retrieval, mission lifecycle, and type invariants.
