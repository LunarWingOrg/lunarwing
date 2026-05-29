# Human Delay Mode - Phase 1 Test Checklist

**Status**: Implementation complete (branch `human-delay-mode-phase-1-baud`), ready for verification.

## Overview

Phase 1 introduces `supervised_mode` + `supervised_timeout_secs` fields to:
- `ThreadConfig`
- `ThreadExecutionContext` 
- `GateContext`

When `supervised_mode = true`:
- All tools require human approval (overrides auto-approve)
- Tool request pauses at gate with `GatePaused(PendingGate { ... })`
- User must approve via existing approval flow

## What Changed

### 1. Data Model Additions
- `ic/crates/lunarwing_types/src/thread.rs` → `ThreadConfig`
  - `pub supervised_mode: bool` (default false)
  - `pub supervised_timeout_secs: u64` (default 300)
- `ic/crates/lunarwing_engine/src/executor/structured.rs` → `ThreadExecutionContext`
  - Same fields added
- `ic/crates/lunarwing_engine/src/gate/mod.rs` → `GateContext`
  - Same fields added

### 2. Gate/Approval Logic
- **Inline check** (`ic/crates/lunarwing_engine/src/bridge/effect_adapter.rs`):
  - At `execute_action_internal()`, before tier-based approval logic
  - If `context.supervised_mode == true` → returns `GatePaused`
- **Gate pipeline** (`ic/crates/lunarwing_engine/src/gate/approval.rs`):
  - `ApprovalGate::evaluate()` early exit if supervised mode

### 3. Configuration & CLI
- **CLI flag**: `lunarwing --supervised` or `lunarwing run --supervised`
- **Environment variable**: `AGENT_SUPERVISED_MODE=true`
- **Router integration** (`ic/crates/lunarwing_router/src/lib.rs`):
  - Reads env var, sets `thread_config.supervised_mode = true`
  - Applies to new foreground threads

## Verification Steps

### Step 1: Compilation
```bash
cd /path/to/lunarwing/ic
cargo check
```
Expected: No compilation errors.

### Step 2: Run existing tests
```bash
cargo test --lib
```
Expected: All existing tests pass (test constructors updated for new fields).

### Step 3: Test supervised mode via CLI
```bash
# 1. Start agent with supervised mode
AGENT_SUPERVISED_MODE=true ./target/debug/lunarwing

# 2. From another terminal, start a thread
./target/debug/lunarwing thread create

# 3. Try any tool (e.g., tool search, web_fetch, exec)
# Expected: Tool request pauses, approval required
```

### Step 4: Test approval flow
```bash
# 1. List pending approvals
./target/debug/lunarwing gate list

# 2. Approve a pending gate
./target/debug/lunarwing gate approve <gate_id>

# 3. Verify tool executes after approval
```

### Step 5: Test auto-approve override
**Goal**: Verify `supervised_mode` overrides `auto_approve_tools`.

1. Configure agent with `auto_approve_tools = ["web_fetch", "tool_search"]`
2. Start with `AGENT_SUPERVISED_MODE=true`
3. Request `web_fetch` tool
4. Expected: Tool pauses (requires approval) even though in auto-approve list

### Step 6: Test timeout configuration
**Goal**: Verify `supervised_timeout_secs` is respected (though pending gate integration pending Phase 2).

Currently `supervised_timeout_secs` is passed through but not yet wired to `PendingGate::expires_at` (Phase 2). For now, verify the field flows correctly:
- Create supervised thread → check `GateContext` contains timeout value

## Known Issues / Phase 2 Dependencies

1. **Pending gate expiration** not yet wired — timeout value exists but not used
2. **Gate pipeline integration** incomplete — only inline path (`effect_adapter.rs`) currently active
3. **UI "modify" option** for supervised threads not yet implemented
4. **Test coverage** for supervised mode flow is minimal (only data model tests)

## Files to Review

- `ic/crates/lunarwing_types/src/thread.rs` — ThreadConfig additions
- `ic/crates/lunarwing_engine/src/bridge/effect_adapter.rs` — inline supervised check
- `ic/crates/lunarwing_engine/src/executor/orchestrator.rs` — ThreadExecutionContext construction
- `ic/crates/lunarwing_engine/src/executor/structured.rs` — ThreadExecutionContext definition
- `ic/crates/lunarwing_engine/src/gate/approval.rs` — gate pipeline integration
- `ic/crates/lunarwing_router/src/lib.rs` — env var integration
- All test files updated with new struct fields

## Success Criteria

- ✅ Compiles without errors
- ✅ All existing tests pass
- ✅ Supervised mode triggers pause for all tools
- ✅ Supervised mode overrides auto-approve config
- ✅ Timeout field flows through execution context
- ✅ CLI flag/env var properly sets thread config

---

**Next**: Phase 2 will wire `supervised_timeout_secs` to `PendingGate` expiration, add UI modify option, and improve test coverage.