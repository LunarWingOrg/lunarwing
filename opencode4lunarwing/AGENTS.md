# Agent Rules — opencode4lunarwing

## What This Is

Persistent container worker for upstream opencode, following the same pattern as `lunarcode4lunarwing`. The WebSocket bridge is TypeScript/Bun and uses `@opencode-ai/sdk/v2` to communicate with the internal opencode headless server.

## Key Files

- `scripts/lunarwing_bridge.ts` — The WebSocket server/client. Changes here affect protocol behavior.
- `scripts/opencode_task_executor.ts` — Task execution via opencode SDK. Controls session creation, permissions, event streaming.
- `scripts/lunarwing_runtime.ts` — Shared types and envelope helpers. Keep in sync with `agent_comm_protocol.json`.
- `entrypoint.sh` — Startup orchestration. Three modes: websocket, cli, acp.
- `config/opencode.json` — Mounted into container; controls LLM provider, plugins, MCP servers.

## Protocol Compatibility

The `lunarwing-agent-v1` WebSocket subprotocol (legacy alias `ironclaw-agent-v1` still accepted for one deprecation cycle) is shared with nanocode and pebble workers. Changes to `agent_comm_protocol.json` or envelope format must stay backward-compatible or be coordinated across all workers.

## Build Notes

The Dockerfile clones the sst/opencode repo at build time. For reproducible builds, pin a specific commit by changing the `git clone` line in the Dockerfile.

## Do Not

- Break the `lunarwing-agent-v1` envelope format
- Expose the internal opencode serve port (4096) externally
- Store secrets in config files (use env vars with `{env:VAR}` syntax)
- Remove the health server — orchestration depends on it
