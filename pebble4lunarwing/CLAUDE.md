# CLAUDE.md

## What This Project Is

**LunarWing Pebble Worker** — a Rust binary that wraps the Pebble agentic coding harness as a persistent managed worker. It speaks the `ironclaw-agent-v1` WebSocket protocol and spawns `pebble prompt --output-format ndjson` per task, streaming NDJSON events back as `task_progress` messages.

## Build & Run

```bash
cargo build --release
cargo test
cargo clippy --all-targets -- -D warnings

# Native mode
PEBBLE_BIN=../pebble/target/release/pebble WORKSPACE_ROOT=/tmp/workspace ./target/release/pebble4lunarwing

# Docker mode
docker compose build
docker compose up -d pebble-worker
```

## Key Environment Variables

| Variable | Default | Notes |
|---|---|---|
| `PEBBLE_BIN` | `pebble` | Path to pebble binary |
| `PEBBLE_MODEL` | `openai/gpt-5.2` | Model for pebble tasks |
| `PEBBLE_PERMISSION_MODE` | `danger-full-access` | Permission mode (full-auto for worker) |
| `AGENT_AUTH_TOKEN` | — | WebSocket bearer auth (empty = no auth) |
| `WS_PORT` | `9090` | WebSocket listen port |
| `HEALTH_PORT` | `8443` | Health endpoint port |
| `WORKSPACE_ROOT` | `/workspace` | Default task working directory |
| `LUNARWING_WORKER_ID` | `worker-pebble-01` | Worker ID in ready messages |

## LunarWing Integration

Add to `config.toml`:
```toml
[[sandbox.external_workers]]
name = "pebble"
url = "ws://localhost:9090/ws/agent"
timeout_ms = 300000
```

Then use `create_job(mode: "pebble", description: "...")` to dispatch tasks.

## Architecture

- `src/main.rs` — Entry point, starts health server + bridge
- `src/bridge.rs` — WebSocket server, connection handling, message dispatch
- `src/executor.rs` — Spawns pebble subprocess, parses NDJSON, forwards events
- `src/protocol.rs` — ironclaw-agent-v1 envelope types and helpers
- `src/health.rs` — HTTP health/ready endpoints

## Protocol Flow

1. Bridge listens on `ws://0.0.0.0:9090/ws/agent`
2. Agent connects, bridge sends `ready`
3. Agent sends `task_request` with prompt
4. Bridge spawns `pebble prompt --output-format ndjson` with the prompt
5. NDJSON lines stream back as `task_progress` events
6. Final `result` line becomes `task_result`
