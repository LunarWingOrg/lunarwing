# External Worker Upgrades — Progress Checklist

> Last updated: 2026-06-22. Tracks completed and remaining tasks for the external worker upgrades plan.

## Plan

- Full plan: `docs/proposals/EXTERNAL-WORKER-PLAN-UPGRADES.md`

## Wave 1 — COMPLETE

- [x] **Task 1**: `TaskContext` + `ConversationMessage` structs in `ic/src/orchestrator/external_worker.rs`
  - All fields use `#[serde(default)]` for backward compatibility
  - `task_request` serialization uses `TaskContext::default()`
  - Tests passing: `task_context_full_roundtrip`, `task_context_backward_compat`

- [x] **Task 2**: `ExternalTaskStatus` enum in `ic/src/orchestrator/external_worker.rs`
  - Variants: `Success`, `Failed`, `Cancelled`, `TimedOut`, `Partial(String)`
  - `ExternalTaskResult.status` typed; `execute_external()` in `job.rs` updated
  - Tests passing: `task_status_enum_serde`, `task_status_enum_matching`

- [x] **Task 3**: Multi-instance `ExternalWorkerConfig` schema
  - `WorkerEndpoint` struct (`url`, `auth_token`, `weight`) in `ic/src/config/sandbox.rs`
  - `LoadBalanceStrategy` enum (`RoundRobin` default, `LeastConnections`) in `ic/src/config/sandbox.rs`
  - `ExternalWorkerConfig` extended with `endpoints: Vec<WorkerEndpoint>` and `load_balance`
  - `ExternalWorkerSettings` extended in `ic/src/settings.rs` with matching fields
  - `resolve_from_settings()` populates new fields
  - `endpoints()` helper returns canonical endpoint list (fallback to legacy single `url`)
  - `config/mod.rs` re-exports `WorkerEndpoint` and `LoadBalanceStrategy`
  - Tests passing: `external_worker_config_multi_endpoint`, `external_worker_config_legacy_fallback`

## Pending — Wave 2 (core implementations)

- [ ] **Task 4**: `WorkerConnectionPool` implementation (depends: Task 2)
- [ ] **Task 5**: Context serialization + credential injection (depends: Task 1)
- [ ] **Task 6**: Round-robin `LoadBalancer` struct (depends: Task 3)

## Pending — Wave 3 (integration)

- [ ] **Task 7**: Wire pool + LB into `ExternalWorkerManager` (depends: Tasks 4, 5, 6)
- [ ] **Task 8**: Update `CreateJobTool` to pass `project_dir` + context (depends: Tasks 5, 7)

## Pending — Wave 4 (worker containers)

- [ ] **Task 9**: Update codex worker for extended context (depends: Task 7)
- [ ] **Task 10**: Update nanocode worker for extended context (depends: Task 7)
- [ ] **Task 11**: Update pebble worker for extended context (depends: Task 7)

## Pending — Final review

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

## Verification

```bash
cd ic
cargo test external_worker -- --nocapture   # all 15 Wave 1 tests pass
```
