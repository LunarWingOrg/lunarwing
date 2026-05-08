# BUG: Main agent becomes unresponsive after subagent worker container exits

**Severity:** High
**Found:** 2026-05-08 during v1.0.2 pre-release testing
**Status:** Open
**Affects:** Multi-tenant deployments with sandbox worker containers

## Symptoms

1. User asks the agent to spawn a subagent (sandboxed Docker job)
2. Worker container (`lunarwing-worker` image) starts and runs successfully
3. Worker container exits (exit code 0)
4. Main agent stops responding — no output flows back to user via XMPP or gateway
5. Restarting the main daemon (`restart-tenant`) immediately restores responsiveness

## Reproduction

1. Deploy a tenant via `lunarwing-mt-admin.sh` with `SANDBOX_IMAGE=lunarwing-worker`
2. Send a message via XMPP asking the agent to spawn a subagent
3. Observe: worker container starts, runs, exits cleanly
4. Observe: main agent produces no further responses

## Root Cause Analysis

The bug is a race condition in the job completion pipeline. The main agent relies on an in-memory broadcast channel to learn that a container job finished, but that event can be lost.

### Normal flow (expected)

1. `create_job` tool (`src/tools/builtin/job.rs`) spawns a container and a background job monitor via `spawn_job_monitor_with_context` (`src/agent/job_monitor.rs`)
2. Monitor subscribes to a `broadcast::Receiver` waiting for `SseEvent::JobResult`
3. Worker container runs, calls `POST /worker/{job_id}/event` with the result
4. Orchestrator broadcasts `SseEvent::JobResult`
5. Job monitor receives event, transitions job state in `ContextManager`, exits

### Actual flow (broken)

1. Steps 1-3 same as above
2. Worker calls `POST /worker/{job_id}/complete` → `report_complete` (`src/orchestrator/api.rs:225-274`)
3. `report_complete` calls `job_manager.complete_job()` (`src/orchestrator/job_manager.rs:523-578`)
4. **`complete_job` updates the container handle state to `Stopped` but does NOT update `ContextManager`** — the job stays `InProgress` in memory
5. The broadcast event either:
   - Was sent before the monitor subscribed (race)
   - Was dropped due to channel capacity
   - Was never sent via the correct path
6. Job monitor blocks forever in `event_rx.recv().await` with no timeout
7. The stuck `InProgress` job holds a slot in `ContextManager`, potentially blocking all future job creation when `max_jobs` is reached

### Why restart fixes it

Restarting the daemon clears the in-memory `ContextManager`, freeing the stuck job slot. The database already shows the job as completed — only the in-memory state is wrong.

## Affected Code

| File | Issue |
|------|-------|
| `src/orchestrator/job_manager.rs:523-578` | `complete_job()` does not update `ContextManager` |
| `src/agent/job_monitor.rs:71-163` | `spawn_job_monitor_with_context` has no timeout on `event_rx.recv().await` |
| `src/tools/builtin/job.rs:483-521` | Monitor spawned fire-and-forget with no watchdog |
| `src/orchestrator/api.rs:225-274` | `report_complete` updates DB but not in-memory state |

## Proposed Fix

### 1. Update ContextManager in `complete_job` (primary fix)

In `job_manager.rs`, after updating the container handle state, also call `context_manager.update_context()` to transition the job to its final state. This ensures the job transitions even if the broadcast is lost.

### 2. Add timeout to job monitor (defense in depth)

In `job_monitor.rs`, wrap `event_rx.recv().await` in `tokio::time::timeout()` using the container's configured timeout plus a grace period (e.g., `SANDBOX_TIMEOUT_SECS + 30`). On timeout, transition the job to `Stuck` or `Failed` and log a warning.

### 3. Subscribe before container start (race prevention)

Ensure the broadcast receiver is created and subscribed BEFORE the container is started, not after. This eliminates the window where the container can complete before the monitor is listening.

## Workaround

Restart the affected tenant's daemon:

```bash
sudo env PATH="$PATH" scripts/lunarwing-mt-admin.sh restart-tenant <name>
```

## Notes

- Core features (XMPP/OMEMO, Gotify, routines) are unaffected
- Only impacts sandbox worker container jobs (subagent spawning)
- Database state is correct — only in-memory `ContextManager` is stale
- Not a release blocker for v1.0.2; tracked for post-release fix
