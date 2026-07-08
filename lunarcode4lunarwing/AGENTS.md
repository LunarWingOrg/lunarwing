# Agent Rules — lunarcode4lunarwing

## What This Is

Persistent container worker for nanocode, following the same pattern as the other LunarWing workers (pebble, opencode). The WebSocket bridge is TypeScript/Bun (not Python) because nanocode has an SDK that can be used in-process.

## Key Files

- `scripts/lunarwing_bridge.ts` — The WebSocket server/client. Changes here affect protocol behavior.
- `scripts/nanocode_task_executor.ts` — Task execution via nanocode SDK. Controls session creation, permissions, event streaming.
- `scripts/lunarwing_runtime.ts` — Shared types and envelope helpers. Keep in sync with `agent_comm_protocol.json`.
- `entrypoint.sh` — Startup orchestration. Three modes: websocket, cli, acp.
- `config/opencode.json` — Mounted into container; controls LLM provider, plugins, MCP servers.

## Protocol Compatibility

The `lunarwing-agent-v1` WebSocket subprotocol (legacy alias `ironclaw-agent-v1` still accepted for one deprecation cycle) is shared with the pebble and opencode workers. Changes to `agent_comm_protocol.json` or envelope format must stay backward-compatible or be coordinated across all workers.

## Build Notes

The Dockerfile clones the upstream nanocode repo at build time. For reproducible builds, pin a specific tag by changing the `ARG NANOCODE_REF` line, or override at build time:

```bash
docker build --build-arg NANOCODE_REF=v1.2.28 -t lunarwing-worker-nanocode:latest .
```

The `nanocode/` directory in this repo is NOT needed for builds — it's only a cached copy from the previous vendoring approach and is gitignored.

## Do Not

- Break the `lunarwing-agent-v1` envelope format
- Expose the internal nanocode serve port (4096) externally
- Store secrets in config files (use env vars with `{env:VAR}` syntax)
- Remove the health server — orchestration depends on it
