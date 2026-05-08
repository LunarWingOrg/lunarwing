# Worker Test Harness

## Overview
Matrix test suite for all 4 LunarWing worker types:
- **Codex Worker** (`codex4ironclaw/`)
- **Nanocode Worker** (`nanocode4ironclaw/`)
- **Built-in Worker** (`ic/src/worker/`)
- **Sandbox Worker** (`ic/src/sandbox/`)

Runs in Docker Compose isolation, validates:
- Health endpoints (`/health`, `/ready`)
- WebSocket protocol (`task_request` → `task_progress` → `task_result`)
- Error cases (timeout, auth fail, rate-limit)
- Resource limits & cleanup

## Quick Start
```bash
cd tests/worker-harness
pip install -r requirements.txt
python runner.py --mode smoke     # happy paths only (CI)
python runner.py --mode full      # + chaos cases (nightly)
python runner.py --worker codex   # single worker
```

## Test Matrix (`tests.yaml`)
YAML-driven: each worker × scenario pair runs in isolation with mock services.