# Pebble External Worker

Pebble integrated as a LunarWing external worker via `pebble4lunarwing/`.

## Implementation

1. **NDJSON output mode** — `pebble prompt --output-format ndjson` streams `RuntimeEvent`s as JSON lines (iteration, assistant, tool_start, tool_end, result)
2. **Bridge binary** — `pebble4lunarwing/` Rust crate speaks `ironclaw-agent-v1` WebSocket protocol, spawns pebble subprocess per task, forwards NDJSON as `task_progress`
3. **Multi-tenant** — Port registry v4 (reserved_2 → pebble_wss), admin script hooks in `lunarwing-mt-admin.sh`

## Usage

```toml
[[sandbox.external_workers]]
name = "pebble"
url = "ws://localhost:9090/ws/agent"
timeout_ms = 300000
```

```
create_job(mode: "pebble", description: "fix the tests")
```

## Docs

- `pebble4lunarwing/CLAUDE.md` — Dev guide
- `docs/ops/PEBBLE-WORKER.md` — Operational guide
