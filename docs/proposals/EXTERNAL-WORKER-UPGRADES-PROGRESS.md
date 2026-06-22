# External Worker Upgrades — Progress Checklist

> Last updated: 2026-06-22. Tracks completed and remaining tasks for the external worker upgrades plan.

## Plan

- Full plan: `docs/proposals/EXTERNAL-WORKER-PLAN-UPGRADES.md`

## Wave 1 — COMPLETE

- [x] **Task 1**: `TaskContext` + `ConversationMessage` structs in `ic/src/orchestrator/external_worker.rs`
  - All fields use `#[serde(default)]` for backward compatibility
  - Tests passing: `task_context_full_roundtrip`, `task_context_backward_compat`

- [x] **Task 2**: `ExternalTaskStatus` enum in `ic/src/orchestrator/external_worker.rs`
  - Variants: `Success`, `Failed`, `Cancelled`, `TimedOut`, `Partial(String)`
  - `ExternalTaskResult.status` typed; `execute_external()` in `job.rs` updated
  - Tests passing: `task_status_enum_serde`, `task_status_enum_matching`

- [x] **Task 3**: Multi-instance `ExternalWorkerConfig` schema
  - `WorkerEndpoint`, `LoadBalanceStrategy`, config extensions across `sandbox.rs`, `settings.rs`, `mod.rs`
  - Tests passing: `external_worker_config_multi_endpoint`, `external_worker_config_legacy_fallback`

## Wave 2 + 7 — COMPLETE

- [x] **Task 6**: `LoadBalancer` struct with `AtomicUsize` round-robin
  - `next_endpoint()` cycles through endpoints lock-free
  - Tests passing: `load_balancer_round_robin`, `load_balancer_single_endpoint`

- [x] **Task 5**: Context serialization — `build_task_context()` + signature changes
  - `execute_task()` and `run_external_task()` now accept `TaskContext` parameter
  - `execute_external()` in `job.rs` builds and passes `TaskContext` with user_id
  - `task_request` payload uses real context instead of `TaskContext::default()`
  - Tests passing: `build_task_context_populates_fields`, `build_task_context_defaults`

- [x] **Task 4+7**: `WorkerConnectionPool` + wiring into `ExternalWorkerManager`
  - Pool struct with `try_acquire`/`release`/`evict_stale`/`drain` methods
  - `ExternalWorkerManager` now has `load_balancers` and `pool` fields
  - `new()` initializes LBs from each worker's `config.endpoints()` list
  - `execute_task()` uses LB for endpoint selection, passes pool to runner
  - `connect_and_handshake()` extracted as reusable helper
  - `run_external_task()` tries pooled connection first, falls back to fresh
  - Opportunistic stale eviction on each `execute_task()` call
  - Pool release after task completion noted as follow-up (stream reunification)
  - Tests passing: `pool_try_acquire_empty_returns_none`, `pool_evict_stale_removes_old`, `pool_drain_empties_all`, `manager_initializes_load_balancers`

## Wave 3 — COMPLETE

- [x] **Task 8**: Update `CreateJobTool` to pass `project_dir` + credentials via `TaskContext`
  - `parameters_schema()` exposes `project_dir` and `credentials` for external workers (not just sandbox)
  - `execute()` parses both params when routing to external workers
  - `execute_external()` accepts `project_dir` and `credential_grants`, resolves secrets to env vars via `SecretsStore::get_decrypted()`, populates `TaskContext.environment` and `TaskContext.project_dir`
  - Job record persists `project_dir` and `credential_grants_json`
  - Backward compatible: empty credentials/project_dir produce same behavior as before

## Pending — Wave 4 (worker containers)

- [ ] **Task 9**: Update codex worker for extended context
- [ ] **Task 10**: Update nanocode worker for extended context
- [ ] **Task 11**: Update pebble worker for extended context

## Pending — Final review

- [ ] **F1**: Plan compliance audit
- [ ] **F2**: Code quality review
- [ ] **F3**: Real manual QA
- [ ] **F4**: Scope fidelity check

## Files Modified

| Wave | Files |
|------|-------|
| 1 | `ic/src/orchestrator/external_worker.rs`, `ic/src/tools/builtin/job.rs`, `ic/src/config/sandbox.rs`, `ic/src/config/mod.rs`, `ic/src/settings.rs` |
| 2+7 | `ic/src/orchestrator/external_worker.rs`, `ic/src/tools/builtin/job.rs` |

## Verification

```bash
cd ic
cargo fmt -- --check                                    # clean
cargo clippy --all --benches --tests --examples         # zero warnings
cargo test external_worker -- --nocapture                # 23 tests pass
cargo test create_job -- --nocapture                     # 6 tests pass
```
