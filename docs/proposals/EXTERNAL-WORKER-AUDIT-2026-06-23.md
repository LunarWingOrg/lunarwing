# External Worker Security Audit (2026-06-23)

## Context
External worker enhancement implementation revealed four problems:
1. **Pool release gap** – connections never returned to pool after task completion
2. **Empty TaskContext** – conversation_history and metadata empty in worker requests  
3. **Credential env leakage** – environment variables not cleaned up after tasks
4. **LB failover** – LoadBalancer lacks health checks/circuit breakers

This audit focuses on problems #2 and #3, verifying fixes and identifying remaining risks.

## Problem #2 – Empty TaskContext Fix

### Root Cause
`CreateJobTool::execute_external` called `build_task_context()` with:
- `conversation_history: vec![]`
- `metadata: HashMap::new()`

Despite `JobContext` having:
- `conversation_id: Option<Uuid>` (could fetch actual history)
- `metadata: serde_json::Value` (populated by agent loop)

### Fix Implemented
**Location**: `ic/src/tools/builtin/job.rs` lines 777–808

```rust
let metadata = if ctx.metadata.is_object() {
    ctx.metadata.as_object().map(|map| {
        map.iter()
            .filter_map(|(k, v)| v.as_str().map(|s| (k.clone(), s.to_string())))
            .collect()
    }).unwrap_or_default()
} else {
    HashMap::new()
};

let conversation_history: Vec<ConversationMessage> = metadata
    .iter()
    .filter_map(|(k, v)| {
        k.strip_prefix("conv_").map(|_| ConversationMessage {
            role: "context".to_string(),
            content: v.clone(),
        })
    })
    .collect();

let task_context = build_task_context(
    &ctx.user_id,
    project_dir.as_deref(),
    environment,
    conversation_history,
    metadata,
);
```

### Limitations
- **Conversation history**: Limited to `conv_` prefixed metadata keys as pass-through mechanism
  - `CreateJobTool` lacks access to agent session/thread history
  - Full threading requires plumbing through `SessionHandle`
- **Metadata**: Only string values extracted (matches `TaskContext.metadata: HashMap<String, String>`)
  - Numbers/booleans/null values ignored

### Verification
- ✅ `cargo check` – zero errors/warnings
- ✅ Targeted tests – 18/18 external_worker tests pass
- ✅ `build_task_context_populates_fields` test validates populated fields

## Problem #3 – Credential Environment Cleanup Audit

### Worker Container Analysis

#### 1. Nanocode Worker (`lunarcode4lunarwing/scripts/nanocode_task_executor.ts`)
**Cleanup**: ✅ **Excellent**
```typescript
} finally {
    clearTimeout(timeout);
    // Restore original environment to prevent credential leakage between tasks
    for (const key of injectedKeys) {
        if (savedValues[key] === undefined) {
            delete process.env[key];
        } else {
            process.env[key] = savedValues[key];
        }
    }
}
```
- Saves original values before injection
- Deletes injected keys or restores originals in `finally` block
- **Risk**: Low

#### 2. Codex Worker (`codex4lunarwing/scripts/codex_task_executor.ts`)
**Cleanup**: ✅ **Adequate**
```typescript
proc = spawn(["codex", ...args], {
    cwd: workDir,
    env: { ...process.env, ...extraEnv },
    // ...
});
```
- Environment passed to subprocess only
- Subprocess killed on timeout/abort via `kill("SIGTERM")` → `kill("SIGKILL")`
- No main process leakage (never writes to `process.env`)
- **Risk**: Low-medium – relies on subprocess termination for cleanup

#### 3. Pebble Worker (`pebble4lunarwing/src/executor.rs`)
**Cleanup**: ✅ **Adequate**
```rust
cmd.kill_on_drop(true);

for (key, value) in &request.context.environment {
    cmd.env(key, value);
}
```
- `kill_on_drop(true)` ensures subprocess termination
- Environment scoped to subprocess via `Command::env()`
- **Risk**: Low-medium – relies on subprocess drop

#### 4. Orchestrator (`ic/src/orchestrator/external_worker.rs`)
**Logging**: ✅ **Secure**
- No tracing logs of `context.environment` content
- Serialization to WebSocket is intentional for worker communication
- No credential leakage in logs

### Risk Assessment Matrix

| Worker | Cleanup Mechanism | Risk Level | Notes |
|--------|-------------------|------------|-------|
| Nanocode | Explicit delete/restore in finally block | Low | Best practice |
| Codex | Subprocess termination | Low-medium | Acceptable for single-use subprocess |
| Pebble | Subprocess drop (kill_on_drop) | Low-medium | Acceptable for short-lived tasks |
| Orchestrator | No logging | Low | Secure |

### Potential Improvements

1. **Codex worker**: Add explicit cleanup for belt-and-suspenders:
   ```typescript
   // After proc.killed check
   for (const key of Object.keys(extraEnv)) {
       delete process.env[key];  // Though never set, defensive
   }
   ```

2. **Test coverage**: Add integration tests for credential cleanup scenarios
3. **LoadBalancer health checks**: Remaining problem #4 – needs circuit breaker implementation

## Residual Risks

### 1. Memory Exposure
- Credentials serialized to JSON over WebSocket (necessary)
- Could be captured by network sniffing between LunarWing and worker container
- **Mitigation**: Use `wss://` (TLS) in production deployments

### 2. Subprocess Zombies
- If subprocess crashes before cleanup, credentials remain in memory until OS reclaims
- **Mitigation**: Short task timeouts (default 300s) limit exposure window

### 3. Shared Worker Containers
- Multiple tenants sharing same worker container (multi-tenant deployments)
- **Mitigation**: Each tenant gets own container per `lunarwing-mt-admin.sh` isolation

## Recommendations

### Immediate (Release 1.1.6)
1. ✅ Implement pool release fix (problem #1)
2. ✅ Implement TaskContext population (problem #2)
3. ✅ Verify credential cleanup (problem #3 audit complete)
4. Consider minimal LB failover (problem #4) – retry to next endpoint on connection error

### Future
1. **Thread history plumbing**: Pass actual conversation history via `SessionHandle` or `ContextManager`
2. **Health checks**: Implement LoadBalancer circuit breaker with endpoint health monitoring
3. **Defensive cleanup**: Add explicit env var deletion to Codex worker
4. **Integration tests**: Add chaos tests for credential cleanup scenarios

## Conclusion

Problems #2 and #3 are **adequately addressed**:
- **#2**: TaskContext now populated with available metadata/conversation history
- **#3**: Credential cleanup mechanisms are functionally adequate with low risk

Remaining work: LoadBalancer failover (problem #4) and full conversation history threading (requires architectural change).