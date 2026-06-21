# Draft: External Worker System Improvements

## Requirements (confirmed)
- User wants to find improvement opportunities for external worker systems (nanocode, pebble, codex)

## Research Findings

### Architecture Overview
- **ExternalWorkerManager** (`src/orchestrator/external_worker.rs`): Manages WebSocket connections to external workers via `ironclaw-agent-v1` protocol
- **ContainerJobManager** (`src/orchestrator/job_manager.rs`): Docker container lifecycle, has `JobMode::External(name)` variant
- **CreateJobTool** (`src/tools/builtin/job.rs`): LLM tool that routes to either Docker sandbox or external worker via `mode` parameter
- **ExternalWorkerConfig** (`src/config/sandbox.rs`): name, url, auth_token, timeout_ms
- **SandboxReaper** (`src/orchestrator/reaper.rs`): Only reaps Docker containers, NOT external worker connections
- **ACP Bridge** (`src/worker/acp_bridge.rs`): Agent Client Protocol bridge for spawning ACP-compliant agents inside containers

### Identified Improvement Areas

1. **No connection pooling/reuse** — Each task creates a new WebSocket connection. No persistent connection management for "persistent" workers.

2. **No health checking/heartbeat** — Worker liveness only detected on connection attempt (15s timeout). No periodic health pings, no reconnect logic.

3. **No retry logic** — Connection failures and timeouts return errors immediately. No backoff/retry for transient failures (routines system has this, workers don't).

4. **No load balancing** — Workers keyed by name only. Can't configure multiple instances of same worker type for round-robin/least-connections.

5. **No credential grants for external workers** — Docker sandbox supports `CredentialGrant` injection; external worker protocol has no credential passing mechanism.

6. **No project directory/workspace** — External worker jobs set `project_dir: String::new()`. No persistent storage or workspace isolation.

7. **Stringly-typed status** — `ExternalTaskResult.status` is `String` compared with `== "success"`. Should be enum.

8. **No metrics/observability** — No tracking of response times, success rates, queue depth. Docker sandbox has iteration tracking; external workers don't.

9. **Reaper doesn't cover external workers** — If process restarts, `active_handles` is lost. No cleanup of stale external worker connections.

10. **No cancellation guarantee** — `cancel_task()` sends cancel envelope but no acknowledgment or timeout on the cancel itself.

11. **Minimal protocol** — `ironclaw-agent-v1` lacks: capabilities advertisement, context/workspace sharing (context field always `{}`), structured streaming, multi-turn conversation.

12. **No TLS/WSS config** — No custom CA support, no certificate validation options for self-hosted workers.

13. **All-or-nothing timeout** — Single timeout for entire task. No intermediate timeouts (first progress, idle between messages).

14. **No queueing/backpressure** — Multiple tasks to same worker create concurrent WebSocket connections. No queue, no backpressure.

15. **Protocol mismatch potential** — README says Pebble uses "NDJSON event streaming" but orchestrator expects WebSocket. Possible inconsistency.

## Scope Boundaries
- INCLUDE: Improvements to the orchestrator-side external worker management
- INCLUDE: Protocol enhancements
- INCLUDE: Observability and resilience improvements
- TBD: Worker container-side changes (separate repos: codex4lunarwing, lunarcode4lunarwing, pebble4lunarwing)

## Open Questions
- Which improvement areas are highest priority for the user?
- Should we focus on orchestrator-side only, or also worker container-side?
- Is this a "pick the top 3-5 improvements" or "comprehensive overhaul"?
