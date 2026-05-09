## LunarWing v1.0.3

Bug fix release focused on worker sub-agent reliability, memory operations, and WASM channel stability.

### Bug Fixes

- **Worker sub-agent jobs no longer hang forever.** Three layers of protection:
  - Container exit watcher (bollard) force-completes jobs when the container exits without calling `/complete`
  - Direct ContextManager update in `report_complete` — jobs transition out of InProgress even if the broadcast is missed
  - Job monitor channel-close handling transitions ContextManager to Failed instead of silently breaking
- **Worker loop termination on error path.** When a tool call fails (e.g., Permission denied), the worker now exits after 3 consecutive all-fail iterations instead of retrying forever
- **Worker loop termination on success path.** Post-work LLM chatter (`<suggestions>`, "would you like me to", etc.) and 3+ consecutive text-only responses now trigger clean exit
- **`memory_write` no longer crashes when layer is null.** Graceful fallback instead of panic
- **WASM channel polling reliability improvements.** Fixes for daemon occasionally stopping XMPP bridge polling
- **Worker Dockerfile:** added cmake for libsignal-protocol-sys build

### Multi-Tenancy

- Configurable per-tenant orchestrator port in MT admin script (prevents port collision between tenants)
- `patch-env` / `patch-env-all` commands for updating existing tenant env files
- Orchestrator port displayed in `list-tenants` and `status-tenant` output

### Other

- Watchdog scripts updated for OpenRC and systemd
- Bug documentation and proposed fixes added for known issues
- Test compilation fixes across multiple modules
