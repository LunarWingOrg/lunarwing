# LunarWing v1.0.4 Release Notes (2026-05-09)

## Summary
Fixed async timeout issues and removed Claude Code mode. Added external worker support (nanocode), tokio timeouts for worker HTTP API, improved config validation.

## Changes

### External Worker Support
- Added `ExternalWorkerManager` in `ic/src/orchestrator/external_worker.rs`
- WebSocket client speaking `ironclaw-agent-v1` protocol
- `create_job` can use `mode: "nanocode"` (or any configured external worker name) to dispatch to a persistent worker instead of per-job Docker sandboxes
- Real-time progress streamed back via SSE
- Cancellation of active external worker tasks supported

### Timeout Fix
- Added Tokio timeouts for worker HTTP API endpoint calls to prevent hung requests

### Removed
- All Claude Code mode implementation (bridge/config/subcommand/Dockerfile bits) removed in favor of agnostic external-worker approach

### Config Fixes
- TOML merge validation improvements
- Fixed duplicate `[sandbox]` table header issues

## Config Example
```toml
[[sandbox.external_workers]]
name = "nanocode"
url = "ws://localhost:9090/ws/agent"
timeout_ms = 300000
```

## Links
- Release: https://github.com/LunarWingOrg/lunarwing/releases/tag/v1.0.4

