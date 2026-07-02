# opencode4lunarwing

WebSocket bridge that integrates [opencode](https://opencode.ai) (sst/opencode) as a LunarWing external worker.

## Quick Start

### Docker

```bash
docker compose build
docker compose up -d lunarwing-worker
```

### CLI mode (one-shot)

```bash
docker compose --profile cli run opencode-cli prompt "hello world"
```

## LunarWing Configuration

Add to `config.toml` under `LUNARWING_BASE_DIR`:

```toml
[[sandbox.external_workers]]
name = "opencode"
url = "ws://localhost:9090/ws/agent"
timeout_ms = 300000
```

The agent logs `External workers configured: opencode` on startup.

## Usage

```
create_job(title: "Fix the tests", description: "Run cargo test and fix failures", mode: "opencode")
```

## Health Endpoints

- `GET /health` — Worker status, uptime, version
- `GET /ready` — WebSocket readiness and connection count

## Protocol

Speaks `ironclaw-agent-v1` WebSocket subprotocol. See `agent_comm_protocol.json` for the full spec.

## Environment Variables

See `.env.example` for the full list with descriptions.
