# BUG: Agent loop blocks on synchronous (wait=true) external worker jobs

**Severity:** Medium
**Found:** 2026-07-03 during v1.1.8 live validation on tenant `orca`
**Status:** Open (feature request / architectural improvement)
**Affects:** Agent loop, orchestrator/external worker manager. All external worker types (opencode, nanocode, pebble) and the built-in sandbox worker.

## Symptoms

1. Agent dispatches a job to an external worker via `create_job` with `wait=true`
2. The entire conversational turn blocks until the worker job completes
3. For a multi-minute worker task (e.g. a 4.5-minute repo analysis), the agent sits idle — it cannot:
   - Perform other actions in parallel
   - Service other conversations or channels
   - Kick off additional worker jobs concurrently
4. The user receives no intermediate feedback until the job completes

## Reproduction

1. Deploy a tenant with an external worker (opencode/nanocode/pebble)
2. Send a prompt that triggers a long-running worker task: "Use the opencode worker to analyze the repo structure and summarize each directory"
3. Observe: the agent produces no output and cannot respond to other messages until the worker job completes

## Root Cause Analysis

The agent's tool execution loop calls `create_job` with `wait=true`, which synchronously awaits the worker result. The existing `wait=false` path exists and returns a `job_id` immediately, but there is no mechanism for the agent to:

- Poll the job status mid-conversation without surrendering its turn
- Receive a completion notification asynchronously while continuing other work
- Manage multiple in-flight jobs simultaneously

This is an agent-loop / orchestrator-level architectural limitation, not a worker bug. The `ExternalWorkerManager` (`ic/src/orchestrator/external_worker.rs`) is already generic and capable of dispatching async jobs — the bottleneck is in how the agent loop consumes the result.

## Impact

- **Throughput:** Single long worker task blocks the entire agent — no parallelism
- **User experience:** No intermediate feedback during long worker tasks; user must wait silently
- **Multi-worker:** Cannot leverage multiple worker containers (e.g. opencode + nanocode) concurrently

## Potential Fixes

1. **Async job registry:** Allow the agent to fire `wait=false` jobs and register them in a per-session job registry. The agent can poll the registry mid-conversation (between tool calls, between turns) without blocking. Completed jobs surface their results when polled.
2. **Non-blocking tool wrapper:** Wrap `create_job` so `wait=true` is handled by polling internally with yield points, allowing the agent loop to interleave other work (respond to other channels, run routines).
3. **SSE/streaming results:** Have workers stream intermediate results back via SSE so the agent can relay progress to the user while the job continues.

## Notes

- This is as much a feature request as a bug — the current synchronous behavior is the designed default, but the throughput limitation becomes acute with multi-minute external worker tasks
- Related to the broader "concurrent agent capabilities" theme tracked in `docs/proposals/COOL_THINGS_THAT_HERMES_AGENT_HAS.md`
