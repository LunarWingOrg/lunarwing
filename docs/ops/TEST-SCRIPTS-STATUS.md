# Test Scripts Status Report

**Generated**: 2026-07-08 (v1.1.9 `Kiyome きよめ` pre-release, item #3)
**Author**: Rarity

This report catalogs every automated testing script in the LunarWing repo, its
current status, what was fixed, and what remains untested or broken.

---

## Summary of Changes (Item #3)

| Fix | File | Detail |
|-----|------|--------|
| **Bug fix** | `tests/mock_orchestrator/server.py:81` | f-string syntax error (`{args.host}:args.port}` → `{args.host}:{args.port}`) — the mock orchestrator could not start at all |
| **Missing dependency** | `tests/requirements.txt` | Added `websockets==12.0` (used by `hub.py` but was absent from requirements); removed stale bare `docker` package (runner.py shells out to `docker compose`, doesn't use the Python SDK) |
| **Missing workers** | `tests/docker-compose.test.yml` | Added `opencode_worker` and `pebble_worker` services (both have Dockerfiles and health endpoints at 8443/9090, same as nanocode) |
| **Missing test matrix entries** | `tests/tests.yaml` | Added `opencode` and `pebble` worker entries with health/ready/ws_handshake scenarios |
| **Stale content** | `tests/a.txt` | Removed (placeholder file containing only `# A`) |
| **Documentation** | `tests/README.md` | Updated worker table to include opencode and pebble; updated docker-compose service table; updated requirements list |
| **Documentation** | `docs/guides/TESTING_GUIDE.md` | Updated worker matrix references from 3 workers to 5 (nanocode, opencode, pebble, builtin, sandbox) |

---

## Test Script Inventory

### 1. `tests/runner.py` — Worker Test Harness Runner

| Field | Value |
|-------|-------|
| **Status** | ✅ Working (syntax valid, logic intact) |
| **Language** | Python 3.10+ |
| **Purpose** | Matrix-driven test suite for all worker types. Brings up Docker Compose services, runs health/WS/auth scenarios, reports pass/fail. |
| **Tests** | nanocode (health, ready, ws_handshake), opencode (health, ready, ws_handshake), pebble (health, ws_handshake), builtin (orchestrator_health, worker_config), sandbox (orchestrator_health) |
| **Dependencies** | `requests`, `websocket-client`, `pyyaml` |
| **Run** | `cd tests && python runner.py --mode smoke` |
| **Notes** | No code changes needed. The runner correctly handles the new workers via `tests.yaml`. |

### 2. `tests/mock_orchestrator/server.py` — Mock HTTP Orchestrator

| Field | Value |
|-------|-------|
| **Status** | ✅ Fixed (was broken by f-string syntax error on line 81) |
| **Language** | Python 3.10+ |
| **Purpose** | HTTP mock of the LunarWing orchestrator API for built-in/sandbox worker tests |
| **Endpoints** | `GET /health`, `GET /worker/config`, `GET /worker/{id}/llm/complete`, `POST /worker/{id}/status`, `POST /jobs/create` |
| **Bug fixed** | `print(f"[mock-orch] listening on {args.host}:args.port}")` → `print(f"[mock-orch] listening on {args.host}:{args.port}")` |

### 3. `tests/mock_orchestrator/hub.py` — Mock WebSocket Hub

| Field | Value |
|-------|-------|
| **Status** | ✅ Working (syntax valid, logic intact) |
| **Language** | Python 3.10+ |
| **Purpose** | Plays the agent side of the WebSocket protocol: authenticates, waits for `ready`, sends `task_request`, collects `task_progress`/`task_result` |
| **Dependencies** | `websockets` (was missing from requirements.txt — now fixed) |

### 4. `ic/scripts/release-test.sh` — Gateway Smoke Tests

| Field | Value |
|-------|-------|
| **Status** | ✅ Working (bash syntax valid, no issues found) |
| **Language** | Bash |
| **Purpose** | Hits gateway API to verify core subsystems: health, settings, memory, routines, jobs, skills, extensions, chat, gotify, secrets, logging |
| **Checks** | 16 authenticated checks + 2 unauthenticated |
| **Run** | `GATEWAY_URL=http://localhost:9098 GATEWAY_AUTH_TOKEN=tok ./ic/scripts/release-test.sh` |
| **Not automated** | XMPP, WeeChat, Docker/sandbox workers, GitHub integration, image tools, REPL v2, performance/load, rollback, post-release monitoring, documentation (all documented in script header) |

### 5. `ic/scripts/check-boundaries.sh` — Architecture Boundary Checks

| Field | Value |
|-------|-------|
| **Status** | ✅ Working (bash syntax valid) |
| **Language** | Bash |
| **Purpose** | 6 checks: direct DB driver usage outside `src/db/`, `.unwrap()`/`.expect()` in production code, direct `env::var` reads outside config, integration test feature gating, silent test-skip patterns, LLM module isolation |
| **Run** | `cd ic && bash scripts/check-boundaries.sh` |
| **Exit** | Non-zero if hard violations found (warnings don't fail) |

### 6. `ic/scripts/coverage.sh` — Coverage Report Generator

| Field | Value |
|-------|-------|
| **Status** | ✅ Working (bash syntax valid) |
| **Language** | Bash |
| **Purpose** | Generates HTML/text/JSON/LCOV coverage reports via `cargo-llvm-cov` |
| **Requires** | `cargo-llvm-cov` installed |
| **Run** | `cd ic && ./scripts/coverage.sh [test_filter]` |

### 7. `ic/scripts/lunarwing-xmpp-test-env.sh` — Full-Stack Integration Harness

| Field | Value |
|-------|-------|
| **Status** | ✅ Working (bash syntax valid, 2650 lines) |
| **Language** | Bash |
| **Purpose** | Full-stack test environment: PostgreSQL, TensorZero proxy, XMPP bridge, WASM channels/tools, and the LunarWing daemon |
| **Commands** | `init`, `build`, `build-wasm`, `install-wasm`, `doctor`, `up`, `down`, `status`, `verify`, `start-postgres`, `start-proxy`, `start-bridge`, `start-lunarwing`, `repl`, etc. |
| **Docs** | `docs/ops/HARNESS-SINGLE-TENANT.md`, `docs/ops/MULTITENANCY-HARNESS.md`, `ic/testing/lunarwing-xmpp/README.md` |

### 8. `ic/tests/e2e/` — Playwright Browser E2E Tests

| Field | Value |
|-------|-------|
| **Status** | ⚠️ Exists but not reviewed in this task (separate test tier) |
| **Language** | Python (Playwright) |
| **Purpose** | Browser-based E2E tests against a live instance with a mock LLM |
| **Docs** | `ic/tests/e2e/CLAUDE.md` |

---

## What's Missing / Known Limitations

1. **Chaos scenarios not defined in tests.yaml** — The runner supports `chaos: true` scenarios (run only in `--mode full`), but no chaos scenarios are currently defined. Adding invalid-auth, timeout, and rate-limit chaos scenarios is a future improvement.

2. **No automated CI integration** — The worker test harness (`tests/runner.py`) and release-test.sh are designed for CI but no CI pipeline configuration exists in the repo to run them automatically.

3. **No performance/load testing** — Referenced in TESTING_GUIDE.md but no k6/locust scripts exist.

4. **Built-in and sandbox workers require pre-built binary** — These are behind the `full` Docker Compose profile and need `lunarwing:latest` image built first.

5. **Worker test harness not validated end-to-end on this machine** — Docker is not available in the current dev environment. Syntax and structural correctness verified; runtime validation deferred.

---

## Recommendations for Future Work

- Add chaos scenarios (invalid auth, timeout, resource exhaustion) to `tests.yaml`
- Set up CI (GitHub Actions) to run `python runner.py --mode smoke` on PRs
- Add performance/load test scripts (k6 or Locust)
- Validate the worker harness end-to-end once Docker is available
- Consider adding a `Makefile` target or `justfile` recipe that runs the full test suite (cargo test + runner.py + release-test.sh + check-boundaries.sh) in one command
