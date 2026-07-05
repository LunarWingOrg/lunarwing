# External Worker System Upgrades

## TL;DR

### really rough

> **Quick Summary**: Extend the external worker protocol to pass real context/credentials, add WebSocket connection pooling for persistent workers, and support multi-instance load balancing.
>
> **Deliverables**:
> - Extended `task_request` payload with workspace context, conversation history, and credential injection
> - `WorkerConnectionPool` that reuses WebSocket connections across sequential tasks
> - Multi-instance `ExternalWorkerConfig` with round-robin load balancing
> - `ExternalTaskStatus` enum replacing stringly-typed status
> - Worker container updates (codex, nanocode, pebble) to accept extended context
>   *(Note: codex worker removed in v1.1.9; nanocode/pebble remain)*
>
> **Estimated Effort**: Large
> **Parallel Execution**: YES - 4 waves
> **Critical Path**: Task 1 → Task 5 → Task 7 → Task 8 → Task 9-11 → Final

---

## Context

### Original Request
User asked to find improvement opportunities for the external worker systems (nanocode, pebble, codex). After research and discussion, user selected three improvements: context passing, connection pooling, and multi-instance load balancing.

> **Note**: The Codex worker was removed in v1.1.9. References to it throughout this plan are retained for historical reference; the orchestrator-side improvements (Tasks 1–8) apply to all remaining workers.

### Interview Summary
**Key Discussions**:
- Focus areas: Protocol enhancements + Scalability (pooling/load-balancing)
- Depth: Top 3-5 high-impact fixes
- Boundary: Both orchestrator-side AND worker container repos can be touched

**Research Findings**:
- `ExternalWorkerManager` (`src/orchestrator/external_worker.rs`) manages WebSocket connections via the `lunarwing-agent-v1` protocol (legacy alias `ironclaw-agent-v1`)
- Each task opens a new WebSocket — no reuse despite "persistent" worker label
- `task_request` sends `"context": {}` — no workspace, conversation, or credential data
- `ExternalWorkerConfig` (name, url, auth_token, timeout_ms) — single endpoint per name
- `ExternalTaskResult.status` is `String` compared with `== "success"`
- Worker containers in `lunarcode4lunarwing/`, `pebble4lunarwing/` (codex4lunarwing/ removed in v1.1.9)
- `ContainerJobManager` supports `CredentialGrant` env injection; external workers do not

### Self-Review Gaps (addressed)
- **Backward compatibility**: All protocol additions use `#[serde(default)]` so older workers ignore new fields
- **Connection pool + cancellation**: Pooled connections must handle cancel envelopes and per-task reset
- **Multi-instance state**: Round-robin selection is fine — workers are stateless between tasks (context is passed per-request)
- **Security**: Credentials passed via encrypted WS + Bearer auth; same trust model as existing Docker credential grants
- **Status enum**: Added as Task 2 since it's a dependency for proper pool state tracking

---

## Work Objectives

### Core Objective
Transform external workers from stateless one-shot WebSocket callers into efficient persistent work delegation with real context and scalable routing.

### Concrete Deliverables
- Extended `lunarwing-agent-v1` protocol (backward compatible)
- `WorkerConnectionPool` struct with connection reuse
- Multi-instance `ExternalWorkerConfig` with load balancer
- `ExternalTaskStatus` enum
- Updated worker containers for all three worker types

### Definition of Done
- [ ] `cargo test` passes (all existing + new tests)
- [ ] `cargo clippy --all --benches --tests --examples -- -D warnings` clean
- [ ] `cargo fmt --all -- --check` clean
- [ ] External worker with extended context fields works against an unmodified worker (backward compat)
- [ ] Connection pool reuses connections for sequential tasks to same worker
- [ ] Multi-instance config routes tasks round-robin across endpoints
- [ ] All three worker containers updated to use extended context *(codex removed v1.1.9; applies to nanocode + pebble)*

### Must Have
- Backward compatibility: unmodified workers must still function with updated orchestrator
- Credential injection for external workers (parity with Docker sandbox)
- Connection pool with automatic cleanup on disconnect
- Round-robin load balancing across worker instances
- Typed status enum

### Must NOT Have (Guardrails)
- No breaking changes to the wire protocol (all new fields must be optional with serde defaults)
- No changes to Docker sandbox/ContainerJobManager code paths
- No changes to the ACP bridge pathway (`src/worker/acp_bridge.rs`)
- No removal of existing config format (`[[sandbox.external_workers]]` with single `url` must still work)
- No new external dependencies (use existing `tokio_tungstenite`, `serde`, etc.)
- No AI slop: no excessive comments, no over-abstraction, no generic names
- No scope creep into health checking, retry logic, or reaper coverage (separate future work)

---

## Verification Strategy

> **ZERO HUMAN INTERVENTION** - ALL verification is agent-executed. No exceptions.

### Test Decision
- **Infrastructure exists**: YES
- **Automated tests**: YES (Tests-after — add tests alongside implementation)
- **Framework**: Rust `cargo test` (unit + integration)

### QA Policy
Every task MUST include agent-executed QA scenarios.
Evidence saved to `.sisyphus/evidence/task-{N}-{scenario-slug}.{ext}`.

- **Library/Module**: Use Bash (cargo test) - Run specific test, verify pass
- **Protocol**: Use Bash (cargo test) - Verify serialization/deserialization roundtrips
- **Integration**: Use Bash (cargo test) - Verify end-to-end behavior

---

## Execution Strategy

### Parallel Execution Waves

```
Wave 1 (Start Immediately - foundation types + config):
├── Task 1: Extend TaskRequest payload with context struct [quick]
├── Task 2: Add ExternalTaskStatus enum [quick]
└── Task 3: Multi-instance ExternalWorkerConfig schema [quick]

Wave 2 (After Wave 1 - core implementations, MAX PARALLEL):
├── Task 4: WorkerConnectionPool implementation (depends: 2) [deep]
├── Task 5: Context serialization + credential injection (depends: 1) [unspecified-high]
└── Task 6: Round-robin load balancer (depends: 3) [quick]

Wave 3 (After Wave 2 - integration):
├── Task 7: Wire pool + LB into ExternalWorkerManager (depends: 4, 5, 6) [deep]
└── Task 8: Update CreateJobTool to pass project_dir + context (depends: 5, 7) [unspecified-high]

Wave 4 (After Wave 3 - worker container updates, MAX PARALLEL):
├── Task 9: ~~Update codex worker for extended context~~ (depends: 7) [unspecified-high] — N/A, removed v1.1.9
├── Task 10: Update nanocode worker for extended context (depends: 7) [unspecified-high]
└── Task 11: Update pebble worker for extended context (depends: 7) [unspecified-high]

Wave FINAL (After ALL tasks — 4 parallel reviews):
├── Task F1: Plan compliance audit (oracle)
├── Task F2: Code quality review (unspecified-high)
├── Task F3: Real manual QA (unspecified-high)
└── Task F4: Scope fidelity check (deep)
-> Present results -> Get explicit user okay

Critical Path: Task 1 → Task 5 → Task 7 → Task 8 → Task 9-11 → F1-F4 → user okay
Parallel Speedup: ~65% faster than sequential
Max Concurrent: 3 (Waves 1, 2, 4)
```

### Dependency Matrix

| Task | Depends On | Blocks |
|------|-----------|--------|
| 1 | - | 5 |
| 2 | - | 4 |
| 3 | - | 6 |
| 4 | 2 | 7 |
| 5 | 1 | 7, 8 |
| 6 | 3 | 7 |
| 7 | 4, 5, 6 | 8, 9, 10, 11 |
| 8 | 5, 7 | - |
| 9 | 7 | - |
| 10 | 7 | - |
| 11 | 7 | - |

### Agent Dispatch Summary

- **Wave 1**: 3 tasks — T1 → `quick`, T2 → `quick`, T3 → `quick`
- **Wave 2**: 3 tasks — T4 → `deep`, T5 → `unspecified-high`, T6 → `quick`
- **Wave 3**: 2 tasks — T7 → `deep`, T8 → `unspecified-high`
- **Wave 4**: 3 tasks — T9 → `unspecified-high`, T10 → `unspecified-high`, T11 → `unspecified-high`
- **FINAL**: 4 tasks — F1 → `oracle`, F2 → `unspecified-high`, F3 → `unspecified-high`, F4 → `deep`

---

## TODOs

- [x] 1. Extend `TaskRequest` payload with context struct

  **What to do**:
  - Add `TaskContext` struct to `external_worker.rs` containing:
    - `project_dir: Option<String>` — workspace path
    - `conversation_history: Vec<ConversationMessage>` — recent messages
    - `environment: HashMap<String, String>` — env vars to inject
    - `user_id: String`
    - `metadata: HashMap<String, String>` — arbitrary key-value
  - Add `ConversationMessage` struct: `role: String`, `content: String`
  - All fields get `#[serde(default)]` for backward compatibility — old workers who ignore the fields still work
  - Add `#[derive(Debug, Serialize, Deserialize)]` and `#[serde(deny_unknown_fields)]` on TaskContext but NOT on ConversationMessage (allow unknown)
  - Update `task_request` serialization in `run_external_task()` to use `TaskContext` instead of `{}`
  - Keep `context: {}` as fallback when no context is provided
  - Add unit tests: roundtrip serialization, empty context works, full context serializes correctly, deserialization with missing fields succeeds

  **Must NOT do**:
  - Do NOT change the envelope format (id, type, timestamp, payload remain)
  - Do NOT make any context fields required
  - Do NOT touch ACP bridge or Docker sandbox paths

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: Protocol type definitions with clear structure, well-bounded changes
  - **Skills**: []
  - **Skills Evaluated but Omitted**:
    - `customize-opencode`: Not configuring opencode toolchain

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 1 (with Tasks 2, 3)
  - **Blocks**: Task 5
  - **Blocked By**: None (can start immediately)

  **References**:
  - `ic/src/orchestrator/external_worker.rs:24-42` — Existing `Envelope` and protocol types to extend
  - `ic/src/orchestrator/external_worker.rs:403-412` — Current `task_request` serialization with `"context": {}`
  - `ic/src/orchestrator/auth.rs` — Existing `CredentialGrant` for reference on credential model
  - `ic/src/config/sandbox.rs:187-193` — `ExternalWorkerConfig` for context on timeout/worker config

  **Acceptance Criteria**:
  - [ ] `TaskContext` and `ConversationMessage` structs exist with `#[serde(default)]`
  - [ ] `cargo test -- task_context` passes (roundtrip tests)
  - [ ] Old config.toml with single `url` still parses correctly
  - [ ] Serialized JSON without `context` field deserializes to `TaskContext` defaults

  **QA Scenarios (MANDATORY)**:

  ```
  Scenario: Full context roundtrip serialization
    Tool: Bash (cargo test)
    Preconditions: Code compiles
    Steps:
      1. Run: cargo test task_context_full_roundtrip -- --nocapture
      2. Assert: Test serializes TaskContext with all fields → deserializes → fields match
    Expected Result: All fields preserved through serde roundtrip
    Failure Indicators: Any field missing or mangled after deserialize
    Evidence: .sisyphus/evidence/task-1-full-context-roundtrip.txt

  Scenario: Backward compatibility — missing context field
    Tool: Bash (cargo test)
    Preconditions: Code compiles
    Steps:
      1. Run: cargo test task_context_backward_compat -- --nocapture
      2. Assert: JSON with omitted `context` → deserializes with all defaults (empty vecs, None strings)
    Expected Result: TaskContext::default() produced from legacy payload
    Failure Indicators: Deserialize fails or non-default values appear
    Evidence: .sisyphus/evidence/task-1-backward-compat.txt
  ```

  **Evidence to Capture**:
  - [ ] Each evidence file named: task-1-scenario-slug}.txt

  **Commit**: YES (groups with 2, 3)
  - Message: `feat(orchestrator): extend external worker protocol types`
  - Files: `src/orchestrator/external_worker.rs`
  - Pre-commit: `cargo test -- external_worker`

- [x] 2. Add `ExternalTaskStatus` enum

  **What to do**:
  - Add `ExternalTaskStatus` enum in `external_worker.rs`:
    - Variants: `Success`, `Failed`, `Cancelled`, `TimedOut`, `Partial(String)`
  - Implement `Serialize`/`Deserialize` with `serde` (lowercase variant names)
  - Change `ExternalTaskResult.status` from `String` to `ExternalTaskStatus`
  - Update all match arms comparing `== "success"` to use enum matching
  - Update `run_external_task()` status comparisons
  - Update `execute_external()` in `src/tools/builtin/job.rs` status comparisons
  - Add `impl Display` for `ExternalTaskStatus`
  - Add unit tests: each variant serializes/deserializes, enum matching works

  **Must NOT do**:
  - Do NOT change the wire format (variants serialize to lowercase strings matching current values)
  - Do NOT add new status variant values that existing workers wouldn't send

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: Simple enum refactor, well-bounded, clear before/after
  - **Skills**: []
  - **Skills Evaluated but Omitted**:
    - `customize-opencode`: Not configuring opencode toolchain

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 1 (with Tasks 1, 3)
  - **Blocks**: Task 4
  - **Blocked By**: None (can start immediately)

  **References**:
  - `ic/src/orchestrator/external_worker.rs:260-267` — `ExternalTaskResult` struct
  - `ic/src/orchestrator/external_worker.rs:496-517` — `task_result` match arm using `result.status`
  - `ic/src/tools/builtin/job.rs:756` — `result.status == "success"` comparison to update
  - `ic/src/orchestrator/external_worker.rs:547-554` — Timeout handling that could use `TimedOut` variant
  - `ic/src/orchestrator/external_worker.rs:534-539` — Cancel handling that could use `Cancelled` variant

  **Acceptance Criteria**:
  - [ ] `ExternalTaskStatus` enum exists with `Serialize`/`Deserialize`/`Display`
  - [ ] `ExternalTaskResult.status` is typed
  - [ ] All `== "success"` string comparisons replaced with enum matching
  - [ ] `cargo test -- external_worker` passes
  - [ ] `cargo test -- create_job` passes (job.rs tests)

  **QA Scenarios (MANDATORY)**:

  ```
  Scenario: Enum serialization matches wire format
    Tool: Bash (cargo test)
    Preconditions: Code compiles
    Steps:
      1. Run: cargo test task_status_enum_serde -- --nocapture
      2. Assert: ExternalTaskStatus::Success → "success", Failed → "failed", Cancelled → "cancelled"
    Expected Result: Serde produces same strings as current String-based approach
    Failure Indicators: Serialized value differs from expected wire format
    Evidence: .sisyphus/evidence/task-2-status-enum-serde.txt

  Scenario: Status matching logic preserved
    Tool: Bash (cargo test)
    Preconditions: Code compiles
    Steps:
      1. Run: cargo test task_status_enum_matching -- --nocapture
      2. Assert: Success variant → JobState::Completed, Failed variant → JobState::Failed
    Expected Result: Same behavior as before but using enum matching
    Failure Indicators: Wrong JobState transition for any variant
    Evidence: .sisyphus/evidence/task-2-status-enum-matching.txt
  ```

  **Evidence to Capture**:
  - [ ] Each evidence file named: task-2-scenario-slug}.txt

  **Commit**: YES (groups with 1, 3)
  - Message: `feat(orchestrator): extend external worker protocol types`
  - Files: `src/orchestrator/external_worker.rs`, `src/tools/builtin/job.rs`

- [x] 3. Multi-instance `ExternalWorkerConfig` schema

  **What to do**:
  - Add `endpoints: Vec<WorkerEndpoint>` field to `ExternalWorkerConfig` with `#[serde(default)]`
  - Add `WorkerEndpoint` struct: `url: String`, `auth_token: Option<String>`, `weight: Option<u32>`
  - When `endpoints` is non-empty: use those; when empty: fall back to legacy single `url`/`auth_token`
  - Add `load_balance: LoadBalanceStrategy` with variants: `RoundRobin`, `LeastConnections`
  - Add `impl Default` for `LoadBalanceStrategy` → `RoundRobin`
  - Update `ExternalWorkerConfig::resolve_from_settings()` to parse `endpoints` from TOML
  - Add `ExternalWorkerConfig::endpoints()` helper returning canonical endpoint list (fallback or multi)
  - Add `#[serde(default)]` on `load_balance` field
  - Add unit tests: single-endpoint fallback works, multi-endpoint parsing, round-robin default, toml deserialization

  **Must NOT do**:
  - Do NOT remove backward compatibility with single `url` field
  - Do NOT change `[[sandbox.external_workers]]` TOML format when `endpoints` is absent

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: Config schema additions, well-defined structure, no new runtime logic
  - **Skills**: []
  - **Skills Evaluated but Omitted**:
    - `customize-opencode`: Not configuring opencode toolchain

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 1 (with Tasks 1, 2)
  - **Blocks**: Task 6
  - **Blocked By**: None (can start immediately)

  **References**:
  - `ic/src/config/sandbox.rs:187-193` — Current `ExternalWorkerConfig` struct
  - `ic/src/config/sandbox.rs:196-209` — `resolve_from_settings()` method
  - `ic/src/config/sandbox.rs:505-567` — Tests showing TOML multi-worker parsing
  - `ic/src/orchestrator/external_worker.rs:92-98` — `ExternalWorkerManager` fields, where config is consumed

  **Acceptance Criteria**:
  - [ ] `WorkerEndpoint` struct exists with `url`, `auth_token`, `weight` fields
  - [ ] `ExternalWorkerConfig.endpoints` is `#[serde(default)]` (empty = legacy fallback)
  - [ ] `LoadBalanceStrategy` enum exists with `RoundRobin` default
  - [ ] `cargo test -- external_worker_config` passes (all existing + new multi-instance tests)
  - [ ] Config with only `url` still parses to single `WorkerEndpoint`

  **QA Scenarios (MANDATORY)**:

  ```
  Scenario: Multi-endpoint config parses from TOML
    Tool: Bash (cargo test)
    Preconditions: Code compiles
    Steps:
      1. Run: cargo test external_worker_config_multi_endpoint -- --nocapture
      2. Assert: TOML with [[sandbox.external_workers.endpoints]] → two WorkerEndpoints parsed
    Expected Result: Both endpoints present with correct urls and tokens
    Failure Indicators: Endpoints missing, wrong count, wrong values
    Evidence: .sisyphus/evidence/task-3-multi-endpoint-parse.txt

  Scenario: Legacy single-url config still works
    Tool: Bash (cargo test)
    Preconditions: Code compiles
    Steps:
      1. Run: cargo test external_worker_config_legacy_fallback -- --nocapture
      2. Assert: Config with only `url` and `auth_token` (no `endpoints`) → endpoints() returns single endpoint
    Expected Result: Backward compatible — same behavior as before
    Failure Indicators: Legacy config fails to parse or produces empty endpoints
    Evidence: .sisyphus/evidence/task-3-legacy-fallback.txt
  ```

  **Evidence to Capture**:
  - [ ] Each evidence file named: task-3-scenario-slug}.txt

  **Commit**: YES (groups with 1, 2)
  - Message: `feat(orchestrator): extend external worker protocol types`
  - Files: `src/config/sandbox.rs`

- [x] 4. `WorkerConnectionPool` implementation

  **What to do**:
  - Add `WorkerConnection` struct wrapping `(WriteHalf, ReadHalf)` from `tokio_tungstenite`
  - Add `WorkerConnectionPool` struct with:
    - `connections: RwLock<HashMap<String, PooledConnection>>` keyed by `"{worker_name}:{endpoint_url}"`
    - `PooledConnection` containing: `ws_stream`, `ready_worker_id: String`, `last_used: Instant`, `in_use: bool`
  - Implement `acquire(worker_name, url, auth_token)` → returns `PooledConnection` or creates new one
    - If idle connection exists for key: return it (reset per-task state)
    - If no idle connection: open new WebSocket, wait for `ready`, store in pool
  - Implement `release(connection)` → marks `in_use: false`, updates `last_used`
  - Implement `evict_stale(max_idle: Duration)` → removes connections idle longer than threshold
  - Implement `drain()` → closes all connections (for shutdown)
  - Add `PoolConfig` with `max_idle_connections: usize` (default 5), `idle_timeout: Duration` (default 5 min)
  - Add unit tests: acquire/release cycle, stale eviction, drain, acquire after release reuses connection

  **Must NOT do**:
  - Do NOT change the wire protocol (ready/task_request/task_result remain same)
  - Do NOT share connections across concurrent tasks (one task = one connection at a time)
  - Do NOT add retry logic (out of scope — separate future work)

  **Recommended Agent Profile**:
  - **Category**: `deep`
    - Reason: Complex async state management, WebSocket lifecycle, concurrent access patterns
  - **Skills**: []
  - **Skills Evaluated but Omitted**:
    - `customize-opencode`: Not configuring opencode toolchain

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 2 (with Tasks 5, 6)
  - **Blocks**: Task 7
  - **Blocked By**: Task 2 (needs `ExternalTaskStatus` for pool state tracking)

  **References**:
  - `ic/src/orchestrator/external_worker.rs:272-337` — Current `run_external_task()` WebSocket connect logic to extract into pool
  - `ic/src/orchestrator/external_worker.rs:339-391` — Current `ready` message handshake to reuse in pool
  - `ic/src/orchestrator/external_worker.rs:436-543` — Current message loop to adapt for pooled connections
  - `ic/src/orchestrator/external_worker.rs:92-98` — `ExternalWorkerManager` struct where pool will be injected
  - `ic/src/orchestrator/auth.rs` — `TokenStore` pattern for in-memory connection tracking reference

  **Acceptance Criteria**:
  - [ ] `WorkerConnectionPool` struct exists with `acquire`/`release`/`evict_stale`/`drain`
  - [ ] `PooledConnection` wraps WebSocket stream with metadata
  - [ ] Sequential tasks to same worker reuse the same connection
  - [ ] `cargo test -- worker_pool` passes
  - [ ] No `unwrap()`/`expect()` in production code paths

  **QA Scenarios (MANDATORY)**:

  ```
  Scenario: Connection reuse across sequential tasks
    Tool: Bash (cargo test)
    Preconditions: Code compiles
    Steps:
      1. Run: cargo test worker_pool_connection_reuse -- --nocapture
      2. Assert: acquire → release → acquire returns same underlying connection (by pointer/id)
    Expected Result: Second acquire reuses first connection (no new WebSocket created)
    Failure Indicators: New connection created each time
    Evidence: .sisyphus/evidence/task-4-pool-reuse.txt

  Scenario: Stale connection eviction
    Tool: Bash (cargo test)
    Preconditions: Code compiles
    Steps:
      1. Run: cargo test worker_pool_stale_eviction -- --nocapture
      2. Assert: Connection idle beyond threshold is removed by evict_stale()
    Expected Result: Pool size decreases after eviction
    Failure Indicators: Stale connections remain in pool
    Evidence: .sisyphus/evidence/task-4-stale-eviction.txt

  Scenario: Drain closes all connections
    Tool: Bash (cargo test)
    Preconditions: Code compiles
    Steps:
      1. Run: cargo test worker_pool_drain -- --nocapture
      2. Assert: After drain(), pool is empty and all connections closed
    Expected Result: Pool size = 0 after drain
    Failure Indicators: Connections remain after drain
    Evidence: .sisyphus/evidence/task-4-drain.txt
  ```

  **Evidence to Capture**:
  - [ ] Each evidence file named: task-4-{scenario-slug}.txt

  **Commit**: YES (groups with 5, 6)
  - Message: `feat(orchestrator): add connection pool and load balancer`
  - Files: `src/orchestrator/external_worker.rs` (new pool module or inline)

- [x] 5. Context serialization + credential injection

  **What to do**:
  - Add `build_task_context()` function in `external_worker.rs` that constructs `TaskContext` from:
    - `ContextManager` job context (user_id, metadata, conversation history)
    - `project_dir: Option<PathBuf>` (workspace path)
    - `credential_grants: Vec<CredentialGrant>` resolved to env vars via `SecretsStore`
  - Add `resolve_credentials()` helper that takes `Vec<CredentialGrant>` + `SecretsStore` → `HashMap<String, String>`
    - For each grant: look up secret value, map to env var name
    - Return empty map if no secrets store configured
  - Update `run_external_task()` signature to accept `TaskContext` instead of raw `task: &str`
  - Serialize `TaskContext` into the `task_request` payload's `context` field
  - Add unit tests: context building with all fields, credential resolution, empty credentials

  **Must NOT do**:
  - Do NOT log secret values (use `tracing::debug!` with redacted values only)
  - Do NOT change the `CredentialGrant` struct itself
  - Do NOT touch Docker sandbox credential injection path

  **Recommended Agent Profile**:
  - **Category**: `unspecified-high`
    - Reason: Cross-cutting concern touching ContextManager, SecretsStore, and external worker protocol
  - **Skills**: []
  - **Skills Evaluated but Omitted**:
    - `customize-opencode`: Not configuring opencode toolchain

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 2 (with Tasks 4, 6)
  - **Blocks**: Task 7, Task 8
  - **Blocked By**: Task 1 (needs `TaskContext` struct)

  **References**:
  - `ic/src/orchestrator/external_worker.rs:272-283` — `run_external_task()` signature to extend
  - `ic/src/orchestrator/external_worker.rs:403-412` — Current `task_request` with `"context": {}` to replace
  - `ic/src/orchestrator/auth.rs` — `CredentialGrant` struct definition
  - `ic/src/context.rs` — `ContextManager`, `JobContext` for extracting conversation history
  - `ic/src/secrets/mod.rs` — `SecretsStore` trait for resolving secret values
  - `ic/src/tools/builtin/job.rs:204-267` — Existing `parse_credentials()` pattern to follow for credential resolution

  **Acceptance Criteria**:
  - [ ] `build_task_context()` constructs `TaskContext` from ContextManager + credentials
  - [ ] `resolve_credentials()` returns `HashMap<String, String>` from `SecretsStore`
  - [ ] `task_request` payload includes populated `context` field
  - [ ] `cargo test -- task_context` passes (context building tests)
  - [ ] No secret values in log output

  **QA Scenarios (MANDATORY)**:

  ```
  Scenario: Context built with all fields populated
    Tool: Bash (cargo test)
    Preconditions: Code compiles
    Steps:
      1. Run: cargo test build_task_context_full -- --nocapture
      2. Assert: TaskContext has user_id, project_dir, conversation_history, environment populated
    Expected Result: All fields present and correctly typed
    Failure Indicators: Any field empty or wrong type
    Evidence: .sisyphus/evidence/task-5-context-full.txt

  Scenario: Credential resolution with no secrets store
    Tool: Bash (cargo test)
    Preconditions: Code compiles
    Steps:
      1. Run: cargo test resolve_credentials_no_store -- --nocapture
      2. Assert: Returns empty HashMap, no panic
    Expected Result: Graceful empty result
    Failure Indicators: Panic or error when no store
    Evidence: .sisyphus/evidence/task-5-no-credentials.txt

  Scenario: Credential resolution with secrets store
    Tool: Bash (cargo test)
    Preconditions: Code compiles, mock secrets store available
    Steps:
      1. Run: cargo test resolve_credentials_with_store -- --nocapture
      2. Assert: CredentialGrant { secret_name: "github_token", env_var: "GITHUB_TOKEN" } → HashMap contains "GITHUB_TOKEN" → resolved value
    Expected Result: Secret value resolved and mapped to env var
    Failure Indicators: Missing key or wrong value in HashMap
    Evidence: .sisyphus/evidence/task-5-credentials-resolved.txt
  ```

  **Evidence to Capture**:
  - [ ] Each evidence file named: task-5-{scenario-slug}.txt

  **Commit**: YES (groups with 4, 6)
  - Message: `feat(orchestrator): add connection pool and load balancer`
  - Files: `src/orchestrator/external_worker.rs`

- [x] 6. Round-robin load balancer

  **What to do**:
  - Add `LoadBalancer` struct with:
    - `endpoints: Vec<WorkerEndpoint>` (from Task 3)
    - `current_index: AtomicUsize` for round-robin counter
    - `active_connections: Vec<AtomicUsize>` per-endpoint for least-connections tracking
  - Implement `next_endpoint(&self, strategy: &LoadBalanceStrategy) -> &WorkerEndpoint`
    - `RoundRobin`: `current_index.fetch_add(1, Ordering::Relaxed) % endpoints.len()`
    - `LeastConnections`: find endpoint with minimum `active_connections`
  - Implement `increment_active(index)` / `decrement_active(index)` for tracking
  - Add `impl Default` → `RoundRobin`
  - Add unit tests: round-robin cycles correctly, least-connections picks minimum, single endpoint always returns same

  **Must NOT do**:
  - Do NOT add health-aware routing (out of scope)
  - Do NOT add weighted routing beyond the `weight` field existing on `WorkerEndpoint`

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: Simple algorithmic implementation, well-defined behavior
  - **Skills**: []
  - **Skills Evaluated but Omitted**:
    - `customize-opencode`: Not configuring opencode toolchain

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 2 (with Tasks 4, 5)
  - **Blocks**: Task 7
  - **Blocked By**: Task 3 (needs `WorkerEndpoint` and `LoadBalanceStrategy`)

  **References**:
  - `ic/src/config/sandbox.rs:187-193` — `ExternalWorkerConfig` with new `endpoints` field (from Task 3)
  - `ic/src/orchestrator/external_worker.rs:153-168` — `execute_task()` where worker is selected by name — will use LB here
  - `ic/src/orchestrator/external_worker.rs:100-119` — `ExternalWorkerManager::new()` where LB will be initialized

  **Acceptance Criteria**:
  - [ ] `LoadBalancer` struct with `next_endpoint()` works for both strategies
  - [ ] Round-robin cycles through all endpoints evenly
  - [ ] Least-connections picks endpoint with fewest active
  - [ ] Single-endpoint config always returns that endpoint
  - [ ] `cargo test -- load_balancer` passes

  **QA Scenarios (MANDATORY)**:

  ```
  Scenario: Round-robin distributes evenly
    Tool: Bash (cargo test)
    Preconditions: Code compiles
    Steps:
      1. Run: cargo test load_balancer_round_robin -- --nocapture
      2. Assert: 3 endpoints, 6 calls → each endpoint selected exactly twice
    Expected Result: Even distribution across endpoints
    Failure Indicators: Uneven distribution or out-of-bounds index
    Evidence: .sisyphus/evidence/task-6-round-robin.txt

  Scenario: Least-connections picks minimum
    Tool: Bash (cargo test)
    Preconditions: Code compiles
    Steps:
      1. Run: cargo test load_balancer_least_connections -- --nocapture
      2. Assert: With counts [3, 1, 5], next_endpoint returns index 1
    Expected Result: Endpoint with count=1 selected
    Failure Indicators: Wrong endpoint selected
    Evidence: .sisyphus/evidence/task-6-least-connections.txt

  Scenario: Single endpoint always returns same
    Tool: Bash (cargo test)
    Preconditions: Code compiles
    Steps:
      1. Run: cargo test load_balancer_single_endpoint -- --nocapture
      2. Assert: 10 calls with 1 endpoint → all return index 0
    Expected Result: Always returns the single endpoint
    Failure Indicators: Index out of bounds or different endpoint
    Evidence: .sisyphus/evidence/task-6-single-endpoint.txt
  ```

  **Evidence to Capture**:
  - [ ] Each evidence file named: task-6-{scenario-slug}.txt

  **Commit**: YES (groups with 4, 5)
  - Message: `feat(orchestrator): add connection pool and load balancer`
  - Files: `src/orchestrator/external_worker.rs`

- [x] 7. Wire pool + LB into `ExternalWorkerManager`

  **What to do**:
  - Add `connection_pool: Option<WorkerConnectionPool>` field to `ExternalWorkerManager`
  - Add `load_balancers: HashMap<String, LoadBalancer>` field keyed by worker name
  - Update `ExternalWorkerManager::new()` to initialize pool and LBs from configs
  - Refactor `execute_task()` to:
    1. Use `LoadBalancer::next_endpoint()` to select endpoint (instead of single `config.url`)
    2. Use `connection_pool.acquire()` to get/reuse a connection (instead of opening new WS)
    3. Send `task_request` with `TaskContext` (from Task 5) over pooled connection
    4. On completion: `connection_pool.release()` the connection
    5. On error/timeout: evict the connection from pool (don't reuse poisoned connections)
  - Update `with_event_deps()` and `with_store()` to also initialize pool if not already set
  - Update `cancel_task()` to work with pooled connections (send cancel envelope, then release)
  - Add background task: `evict_stale()` called periodically (use `tokio::spawn` + `interval`)
  - Add `drain()` method on manager for graceful shutdown
  - Add integration tests: full task lifecycle with pool, LB routing across two mock endpoints

  **Must NOT do**:
  - Do NOT remove the `active_handles` HashMap (still needed for cancel tracking)
  - Do NOT change the public API signatures of `execute_task()` (callers in job.rs should not need changes yet)
  - Do NOT add health checking (out of scope)

  **Recommended Agent Profile**:
  - **Category**: `deep`
    - Reason: Core integration task — touches the main execution path, must coordinate pool/LB/context correctly
  - **Skills**: []
  - **Skills Evaluated but Omitted**:
    - `customize-opencode`: Not configuring opencode toolchain

  **Parallelization**:
  - **Can Run In Parallel**: NO
  - **Parallel Group**: Wave 3 (with Task 8, but 8 depends on 7)
  - **Blocks**: Task 8, Tasks 9, 10, 11
  - **Blocked By**: Tasks 4, 5, 6

  **References**:
  - `ic/src/orchestrator/external_worker.rs:92-258` — Full `ExternalWorkerManager` struct and methods to modify
  - `ic/src/orchestrator/external_worker.rs:153-245` — `execute_task()` method to refactor with pool + LB
  - `ic/src/orchestrator/external_worker.rs:272-612` — `run_external_task()` to adapt for pooled connections
  - `ic/src/orchestrator/mod.rs:161-173` — `setup_orchestrator()` where manager is created and wired
  - `ic/src/tools/builtin/job.rs:697-851` — `execute_external()` caller of `execute_task()` — verify no signature change needed

  **Acceptance Criteria**:
  - [ ] `ExternalWorkerManager` has `connection_pool` and `load_balancers` fields
  - [ ] `execute_task()` uses pool for connection acquire/release
  - [ ] `execute_task()` uses LB for endpoint selection when multi-instance configured
  - [ ] Stale eviction background task runs periodically
  - [ ] `drain()` method exists and closes all pooled connections
  - [ ] `cancel_task()` works with pooled connections
  - [ ] `cargo test -- external_worker_manager` passes
  - [ ] `cargo test -- execute_task` passes
  - [ ] Existing `execute_external()` in job.rs compiles without changes

  **QA Scenarios (MANDATORY)**:

  ```
  Scenario: Full task lifecycle with pooled connection
    Tool: Bash (cargo test)
    Preconditions: Tasks 1-6 complete, code compiles
    Steps:
      1. Run: cargo test manager_pooled_task_lifecycle -- --nocapture
      2. Assert: Task dispatched, progress streamed, result returned, connection released to pool
    Expected Result: Task completes and connection is reusable
    Failure Indicators: Connection not released, task fails, or pool state corrupted
    Evidence: .sisyphus/evidence/task-7-pooled-lifecycle.txt

  Scenario: LB routes to second endpoint on second task
    Tool: Bash (cargo test)
    Preconditions: Multi-endpoint config with 2 endpoints
    Steps:
      1. Run: cargo test manager_lb_routes_round_robin -- --nocapture
      2. Assert: First task → endpoint[0], second task → endpoint[1], third task → endpoint[0]
    Expected Result: Round-robin distribution across endpoints
    Failure Indicators: All tasks go to same endpoint
    Evidence: .sisyphus/evidence/task-7-lb-routing.txt

  Scenario: Poisoned connection evicted on error
    Tool: Bash (cargo test)
    Preconditions: Code compiles
    Steps:
      1. Run: cargo test manager_evict_poisoned -- --nocapture
      2. Assert: Task fails → connection removed from pool (not reused)
    Expected Result: Failed connection not reused for next task
    Failure Indicators: Poisoned connection returned on next acquire
    Evidence: .sisyphus/evidence/task-7-evict-poisoned.txt
  ```

  **Evidence to Capture**:
  - [ ] Each evidence file named: task-7-{scenario-slug}.txt

  **Commit**: YES (groups with 8)
  - Message: `feat(orchestrator): wire pool + context into worker manager`
  - Files: `src/orchestrator/external_worker.rs`, `src/orchestrator/mod.rs`

- [x] 8. Update `CreateJobTool` to pass project_dir + context

  **What to do**:
  - Update `execute_external()` in `src/tools/builtin/job.rs` to:
    - Accept `project_dir: Option<PathBuf>` parameter (resolve via `resolve_project_dir()`)
    - Accept `credentials` parameter (parse via existing `parse_credentials()`)
    - Build `TaskContext` via `build_task_context()` (from Task 5)
    - Pass `TaskContext` to `ewm.execute_task()` (may require extending `execute_task` signature or adding a new method)
  - Update `CreateJobTool::parameters_schema()` to include `project_dir` and `credentials` for external worker mode
  - Update the `execute()` method routing: when `mode != "worker"` and external workers available, pass project_dir + credentials
  - Update `ExternalWorkerManager::execute_task()` signature to accept `TaskContext` (or add `execute_task_with_context()`)
  - Add tests: external job with project_dir, external job with credentials, external job without either

  **Must NOT do**:
  - Do NOT change Docker sandbox execution path (`execute_sandbox()`)
  - Do NOT change local execution path (`execute_local()`)
  - Do NOT remove existing `execute_external()` behavior for tasks without context (backward compat)

  **Recommended Agent Profile**:
  - **Category**: `unspecified-high`
    - Reason: Touches the LLM-facing tool API, must carefully extend without breaking existing schema
  - **Skills**: []
  - **Skills Evaluated but Omitted**:
    - `customize-opencode`: Not configuring opencode toolchain

  **Parallelization**:
  - **Can Run In Parallel**: NO (depends on Task 7)
  - **Parallel Group**: Wave 3 (after Task 7)
  - **Blocks**: None (final orchestrator-side task)
  - **Blocked By**: Tasks 5, 7

  **References**:
  - `ic/src/tools/builtin/job.rs:696-851` — `execute_external()` method to extend
  - `ic/src/tools/builtin/job.rs:1038-1110` — `parameters_schema()` to update with project_dir/credentials for external mode
  - `ic/src/tools/builtin/job.rs:1125-1186` — `execute()` routing logic to update
  - `ic/src/tools/builtin/job.rs:204-267` — Existing `parse_credentials()` to reuse
  - `ic/src/tools/builtin/job.rs:926-986` — Existing `resolve_project_dir()` to reuse
  - `ic/src/orchestrator/external_worker.rs:153-160` — `execute_task()` signature to extend

  **Acceptance Criteria**:
  - [ ] `execute_external()` accepts and passes `project_dir` and `credentials`
  - [ ] `parameters_schema()` includes `project_dir` and `credentials` when external workers available
  - [ ] External jobs without project_dir/credentials still work (backward compat)
  - [ ] `cargo test -- execute_external` passes
  - [ ] `cargo test -- create_job` passes

  **QA Scenarios (MANDATORY)**:

  ```
  Scenario: External job with project_dir
    Tool: Bash (cargo test)
    Preconditions: Tasks 1-7 complete
    Steps:
      1. Run: cargo test execute_external_with_project_dir -- --nocapture
      2. Assert: TaskContext sent to worker contains project_dir field
    Expected Result: Worker receives workspace path in context
    Failure Indicators: project_dir missing from serialized TaskContext
    Evidence: .sisyphus/evidence/task-8-external-project-dir.txt

  Scenario: External job with credentials
    Tool: Bash (cargo test)
    Preconditions: Tasks 1-7 complete, mock secrets store
    Steps:
      1. Run: cargo test execute_external_with_credentials -- --nocapture
      2. Assert: TaskContext.environment contains resolved credential env vars
    Expected Result: Credentials injected into context environment map
    Failure Indicators: Environment map empty or missing expected keys
    Evidence: .sisyphus/evidence/task-8-external-credentials.txt

  Scenario: External job without context (backward compat)
    Tool: Bash (cargo test)
    Preconditions: Tasks 1-7 complete
    Steps:
      1. Run: cargo test execute_external_no_context -- --nocapture
      2. Assert: TaskContext sent with default/empty values, task still succeeds
    Expected Result: Worker receives empty context, functions normally
    Failure Indicators: Task fails or context fields are non-default
    Evidence: .sisyphus/evidence/task-8-external-no-context.txt
  ```

  **Evidence to Capture**:
  - [ ] Each evidence file named: task-8-{scenario-slug}.txt

  **Commit**: YES (groups with 7)
  - Message: `feat(orchestrator): wire pool + context into worker manager`
  - Files: `src/tools/builtin/job.rs`, `src/orchestrator/external_worker.rs`

- [x] 9. ~~Update codex worker for extended context~~ — **N/A: Codex worker removed in v1.1.9**

  > **Note**: The Codex worker (`codex4lunarwing/`) was removed in v1.1.9. The following task
  > description is retained for historical reference. The orchestrator-side context passing
  > (Tasks 1–8) applies to all remaining workers (nanocode, pebble, opencode).

  **What to do**:
  - Update `codex4lunarwing/agent_comm_protocol.json` to document extended `context` fields:
    - `project_dir`, `conversation_history`, `environment`, `user_id`, `metadata`
  - Update `codex4lunarwing/entrypoint.sh` or Python handler to:
    - Parse `context.project_dir` and `cd` into it if provided
    - Parse `context.environment` and inject env vars before spawning codex
    - Parse `context.conversation_history` and prepend to prompt if provided
  - Ensure backward compatibility: if `context` is `{}` or missing, behave exactly as before
  - Add a test script that sends a task_request with populated context and verifies codex receives it

  **Must NOT do**:
  - Do NOT change the WebSocket connection logic or envelope format
  - Do NOT break existing task processing when context is empty

  **Recommended Agent Profile**:
  - **Category**: `unspecified-high`
    - Reason: Worker container codebase, different language (Python/bash), needs careful protocol understanding
  - **Skills**: []
  - **Skills Evaluated but Omitted**:
    - `customize-opencode`: Not configuring opencode toolchain

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 4 (with Tasks 10, 11)
  - **Blocks**: None
  - **Blocked By**: Task 7 (orchestrator must send extended context first)

  **References**:
  - `codex4lunarwing/agent_comm_protocol.json` — Protocol schema to update with context fields documentation
  - `codex4lunarwing/entrypoint.sh` — Entry point that handles task_request, where context parsing goes
  - `codex4lunarwing/health_server.py` — Health server, may need context-aware health checks
  - `ic/src/orchestrator/external_worker.rs:403-412` — Orchestrator-side `task_request` serialization (what the worker receives)

  **Acceptance Criteria**:
  - [ ] `agent_comm_protocol.json` documents extended context fields
  - [ ] Worker parses `context.project_dir` and changes working directory
  - [ ] Worker parses `context.environment` and injects env vars
  - [ ] Worker handles empty/missing context without errors
  - [ ] Test script verifies context is received and used

  **QA Scenarios (MANDATORY)**:

  ```
  Scenario: Codex worker uses project_dir from context
    Tool: Bash
    Preconditions: Codex worker container running
    Steps:
      1. Send task_request with context.project_dir = "/workspace/myproject"
      2. Assert: Worker changes to that directory before executing
    Expected Result: Codex runs in the specified directory
    Failure Indicators: Worker stays in default directory
    Evidence: .sisyphus/evidence/task-9-codex-project-dir.txt

  Scenario: Codex worker injects environment from context
    Tool: Bash
    Preconditions: Codex worker container running
    Steps:
      1. Send task_request with context.environment = {"API_KEY": "test123"}
      2. Assert: Codex process has API_KEY env var set
    Expected Result: Environment variables injected
    Failure Indicators: Env vars missing from codex process
    Evidence: .sisyphus/evidence/task-9-codex-env-injection.txt

  Scenario: Codex worker handles empty context (backward compat)
    Tool: Bash
    Preconditions: Codex worker container running
    Steps:
      1. Send task_request with context = {}
      2. Assert: Worker processes task normally, no errors
    Expected Result: Same behavior as before context extension
    Failure Indicators: Worker crashes or errors on empty context
    Evidence: .sisyphus/evidence/task-9-codex-empty-context.txt
  ```

  **Evidence to Capture**:
  - [ ] Each evidence file named: task-9-{scenario-slug}.txt

  **Commit**: YES
  - Message: `feat(workers): accept extended context in codex worker`
  - Files: `codex4lunarwing/agent_comm_protocol.json`, `codex4lunarwing/entrypoint.sh`

- [x] 10. Update nanocode worker for extended context

  **What to do**:
  - Update `lunarcode4lunarwing/agent_comm_protocol.json` to document extended `context` fields
  - Update `lunarcode4lunarwing/entrypoint.sh` or handler to:
    - Parse `context.project_dir` and `cd` into it if provided
    - Parse `context.environment` and inject env vars before spawning nanocode
    - Parse `context.conversation_history` and prepend to prompt if provided
  - Ensure backward compatibility: if `context` is `{}` or missing, behave exactly as before
  - Add a test script that sends a task_request with populated context and verifies nanocode receives it

  **Must NOT do**:
  - Do NOT change the WebSocket connection logic or envelope format
  - Do NOT break existing task processing when context is empty

  **Recommended Agent Profile**:
  - **Category**: `unspecified-high`
    - Reason: Worker container codebase, similar to codex but separate codebase
  - **Skills**: []
  - **Skills Evaluated but Omitted**:
    - `customize-opencode`: Not configuring opencode toolchain

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 4 (with Tasks 9, 11)
  - **Blocks**: None
  - **Blocked By**: Task 7

  **References**:
  - `lunarcode4lunarwing/agent_comm_protocol.json` — Protocol schema to update
  - `lunarcode4lunarwing/entrypoint.sh` — Entry point where context parsing goes
  - `lunarcode4lunarwing/health_server.py` — Health server
  - `ic/src/orchestrator/external_worker.rs:403-412` — Orchestrator-side serialization

  **Acceptance Criteria**:
  - [ ] `agent_comm_protocol.json` documents extended context fields
  - [ ] Worker parses `context.project_dir` and changes working directory
  - [ ] Worker parses `context.environment` and injects env vars
  - [ ] Worker handles empty/missing context without errors
  - [ ] Test script verifies context is received and used

  **QA Scenarios (MANDATORY)**:

  ```
  Scenario: Nanocode worker uses project_dir from context
    Tool: Bash
    Preconditions: Nanocode worker container running
    Steps:
      1. Send task_request with context.project_dir = "/workspace/myproject"
      2. Assert: Worker changes to that directory before executing
    Expected Result: Nanocode runs in the specified directory
    Failure Indicators: Worker stays in default directory
    Evidence: .sisyphus/evidence/task-10-nanocode-project-dir.txt

  Scenario: Nanocode worker injects environment from context
    Tool: Bash
    Preconditions: Nanocode worker container running
    Steps:
      1. Send task_request with context.environment = {"GIT_SSH_KEY": "test"}
      2. Assert: Nanocode process has GIT_SSH_KEY env var set
    Expected Result: Environment variables injected
    Failure Indicators: Env vars missing from nanocode process
    Evidence: .sisyphus/evidence/task-10-nanocode-env-injection.txt

  Scenario: Nanocode worker handles empty context (backward compat)
    Tool: Bash
    Preconditions: Nanocode worker container running
    Steps:
      1. Send task_request with context = {}
      2. Assert: Worker processes task normally, no errors
    Expected Result: Same behavior as before context extension
    Failure Indicators: Worker crashes or errors on empty context
    Evidence: .sisyphus/evidence/task-10-nanocode-empty-context.txt
  ```

  **Evidence to Capture**:
  - [ ] Each evidence file named: task-10-{scenario-slug}.txt

  **Commit**: YES
  - Message: `feat(workers): accept extended context in nanocode worker`
  - Files: `lunarcode4lunarwing/agent_comm_protocol.json`, `lunarcode4lunarwing/entrypoint.sh`

- [x] 11. Update pebble worker for extended context

  **What to do**:
  - Update `pebble4lunarwing/src/protocol.rs` to parse extended `context` fields from `TaskRequest`
  - Add `TaskContext` struct in pebble's Rust code mirroring the orchestrator's (project_dir, conversation_history, environment, user_id, metadata)
  - Update `pebble4lunarwing/src/executor.rs` to:
    - Use `context.project_dir` as working directory if provided
    - Inject `context.environment` vars before executing tasks
    - Prepend `context.conversation_history` to prompt if provided
  - Ensure backward compatibility: if `context` is `{}` or missing, behave exactly as before
  - Update pebble tests in `protocol.rs` to cover extended context deserialization
  - Update `pebble4lunarwing/CLAUDE.md` if it documents the protocol

  **Must NOT do**:
  - Do NOT change the WebSocket connection logic or envelope format
  - Do NOT break existing task processing when context is empty
  - Do NOT change pebble's NDJSON streaming format (that's a separate concern)

  **Recommended Agent Profile**:
  - **Category**: `unspecified-high`
    - Reason: Rust worker container, closer to orchestrator code style, needs protocol-level changes
  - **Skills**: []
  - **Skills Evaluated but Omitted**:
    - `customize-opencode`: Not configuring opencode toolchain

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 4 (with Tasks 9, 10)
  - **Blocks**: None
  - **Blocked By**: Task 7

  **References**:
  - `pebble4lunarwing/src/protocol.rs:27-29` — Current `TaskRequest` with `context: serde_json::Value` to extend
  - `pebble4lunarwing/src/protocol.rs:184-200` — Existing tests showing deserialization patterns
  - `pebble4lunarwing/src/executor.rs` — Executor where context should be applied
  - `pebble4lunarwing/src/main.rs` — Entry point, may need context passing
  - `ic/src/orchestrator/external_worker.rs:403-412` — Orchestrator-side serialization (what pebble receives)

  **Acceptance Criteria**:
  - [ ] `TaskContext` struct exists in pebble's `protocol.rs`
  - [ ] `TaskRequest.context` is parsed into `TaskContext` (or remains `Value` with typed accessor)
  - [ ] Executor uses `context.project_dir` as working directory
  - [ ] Executor injects `context.environment` vars
  - [ ] `cargo test` passes in `pebble4lunarwing/`
  - [ ] Existing tests with `context: {}` still pass

  **QA Scenarios (MANDATORY)**:

  ```
  Scenario: Pebble deserializes extended context
    Tool: Bash (cargo test)
    Preconditions: Code compiles in pebble4lunarwing/
    Steps:
      1. Run: cd pebble4lunarwing && cargo test task_request_extended_context -- --nocapture
      2. Assert: TaskRequest with full context → all fields parsed correctly
    Expected Result: project_dir, environment, conversation_history all populated
    Failure Indicators: Fields missing or default after deserialization
    Evidence: .sisyphus/evidence/task-11-pebble-deserialize-context.txt

  Scenario: Pebble executor uses project_dir
    Tool: Bash (cargo test)
    Preconditions: Code compiles
    Steps:
      1. Run: cd pebble4lunarwing && cargo test executor_uses_project_dir -- --nocapture
      2. Assert: Executor changes to context.project_dir before running task
    Expected Result: Working directory matches context.project_dir
    Failure Indicators: Executor stays in default directory
    Evidence: .sisyphus/evidence/task-11-pebble-project-dir.txt

  Scenario: Pebble handles empty context (backward compat)
    Tool: Bash (cargo test)
    Preconditions: Code compiles
    Steps:
      1. Run: cd pebble4lunarwing && cargo test task_request_empty_context -- --nocapture
      2. Assert: TaskRequest with context = {} deserializes, all fields default
    Expected Result: No errors, default values for all context fields
    Failure Indicators: Deserialization fails or non-default values
    Evidence: .sisyphus/evidence/task-11-pebble-empty-context.txt
  ```

  **Evidence to Capture**:
  - [ ] Each evidence file named: task-11-{scenario-slug}.txt

  **Commit**: YES
  - Message: `feat(workers): accept extended context in pebble worker`
  - Files: `pebble4lunarwing/src/protocol.rs`, `pebble4lunarwing/src/executor.rs`

---

## Final Verification Wave (MANDATORY — after ALL implementation tasks)

> 4 review agents run in PARALLEL. ALL must APPROVE. Present consolidated results to user and get explicit "okay" before completing.

- [ ] F1. **Plan Compliance Audit** — `oracle`
  Read the plan end-to-end. For each "Must Have": verify implementation exists (read file, run command). For each "Must NOT Have": search codebase for forbidden patterns — reject with file:line if found. Check evidence files exist in .sisyphus/evidence/. Compare deliverables against plan.
  Output: `Must Have [N/N] | Must NOT Have [N/N] | Tasks [N/N] | VERDICT: APPROVE/REJECT`

- [ ] F2. **Code Quality Review** — `unspecified-high`
  Run `cargo clippy --all --benches --tests --examples -- -D warnings` + `cargo fmt --all -- --check` + `cargo test`. Review all changed files for: `as any`/`unwrap`/`expect` in production code, empty catches, console.log equivalents, commented-out code, unused imports. Check AI slop: excessive comments, over-abstraction, generic names.
  Output: `Build [PASS/FAIL] | Lint [PASS/FAIL] | Tests [N pass/N fail] | Files [N clean/N issues] | VERDICT`

- [ ] F3. **Real Manual QA** — `unspecified-high`
  Start from clean state. Execute EVERY QA scenario from EVERY task — follow exact steps, capture evidence. Test cross-task integration: pool reuse across tasks, LB routing across instances, backward compat with unmodified workers. Save to `.sisyphus/evidence/final-qa/`.
  Output: `Scenarios [N/N pass] | Integration [N/N] | Edge Cases [N tested] | VERDICT`

- [ ] F4. **Scope Fidelity Check** — `deep`
  For each task: read "What to do", read actual diff (git log/diff). Verify 1:1 — everything in spec was built (no missing), nothing beyond spec was built (no creep). Check "Must NOT do" compliance. Detect cross-task contamination. Flag unaccounted changes.
  Output: `Tasks [N/N compliant] | Contamination [CLEAN/N issues] | Unaccounted [CLEAN/N files] | VERDICT`

---

## Commit Strategy

- **Wave 1**: `feat(orchestrator): extend external worker protocol types` - external_worker.rs, config/sandbox.rs
- **Wave 2**: `feat(orchestrator): add connection pool and load balancer` - external_worker.rs, config/sandbox.rs
- **Wave 3**: `feat(orchestrator): wire pool + context into worker manager` - external_worker.rs, tools/builtin/job.rs
- **Wave 4**: `feat(workers): accept extended context in worker containers` - ~~codex4lunarwing/~~ *(removed v1.1.9)*, lunarcode4lunarwing/, pebble4lunarwing/

---

## Success Criteria

### Verification Commands
```bash
cd ic && cargo test -- --nocapture                          # All tests pass
cd ic && cargo clippy --all --benches --tests --examples -- -D warnings  # Zero warnings
cd ic && cargo fmt --all -- --check                          # Format clean
cd ic && cargo test external_worker -- --nocapture           # Worker-specific tests pass
cd ic && cargo test test_envelope -- --nocapture             # Protocol serialization tests pass
```

### Final Checklist
- [ ] All "Must Have" present
- [ ] All "Must NOT Have" absent
- [ ] All tests pass
- [ ] Backward compatibility verified (old config format still works)
- [ ] All three worker containers updated
- [ ] final verification needed
