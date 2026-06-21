# External Worker Upgrades — Progress Checklist

> Work paused on 2026-06-21. This checklist tracks completed and remaining tasks for the `external-worker-upgrades` plan.

## Plan

- Full plan: `.sisyphus/plans/external-worker-upgrades.md`
- Boulder state: `.sisyphus/boulder.json`
- Memory state: `project:external-worker-execution-state`

## Done

- [x] **Task 1**: `TaskContext` + `ConversationMessage` structs in `ic/src/orchestrator/external_worker.rs`
  - All fields use `#[serde(default)]` for backward compatibility
  - `task_request` serialization uses `TaskContext::default()`
  - Tests passing: `task_context_full_roundtrip`, `task_context_backward_compat`

- [x] **Task 2**: `ExternalTaskStatus` enum in `ic/src/orchestrator/external_worker.rs`
  - Variants: `Success`, `Failed`, `Cancelled`, `TimedOut`, `Partial(String)`
  - `ExternalTaskResult.status` typed; `execute_external()` in `job.rs` updated
  - Tests passing: `task_status_enum_serde`, `task_status_enum_matching`

- [x] **Task 3.1–3.5**: Multi-instance `ExternalWorkerConfig` schema
  - `WorkerEndpoint` and `LoadBalanceStrategy` types added to `ic/src/config/sandbox.rs`
  - `ExternalWorkerConfig` extended with `endpoints` and `load_balance`
  - `ExternalWorkerSettings` extended in `ic/src/settings.rs`
  - `resolve_from_settings()` populates new fields
  - `endpoints()` helper returns canonical endpoint list (fallback to legacy single)
  - `config/mod.rs` re-exports `WorkerEndpoint` and `LoadBalanceStrategy`
  - Code compiles cleanly (`cargo check --lib`)

## In Progress

- [ ] **Task 3.6**: Add unit test `external_worker_config_multi_endpoint`
- [ ] **Task 3.7**: Add unit test `external_worker_config_legacy_fallback`

## Pending (Waves 2–4 + Final)

- [ ] **Task 4**: `WorkerConnectionPool` implementation
- [ ] **Task 5**: Context serialization + credential injection
- [ ] **Task 6**: Round-robin load balancer
- [ ] **Task 7**: Wire pool + LB into `ExternalWorkerManager`
- [ ] **Task 8**: Update `CreateJobTool` to pass `project_dir` + context
- [ ] **Task 9**: Update codex worker for extended context
- [ ] **Task 10**: Update nanocode worker for extended context
- [ ] **Task 11**: Update pebble worker for extended context
- [ ] **F1**: Plan compliance audit
- [ ] **F2**: Code quality review
- [ ] **F3**: Real manual QA
- [ ] **F4**: Scope fidelity check

## Files Modified (Wave 1)

- `ic/src/orchestrator/external_worker.rs`
- `ic/src/tools/builtin/job.rs`
- `ic/src/config/sandbox.rs`
- `ic/src/config/mod.rs`
- `ic/src/settings.rs`

## Verification Commands So Far

```bash
cd ic
cargo check --lib
cargo test task_context_full_roundtrip -- --nocapture
cargo test task_status_enum_serde -- --nocapture
cargo test task_status_enum_matching -- --nocapture
```

## Next Steps on Resume

1. Add Task 3.6 and 3.7 tests in `ic/src/config/sandbox.rs`.
2. Run `cargo test -- external_worker_config`.
3. Launch Wave 2 tasks (4 / 5 / 6) in parallel via subagents.
