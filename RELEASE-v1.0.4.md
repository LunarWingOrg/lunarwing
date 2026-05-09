# Release Notes for LunarWing v1.0.4

**Release Date:** 2026-05-09

## Overview

This release introduces external worker support, enabling LunarWing to dispatch coding tasks to persistent containerized workers via WebSocket. The nanocode worker is the first supported external worker, providing an alternative to per-job Docker sandbox execution.

## New Features

### External Worker Support
- **ExternalWorkerManager** (`ic/src/orchestrator/external_worker.rs`): WebSocket client implementing the `ironclaw-agent-v1` protocol for communicating with persistent external workers
- **Configuration**: Add `[[sandbox.external_workers]]` entries to `config.toml` to register worker endpoints
- **Job routing**: `create_job` tool accepts `mode: "nanocode"` (or any configured worker name) to dispatch tasks externally
- **Progress streaming**: Real-time task progress streamed back via SSE events
- **Cancellation**: Support for canceling active external worker tasks

### Nanocode Worker Container
- New `nanocode4ironclaw/` directory containing a complete Docker-based nanocode worker
- TypeScript/Bun bridge implementing the `ironclaw-agent-v1` WebSocket subprotocol
- In-process SDK communication with nanocode headless server (no subprocess spawning)
- Health endpoint on port 8443 for orchestration readiness checks
- Supports three modes: WebSocket (persistent), CLI (one-shot), ACP (stdio bridge)

## Changes

### Removed
- **Claude Code mode**: Removed all Claude Code-specific worker implementation (`claude_bridge.rs`, `ClaudeCodeConfig`, CLI subcommand, Dockerfile npm install). This paves the way for an agnostic external worker approach.

### Improved
- **Timeouts**: Added tokio timeouts for worker HTTP API endpoint function calls to prevent hung requests
- **Config validation**: Enhanced TOML config merge validation to detect invalid logic and duplicate sandbox labels
- **Documentation**: Updated `AGENTS.md`, `CLAUDE.md`, and README with external worker architecture and setup instructions

### Fixed
- **Config merging**: Fixed duplicate `[sandbox]` table header issues in config TOML parsing
- **External worker config**: `ExternalWorkerConfig` now properly resolves from settings with validation

## Configuration Example

```toml
[sandbox]
enabled = true

[[sandbox.external_workers]]
name = "nanocode"
url = "ws://localhost:9090/ws/agent"
timeout_ms = 300000
```

## Known Issues

- Nanocode v1.2.28 has a schema validation bug where `PartID` prefix (`prt`) is incorrectly validated against `SessionID` fields. This is patched in the worker container via a `fn.ts` safeParse workaround.
- The nanocode worker config file must be named `nanocode.json` (not `opencode.json`) for the config loader to find it.

## Upgrade Notes

1. If you previously used Claude Code worker mode, migrate to the new external worker system
2. Build the nanocode worker image: `cd nanocode4ironclaw && docker compose build`
3. Add external worker configuration to your `config.toml`
4. Ensure your TensorZero gateway is accessible from the worker container

## Full Commit Log

20 commits since v1.0.3:

- Added ExternalWorker Mode to LunarWing
- Made full external agent pipeline work with nanocode worker
- Added nanocode worker Dockerfile and bridge implementation
- Removed Claude Code mode implementation
- Added tokio timeouts for worker HTTP endpoints
- Fixed config TOML merge validation
- Updated documentation (AGENTS.md, CLAUDE.md, README)

---

**Docker Images:**
- `lunarwing-worker:latest` (sandbox worker)
- `ironclaw-worker-nanocode:latest` (nanocode external worker)

**Binaries:**
- `lunarwing` (main daemon)
- `xmpp-bridge` (XMPP bridge service)
