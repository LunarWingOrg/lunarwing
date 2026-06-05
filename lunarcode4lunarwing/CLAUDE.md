# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Project Is

**LunarWing Nanocode Worker** — a Docker image that wraps nanocode (a fork of opencode) as a persistent managed worker. It runs the nanocode headless HTTP/SSE server internally and bridges it to the LunarWing WebSocket protocol for agent communication.

## Build & run

```bash
# Build the image
docker compose build

# WebSocket mode (default, persistent worker)
docker compose up -d lunarwing-worker

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
| `LUNARWING_WORKER_ID` | `worker-nanocode-01` | Worker ID in ready messages |

See `.env.example` for the full list with descriptions.

## LunarWing integration

The nanocode worker integrates with LunarWing via the **ExternalWorker** system. The agent's `create_job` tool accepts `mode: "nanocode"` to route tasks to this container.

### LunarWing-side config

Add to the agent's `config.toml` (under `LUNARWING_BASE_DIR`):

```toml
[sandbox]
# ... existing sandbox settings ...

[[sandbox.external_workers]]
name = "nanocode"
url = "ws://localhost:9090/ws/agent"
timeout_ms = 300000
```

The `name` field must match the `mode` value used in `create_job` calls. The agent logs `External workers configured: nanocode` on startup when loaded correctly.

### TensorZero routing

The nanocode worker uses TensorZero as its LLM backend. A corresponding function must exist in `tensorzero.toml`:

```toml
[functions.lunarwing]
type = "chat"

[functions.lunarwing.variants.your_variant]
type = "chat_completion"
model = "your_model"
```

The model name in `config/nanocode.json` must use TensorZero's format: `tensorzero::function_name::lunarwing`.

### End-to-end flow

1. User asks agent to `create_job` with `mode: "nanocode"`
2. LunarWing's `ExternalWorkerManager` connects via WebSocket to `ws://localhost:9090/ws/agent`
3. Bridge receives `ready` → sends `task_request` with prompt
4. Nanocode creates a session, sends prompt to TensorZero LLM
5. Tools (write, read, bash) execute inside the container
6. `task_progress` events stream back through the bridge
7. `task_result` returns final output to the agent

## Architecture

### Entrypoint flow (`entrypoint.sh`)
1. Links `config/nanocode.json` into workspace `.nanocode/` dir
2. Starts `health_server.py` in background (port 8443)
3. **CLI mode**: `exec bun run ... src/index.ts run "$@"`
4. **ACP mode**: `exec bun run ... src/index.ts acp`
5. **WebSocket mode**:
   - Starts `nanocode serve` on internal port 4096 (localhost only)
   - Waits for server readiness (curl health loop)
    - Launches `scripts/lunarwing_bridge.ts` (Bun WebSocket server/client)

### Bridge → nanocode communication
The bridge uses `@nanogpt/sdk/v2` (`createOpencodeClient`) to talk to the internal nanocode server. Each `task_request` creates a session with full-auto permissions, sends a prompt, and subscribes to SSE events for streaming progress. This is in-process SDK communication, not subprocess spawning.

### WebSocket protocol (`agent_comm_protocol.json`)
Same protocol as codex4ironclaw: JSON envelope with `id`, `type`, `timestamp`, `payload`. Subprotocol: `ironclaw-agent-v1`. Worker sends `ready` on connect, receives `task_request`, streams `task_progress`, sends `task_result`.

### Health server (`health_server.py`)
Python stdlib HTTP server. `/ready` reads `/tmp/lunarwing_ws_state.json` written by the bridge to report WebSocket readiness.

### Key difference from codex4ironclaw
- TypeScript/Bun bridge instead of Python (uses nanocode SDK natively)
- In-process SDK calls instead of subprocess spawning
- Stateful sessions (nanocode keeps session history in SQLite)
- Bun runtime instead of Node.js

## Known issues

### Nanocode schema validation bug (v1.2.28)

Nanocode's tool execution (write, read, bash) fails with `"Invalid string: must start with \"prt\""` — a `PartID` schema is incorrectly applied to a `SessionID` field in the permission check path. The actual session IDs are valid (`ses_*` format).

**Root cause**: `id/id.ts` defines `Identifier.schema("part")` as `z.string().startsWith("prt")`. The generic `fn()` wrapper in `src/util/fn.ts` applies strict `schema.parse()` to all inputs. When tool execution hits the permission check path, a `SessionID` (`ses_...`) is validated against the `PartID` schema, and `parse()` throws — blocking all bash, write, and read tool calls. The LLM can reason and generate code but cannot execute anything.

**Fix applied**: `patches/fn.ts` replaces `schema.parse()` with `schema.safeParse()` and falls back to the raw input on validation failure (logging a warning instead of throwing). The Dockerfile includes a persistent `COPY patches/fn.ts` line so the fix survives rebuilds.

**Hot-patching a running container** (if rebuilding isn't feasible):
```bash
docker cp patches/fn.ts <container_id>:/app/nanocode/packages/opencode/src/util/fn.ts
docker restart <container_id>
```

### SELinux (Fedora/RHEL)

Bind-mounted volumes require the `:z` SELinux label flag in `docker-compose.yml`. Without it, the container cannot read mounted config files or write to the workspace. The `docker-compose.yml` already includes `:z` on all bind mounts.

### Provider ID restriction

This nanocode fork hardcodes `if (providerID !== "nanogpt") return false` in `provider.ts`. All provider configs must use `"nanogpt"` as the provider key, regardless of the actual backend name.

### Config filename

Nanocode's config loader looks for `nanocode.json` (not `opencode.json`) in `.nanocode/` directories. The entrypoint symlinks `config/nanocode.json` into the workspace.

## File layout

```
Dockerfile                    # Multi-stage: build nanocode, slim runtime
docker-compose.yml            # Services, volumes, env
entrypoint.sh                 # Startup orchestration
health_server.py              # HTTP health/ready endpoint (Python)
agent_comm_protocol.json      # WebSocket protocol spec
.env.example                  # All env vars documented
config/
  nanocode.json               # Nanocode config (TensorZero provider via nanogpt ID)
patches/
  fn.ts                       # safeParse fix for PartID/SessionID schema mismatch
scripts/
  lunarwing_bridge.ts          # WebSocket server/client bridge
  lunarwing_runtime.ts         # Protocol types, envelope helpers, state file
  nanocode_task_executor.ts   # SDK-based task execution (session, prompt, stream)
  smoke_test.ts               # Connectivity verification
workspace/                    # Default coding workspace
```
