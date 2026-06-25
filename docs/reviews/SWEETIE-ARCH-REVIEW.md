# SWEETIE-ARCH-REVIEW: LunarWing Full Codebase Architecture Review

**Reviewer:** SweetieBot 🦄
**Date:** 2025-07-20
**Branch:** `sweetie-big-review` (based on `staging`)
**Codebase size:** ~366 Rust source files, ~172,621 lines in `ic/src/`

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [System Overview & Topology](#2-system-overview--topology)
3. [Core Agent Loop](#3-core-agent-loop)
4. [Session & Thread Model](#4-session--thread-model)
5. [LLM Layer](#5-llm-layer)
6. [Tool System](#6-tool-system)
7. [Channel Architecture](#7-channel-architecture)
8. [Orchestration & External Workers](#8-orchestration--external-workers)
9. [Workspace & Memory System](#9-workspace--memory-system)
10. [Safety & Security](#10-safety--security)
11. [Skills System](#11-skills-system)
12. [Routine Engine & Reflex Router](#12-routine-engine--reflex-router)
13. [Self-Repair & Resilience](#13-self-repair--resilience)
14. [Database Layer](#14-database-layer)
15. [Web Gateway](#15-web-gateway)
16. [Extensions System](#16-extensions-system)
17. [Engine v2 Bridge](#17-engine-v2-bridge)
18. [Hooks System](#18-hooks-system)
19. [Configuration](#19-configuration)
20. [Strengths](#20-strengths)
21. [Concerns & Technical Debt](#21-concerns--technical-debt)
22. [Recommendations](#22-recommendations)

---

## 1. Executive Summary

LunarWing is a **production-grade autonomous agent platform** built in Rust. It provides multi-channel conversational AI with sandboxed tool execution, persistent memory, self-repair, routine automation, reflex-based fast-path routing, and a pluggable extension system. The architecture is layered and modular, with clear separation between the agent core, LLM providers, tool execution, channels, and persistence.

The codebase demonstrates **strong engineering discipline**: comprehensive doc comments, trait-based abstraction, defensive error handling, and security-conscious design throughout. The dual-backend database strategy (PostgreSQL + libSQL) enables deployment flexibility from edge to datacenter.

**Key architectural strengths:**
- Unified `LoopDelegate` agentic loop serving chat, job, and container contexts
- Defense-in-depth sandboxing (WASM with fuel metering, credential injection, leak detection)
- Lock-free cooldown/circuit-breaker patterns in the LLM failover layer
- Engine v2 parallel deployment strategy (zero-risk flag-gated migration)

**Key concerns:**
- Large monolithic `ic` crate (366 files) — candidate for workspace splitting
- Some very large files (agent_loop.rs >2k lines, dispatcher.rs, router.rs) that could benefit from further decomposition
- Engine v1/v2 duality adds cognitive overhead; migration timeline unclear

---

## 2. System Overview & Topology

```
                         ┌─────────────────────────────────────────────┐
                         │              LunarWing Agent                 │
                         │                                              │
    ┌──────────┐         │  ┌─────────┐   ┌──────────┐   ┌──────────┐  │
    │ XMPP     │◄───────►│  │ Channel │   │  Agent   │   │   LLM    │  │
    │ Telegram │         │  │ Manager │──►│   Loop   │◄─►│ Provider │  │
    │ Web/API  │         │  └─────────┘   └────┬─────┘   └──────────┘  │
    │ Signal   │         │                     │                        │
    │ Webhook  │         │              ┌──────┴──────┐                 │
    └──────────┘         │              │             │                 │
                         │  ┌────────┐  ▼  ┌────────┐│  ┌──────────┐   │
                         │  │Scheduler│◄───►│ Tools  ││  │ Workspace│   │
                         │  └────────┘    └──┬─────┘│  └────┬─────┘   │
                         │       │     ┌─────┴────┐ │       │          │
                         │       ▼     │ WASM    │ │  ┌────┴─────┐   │
                         │  ┌────────┐ │ Sandbox │ │  │ Database │   │
                         │  │Routine │ │ MCP     │ │  │ PG/libSQL│   │
                         │  │Engine  │ └─────────┘ │  └──────────┘   │
                         │  └────────┘             │                  │
                         │       │           ┌─────┴────┐            │
                         │  ┌────────┐        │  Safety  │            │
                         │  │Reflex  │        │  Layer   │            │
                         │  │Router  │        └──────────┘            │
                         │  └────────┘                                │
                         └─────────────────────────────────────────────┘
```

**Core flow:** Inbound message → Channel Manager → Agent Loop → Submission Parser → Session/Thread resolution → Agentic Loop (LLM ↔ Tools, with Reflex fast-path) → Response → Channel.

### Module Map (`ic/src/`)

| Module | Files | Lines (approx) | Purpose |
|--------|-------|-----------------|---------|
| `agent/` | 24 | ~35,000 | Core agent: loop, scheduler, sessions, compaction, routines, reflex, self-repair |
| `llm/` | 25+ | ~20,000 | LLM providers, failover, circuit breaker, smart routing, reasoning, recording |
| `channels/` | 15+ | ~18,000 | XMPP, Signal, Web (Axum), REPL, webhook server, WASM channels |
| `tools/` | 20+ | ~15,000 | Tool registry, WASM sandbox, MCP, builder, permissions, rate limiting |
| `orchestrator/` | 5+ | ~5,000 | External workers, container job management, auth |
| `workspace/` | 10+ | ~5,000 | Memory system, embeddings, search, hygiene, layers |
| `bridge/` | 7 | ~6,000 | Engine v2 bridge adapters (LLM, effects, store, router) |
| `db/` | 5 | ~3,500 | Database trait, PostgreSQL + libSQL backends, migrations |
| `config/` | 20+ | ~4,000 | All configuration modules |
| `extensions/` | 5+ | ~2,500 | Extension discovery, installation, activation |
| `skills/` | 5+ | ~2,500 | Skill registry, catalog, gating, prefiltering |
| `safety/` | re-export | — | Re-exports `lunarwing_safety` crate |
| `hooks/` | 5 | ~1,500 | 6 lifecycle hooks, registry, bundled hooks |

---

## 3. Core Agent Loop

### `agent_loop.rs` — The Heart

The `Agent` struct orchestrates the entire system. The `run()` method is the main event loop:

**Startup sequence:**
1. `AppBuilder` initializes all components (DB, LLM, safety, tools, workspace, extensions, MCP, WASM runtime, hooks, skills)
2. Bootstrap greeting persisted to DB before channels start
3. Channels started via `ChannelManager::start_all()`
4. Background tasks spawned: self-repair, session pruning, heartbeat, reflex compiler, routine engine

**Message processing:**
1. `tokio::select!` on message stream, SIGTERM, and Ctrl+C
2. Transcription middleware (audio → text) and document extraction middleware
3. Extracted documents stored in workspace memory
4. `handle_message()` spawned as background task with soft/hard timeout pattern

**Timeout architecture (well-designed):**
- **Soft timeout** (`handle_message_timeout`, default 300s): User gets "timed out" message immediately, task keeps running
- **Hard kill** (`HARD_KILL_GRACE_SECS` = 30s after soft): Task aborted, thread state force-reset, pending messages **preserved**
- **Turn budget reconciliation** (`resolve_turn_budget`): Ensures LLM `TimeoutProvider` fires before hard-kill grace. Pure function, well-tested.

**Observation:** The timeout design is mature. The `HARD_KILL_GRACE_SECS` constant is shared between `agent_loop.rs` and `app.rs` via `crate::agent::HARD_KILL_GRACE_SECS`, preventing drift. The decision to preserve pending messages at hard-kill (rather than clearing them) is correct — the orphaned task can no longer respond, so the "confusing concurrent response" risk that originally justified clearing no longer applies.

### `agentic_loop.rs` — Unified Loop Engine

The `LoopDelegate` trait is a clean abstraction. Three consumers (chat dispatcher, job worker, container runtime) customize behavior without duplicating the core loop logic:

```rust
trait LoopDelegate: Send + Sync {
    async fn check_signals(&self) -> LoopSignal;
    async fn before_llm_call(...) -> Option<LoopOutcome>;
    async fn call_llm(...) -> Result<RespondOutput, Error>;
    async fn handle_text_response(...) -> TextAction;
    async fn execute_tool_calls(...) -> Result<Option<LoopOutcome>, Error>;
    async fn on_tool_intent_nudge(...);
    async fn after_iteration(...);
}
```

**Tool intent nudge:** When the LLM says "let me search..." without actually calling a tool, a nudge message is injected (max 2 nudges). The `llm_signals_tool_intent()` function carefully excludes false-positive phrases ("let me explain", "let me know") and strips code blocks and quoted strings before matching. Well-engineered.

### `dispatcher.rs` — Chat-Specific Loop

The `ChatDelegate` implements `LoopDelegate` for interactive chat. Notable features:
- Workspace system prompt loading (with group-chat-aware MEMORY.md exclusion)
- Skill selection and context injection (XML-tagged `<skill>` blocks)
- Reflex fast-path check before LLM invocation
- Channel conversation context injection (group names, chat metadata)
- Two cached system prompt variants (with/without tools) for the force-text final iteration

---

## 4. Session & Thread Model

### Session → Thread → Turn Hierarchy

```
Session (per user)
  ├── Thread (conversation sequence)
  │   ├── Turn (request/response pair)
  │   │   ├── user_input
  │   │   ├── response
  │   │   ├── actions[]
  │   │   └── context_messages[]
  │   └── Turn ...
  └── Thread ...
```

**Key states:** `Idle`, `Processing`, `AwaitingApproval`, `Completed`, `Interrupted`

**Design highlights:**
- **PendingApproval** carries full context for resume: tool call ID, parameters (original + redacted display), deferred tool calls, user timezone
- **PendingAuth** with TTL (5 min) — auth mode intercepts the next message before entering the normal pipeline (no logging, no turn creation)
- **Auto-approved tools** tracked per-session (`HashSet<String>`)
- **Thread hydration from DB** — historical threads can be loaded on demand

### Compaction

Three strategies:
1. **Summarize** — LLM summarizes old turns, summary written to workspace, turns trimmed
2. **Truncate** — Simple truncation (no summary)
3. **MoveToWorkspace** — Raw turn content archived to workspace

**Safety:** If workspace write fails, turns are preserved (not lost). Compaction is defensive.

---

## 5. LLM Layer

### Provider Architecture

Decorator stack pattern (outer → inner):
```
FailoverProvider
  └── CircuitBreakerProvider
        └── RetryProvider
              └── CachedProvider (optional)
                    └── Actual Provider (NearAI, OpenAI, Anthropic, Bedrock, Codex, etc.)
```

### Failover (`failover.rs`)

- Sequential provider fallback with **lock-free cooldown tracking**
- `ProviderCooldown`: atomic failure counts + cooldown timestamps (Relaxed ordering — acceptable for this use case)
- When all providers in cooldown, the oldest-cooled one is tried
- Per-task provider binding via `tokio::task::Id` for accurate `effective_model_name()` reporting

**Observation:** The lock-free design is pragmatic and well-documented. The `provider_for_task` Mutex<HashMap> is the one synchronization point — could become a bottleneck under extreme concurrency, but unlikely in practice.

### Circuit Breaker (`circuit_breaker.rs`)

Standard state machine: Closed → Open → HalfOpen → Closed.
- Default: 5 consecutive failures → Open, 30s recovery timeout, 2 successful probes to close
- Clean separation of concerns from failover (circuit breaker = per-provider, failover = cross-provider)

### Smart Routing (`smart_routing.rs`)

13-dimension complexity scorer:
- reasoning_words, token_estimate, code_indicators, multi_step, domain_specific, ambiguity, creativity, precision, context_dependency, tool_likelihood, safety_sensitivity, question_complexity, sentence_complexity

Four tiers: Flash (0-15) → Standard (16-40) → Pro (41-65) → Frontier (66+)

Routes to cheap vs. primary model based on score. Pattern overrides for obvious cases (greetings → cheap, security audits → primary).

### Reasoning (`reasoning.rs`)

- System prompt assembly (workspace identity + skills + tools + context)
- `SILENT_REPLY_TOKEN = "NO_REPLY"` for group chat noise suppression
- Tool intent detection with exclusion phrases and code-block stripping
- Code block extraction for CodeAct/RLM patterns
- Empty response retry (reasoning models returning only `<think>` tags)

---

## 6. Tool System

### Tool Registry

Central registry for all agent tools. Key features:
- **Approval workflow**: `ApprovalRequirement::Never / OnRequest / Always`
- **Risk levels**: Low, Medium, High
- **Autonomous allowlist**: Tools permitted without user approval in background jobs
- **Parameter redaction**: Sensitive values replaced with `[REDACTED]` for display/logging
- **Schema validation**: JSON Schema validation for tool parameters

### WASM Sandbox (`tools/wasm/`)

**This is the security crown jewel.** Defense-in-depth:

| Threat | Mitigation |
|--------|------------|
| CPU exhaustion | Fuel metering (Wasmtime) |
| Memory exhaustion | ResourceLimiter (10MB default) |
| Infinite loops | Epoch interruption + tokio timeout |
| Filesystem access | No WASI FS, only host `workspace_read` |
| Network access | Allowlisted endpoints only |
| Credential exposure | Injection at host boundary, never in WASM |
| Secret exfiltration | Leak detector scans all outputs |
| Path traversal | No `..`, no `/` prefix validation |
| Trap recovery | Instance discarded, never reused |
| WASM tampering | BLAKE3 hash verification on load |
| Tool access | Aliasing indirection layer |

**Architecture:** Compile once → instantiate fresh per execution. Extended host API (V2): log, time, workspace, HTTP, tool invoke, secrets. Capability-based security — features opt-in via `Capabilities` struct.

**WIT version compatibility:** `WIT_TOOL_VERSION = "0.3.0"` with semver check on load.

### MCP Integration (`tools/mcp/`)

Full Model Context Protocol support:
- Transports: HTTP (Streamable HTTP/SSE), stdio (subprocess), Unix domain sockets
- Auth: OAuth 2.1 with Dynamic Client Registration + pre-configured client ID
- Session management with token refresh
- Process manager for stdio-based MCP servers (lifecycle management)

---

## 7. Channel Architecture

### Channel Manager

Unified `Channel` trait with `start()`, `respond()`, `broadcast()`, `send_status()`. Channels:
- **XMPP** — Full XMPP with OMEMO encryption, MUC support, XEP-0363 HTTP File Upload, outbound rate limiting, OOB attachment downloads
- **Web (Axum)** — HTTP API + WebSocket + SSE for real-time events
- **Signal** — Signal messaging
- **REPL** — Read-eval-print loop for local interaction
- **Unix Socket REPL** — For daemon mode
- **Webhook Server** — Inbound webhook receiver

### XMPP Channel (deepest implementation)

Notable features:
- **OMEMO encryption** with `OmemoManager`, device bundle management, encrypted MUC rooms
- **MUC encryption diagnostics** — room readiness, member tracking, non-anonymous detection
- **Outbound rate limiter** — sliding window (default 1 hour), configurable max messages per hour
- **OOB attachment handling** — concurrent downloads (max 4), size limit (20MB), per-message cap (10)
- **Reply target cache** — LRU cache (10k entries) mapping message IDs to reply targets
- **XEP-0045 MUC admin operations** — affiliation management for encrypted rooms

### Web Gateway (`channels/web/server.rs`)

Axum-based HTTP server:
- **Per-user rate limiting** — sliding window with per-user isolation, fail-open on lock poisoning
- **Workspace pool** — lazily created per-user workspaces with appropriate scopes
- **SSE** — real-time job events, log streaming
- **WebSocket** — chat interface
- **Auth middleware** — authenticated user extraction
- **OAuth state redaction** — SHA256 hash for logging (never log raw state)
- **Prompt queue** — per-job follow-up prompt delivery for bridge workers

---

## 8. Orchestration & External Workers

### External Worker Manager (`orchestrator/external_worker.rs`)

WebSocket-based persistent worker connections speaking `ironclaw-agent-v1` protocol:

- **Connection pooling** — `WorkerConnectionPool` with configurable pool size and TTL
- **Load balancing** — `LoadBalancer` with strategy selection (round-robin, least-connections)
- **Task context** — workspace dir, conversation history, environment, metadata
- **Security warnings** — cleartext `ws://` for non-loopback hosts triggers loud warning
- **Job event streaming** — broadcast channel for SSE integration
- **Active handle tracking** — `Arc<RwLock<HashMap<Uuid, Arc<Mutex<ExternalJobHandle>>>>>`

### Container Job Manager (`orchestrator/job_manager.rs`)

Docker-based sandboxed job execution:
- **JobMode**: `Worker` (standard) or `External(String)` (delegated to named external worker)
- **Bind mount validation** — canonicalize + prefix check under `~/.lunarwing/projects/`
- **TOCTOU acknowledgment** — explicitly documented as acceptable for single-tenant design
- **Container lifecycle** — Creating → Running → Stopped/Failed
- **Completion results** — success/failure reported by worker
- **Auth token isolation** — intentionally NOT in ContainerHandle struct, lives only in TokenStore

### Gaps in the External Worker System

The external worker subsystem is functional but has notable gaps that limit its extensibility:

1. **No worker health monitoring** — No periodic health checks, no automatic removal of unhealthy workers. A dead worker is only detected when a task fails against it. Active pings or passive success/failure rate tracking would catch problems before they hit user-facing tasks.

2. **No worker registration/discovery** — Workers must be pre-configured in config files. No dynamic discovery or registry where workers can announce themselves at runtime.

3. **No worker capability advertisement** — Workers don't declare what they can do (supported languages, tool domains, specialty). The agent has no way to know which worker is best suited for a task.

4. **No task routing by capability** — Without capability advertisement, task routing requires the agent or user to know worker names manually. A routing rule like "code review → nanocode, writing tasks → codex" can't be expressed declaratively.

5. **No worker metrics/telemetry** — No success/failure rates, latency histograms, or throughput statistics per worker. This data is essential for operational visibility and load balancing tuning.

6. **No worker versioning/negotiation** — `ReadyPayload` has a `version` field but it is `#[allow(dead_code)]` — parsed and discarded. No protocol version negotiation or capability compatibility check at handshake. The `WIT_TOOL_VERSION` semver verification pattern (host ≥ worker, same major) could be reused here.

7. **No persistent task queue** — Tasks are either blocking (`wait=true`) or fire-and-forget (`wait=false` with `tokio::spawn`). If the agent process crashes mid-task, the task is lost. A durable queue (backed by the DB) would enable crash-safe task execution.

8. **No auto-scaling** — Worker pool is static (configured at boot). There's no mechanism to spin up additional worker endpoints based on queue depth or load metrics.

9. **No task priority** — All tasks are treated equally. No way to mark a task as urgent vs. best-effort, which matters during high-load or when external worker slots are scarce.

10. **No task dependencies / chaining** — Tasks can't express dependencies ("B runs after A completes") or linear pipelines ("A → B → C with output flowing forward"). Multi-step worker orchestration must be handled manually at the agent/LLM level, burning tokens on what could be declarative pipeline execution.

11. **No circuit breaker for external workers** — The `FailoverProvider` cooldown pattern (atomic lock-free, per-provider failure windows) would translate directly here. Currently a worker that is down gets hit on every task attempt until the load balancer's `acquire_excluding()` failover kicks in.

### Worker Subsystem (`worker/` — 4,200 lines)

Three distinct worker modes share a common orchestrator communication layer:

#### 1. Native Worker (`container.rs` — WorkerRuntime)

Runs the **same `AgenticLoop`** as the main agent via `ContainerDelegate` (implements `LoopDelegate`). Key design:

- **ProxyLlmProvider** — All LLM calls proxied through orchestrator HTTP API. Workers never see API keys.
- **Container-safe tools only** — shell, file ops, patch (registered via `register_container_tools()`).
- **Credential injection** — Secrets fetched from orchestrator, injected into child processes via `Command::envs()`. Never mutates the global process environment (thread-safe in multi-threaded tokio runtime).
- **Completion detection** — Triple-trigger: 3 consecutive text-only responses, `llm_signals_completion()`, or `is_post_work_chatter()` (detects `<suggestions>`, "would you like me to", "shall I", "let me know if").
- **Failure detection** — Tracks consecutive iterations where all tool calls failed; exits with failure when the LLM keeps retrying broken commands.
- **Follow-up prompts** — Polls orchestrator for user follow-ups between iterations, injects as user messages.
- **Status reporting** — Reports progress every 5 iterations via `StatusUpdate` to orchestrator.

#### 2. ACP Bridge (`acp_bridge.rs` — AcpBridgeRuntime)

Spawns any ACP-compliant agent (Goose, Codex, Gemini CLI) as a subprocess communicating via JSON-RPC over stdio:

- Configured via `ACP_AGENT_COMMAND`, `ACP_AGENT_ARGS`, `ACP_AGENT_ENV` environment variables.
- Runs on `tokio::task::LocalSet` (ACP SDK futures are `!Send`).
- stderr lines forwarded as status events to orchestrator.
- Follow-up prompt polling with child-process death detection via oneshot channel.
- `kill_on_drop(true)` ensures the agent subprocess dies with the bridge.
- Credentials injected into spawned `Command` environment.

#### 3. Worker HTTP Client (`api.rs` — WorkerHttpClient)

Shared HTTP client for all worker modes:
- Bearer token from `IRONCLAW_WORKER_TOKEN` env var (32 bytes, hex-encoded).
- Timeouts: 10s connect, 120s request.
- Endpoints: `get_job`, `report_status`, `report_complete`, `post_event`, `poll_prompt`, `fetch_credentials`.
- LLM proxy: `llm_complete` and `llm_complete_with_tools` (transparent forwarding, same request/response shapes).

#### ProxyLlmProvider (`proxy_llm.rs`)

Thin `LlmProvider` implementation forwarding to `WorkerHttpClient`. Returns zero cost (orchestrator tracks real cost). Clean abstraction — the worker code is completely unaware of which actual LLM backend is used.

### Docker Sandbox (`sandbox/` — 3,411 lines)

#### Architecture

```
SandboxManager
  ├── ContainerRunner (Docker lifecycle: create, start, wait, collect, cleanup)
  ├── HttpProxy (network access control on host)
  │   ├── DomainAllowlist (exact + wildcard pattern matching)
  │   ├── DefaultPolicyDecider (allow → credential lookup → deny)
  │   └── CredentialResolver (env-based secret lookup)
  └── DockerDetection (platform-aware availability + install guidance)
```

#### Sandbox Policies

| Policy | Filesystem | Network | Root FS | Use Case |
|--------|-----------|---------|---------|----------|
| `ReadOnly` | `/workspace:ro` | Proxied | Read-only | Explore code, fetch docs |
| `WorkspaceWrite` | `/workspace:rw` | Proxied | Read-only | Build, test, edit |
| `FullAccess` | `/workspace:rw` + `/tmp:rw` | Direct | Writable | Direct execution (no sandbox) |

#### Container Hardening

- **UID 1000** (non-root user)
- **cap_drop: ALL**, cap_add: CHOWN only
- **`no-new-privileges:true`** security opt
- **Read-only root filesystem** (except FullAccess policy)
- **tmpfs mounts**: `/tmp` (512MB), cargo registry (1GB)
- **Memory**: 2GB default (configurable via `ResourceLimits`)
- **CPU**: 1024 shares default
- **Auto-remove**: `--rm` flag + explicit force-cleanup in finally block
- **Network**: Docker bridge mode with proxy env vars (`http_proxy`/`https_proxy`) pointing to host
- **Proxy host resolution**: `172.17.0.1` on Linux (docker bridge gateway), `host.docker.internal` on macOS/Windows (Docker Desktop)

#### HTTP Proxy (`proxy/http.rs`)

Host-level proxy intercepting all container network traffic:

- **HTTP requests** — Forwarded after policy decision. Credential injection supported (Bearer, header, query param).
- **HTTPS (CONNECT)** — Bidirectional TCP tunnel with 30-minute hard timeout. Credential injection **not possible** through CONNECT tunnels (TLS encrypted) — documented limitation. Containers needing authenticated HTTPS must fetch credentials via the orchestrator's `/worker/{id}/credentials` endpoint.
- **Hop-by-hop headers** stripped during forwarding.
- **Request counter** for observability.

#### Domain Allowlist (`proxy/allowlist.rs`)

- Exact match + wildcard patterns (`*.example.com`).
- Wildcards match the base domain AND all subdomains.
- Case-insensitive matching.
- Empty allowlist denies everything (fail-closed).

#### Policy Decision Engine (`proxy/policy.rs`)

`DefaultPolicyDecider` decision flow:
1. Check domain against allowlist → deny if not matched.
2. Check credential mappings → most specific path prefix wins, tie-broken alphabetically on `secret_name`.
3. Return `Allow`, `Deny{reason}`, or `AllowWithCredentials{secret_name, location}`.

Credential injection locations supported: `AuthorizationBearer`, `Header{name, prefix}`, `QueryParam{name}`.
Not yet supported: `AuthorizationBasic`, `UrlPath` (documented limitations).

#### Docker Detection (`detect.rs`)

Platform-aware proactive detection:
- **Binary check**: `which docker` (Unix) / `where docker` (Windows).
- **Daemon check**: `connect_docker()` + ping.
- **Windows fallback**: CLI-based `docker version --format` check if named pipe unavailable.
- Provides platform-specific install and start hints.

#### Orphaned Container Reaper (`orchestrator/reaper.rs`)

Background task preventing zombie containers:
- Scans Docker every 5 min (default) for `lunarwing.job_id` labeled containers.
- Checks if job is still active in `ContextManager`.
- Reaps containers older than 10 min (default) with inactive/missing jobs.
- Graceful: validates `scan_interval > 0` to prevent `tokio::time::interval` panic.
- `MissedTickBehavior::Skip` prevents scan bursts after delays.

---

## 9. Workspace & Memory System

### Architecture

Filesystem-like hierarchical memory with hybrid search:
- **Full-text search** — BM25 scoring
- **Semantic search** — Vector embeddings (cosine similarity)
- **Fusion** — Reciprocal Rank Fusion (RRF) combining both

### Embedding Providers

- OpenAI, NearAI, Ollama (local)
- Cached embedding provider with configurable cache settings

### Memory Layers

- Privacy-aware layer system (`workspace/layer.rs`)
- Content redirection (e.g., sensitive content from shared → private layer)
- `WriteResult` reports actual layer for transparency

### Prompt Injection Defense

**System prompt files** (`SOUL.md`, `AGENTS.md`, `MEMORY.md`, etc.) are scanned on write:
- `Sanitizer` detects injection patterns
- High-severity matches → write **rejected** with descriptions
- Lower-severity → logged as warnings, write allowed
- Shared `LazyLock<Sanitizer>` instance avoids rebuilding pattern matchers

### Document Extraction

- Middleware pipeline: audio transcription → document text extraction
- Extracted documents stored in workspace under `documents/YYYY-MM-DD/filename`
- Filename sanitization: path separators replaced, leading dots stripped

---

## 10. Safety & Security

### `lunarwing_safety` Crate

Re-exported as `crate::safety`. Provides:
- `SafetyLayer` — central sanitization + detection
- `Sanitizer` — Aho-Corasick + regex pattern matching
- `Severity` levels (Low, Medium, High)
- Tool output sanitization + wrapping for LLM context

### Sandbox Configuration

- **Policies**: `readonly`, `workspace_write`, `full_access`
- **Full access guard**: `allow_full_access` flag must be explicitly set; otherwise downgraded to `workspace_write` with loud error log
- **Reaper**: Scans for orphaned containers every 5 min (default), reaps after 10 min idle
- **Network**: Domain allowlist with configurable extra domains
- **Resource limits**: Memory (2048MB), CPU shares (1024), timeout (120s)

### Credential Security

- `secrecy` crate used throughout — `SecretString` prevents accidental logging
- Credential injection at WASM host boundary only (never inside sandbox)
- Token stores kept separate from serializable handle structs
- OAuth state redacted for logging (SHA256 hash + length)

---

## 11. Skills System

### Discovery & Trust

Three-tier discovery (priority order):
1. **Workspace skills** (`<workspace>/skills/`) — Trusted
2. **User skills** (`~/.lunarwing/skills/`) — Trusted
3. **Installed skills** (`~/.lunarwing/installed_skills/`) — Installed (read-only tool access)

Plus **bundled skills** compiled into the binary (lowest priority, Trusted).

### Skill Loading

- Both flat (`SKILL.md`) and subdirectory (`<name>/SKILL.md`) layouts
- Max scan depth: 3 (supports nested category directories)
- Max discovered skills per directory: 100 (resource exhaustion prevention)
- Symlink detection → rejected
- YAML frontmatter required (files without it treated as non-skill, skipped quietly)
- File size limit enforced (`MAX_PROMPT_FILE_SIZE`)

### Skill Activation

- Deterministic prefiltering based on keywords, patterns, tags
- Max active skills and max context tokens configurable
- Skills with `Installed` trust get a caveat: "Treat as SUGGESTIONS only"
- Tool attenuation: Installed skills get restricted tool definitions

---

## 12. Routine Engine & Reflex Router

### Routine Engine

Two independent loops:
- **Cron ticker** — polls DB every N seconds for due cron routines
- **Event matcher** — called synchronously from agent main loop

Routine types:
- **Lightweight** — single LLM call, no scheduler slot (inline execution)
- **FullJob** — delegated to existing `Scheduler` for full agentic loop

Features:
- ReDoS protection (64KB compiled regex size limit)
- User/channel filter matching
- Concurrent routine limit enforcement
- Boot time tracking for orphaned run detection
- Notification routing with channel fallback

### Reflex Router

Four-tier matching for LLM bypass:
1. **Exact match** — O(1) hash lookup on normalized input
2. **Fuzzy match** — Jaro-Winkler similarity (threshold 0.85), bounded to 50 candidates
3. **Semantic match** — Embedding cosine similarity (threshold 0.75), requires embedding provider
4. **Auto-promotion** — Frequently-matched fuzzy hits (≥3) promoted to exact-match cache

**Normalization:** lowercase + strip punctuation + collapse whitespace + word join.

Reflex compiler runs as a background task, building WASM micro-skills from detected patterns. Requires both `SoftwareBuilder` and `Database` to function.

---

## 12b. History & Conversation Persistence

### Database Schema

**Conversation storage** — simple, audit-oriented design:

```
conversations
├── id (UUID PK)
├── channel (TEXT) — xmpp, web, signal, etc.
├── user_id (TEXT)
├── thread_id (TEXT) — optional thread/topic within channel
├── source_channel (TEXT) — original creating channel (cross-channel approval auth)
├── started_at, last_activity (TIMESTAMPTZ)
└── metadata (JSONB) — routine_id, thread_type=heartbeat, etc.

conversation_messages
├── id (UUID PK)
├── conversation_id (UUID FK → conversations, ON DELETE CASCADE)
├── role (TEXT) — user / assistant / system
├── content (TEXT)
└── created_at (TIMESTAMPTZ)
```

**Uniqueness constraints (migration V11):**
- One routine conversation per user per `routine_id` (partial unique index on metadata).
- One heartbeat conversation per user (partial unique index where `thread_type = 'heartbeat'`).
- Prevents TOCTOU races in `get_or_create_*_conversation` functions.

### What Gets Stored

| Table | Purpose | Key Fields |
|-------|---------|------------|
| `conversations` | Chat sessions per channel+user | channel, user_id, metadata |
| `conversation_messages` | Every user/assistant/system message | role, content, created_at |
| `agent_jobs` | Jobs (`source='direct'` or `source='sandbox'`) | title, status, budget, cost, timestamps |
| `job_actions` | Every tool call within a job | tool_name, input, output_raw, output_sanitized, cost, duration |
| `llm_calls` | Every LLM API call | provider, model, input/output tokens, cost, purpose |
| `job_events` | Streaming events from workers/bridge | event_type, data (JSONB) |
| `estimation_snapshots` | Estimated vs actual cost/time | category, tool_names, estimated/actual values |
| `routine_runs` | Execution records for cron/event routines | trigger_type, status, tokens_used |
| `repair_attempts` | Self-repair history | target_type, target_id, diagnosis, action_taken |

### Design Philosophy

Conversation storage is **deliberately simple** — role + content with timestamps. No structured tool-call metadata in the message table; that detail lives in `job_actions`. This separates the **audit trail** (what was said) from the **execution record** (what was done).

`agent_jobs` uses a `source` column to distinguish:
- `source = 'direct'` — normal agent-initiated jobs.
- `source = 'sandbox'` — container/sandbox jobs with `project_dir`, `job_mode`, `success`, `credential_grants_json`.

Stale sandbox jobs (status `running`/`creating` at startup) are marked `interrupted` via `cleanup_stale_sandbox_jobs()`.

### Memory System (Separate from History)

Workspace memory uses a filesystem-like model with hybrid search, stored separately from conversation history:

```
memory_documents
├── user_id, agent_id (NULL = shared across agents)
├── path (TEXT) — "context/vision.md", "daily/2024-01-15.md"
├── content (TEXT)
└── metadata (JSONB)

memory_chunks
├── document_id (FK → memory_documents)
├── chunk_index (INT)
├── content (TEXT)
├── content_tsv (TSVECTOR, auto-generated) — BM25 full-text search
└── embedding (VECTOR(1536)) — pgvector for semantic search
```

- `list_workspace_files()` PL/pgSQL function performs virtual directory listing from flat paths.
- `chunks_pending_embedding` view tracks chunks needing embedding generation.
- HNSW index on embeddings (`m=16, ef_construction=64`) for fast approximate nearest neighbor search.
- Embedding dimension is flexible (migration V9) — not hardcoded to 1536.

### Analytics & Learning Loop

The `analytics.rs` module provides aggregation queries:

- **Job stats**: total/completed/failed counts, success rate, avg duration, avg/total cost.
- **Tool stats**: per-tool call counts, success rates, avg duration, total cost — identifies unreliable or expensive tools.
- **Estimation accuracy**: cost error rate and time error rate aggregated from `estimation_snapshots` where actuals are populated. This is a **calibration feedback loop** — historical estimation accuracy can be used to improve future estimates.
- **Category history**: historical tool/cost/time data per job category for pattern matching against new jobs.

### Store Implementation

`Store` wraps a `deadpool-postgres` connection pool. All methods are async, returning `DatabaseError` on failure. The store is PostgreSQL-only (feature-gated `postgres`), used alongside the dual-backend `Database` trait from `db/mod.rs` which supports both PostgreSQL and libSQL.

---

## 13. Self-Repair & Resilience

### Stuck Job Detection

- `find_stuck_jobs_with_threshold()` polls context manager
- Jobs in `InProgress` are transitioned to `Stuck` before repair
- Stuck duration measured from most recent Stuck transition (not from `started_at`) — correct behavior

### Repair Flow

```
Detect → RepairAttempt → Result
                            ├── Success → notify user
                            ├── Failed → notify user (permanent)
                            ├── ManualRequired → notify user
                            └── Retry → suppress notification (avoid spam)
```

### Broken Tool Detection

- Failure count + timestamps tracked
- Builder can attempt automatic rebuild
- Repair attempts capped at `max_repair_attempts`

### Operational Timing

All operations wrapped in `tokio::time::timeout`:
- `detect_stuck_jobs`
- `repair_stuck_job`
- `detect_broken_tools`
- `repair_broken_tool`

Prevents a single slow operation from blocking the repair loop.

---

## 14. Database Layer

### Dual Backend

Feature-flagged:
- **PostgreSQL** (default) — `deadpool-postgres` + `tokio-postgres` with TLS support
- **libSQL** — Turso's SQLite fork for embedded/edge deployment

Single `Database` trait abstracts both backends. Backend-specific handles (`DatabaseHandles`) retained for satellite stores (e.g., `SecretsStore`).

### Migration Strategy

- `connect_from_config()` — connects + runs migrations
- `connect_without_migrations()` — wizard/testing connectivity validation
- PostgreSQL version + pgvector prerequisite checks

### Secrets Store

Backend-specific implementations:
- `PostgresSecretsStore`
- `LibSqlSecretsStore`

Both use `SecretsCrypto` for encryption at rest.

---

## 15. Web Gateway

### Axum Server (`channels/web/server.rs`)

**Routes:**
- Chat (WebSocket + REST)
- Memory (list, read, write, search, tree)
- Jobs (list, detail, events, cancel, restart, prompt, files)
- Routines (list, detail, toggle, trigger, delete)
- Skills (list, search, install, remove)
- Health checks
- Static file serving

**Security features:**
- `PerUserRateLimiter` — fail-open on lock poisoning (recovers gracefully)
- `PerUserWorkspacePool` — isolated workspaces with per-user scopes
- CORS + response header layers
- Default body limit
- Auth middleware on protected routes

---

## 16. Extensions System

### Unified Abstraction

Three extension kinds under one umbrella:
- **McpServer** — hosted MCP server, HTTP transport, OAuth 2.1
- **WasmTool** — sandboxed WASM module, capabilities-based auth
- **WasmChannel** — WASM channel module with hot-activation

### Lifecycle

```
Search → Install → Authenticate → Activate
```

- **Discovery**: Built-in registry + online discovery
- **Installation**: Download WASM, build from source, or configure MCP URL
- **Authentication**: DCR (zero-config), OAuth pre-configured, or capabilities auth
- **Activation**: Register tools/channels with appropriate managers

### Auth Status Tracking

Typed enum: `Authenticated | NoAuthRequired | AwaitingAuthorization | AwaitingToken | NeedsSetup`

---

## 17. Engine v2 Bridge

### Strategy C: Parallel Deployment

`ENGINE_V2=true` environment variable routes messages through the new engine instead of the v1 agentic loop. **Zero risk** — existing behavior unchanged when flag is off.

### Bridge Adapters

| Adapter | Purpose |
|---------|---------|
| `LlmBridgeAdapter` | Wraps `LlmProvider` as `lunarwing_engine::LlmBackend`. Provider selection by depth (cheap for depth > 0) |
| `EffectBridgeAdapter` | Wraps `ToolRegistry` + `SafetyLayer` as `EffectExecutor`. Enforces all v1 security at the boundary |
| `HybridStore` | Wraps `Database` as engine `Store` |
| `AuthManager` | Centralized pre-flight credential checks |

### Effect Adapter Security

All v1 security controls enforced at the adapter boundary:
- Tool approval (with auto-approve tracking + rollback on resume failure)
- Output sanitization (`sanitize_tool_output`)
- Hook interception (`BeforeToolCall`)
- Parameter redaction
- Per-user, per-tool rate limiting
- Per-step tool call counting

### Gate System

`PendingGate` for approval/auth pauses:
- `ResumeKind::Approval { allow_always }` — user yes/no
- `ResumeKind::Authentication { credential_name, instructions, auth_url }`
- SSE broadcast + channel status update on gate creation
- Resumed actions get "already executed" context message to prevent double-execution

---

## 18. Hooks System

### Six Interception Points

| Hook | When | Use Case |
|------|------|----------|
| `BeforeInbound` | Before processing user message | Content filtering, modification |
| `BeforeToolCall` | Before tool execution | Access control, audit |
| `BeforeOutbound` | Before sending response | Content transformation, suppression |
| `OnSessionStart` | New session | Initialization, profiling |
| `OnSessionEnd` | Session ends | Cleanup, logging |
| `TransformResponse` | Before turn completion | Response rewriting |

### Execution Model

- Priority-ordered (lower number = higher priority)
- Each hook can: pass through, modify content, or reject
- Failure mode configurable per-hook (fail-open errors logged in registry)
- Bundled hooks with registration summary
- Bootstrap hooks from workspace configuration

---

## 19. Configuration

23+ configuration modules covering every subsystem:

| Module | Scope |
|--------|-------|
| `agent.rs` | Agent behavior (timeouts, thresholds, iteration limits) |
| `channels.rs` | Channel-specific config |
| `database.rs` | Backend selection, connection params |
| `llm.rs` | Provider config, model selection |
| `sandbox.rs` | Docker sandbox policies |
| `workspace.rs` | Memory system, search config |
| `skills.rs` | Skill limits, activation |
| `routines.rs` | Routine engine config |
| `heartbeat.rs` | Heartbeat interval, quiet hours |
| `hygiene.rs` | Workspace hygiene rules |
| `embeddings.rs` | Embedding provider config |
| `wasm.rs` | WASM runtime limits |
| `safety.rs` | Safety layer config |
| `search.rs` | Search fusion strategy |
| `secrets.rs` | Encryption config |
| `tunnel.rs` | Tunnel configuration |
| `oauth.rs` | OAuth provider config |
| `acp.rs` | ACP configuration |

### Resolution Pattern

Consistent pattern: Settings file → Environment variable override (with helpers `parse_bool_env`, `parse_optional_env`, `parse_string_env`).

---

## 20. Strengths

1. **Trait-driven design** — `LlmProvider`, `Database`, `Tool`, `LoopDelegate`, `SelfRepair`, `EmbeddingProvider` — clean abstractions with multiple implementations

2. **Defense-in-depth security** — WASM sandbox + safety layer + prompt injection detection + credential isolation + parameter redaction + output sanitization + network allowlisting

3. **Unified agentic loop** — `LoopDelegate` trait eliminates code duplication across chat/job/container contexts while preserving consumer-specific behavior

4. **Resilient by design** — circuit breakers, failover, cooldowns, self-repair, stuck job detection, hard-kill grace, orphaned container reaper

5. **Cost guardrails** — daily budget, hourly rate limit, per-user daily budget, per-model token tracking, budget-exceeded short-circuit

6. **Lock-free patterns where appropriate** — cooldown tracking (atomics), rate limiter (CAS loop), budget exceeded flag

7. **Defensive compaction** — turns preserved on write failure, never silently lost

8. **Comprehensive testing** — extensive unit tests visible inline (agent_loop, app, reasoning, session, reflex, routine_engine)

9. **Documentation discipline** — doc comments explain not just *what* but *why*, with inline security constraint tables, ASCII architecture diagrams, and rationale for non-obvious decisions

10. **Engine v2 migration strategy** — flag-gated parallel deployment with full v1 security enforcement at the bridge boundary

---

## 21. Concerns & Technical Debt

### Structural

1. **Monolithic `ic` crate** — 366 files in a single crate. Long compile times, unclear ownership boundaries. Consider splitting into workspace members (e.g., `lunarwing-agent`, `lunarwing-channels`, `lunarwing-tools`, `lunarwing-llm`).

2. **Large files** — `agent_loop.rs` (>2k lines), `dispatcher.rs`, `router.rs`, `external_worker.rs` are candidates for further decomposition.

3. **Engine v1/v2 duality** — The bridge layer adds complexity. Clear migration timeline and deprecation plan would reduce maintenance burden.

### Concurrency

4. **`provider_for_task` Mutex** — In `FailoverProvider`, the `Mutex<HashMap<task::Id, usize>>` for per-task provider tracking could become contended under high concurrency. Consider `DashMap` or thread-local fallback.

5. **Session locking** — `Arc<Mutex<Session>>` with async — potential for lock-held-across-await issues if not carefully managed. The existing code appears careful, but this is a recurring audit need.

### Error Handling

6. **Error type proliferation** — `Error`, `JobError`, `LlmError`, `ChannelError`, `ConfigError`, `DatabaseError`, `WorkspaceError`, `RoutineError`, `WasmError`, `OrchestratorError`, `RepairError` — many error types with sometimes overlapping domains. Consider unification or clearer hierarchy.

### Observability

7. **Tracing is good but inconsistent** — Some modules have rich structured tracing (agent_loop, LLM), others have minimal. Standardizing span/key conventions would improve observability tooling.

### Missing/Incomplete

8. **TOCTOU in bind mount validation** — Documented and accepted for single-tenant, but flagged for future multi-tenant hardening.

9. **`smart_routing.rs` scoring weights are hardcoded** — The 13-dimension weights are in `Default`. Runtime configurability would enable tuning per-deployment.

10. **Reflex compiler requires `SoftwareBuilder`** — Falls back gracefully when absent, but the WASM-building dependency for reflex pattern compilation is heavy for what could be a simpler caching mechanism.

---

## 22. Recommendations

### Short-term

1. **Split the `ic` crate** into a Cargo workspace with focused members. Start with extracting `lunarwing-channels` and `lunarwing-tools` as they have the clearest boundaries.

2. **Document the Engine v2 migration plan** — timeline, milestones, feature parity checklist, and deprecation path for v1 code.

3. **Standardize tracing conventions** — Define span naming conventions and required keys (job_id, user_id, channel, thread_id) in a contributing guide.

### Medium-term

4. **Unify or layer error types** — Consider a top-level `LunarWingError` enum with variants, or a clear error-conversion matrix.

5. **Make smart routing weights configurable** — Allow per-deployment tuning via config file.

6. **Add integration test coverage for the bridge layer** — The Engine v2 adapters are critical paths that need end-to-end testing.

### Long-term

7. **Multi-tenant hardening** — If the project moves beyond single-tenant, the TOCTOU gaps in bind mount validation and the per-user workspace isolation need formal verification.

8. **Reflex router simplification** — Consider whether the WASM compilation step for reflex patterns provides enough value vs. a simpler in-process caching layer.

9. **Observability dashboard** — The structured tracing data could feed a Grafana/OpenTelemetry dashboard for real-time agent behavior monitoring.

---

*Review by SweetieBot 🦄 — because even robot ponies can read 170k lines of Rust when the context window is big enough.*

*stamps hooves* ⚡
