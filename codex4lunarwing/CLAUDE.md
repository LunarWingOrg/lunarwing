# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Project Is

**LunarWing Codex Worker** — a Docker image that wraps `@openai/codex` as a persistent managed worker. It runs the OpenAI Codex CLI in full-auto mode and bridges it to the LunarWing WebSocket protocol for agent communication.

## Build & run

```bash
# Build the image
docker compose build

# WebSocket mode (default, persistent worker)
docker compose up -d codex-worker

# CLI mode (one-shot)
docker compose --profile cli run codex-cli

# Smoke test
docker compose --profile smoke up agent-smoke
```

## Key environment variables

| Variable | Default | Notes |
|---|---|---|
| `OPENAI_API_KEY` | — | Required for Codex API access |
| `CODEX_MODEL` | `codex-mini-latest` | Model to use |
| `AGENT_AUTH_TOKEN` | — | WebSocket bearer auth (empty = no auth, dev mode) |
| `CODEX_MODE` | `websocket` | `websocket` or `cli` |
| `WS_ROLE` | `server` | `server` (inbound) or `client` (outbound to hub) |
| `WS_PORT` | `9090` | WebSocket listen port |
| `HEALTH_PORT` | `8443` | Health endpoint port |
| `WORKSPACE_ROOT` | `/workspace` | Default task working directory |
| `LUNARWING_WORKER_ID` | `worker-codex-01` | Worker ID in ready messages |

See `.env.example` for the full list with descriptions.

## LunarWing integration

The codex worker integrates with LunarWing via the **ExternalWorker** system. The agent's `create_job` tool accepts `mode: "codex"` to route tasks to this container.

### LunarWing-side config

Add to the agent's `config.toml` (under `LUNARWING_BASE_DIR`):

```toml
[sandbox]
# ... existing sandbox settings ...

[[sandbox.external_workers]]
name = "codex"
url = "ws://localhost:9090/ws/agent"
timeout_ms = 300000
```

The `name` field must match the `mode` value used in `create_job` calls. The agent logs `External workers configured: codex` on startup when loaded correctly.

### End-to-end flow

1. User asks agent to `create_job` with `mode: "codex"`
2. LunarWing's `ExternalWorkerManager` connects via WebSocket to `ws://localhost:9090/ws/agent`
3. Worker sends `ready` message
4. Agent sends `task_request` with prompt
5. Bridge spawns `codex --approval-mode full-auto --quiet` with the prompt
6. stdout/stderr stream back as `task_progress` events
7. Process exit → `task_result` returned to the agent

## Architecture

### Entrypoint flow (`entrypoint.sh`)
1. Configures git/SSH credentials from env vars
2. Links `config/codex.toml` into `~/.codex/config.toml`
3. Starts `health_server.py` in background (port 8443)
4. **CLI mode**: `exec codex --approval-mode full-auto --quiet "$@"`
5. **WebSocket mode**: launches `scripts/lunarwing_bridge.ts` (Bun WebSocket server/client)

### Bridge → Codex communication
The bridge spawns the `codex` CLI as a subprocess for each task. This is simpler than an SDK integration — no internal server needed. Each task gets a fresh process with full-auto approval mode.

### WebSocket protocol (`agent_comm_protocol.json`)
JSON envelope with `id`, `type`, `timestamp`, `payload`. Subprotocol: `ironclaw-agent-v1`. Worker sends `ready` on connect, receives `task_request`, streams `task_progress`, sends `task_result`.

### Health server (`health_server.py`)
Python stdlib HTTP server. `/ready` reads `/tmp/lunarwing_ws_state.json` written by the bridge to report WebSocket readiness.

### Key difference from nanocode worker
- Spawns CLI subprocess instead of in-process SDK calls
- No internal HTTP/SSE server needed
- Stateless (each task is a fresh codex process)
- Much simpler Dockerfile (no monorepo build)

## File layout

```
Dockerfile                    # Single-stage: Bun + Node.js + codex CLI
docker-compose.yml            # Services, volumes, env
entrypoint.sh                 # Startup orchestration
health_server.py              # HTTP health/ready endpoint (Python)
agent_comm_protocol.json      # WebSocket protocol spec
.env.example                  # All env vars documented
config/
  codex.toml                  # @openai/codex config (model, approval mode)
scripts/
  lunarwing_bridge.ts         # WebSocket server/client bridge
  lunarwing_runtime.ts        # Protocol types, envelope helpers, state file
  codex_task_executor.ts      # CLI subprocess execution
  smoke_test.ts               # Connectivity verification
workspace/                    # Default coding workspace
```
