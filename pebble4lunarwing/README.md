# pebble4lunarwing

WebSocket bridge that integrates the [Pebble](../pebble/) agentic coding harness as a LunarWing external worker.

## Quick Start

### Native

```bash
cargo build --release
PEBBLE_BIN=../pebble/target/release/pebble \
WORKSPACE_ROOT=/tmp/workspace \
./target/release/pebble4lunarwing
```

### Docker

```bash
docker compose build
docker compose up -d pebble-worker
```

### CLI mode (one-shot)

```bash
docker compose --profile cli run pebble-cli prompt "hello world"
```

## LunarWing Configuration

Add to `config.toml` under `LUNARWING_BASE_DIR`:

```toml
[[sandbox.external_workers]]
name = "pebble"
url = "ws://localhost:9090/ws/agent"
timeout_ms = 300000
```

The agent logs `External workers configured: pebble` on startup.

## Usage

```
create_job(title: "Fix the tests", description: "Run cargo test and fix failures", mode: "pebble")
```

With `wait=false`, use `job_events <id>` and `job_status <id>` to monitor progress.

## Environment Variables

See `.env.example` for the full list with descriptions.

## Health Endpoints

- `GET /health` — Worker status, uptime, version
- `GET /ready` — WebSocket readiness and connection count

## Protocol

Speaks `ironclaw-agent-v1` WebSocket subprotocol. See `../codex4lunarwing/agent_comm_protocol.json` for the full spec.
