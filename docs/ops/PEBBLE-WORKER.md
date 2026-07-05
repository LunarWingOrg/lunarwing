# Pebble Worker — Operational Guide

The Pebble worker (`pebble4lunarwing/`) integrates the Pebble agentic coding harness as a LunarWing external worker. It speaks the `lunarwing-agent-v1` WebSocket protocol (legacy alias `ironclaw-agent-v1` still accepted) and spawns `pebble prompt --output-format ndjson` per task.

## Single-Instance Setup

### Native (no Docker)

```bash
cd pebble && cargo build --release
cd ../pebble4lunarwing && cargo build --release

PEBBLE_BIN=../pebble/target/release/pebble \
WORKSPACE_ROOT=/tmp/pebble-workspace \
./target/release/pebble4lunarwing
```

### Docker

```bash
cd pebble4lunarwing
docker compose build
docker compose up -d pebble-worker
```

### LunarWing Config

Add to `config.toml` under `LUNARWING_BASE_DIR`:

```toml
[[sandbox.external_workers]]
name = "pebble"
url = "ws://localhost:9090/ws/agent"
timeout_ms = 300000
```

## Multi-Tenant Setup

### Build

```bash
sudo lunarwing-mt-admin.sh build-pebble-worker
```

### Port Allocation

The v4 port registry migration (`migrate-ports-v4.sh`) assigns `pebble_wss` at offset +8 (previously `reserved_2`).

```bash
sudo ic/scripts/migrate-ports-v4.sh
```

The admin script auto-migrates on `add-tenant` and `build-tenant`.

### Start/Stop

Pebble workers start and stop with the tenant:

```bash
sudo lunarwing-mt-admin.sh start-tenant <name>
sudo lunarwing-mt-admin.sh stop-tenant <name>
```

### Per-Tenant Configuration

Create `pebble.env` in the tenant env directory for pebble-specific overrides:

```bash
# /etc/lunarwing/env/<tenant>/pebble.env
PEBBLE_MODEL=openai/gpt-5.2
NANOGPT_API_KEY=...
```

### Status

```bash
sudo lunarwing-mt-admin.sh status <name>
sudo lunarwing-mt-admin.sh list-ports
```

## Health Endpoints

- `GET /health` — `{"status":"ok","uptime_seconds":...,"worker_id":"...","version":"...","mode":"websocket"}`
- `GET /ready` — `{"ready":true,"connections":1}` (200) or `{"ready":false,"connections":0}` (503)

## Troubleshooting

### Worker not starting

Check the image exists:
```bash
docker image inspect lunarwing-worker-pebble:latest
```

If missing, build it:
```bash
sudo lunarwing-mt-admin.sh build-pebble-worker
```

### Task failures

Check bridge logs:
```bash
docker logs lunarwing-pebble-<tenant>
```

The bridge logs task start/completion and stderr from the pebble process.

### Agent can't connect

Verify the port is allocated and the container is running:
```bash
sudo lunarwing-mt-admin.sh status <tenant>
```

Check that `config.toml` has the correct `url` pointing to the pebble_wss port.
