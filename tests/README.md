# Worker Test Harness

## Overview

Matrix test suite for LunarWing worker types:

| Worker | Source | Docker Service | Description |
|--------|--------|----------------|-------------|
| **Nanocode** | `lunarcode4lunarwing/` | `nanocode_worker` | NanoGPT community Nanocode worker container |
| **Opencode** | `opencode4lunarwing/` | `opencode_worker` | Opencode (sst/opencode) coding-agent worker |
| **Pebble** | `pebble4lunarwing/` | `pebble_worker` | Pebble Rust-based coding-agent worker container |
| **Built-in** | `ic/src/worker/` | `builtin_worker` | Native worker inside the LunarWing daemon |
| **Sandbox** | `ic/src/sandbox/` | `sandbox_worker` | Docker-isolated execution sandbox |

Each worker is tested in Docker Compose isolation against mock services. The test matrix (`tests.yaml`) defines worker x scenario pairs that validate:

- Health endpoints (`/health`, `/ready`)
- WebSocket protocol (`ready` -> `task_request` -> `task_progress` -> `task_result`)
- Error cases (timeout, auth failure, rate-limit)
- Resource limits and cleanup

## Quick Start

```bash
cd tests
pip install -r requirements.txt
python runner.py --mode smoke     # happy paths only (CI)
python runner.py --mode full      # + chaos scenarios (nightly)
python runner.py --worker nanocode   # single worker type
```

### Prerequisites

- Docker and Docker Compose
- Python 3.10+
- Dependencies: `requests`, `websocket-client`, `pyyaml`, `websockets`, `pytest`

## Architecture

```
tests/
  runner.py                   # Test runner -- parses tests.yaml, manages Docker lifecycle
  tests.yaml                  # Test matrix -- worker x scenario definitions
  docker-compose.test.yml     # Docker Compose -- all workers + mock services
  requirements.txt            # Python dependencies
  mock_orchestrator/
    server.py                 # Mock HTTP orchestrator (health, config, LLM proxy, status)
    hub.py                    # Mock WebSocket hub (agent_comm_protocol handshake)
    __init__.py
```

### How It Works

1. `runner.py` loads the test matrix from `tests.yaml`
2. For each worker, it brings up the Docker Compose service and its dependencies
3. Waits for health/ready endpoints to pass
4. Runs each scenario (HTTP checks, WebSocket handshake, auth rejection, etc.)
5. Tears down the service after each worker completes
6. Reports pass/fail summary

### Mock Services

Two mock services simulate the LunarWing orchestrator and agent communication:

**Mock Orchestrator** (`mock_orchestrator/server.py`) -- HTTP server for built-in worker tests:

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/health` | GET | Returns `{"status": "ok"}` |
| `/worker/config` | GET | Bootstrap config with `job_id`, `orchestrator_url`, `max_iterations` |
| `/worker/{id}/llm/complete` | GET | Mock LLM response (configurable via `MOCK_LLM_RESPONSE` env var) |
| `/worker/{id}/status` | POST | Accepts worker status reports |
| `/jobs/create` | POST | Mock job creation |

**Mock WebSocket Hub** (`mock_orchestrator/hub.py`) -- plays the agent side of the WebSocket protocol:

1. Authenticates via `Authorization: Bearer <token>` header
2. Waits for the worker's `ready` message
3. Sends a `task_request` with a configurable prompt
4. Collects `task_progress` and `task_result` messages

Hub env vars: `HARNESS_AUTH_TOKEN` (default `test-token`), `TASK_PROMPT`, `TASK_TIMEOUT_MS` (default `30000`).

## Test Matrix (`tests.yaml`)

The matrix is YAML-driven. Each worker has a `deploy` service name, port configuration, and a list of scenarios:

```yaml
workers:
  nanocode:
    deploy: nanocode_worker     # docker-compose service name
    health_port: 8444           # port for health/ready checks
    ws_port: 9090               # port for WebSocket tests
    auth_token: test-token      # bearer token for auth
    scenarios:
      - name: health
        type: http
        method: GET
        path: /health
        expect:
          status_code: 200
```

### Scenario Types

| Type | Description | Fields |
|------|-------------|--------|
| `http` | HTTP request/response check | `method`, `path`, `body`, `expect.status_code`, `expect.body_contains` |
| `ws_handshake` | WebSocket connect + verify first message | `expect.first_message`, `expect.payload_has` |
| `ws_connect` | WebSocket auth test (expects rejection) | `auth_token`, `expect.error_code` |

### Chaos Scenarios

Scenarios with `chaos: true` only run in `--mode full`. These test error paths like invalid authentication and are intended for nightly CI runs:

```yaml
- name: invalid_auth
  type: ws_connect
  chaos: true
  auth_token: bad-bearer-horse
  expect:
    error_code: 4001
```

## Docker Compose Services

`docker-compose.test.yml` defines the full test environment:

| Service | Image | Ports | Profile | Purpose |
|---------|-------|-------|---------|---------|
| `orchestrator` | `python:3.12-slim` | 8080 | default | Mock HTTP API |
| `ws_hub` | `python:3.12-slim` | 9000 | default | Mock WebSocket hub |
| `nanocode_worker` | Built from `lunarcode4lunarwing/` | 8444, 9090 | default | Nanocode worker under test |
| `opencode_worker` | Built from `opencode4lunarwing/` | 8445, 9091 | default | Opencode worker under test |
| `pebble_worker` | Built from `pebble4lunarwing/` | 8446, 9092 | default | Pebble worker under test |
| `builtin_worker` | `lunarwing:latest` | -- | `full` | Built-in worker (requires binary) |
| `sandbox_worker` | `lunarwing:latest` | -- | `full` | Sandbox worker (requires binary + Docker socket) |

The `full` profile workers require a pre-built `lunarwing:latest` image. Override with `BUILTIN_WORKER_IMAGE` or `SANDBOX_WORKER_IMAGE` env vars.

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `HARNESS_AUTH_TOKEN` | `test-token` | Auth token shared by hub and workers |
| `MOCK_API_KEY` | `test-key` | API key passed to workers |
| `MOCK_LLM_RESPONSE` | `mock llm response from test harness` | Canned LLM response |
| `BUILTIN_WORKER_IMAGE` | `lunarwing:latest` | Image for built-in worker |
| `SANDBOX_WORKER_IMAGE` | `lunarwing:latest` | Image for sandbox worker |

## Adding a New Worker

1. Add a Dockerfile to the worker's source directory
2. Add a service to `docker-compose.test.yml` with health checks
3. Add a worker entry to `tests.yaml` with `deploy`, `health_port`, and scenarios
4. Run `python runner.py --worker <name>` to verify

## Adding a New Scenario

Add an entry to the worker's `scenarios` list in `tests.yaml`:

```yaml
- name: my_new_check
  type: http
  method: POST
  path: /my/endpoint
  body: {"key": "value"}
  expect:
    status_code: 201
    body_contains: created
```

For chaos/error scenarios, add `chaos: true` so they only run in `--mode full`.

## CI Usage

```bash
# Smoke mode for pull request CI
python runner.py --mode smoke

# Full mode for nightly CI (includes chaos scenarios)
python runner.py --mode full
```

Exit code is 0 if all tests pass, 1 if any fail.

## Troubleshooting

- **Worker won't start**: Check Docker build logs with `docker compose -f docker-compose.test.yml build <service>`
- **Health check timeout**: Increase `retries` in the service's `healthcheck` block, or check worker logs with `docker compose -f docker-compose.test.yml logs <service>`
- **WebSocket auth failures**: Verify `HARNESS_AUTH_TOKEN` matches between `ws_hub` and the worker service
- **Built-in/sandbox workers missing**: These require a pre-built `lunarwing:latest` image. Build with `cd ic && cargo build --release && docker build -t lunarwing:latest .`
