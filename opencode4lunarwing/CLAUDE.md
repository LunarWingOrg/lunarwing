# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working in this repository.

## What This Project Is

**LunarWing OpenCode Worker** — a Docker image that wraps upstream opencode (sst/opencode) as a persistent managed worker. It runs the opencode headless HTTP/SSE server internally and bridges it to the LunarWing WebSocket protocol for agent communication.

## Build & run

```bash
# Build the image
docker compose build

# WebSocket mode (default, persistent worker)
docker compose up -d lunarwing-worker

# CLI mode (one-shot)
docker compose --profile cli run opencode-cli

# Smoke test
docker compose --profile smoke up agent-smoke
```

## Key environment variables

| Variable | Default | Notes |
|---|---|---|
| `AGENT_AUTH_TOKEN` | — | WebSocket bearer auth (empty = no auth, dev mode) |
| `TENSORZERO_API_KEY` | `dummy` | LLM gateway auth |
| `OPENCODE_MODEL` | — | Override the LLM model in `opencode.json` (any string) |
| `OPENCODE_BASE_URL` | — | Override the TensorZero baseURL in `opencode.json` (full URL) |
| `OPENCODE_MODE` | `websocket` | `websocket`, `cli`, or `acp` |
| `WS_ROLE` | `server` | `server` (inbound) or `client` (outbound to hub) |
| `WS_PORT` | `9090` | WebSocket listen port |
| `OPENCODE_SERVE_PORT` | `4096` | Internal opencode HTTP/SSE port |
| `HEALTH_PORT` | `8443` | Health endpoint port |
| `WORKSPACE_ROOT` | `/workspace` | Default task working directory |
| `LUNARWING_WORKER_ID` | `worker-opencode-01` | Worker ID in ready messages |
| `PASEO_URL` | — | Optional Paseo daemon URL for MCP integration |
| `PASEO_TOKEN` | — | Optional Paseo auth token |

See `.env.example` for the full list with descriptions.

## LunarWing integration

The opencode worker integrates with LunarWing via the **ExternalWorker** system. The agent's `create_job` tool accepts `mode: "opencode"` to route tasks to this container.

### LunarWing-side config

Add to the agent's `config.toml` (under `LUNARWING_BASE_DIR`):

```toml
[sandbox]

[[sandbox.external_workers]]
name = "opencode"
url = "ws://localhost:9090/ws/agent"
timeout_ms = 300000
```

**Multi-tenant deployments do not need this step:** `ic/scripts/lunarwing-mt-admin.sh` writes the `[[sandbox.external_workers]]` block automatically (`add-tenant`), using the tenant's allocated `opencode_wss` port and `GATEWAY_AUTH_TOKEN` as the worker auth token.

### End-to-end flow

1. User asks agent to `create_job` with `mode: "opencode"`
2. LunarWing's `ExternalWorkerManager` connects via WebSocket to `ws://localhost:9090/ws/agent`
3. Bridge receives `ready` → sends `task_request` with prompt
4. opencode creates a session, sends prompt to TensorZero LLM
5. Tools (write, read, bash) execute inside the container
6. `task_progress` events stream back through the bridge
7. `task_result` returns final output to the agent

## Architecture

### Entrypoint flow (`entrypoint.sh`)
1. Links `config/opencode.json` into workspace `.opencode/` dir
2. Starts `health_server.py` in background (port 8443)
3. **CLI mode**: `exec bun run ... src/index.ts run "$@"`
4. **ACP mode**: `exec bun run ... src/index.ts acp`
5. **WebSocket mode**:
   - Starts `opencode serve` on internal port 4096 (localhost only)
   - Waits for server readiness (curl health loop)
   - Launches `scripts/lunarwing_bridge.ts` (Bun WebSocket server/client)

### Bridge → opencode communication
The bridge uses `@opencode-ai/sdk/v2` (`createOpencodeClient`) to talk to the internal opencode server. Each `task_request` creates a session with full-auto permissions, sends a prompt, and subscribes to SSE events for streaming progress.

### WebSocket protocol (`agent_comm_protocol.json`)
Same protocol as nanocode: JSON envelope with `id`, `type`, `timestamp`, `payload`. Subprotocol: `ironclaw-agent-v1`. Worker sends `ready` on connect, receives `task_request`, streams `task_progress`, sends `task_result`.

### Health server (`health_server.py`)
Python stdlib HTTP server. `/ready` reads `/tmp/lunarwing_ws_state.json` written by the bridge to report WebSocket readiness.

### Key difference from nanocode worker
- Uses upstream `@opencode-ai/sdk` instead of `@nanogpt/sdk`
- No `patches/fn.ts` needed (upstream opencode doesn't have the PartID/SessionID schema bug)
- Provider key is user-defined (not hardcoded `"nanogpt"`)
- Config file is `.opencode/opencode.json` (not `.nanocode/nanocode.json`)

## File layout

```
Dockerfile                    # Multi-stage: build opencode, slim runtime
docker-compose.yml            # Services, volumes, env
entrypoint.sh                 # Startup orchestration
health_server.py              # HTTP health/ready endpoint (Python)
agent_comm_protocol.json      # WebSocket protocol spec
.env.example                  # All env vars documented
config/
  opencode.json               # opencode config (TensorZero provider)
scripts/
  lunarwing_bridge.ts          # WebSocket server/client bridge
  lunarwing_runtime.ts         # Protocol types, envelope helpers, state file
  opencode_task_executor.ts   # SDK-based task execution (session, prompt, stream)
  smoke_test.ts               # Connectivity verification
workspace/                    # Default coding workspace
```
