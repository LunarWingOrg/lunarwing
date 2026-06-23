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
  - **Second pass (2026-06-23, H3)**: the first pass defined
    `LoadBalanceStrategy::LeastConnections` but `next_endpoint()` always
    round-robined regardless of strategy, so selecting `LeastConnections`
    silently behaved as RoundRobin. Replaced the selection API with an
    acquire/release model:
    - `LoadBalancer::new(endpoints, strategy)` now takes the strategy.
    - `acquire() -> EndpointLease` selects by strategy (RoundRobin cycles;
      LeastConnections picks the endpoint with the fewest in-flight tasks,
      ties to lowest index) and bumps a per-endpoint active counter.
    - `EndpointLease` is `Send+Sync`, derefs to `WorkerEndpoint`, and
      decrements the active count on drop — held for the task's lifetime on
      both the `wait=true` (per-attempt) and `wait=false` (moved into the
      spawned task) paths in `execute_task`.
    - Removed the now-unused `next_endpoint()`; updated all call sites.
    - Multi-endpoint connection-failure failover remains RoundRobin-gated;
      LeastConnections failover/circuit-breaking deferred to M9.
    - Tests added: `least_connections_picks_least_loaded`,
      `lease_release_on_drop`, `strategies_diverge`, `endpoint_lease_is_send_sync`.
    - See `docs/proposals/SESSION-AUDIT-MT-DARKIRC-EWE-2026-06-23.md` (H3).

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

## Wave 4 — COMPLETE

- [x] **Task 9**: Update codex worker for extended context
  - `TaskContext` interface added to `scripts/lunarwing_runtime.ts`
  - `codex_task_executor.ts` uses `context.project_dir` for working dir, injects `context.environment` into subprocess env
  - `agent_comm_protocol.json` updated with extended context fields
  - Backward compatible: empty/missing context fields default gracefully

- [x] **Task 10**: Update nanocode worker for extended context
  - `TaskContext` interface added to `scripts/lunarwing_runtime.ts`
  - `nanocode_task_executor.ts` uses `context.project_dir` for working dir, injects `context.environment` into `process.env`
  - `agent_comm_protocol.json` updated with extended context fields
  - Backward compatible: empty/missing context fields default gracefully

- [x] **Task 11**: Update pebble worker for extended context
  - `TaskContext` + `ConversationMessage` structs added to `src/protocol.rs` with `#[serde(default)]`
  - `TaskRequest.context` changed from `serde_json::Value` to typed `TaskContext`
  - `executor.rs` uses `context.project_dir` for working dir, injects `context.environment` into subprocess env
  - Tests passing: `task_request_extended_context`, `task_request_empty_context_backward_compat` (+ 6 existing)
  - Backward compatible: empty `{}` context deserializes to defaults

## Final Review — COMPLETE

> Last updated: 2026-06-23. All waves complete, final review passed against live `mars` tenant.

- [x] **F1**: Plan compliance audit — all 11 tasks verified complete, code matches plan deliverables
- [x] **F2**: Code quality review — `cargo check` clean, 18/18 external_worker tests pass, 0 new clippy warnings on changed files
- [x] **F3**: Real manual QA — live `mars` tenant on Gentoo/OpenRC with all 3 worker types (nanocode:10007, pebble:10008, codex:10010), gateway HTTP 200, daemon log confirms "External workers configured: codex, pebble, nanocode"
- [x] **F4**: Scope fidelity check — changes scoped to `external_worker.rs`, `job.rs`, `catalog.rs` (clippy), test fixtures, codex Dockerfile; no Docker sandbox, ACP bridge, or other guardrailed paths touched

## Files Modified

| Wave | Files |
|------|-------|
| 1 | `ic/src/orchestrator/external_worker.rs`, `ic/src/tools/builtin/job.rs`, `ic/src/config/sandbox.rs`, `ic/src/config/mod.rs`, `ic/src/settings.rs` |
| 2+7 | `ic/src/orchestrator/external_worker.rs`, `ic/src/tools/builtin/job.rs` |
| 3 | `ic/src/tools/builtin/job.rs` |
| 4 | `codex4lunarwing/scripts/lunarwing_runtime.ts`, `codex4lunarwing/scripts/codex_task_executor.ts`, `codex4lunarwing/agent_comm_protocol.json`, `lunarcode4lunarwing/scripts/lunarwing_runtime.ts`, `lunarcode4lunarwing/scripts/nanocode_task_executor.ts`, `lunarcode4lunarwing/agent_comm_protocol.json`, `pebble4lunarwing/src/protocol.rs`, `pebble4lunarwing/src/executor.rs` |

## Verification

```bash
cd ic
cargo fmt -- --check                                    # clean
cargo clippy --all --benches --tests --examples         # zero warnings
cargo test external_worker -- --nocapture                # 23 tests pass
cargo test create_job -- --nocapture                     # 6 tests pass

cd pebble4lunarwing
cargo test -- --nocapture                                # 8 tests pass
```
