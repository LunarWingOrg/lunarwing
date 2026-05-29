# Human Delay Mode - Phase 2 Plan

**Status**: Planned, pending Phase 1 verification first.
**Goal**: Complete the supervised mode experience with timeout integration, UI options, and robust testing.

## Phase 2 Scope

Phase 1 introduced the data model and basic approval gating. Phase 2 makes it actually *usable* — timeouts, UI options, and full pipeline integration.

## 1. Wire `supervised_timeout_secs` to Pending Gate Expiration

### Problem
Currently `supervised_timeout_secs` flows through the context but is never used to set when a pending gate expires. Approval gates timeout at a hardcoded value or never.

### Implementation

**Target**: `ic/crates/lunarwing_engine/src/bridge/effect_adapter.rs` and/or `ic/crates/lunarwing_engine/src/gate/approval.rs`

```rust
// In execute_action_internal() when creating PendingGate:
let expires_at = context.supervised_mode
    .then_some(SystemTime::now() + Duration::from_secs(context.supervised_timeout_secs))
    .or_else(|| default_expiry());
```

### Files to modify
- `ic/crates/lunarwing_engine/src/bridge/effect_adapter.rs` — pass timeout to `PendingGate`
- `ic/crates/lunarwing_engine/src/gate/mod.rs` — `PendingGate` struct may need `expires_at` field (verify exists)

## 2. Gate Pipeline Full Integration

### Problem
Currently the approval gate works via the inline check in `effect_adapter.rs`, but the structured `ApprovalGate` pipeline isn't actually being called in production execution path.

### Implementation

**Goal**: Make `ApprovalGate::evaluate()` the primary approval path, with inline check as fallback.

**Target**: `ic/crates/lunarwing_engine/src/executor/orchestrator.rs`

- Find where the gate pipeline should be invoked before tool execution
- Wire `ApprovalGate` into the execution flow
- Ensure `GateContext` with supervised fields is properly passed through
- Inline check in `effect_adapter.rs` becomes fallback/safety net

### Files to modify
- `ic/crates/lunarwing_engine/src/executor/orchestrator.rs`
- `ic/crates/lunarwing_engine/src/gate/approval.rs`
- `ic/crates/lunarwing_engine/src/bridge/effect_adapter.rs` (potentially reduce inline check scope)

## 3. UI "Modify" Option for Supervised Threads

### Problem
In supervised mode, humans approve or reject tool requests. Sometimes the human wants to *modify* the tool parameters (e.g., change URL, file path, command) rather than blindly approve or reject.

### Implementation

**Goal**: Add "modify" as a third option to the approval UI.

**Flow**:
1. Tool request pauses → `GatePaused(PendingGate { action: ..., params: ... })`
2. Human chooses "modify" → UI shows editable parameters
3. Human edits → submits modified parameters
4. System executes with modified params (not original)

**CLI interface**:
```bash
# Existing
lunarwing gate approve <gate_id>
lunarwing gate reject <gate_id>

# New
lunarwing gate modify <gate_id> --params '{"url": "new_url"}'
```

### Files to modify
- `ic/crates/lunarwing_engine/src/gate/approval.rs` — add modify variant
- `ic/crates/lunarwing_engine/src/bridge/effect_adapter.rs` — handle modified execution
- `ic/crates/lunarwing_router/src/lib.rs` — add CLI modify command
- `ic/crates/lunarwing_cli/src/commands/` — add CLI command handler

## 4. Supervised Mode Configuration Per-Thread

### Problem
Currently supervised mode is a binary flag (on/off). In practice, different threads may need different levels of supervision.

### Enhancement (optional, may be Phase 3)

- `supervised_mode: Always | Tools | Commands | Disabled`
- Different supervision levels for different tool types
- Configurable per-thread via `ThreadConfig`

### Implementation (if included)
```rust
pub enum SupervisionLevel {
    Disabled,      // No supervision
    Tools,         // Only tool execution requires approval
    Commands,      // Only command execution requires approval
    Always,        // All actions require approval (current behavior)
}
```

## 5. Testing

### Unit Tests

**New tests needed**:
- `test_supervised_mode_blocks_all_tools()` — verify all tools require approval
- `test_supervised_mode_overrides_auto_approve()` — verify override behavior
- `test_supervised_timeout_expires_gate()` — verify timeout causes auto-reject
- `test_supervised_mode_with_modify()` — verify modify flow works
- `test_supervised_mode_thread_config_propagation()` — verify context fields flow through

### Integration Tests

- **CLI + Router flow**: Start with `--supervised` flag → create thread → request tool → verify pause
- **Approval + Reject flow**: Verify gate approval/reject behavior
- **Timeout flow**: Verify gate expires after `supervised_timeout_secs`

### Files to modify
- `ic/crates/lunarwing_engine/src/bridge/tests/`
- `ic/crates/lunarwing_engine/src/gate/tests/`
- `ic/crates/lunarwing_router/src/tests/`
- New test file: `ic/crates/lunarwing_engine/src/gate/tests/supervised.rs`

## Phase 2 Timeline (Estimated)

| Task | Effort | Dependencies |
|------|--------|-------------|
| 1. Timeout wiring | Small | Phase 1 verified |
| 2. Gate pipeline integration | Medium | Task 1 complete |
| 3. Modify UI option | Medium | Task 2 complete |
| 4. Supervision levels | Medium | Tasks 1-3 complete |
| 5. Tests | Medium | All above complete |

## Phase 3 (Future)

- Agent-to-agent supervised coordination (supervised thread with agent-to-agent tools)
- Supervision dashboard (UI to view all pending approvals across threads)
- Supervision audit logging (who approved what, when)
- Sweetiebot integration (multi-agent supervised workflow)

---

**Priority Order**: 1 → 2 → 3 → 5 (Task 4 optional)
**Blocker**: Phase 1 must compile and pass existing tests before starting Phase 2.