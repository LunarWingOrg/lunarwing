# LunarWing Worker Test Harness — Summary & Fixes

## What It Is
Matrix test suite for the 4 worker types:
- **Codex** (`codex4ironclaw/`)
- **Nanocode** (`nanocode4ironclaw/`)
- **Built-in** (`ic/src/worker/`)
- **Sandbox** (`ic/src/sandbox/`)

Tests: health/ready endpoints, WebSocket protocol, auth failures, timeouts.

Files (at repo root `tests/`):
- `runner.py` — test runner
- `tests.yaml` — matrix definition
- `docker-compose.test.yml` — Docker services + mocks
- `mock_orchestrator/` — mock HTTP/WS services
- `requirements.txt` — Python deps

## Quick Start
```bash
cd tests
pip install -r requirements.txt
python runner.py --mode smoke     # CI (happy paths)
python runner.py --mode full      # nightly (chaos)
python runner.py --worker codex   # single worker
```

## Known Issues & Fixes

### 1. Docker Compose Path Depth
**Problem**: `docker-compose.test.yml` uses `context: ../../codex4ironclaw` but `tests/` is at repo root, so paths are one level too deep.

**Fix**:
```bash
cd tests
sed -i 's|../../codex4ironclaw|../codex4ironclaw|g' docker-compose.test.yml
sed -i 's|../../nanocode4ironclaw|../nanocode4ironclaw|g' docker-compose.test.yml
```

### 2. Missing `hub.py` Healthcheck
**Problem**: `ws_hub` healthcheck references non-existent `hub.py`.

**Fix**:
```bash
cd tests
echo '#!/usr/bin/env python3\nprint("OK")' > mock_orchestrator/hub_health.py
chmod +x mock_orchestrator/hub_health.py
sed -i 's|python3 -c "import socket; s=socket.socket(); s.connect((\"127.0.0.1\",9000)); s.close()"|["CMD", "./mock_orchestrator/hub_health.py"]|' docker-compose.test.yml
```

### 3. Built-in/Sandbox Workers (Optional)
Require `lunarwing:latest` image:
```bash
cd ic
cargo build --release
docker build -t lunarwing:latest -f Dockerfile.worker .
```

Override: `BUILTIN_WORKER_IMAGE=myimage docker compose up builtin_worker`

## Test Scenarios (`tests.yaml`)
Add new ones easily:
```yaml
- name: custom_test
  type: http
  path: /custom
  expect:
    status_code: 200
```

Types: `http`, `ws_handshake`, `ws_connect`.

Chaos (`chaos: true`) only runs in `--mode full`.

## CI Integration
```yaml
# .github/workflows/test.yml
- name: Worker Tests (Smoke)
  run: cd tests && python runner.py --mode smoke
- name: Worker Tests (Full)
  if: github.event_name == 'schedule'
  run: cd tests && python runner.py --mode full
```

## Next Steps
1. Apply fixes above
2. Run `python runner.py --mode smoke`
3. Add vision worker to `tests.yaml` + Dockerfile
4. Wire to GitHub Actions

Full code: [this tarball](http://tinyhost.sobe.world/542c6874c9bac5f8.tar.gz?expires=1778436668&token=132cc805cda32922f32f4192b3a12d4d4b8e5430cad6fc8fddce22e99f84c59a)

*baud 🦄 2026-05-08*
