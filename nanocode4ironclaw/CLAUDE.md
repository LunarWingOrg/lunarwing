# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

IronClaw Nanocode Worker — a Docker image that wraps nanocode (a fork of opencode) as a persistent managed worker. It runs the nanocode headless HTTP/SSE server internally and bridges it to the IronClaw WebSocket protocol for LunarWing agent communication.

## Build & run

```bash
# Build the image
docker compose build

# WebSocket mode (default, persistent worker)
docker compose up -d ironclaw-worker

# CLI mode (one-shot)
docker compose --profile cli run nanocode-cli

# Smoke test
docker compose --profile smoke up agent-smoke
```

## Key environment variables

| Variable | Default | Notes |
|---|---|---|
| `AGENT_AUTH_TOKEN` | — | WebSocket bearer auth (empty = no auth, dev mode) |
| `TENSORZERO_API_KEY` | `dummy` | LLM gateway auth |
| `NANOCODE_MODE` | `websocket` | `websocket`, `cli`, or `acp` |
| `WS_ROLE` | `server` | `server` (inbound) or `client` (outbound to hub) |
| `WS_PORT` | `9090` | WebSocket listen port |
| `NANOCODE_SERVE_PORT` | `4096` | Internal nanocode HTTP/SSE port |
| `HEALTH_PORT` | `8443` | Health endpoint port |
| `WORKSPACE_ROOT` | `/workspace` | Default task working directory |
| `IRONCLAW_WORKER_ID` | `worker-nanocode-01` | Worker ID in ready messages |

See `.env.example` for the full list with descriptions.

## Architecture

### Entrypoint flow (`entrypoint.sh`)
1. Links `config/opencode.json` into workspace `.nanocode/` dir
2. Starts `health_server.py` in background (port 8443)
3. **CLI mode**: `exec bun run ... src/index.ts run "$@"`
4. **ACP mode**: `exec bun run ... src/index.ts acp`
5. **WebSocket mode**:
   - Starts `nanocode serve` on internal port 4096 (localhost only)
   - Waits for server readiness (curl health loop)
   - Launches `scripts/ironclaw_bridge.ts` (Bun WebSocket server/client)

### Bridge → nanocode communication
The bridge uses `@nanogpt/sdk/v2` (`createOpencodeClient`) to talk to the internal nanocode server. Each `task_request` creates a session with full-auto permissions, sends a prompt, and subscribes to SSE events for streaming progress. This is in-process SDK communication, not subprocess spawning.

### WebSocket protocol (`agent_comm_protocol.json`)
Same protocol as codex4ironclaw: JSON envelope with `id`, `type`, `timestamp`, `payload`. Subprotocol: `ironclaw-agent-v1`. Worker sends `ready` on connect, receives `task_request`, streams `task_progress`, sends `task_result`.

### Health server (`health_server.py`)
Python stdlib HTTP server. `/ready` reads `/tmp/ironclaw_ws_state.json` written by the bridge to report WebSocket readiness.

### Key difference from codex4ironclaw
- TypeScript/Bun bridge instead of Python (uses nanocode SDK natively)
- In-process SDK calls instead of subprocess spawning
- Stateful sessions (nanocode keeps session history in SQLite)
- Bun runtime instead of Node.js

## File layout

```
Dockerfile                    # Multi-stage: build nanocode, slim runtime
docker-compose.yml            # Services, volumes, env
entrypoint.sh                 # Startup orchestration
health_server.py              # HTTP health/ready endpoint (Python)
agent_comm_protocol.json      # WebSocket protocol spec
.env.example                  # All env vars documented
config/
  opencode.json               # Nanocode config (TensorZero provider)
scripts/
  ironclaw_bridge.ts          # WebSocket server/client bridge
  ironclaw_runtime.ts         # Protocol types, envelope helpers, state file
  nanocode_task_executor.ts   # SDK-based task execution (session, prompt, stream)
  smoke_test.ts               # Connectivity verification
workspace/                    # Default coding workspace
```
