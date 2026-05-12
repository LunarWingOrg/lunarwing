# LunarWing Nanocode Worker

Persistent Docker container wrapping [nanocode](https://github.com/nanogpt-community/nanocode) as a managed coding worker for LunarWing. Agents connect via WebSocket, send coding tasks, and receive streaming progress/results.

## Architecture

```
┌────────────────────────── Docker Container ──────────────────────────┐
│                                                                       │
│  entrypoint.sh (tini)                                                 │
│    ├── health_server.py      → port 8443 (/health, /ready)            │
│    ├── nanocode serve         → port 4096 (internal HTTP/SSE)          │
│    └── lunarwing_bridge.ts    → port 9090 (WebSocket, ironclaw-agent-v1)│
│                                                                       │
│  Bridge ←─ SDK (HTTP/SSE) ─→ nanocode serve ←─ LLM ─→ TensorZero    │
│                                                                       │
└───────────────────────────────────────────────────────────────────────┘
```

The bridge uses nanocode's SDK (`createOpencodeClient`) to communicate with the headless server over HTTP/SSE — no subprocess spawning per task. Sessions are stateful and support streaming events.

## Quick Start

```bash
# Build the image
docker compose build

# Start the worker (WebSocket server mode)
docker compose up -d lunarwing-worker

# Run smoke tests
docker compose --profile smoke up agent-smoke

# One-shot CLI mode
docker compose --profile cli run nanocode-cli
```

## Connecting an Agent

```
WebSocket: ws://host:9090/ws/agent
Subprotocol: ironclaw-agent-v1
Auth: Bearer <AGENT_AUTH_TOKEN>
```

### Message Flow

1. Worker sends `ready` on connect
2. Agent sends `task_request` with prompt
3. Worker streams `task_progress` events
4. Worker sends final `task_result`

See `agent_comm_protocol.json` for the full protocol spec.

## Modes

| Mode | Description | Usage |
|------|-------------|-------|
| `websocket` | Persistent worker with WS bridge (default) | `--mode websocket` |
| `cli` | One-shot nanocode run | `--mode cli -- "your prompt"` |
| `acp` | ACP stdio bridge (for OpenClaw/acpx) | `--mode acp` |

## Configuration

Copy `.env.example` to `.env`. Key variables:

| Variable | Default | Purpose |
|----------|---------|---------|
| `AGENT_AUTH_TOKEN` | _(empty)_ | Bearer token for WS auth (empty = no auth) |
| `TENSORZERO_API_KEY` | `dummy` | API key for TensorZero gateway |
| `WS_ROLE` | `server` | `server` (agents connect in) or `client` (worker connects out) |
| `WS_PORT` | `9090` | WebSocket listen port |
| `NANOCODE_SERVE_PORT` | `4096` | Internal nanocode HTTP/SSE server port |
| `HEALTH_PORT` | `8443` | Health check HTTP port |

The nanocode config (`config/opencode.json`) is bind-mounted read-only. Edit it to change the LLM provider, model, plugins, or MCP servers.

## Volumes

| Volume | Mount | Purpose |
|--------|-------|---------|
| `nanocode-data` | `/home/nanocode/.local/share/nanocode` | SQLite DB, session history |
| `nanocode-config-home` | `/home/nanocode/.config/nanocode` | Global config, auth state |
| `./workspace` | `/workspace` | Coding workspace (persistent) |
| `./config/opencode.json` | `/app/config/opencode.json` | Nanocode config (read-only) |
| `./logs` | `/var/log/lunarwing` | Container logs |
| `./results` | `/app/results` | Task output artifacts |

## Health Endpoints

- `GET :8443/health` — always 200 if process is alive
- `GET :8443/ready` — 200 if WebSocket bridge is ready, 503 otherwise

## TensorZero Integration

The default `config/opencode.json` points to `http://192.168.1.157:3000/openai/v1/` with model `tensorzero::nanocode`. The TensorZero gateway handles intelligent routing, fallback chains, and model selection. Set `TENSORZERO_API_KEY` in your `.env`.

For direct NanoGPT access (bypassing TensorZero), edit `config/opencode.json` to use the NanoGPT provider with `NANOGPT_API_KEY`.
