# Engine V2 Architecture

The V2 engine is a unified thread-capability-CodeAct execution model that lives in `ic/crates/lunarwing_engine/`. It replaces approximately 10 separate v1 abstractions (Session, Job, Routine, Channel, Tool, Skill, Hook, Observer, Extension, LoopDelegate) with 5 core primitives.

Enabled at runtime via the `ENGINE_V2=true` environment variable. When enabled, the bridge router (`src/bridge/router.rs`) delegates incoming messages to the engine instead of the legacy v1 agent loop.

## Five Primitives

| Primitive | Purpose | Replaces (v1) |
|-----------|---------|---------------|
| **Thread** | Unit of work with lifecycle, parent-child tree, capability leases | Session + Job + Routine + Sub-agent |
| **Step** | Unit of execution (one LLM call + its action executions) | Agentic loop iteration + tool calls |
| **Capability** | Unit of effect with actions, knowledge, and policies | Tool + Skill + Hook + Extension |
| **MemoryDoc** | Unit of durable knowledge (summaries, lessons, skills) | Workspace memory blobs |
| **Project** | Unit of context (scopes memory, threads, missions) | Flat workspace namespace |

## Module Map

```
ic/crates/lunarwing_engine/src/
  lib.rs                  Public API, re-exports
  types/                  Core data structures (no async, no I/O)
    thread.rs             Thread, ThreadId, ThreadState, ThreadType, ThreadConfig
    step.rs               Step, StepId, LlmResponse, ActionCall, ActionResult, TokenUsage
    capability.rs         Capability, ActionDef, EffectType, CapabilityLease, PolicyRule
    memory.rs             MemoryDoc, DocId, DocType (Summary/Lesson/Skill/Issue/Spec/Note/Plan)
    project.rs            Project, ProjectId
    event.rs              ThreadEvent, EventKind (18 variants for event sourcing)
    message.rs            ThreadMessage, MessageRole
    provenance.rs         Provenance enum (User/System/ToolOutput/LlmGenerated/etc.)
    conversation.rs       ConversationSurface, ConversationEntry, EntrySender
    mission.rs            Mission, MissionId, MissionCadence, MissionStatus
    error.rs              EngineError, ThreadError, StepError, CapabilityError
  traits/                 External dependency abstractions (host implements these)
    llm.rs                LlmBackend trait
    store.rs              Store trait (20 CRUD methods)
    effect.rs             EffectExecutor trait
  capability/             Capability management
    registry.rs           CapabilityRegistry (register/get/list capabilities)
    lease.rs              LeaseManager (grant/check/consume/revoke/expire leases)
    policy.rs             PolicyEngine (deterministic allow/deny/approve + provenance taint)
  runtime/                Thread lifecycle management
    manager.rs            ThreadManager (spawn, stop, inject messages, join threads)
    conversation.rs       ConversationManager (routes UI messages to threads)
    mission.rs            MissionManager (long-running goals that spawn threads on cadence)
    tree.rs               ThreadTree (parent-child relationships)
    messaging.rs          ThreadSignal, ThreadOutcome, signal channels
  executor/               Step execution
    loop_engine.rs        ExecutionLoop (core loop replacing run_agentic_loop)
    structured.rs         Tier 0: structured tool call execution
    scripting.rs          Tier 1: embedded Python via Monty (CodeAct/RLM)
    context.rs            Context builder (messages + actions from leases + memory docs)
    compaction.rs         Context compaction when approaching model context limit
    prompt.rs             System prompt construction (CodeAct preamble/postamble)
    trace.rs              Execution trace recording and retrospective analysis
  memory/                 Memory document system
    store.rs              MemoryStore (project-scoped doc CRUD)
    retrieval.rs          RetrievalEngine (keyword-based context retrieval from project docs)
    skill_tracker.rs      SkillTracker (confidence tracking, versioned updates, rollback)
  reliability.rs          ReliabilityTracker (per-action success rate and latency via EMA)
```

## Thread State Machine

```
Created --> Running --> Waiting --> Running (resume)
                   --> Suspended --> Running (resume)
                   --> Completed --> Done
                   --> Failed
```

All transitions are validated by `ThreadState::can_transition_to()`. Terminal states: `Done`, `Failed`. Invalid transitions return `ThreadError::InvalidTransition`.

### Thread Types

- **Interactive** -- user-initiated conversational threads
- **Background** -- scheduled/routine-spawned threads
- **SubThread** -- child threads spawned by a parent thread

Threads form a tree via `ThreadTree`. Parent threads can spawn children, and child completion propagates events up to the parent.

## Execution Loop

`ExecutionLoop::run()` is the core loop that replaces the v1 `run_agentic_loop()`. It handles three `LlmResponse` variants:

```
1. Check signals (Stop, InjectMessage) via mpsc::Receiver
2. Build context (messages + available actions from active leases)
3. Call LLM via LlmBackend::complete()
4. If Text: check tool intent nudge, return if final response
5. If ActionCalls (Tier 0): find lease -> check policy -> consume use -> execute -> record
6. If Code (Tier 1): execute Python via Monty with context-as-variables
7. Record Step, emit ThreadEvents
8. Repeat until: text response, stop signal, max iterations, or approval needed
```

### Two Execution Tiers

**Tier 0 -- Structured Tool Calls** (`executor/structured.rs`):

Standard tool/function calling. The LLM returns structured `ActionCall` objects. For each call:
1. Find the capability lease that grants this action
2. Check the policy engine (allow/deny/approve)
3. Consume one use from the lease (if use-limited)
4. Execute via `EffectExecutor`
5. Record the `ActionResult`

**Tier 1 -- CodeAct / Python via Monty** (`executor/scripting.rs`):

Embedded Python execution following the RLM (Recursive Language Model) pattern. The LLM generates Python code that the Monty interpreter executes.

Key characteristics:
- **Context as variables**: thread messages injected as `context` Python variable, thread goal as `goal`, step index as `step_number`, prior action results as `previous_results` dict
- **Tool dispatch**: unknown function calls suspend the VM, go through lease check + policy check + `EffectExecutor`, then result returns to Python
- **Recursive LLM calls**: `llm_query(prompt, context)` suspends the VM, spawns a single-shot LLM call, returns text as a Python string. Results stay as variables (symbolic composition), not injected into the parent's attention window
- **Compact output metadata**: between code steps, only a summary is added to chat context (e.g. `"[code output] stdout (4532 chars): The results show..."`) to prevent context bloat
- **Explicit termination**: `FINAL(answer)` or `FINAL_VAR(name)` for output
- **Resource limits**: 300s timeout, 128MB memory, 5M allocations (configurable). All execution wrapped in `catch_unwind` for Monty panic safety

### Python Orchestrator

The orchestrator (`executor/orchestrator.rs`) is a self-modifiable Python execution layer that can replace the compiled Rust `ExecutionLoop::run()` loop:

- Executes via Monty with resource limits
- Exposes host functions: `__llm_complete__`, `__execute_code_step__`, `__execute_action__`, `__execute_actions_parallel__`, `__check_signals__`, `__emit_event__`, `__save_checkpoint__`, `__transition_to__`, `__retrieve_docs__`, `__check_budget__`, `__get_actions__`
- Can be patched by the self-improvement mission and versioned in the Store
- Falls back to compiled-in default (v0) if disabled or patches fail (3+ consecutive failures triggers rollback)
- Async dispatch of tool calls with `asyncio.gather()` for parallel execution
- Default orchestrator source: `ic/orchestrator/default.py`

## Capability Leases

Threads don't have static permissions. Instead, they receive **leases** -- scoped, time-limited, use-limited grants:

```rust
CapabilityLease {
    thread_id,
    capability_name,
    granted_actions,
    expires_at: Option<DateTime>,   // time-limited
    max_uses: Option<u32>,          // use-limited
    revoked: bool,
}
```

### Lease Lifecycle

1. **Grant**: `LeaseManager::grant()` creates a lease for a thread
2. **Check**: `LeaseManager::check()` verifies the lease is valid (not expired, not revoked, uses remaining)
3. **Consume**: `LeaseManager::consume()` decrements the use counter
4. **Revoke**: `LeaseManager::revoke()` permanently disables the lease
5. **Expire**: `LeaseManager::expire_stale()` cleans up time-expired leases

### Policy Engine

The `PolicyEngine` evaluates actions against leases deterministically:

- **Priority**: `Deny > RequireApproval > Allow`
- **Effect types**: `ReadLocal`, `ReadExternal`, `WriteLocal`, `WriteExternal`, `CredentialedNetwork`, `Compute`, `Financial`
- Every action declares its side effects via `EffectType`. The policy engine uses these for allow/deny decisions
- **Provenance taint**: tracks the origin of data flowing through the system

## Execution Gates

Unified gate abstraction for all pre-execution checks (approval, auth, rate limits):

```
GateDecision:
  Allow                                    -- proceed immediately
  Pause(reason, ResumeKind)                -- suspend thread, wait for resolution
  Deny(reason)                             -- reject, do not execute

ResumeKind:
  Approval { allow_always }                -- user must approve
  Authentication { credential, instructions, auth_url }  -- user must authenticate
  External { callback_id }                 -- external system callback

GateResolution:
  Approved | Denied | CredentialProvided | Cancelled | ExternalCallback

ExecutionMode:
  Interactive | InteractiveWithAutoApprove | Unattended | Autonomous
```

**Gate pipeline** (`GatePipeline`): composes multiple gates in sequence. The first `Pause` or `Deny` wins.

**Resolution flow**:
1. Gate returns `Pause` -- `PendingGate` stored in database via `insert_and_notify_pending_gate()`
2. SSE broadcasts `AppEvent::GateRequired` to the user
3. Web UI shows approval/auth prompt
4. User responds with `GateResolution`
5. Thread resumes with the result injected as a message

## Learning Missions

Three event-driven missions fire automatically after thread completion. Created by `MissionManager::ensure_learning_missions()` at project bootstrap.

### Error Diagnosis (`self-improvement`)

- **Trigger**: fires when a thread completes with trace issues
- **Action**: diagnoses root cause and applies prompt overlays or orchestrator patches

### Skill Extraction (`skill-extraction`)

- **Trigger**: fires when a thread succeeds with 5+ steps and 3+ tool actions
- **Action**: extracts reusable skills with activation metadata, CodeAct code snippets, and domain tags
- **Output**: stored as `DocType::Skill` MemoryDoc

### Conversation Insights (`conversation-insights`)

- **Trigger**: fires every 5 completed threads in a project
- **Action**: extracts user preferences, domain knowledge, and workflow patterns

## V2 Skill System

V2 skills (`lunarwing_skills::v2`) differ fundamentally from v1:

| Aspect | V1 | V2 |
|--------|----|----|
| Selection | Deterministic in Rust (`skills/selector.rs`) | Python orchestrator (`score_skill()`) |
| Storage | Filesystem `SKILL.md` files | MemoryDocs via the Store |
| Trust | Binary (Trusted/Installed) | Policy engine controls via leases |
| Creation | Manual authoring | Auto-extracted by skill-extraction mission |
| Tracking | None | Confidence metrics (success/failure ratio) |

### V2 Skill Types

```rust
V2SkillMetadata {
    name, version, description,
    activation: ActivationCriteria,
    source: V2SkillSource (Authored | Extracted | Migrated),
    trust: Trusted | Installed,
    code_snippets: Vec<CodeSnippet>,   // Python function bodies
    metrics: SkillMetrics,              // usage_count, success_count, failure_count
    parent_version: Option<u32>,        // for rollback
    content_hash: String,
}
```

Confidence: `1.0` if no recorded outcomes (benefit of the doubt), else `success_count / (success_count + failure_count)`.

## Bridge Adapters

The daemon integrates the engine via three adapters in `src/bridge/`:

### LlmBridgeAdapter (`src/bridge/llm_adapter.rs`)

Wraps `LlmProvider` as `LlmBackend`:
- Converts between `ThreadMessage` and `ChatMessage`
- Converts `ActionDef` to `ToolDefinition`
- Supports cheaper provider for sub-calls (depth > 0)
- Detects code blocks in responses for CodeAct

### EffectBridgeAdapter (`src/bridge/effect_adapter.rs`)

Wraps tool execution and safety layer as `EffectExecutor`:
- Maps engine action calls to tool registry execution
- Applies safety checks, timeout, serialization

### HybridStore (`src/bridge/store_adapter.rs`)

Wraps `Database` + `Workspace` as the engine's `Store` trait:
- 20 CRUD methods for threads, steps, events, projects, docs, leases, missions, conversations
- In-memory HashMap cache backed by the database
- Fallback to database on cache miss (never deletes LLM output)

## External Trait Boundaries

The engine defines three traits that the host crate implements. This boundary ensures the engine has no dependency on the main daemon crate and is testable in isolation.

| Trait | Signature | Host wraps |
|-------|-----------|------------|
| `LlmBackend` | `complete(messages, actions, config) -> LlmOutput` | `LlmProvider` |
| `Store` | 20 CRUD methods for all engine types | `Database` (PostgreSQL + libSQL) |
| `EffectExecutor` | `execute_action(name, params, lease, ctx) -> ActionResult` | `ToolRegistry` + `SafetyLayer` |

## Data Retention Policy

Thread messages, steps, and events are **never deleted** from the database. This data (context fed to the model, reasoning, tool calls, results) is the most valuable information in the system.

"Cleanup" of terminal threads means evicting from in-memory caches to bound RAM -- the database rows always stay. `load_thread()`, `load_steps()`, and `load_events()` fall back to the database on a cache miss.

## Event Sourcing

Every thread records a complete event log via `ThreadEvent`. The `EventKind` enum has 18 variants covering the full lifecycle: thread creation, state transitions, message receipt, LLM calls, action execution, gate decisions, mission triggers, and more.

This enables:
- Full replay of any thread's execution history
- Retrospective analysis via `executor/trace.rs`
- Learning mission triggers based on event patterns
- Debugging and auditing

## Configuration

```bash
ENGINE_V2=true              # Enable the v2 engine (default: false)
```

The engine inherits most configuration from the host daemon (LLM provider settings, database config, tool registry, safety settings). Engine-specific behavior is controlled through `ThreadConfig` at thread spawn time.

## Build & Test

```bash
cargo check -p lunarwing_engine
cargo clippy -p lunarwing_engine --all-targets -- -D warnings
cargo test -p lunarwing_engine
```

## Key Design Decisions

1. **No dependency on main crate** -- clean separation, testable in isolation
2. **No safety logic in engine** -- sanitization/leak detection applied at the adapter boundary (`EffectExecutor` impl)
3. **Event sourcing from day one** -- every thread records a complete event log
4. **Tier 0 + Tier 1** -- structured tool calls and embedded Python via Monty coexist
5. **Engine owns its message type** -- `ThreadMessage` is simpler than `ChatMessage`; bridge adapters handle conversion
6. **RLM pattern** -- context as variable (not attention input), recursive `llm_query()`, compact output metadata between steps
7. **Fail-closed by construction** -- `GateDecision` has no `None` variant, `ResumeKind` is a closed enum
8. **Never delete LLM output** -- database rows are permanent; only in-memory caches are evicted
