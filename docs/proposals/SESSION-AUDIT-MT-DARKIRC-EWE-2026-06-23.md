# Session Audit — MT Admin, DarkIRC, External Worker Enhancements (2026-06-23)

> Tracking document for the dev session on branch `1.1.6-OCS-A-4DIRCandEWE`.
> Covers three in-development feature areas. Use the Work Tracker below to record
> progress as items are addressed. Headline bugs were verified directly in source.

## Scope

This audit covers three feature areas currently in development for the 1.1.6 cycle:

1. **Multi-tenant admin setup** — `ic/scripts/lunarwing-mt-admin.sh` (4,799 lines)
2. **DarkIRC adapter + daemon** — WASM channel, Python adapter, external `darkirc` daemon
3. **External worker enhancements (EWE)** — WebSocket orchestrator client, connection pool, load balancer

---

## Work Tracker

Status legend: `TODO` · `IN PROGRESS` · `DONE` · `WONTFIX` · `DEFERRED`

### High priority (verified bugs)

| # | Item | Area | Location | Status |
|---|------|------|----------|--------|
| H1 | `on_status` UTF-8 byte-slice panic on >400-byte multibyte status messages | DarkIRC | `ic/channels-src/darkirc/src/lib.rs:354` | DONE |
| H2 | `--enable-darkirc` cannot be flipped on an existing tenant (resume path drops flag) | MT admin | `ic/scripts/lunarwing-mt-admin.sh:857-863` | DONE |
| H3 | `LeastConnections` strategy is dead code — silently behaves as RoundRobin | EWE | `ic/src/orchestrator/external_worker.rs:443-446` | DONE |

### Medium priority (security / correctness)

| # | Item | Area | Location | Status |
|---|------|------|----------|--------|
| M1 | `chmod 777` on worker workspace dirs breaks tenant isolation | MT admin | `lunarwing-mt-admin.sh:2230,2343,2789` | TODO |
| M2 | `tokens` command prints bearer tokens in cleartext (no `--reveal` gate) | MT admin | `lunarwing-mt-admin.sh:4362` (`show_tokens`) | TODO |
| M3 | DarkIRC adapter auth disabled by default; silent cross-tenant fallback to `:6680` | DarkIRC | `darkirc_adapter.py:356-360`, `lib.rs:92,263,351,428,509` | TODO |
| M4 | `/poll` is destructive — message loss on crash (no ACK/redelivery) | DarkIRC | `darkirc_adapter.py:379-384` | TODO |
| M5 | No body-size limit on hand-rolled adapter HTTP server (OOM DoS) | DarkIRC | `darkirc_adapter.py:364` | TODO |
| M6 | Non-constant-time bearer comparison in adapter | DarkIRC | `darkirc_adapter.py:358` | TODO |
| M7 | `auth_token` stored as plain `Option<String>`, not `SecretString` | EWE | `config/sandbox.rs:191,209` | TODO |
| M8 | No graceful `pool.drain()` on shutdown; no background `evict_stale()` | EWE | `main.rs:1217`, `external_worker.rs:215` | TODO |
| M9 | Failover is connection-only — no retry on `ProtocolError`/timeout | EWE | `external_worker.rs:260-323` | TODO |

### Low priority / quality

| # | Item | Area | Location | Status |
|---|------|------|----------|--------|
| L1 | Hardcoded health port `8443` (acknowledged unfinished in commit `175d2686`) | MT admin | `lunarwing-mt-admin.sh:2180,2243,2301,2356,2780` | TODO |
| L2 | Hardcoded `DEFAULT_TENSORZERO_URL=http://192.168.1.157:3000/...` | MT admin | `lunarwing-mt-admin.sh:31` | TODO |
| L3 | ~~Duplicated byte-identical DarkIRC source trees~~ **Non-issue** — `ic/channels-src/darkirc` is a symlink to `darkirc_channel_for_ironclaw/darkirc` (same inode); single source of truth | DarkIRC | WONTFIX |
| L4 | Stale DarkIRC docs (`aiohttp` claim, `darkirc_keypair.yaml`, Unix-socket line) | DarkIRC | `DARKIRC_MT_ADAPTER.md:95`, `darkirc.env:17-18` | TODO |
| L5 | `LoadBalancer::new` `assert!` + `lb.unwrap()` are production panics | EWE | `external_worker.rs:433,265` | TODO |
| L6 | No backpressure / concurrency cap on external worker tasks | EWE | `external_worker.rs` (max_idle_per_endpoint bounds only idle) | TODO |
| L7 | `ws://` cleartext default; no enforcement/warning for remote workers | EWE | `config/sandbox.rs:564-568` | TODO |
| L8 | `FEATURE_PARITY.md` has no rows for MT admin, DarkIRC, or external workers | All | `ic/FEATURE_PARITY.md` | TODO |

### Test gaps

| # | Item | Area | Status |
|---|------|------|--------|
| T1 | Add mock-WS integration test for external worker lifecycle (success/timeout/cancel/failover/pool-reuse) | EWE | DONE |
| T2 | Add regression test for H1 (DarkIRC `on_status` multibyte truncation) | DarkIRC | DONE |
| T3 | Add real-pool eviction test (current tests only touch empty pool) | EWE | TODO |
| T4 | Add DarkIRC adapter integration test (mock IRC server: registration/PING/queue/poll/send/503/auth/oversize) | DarkIRC | TODO |
| T5 | Add regression test for H2 (enable-darkirc flag flip on existing tenant) | MT admin | DONE |
| T6 | Fill/remove empty bug stubs (`BUG-external-worker-loadbalancer-failover-problem.md`, `BUG-external-worker-test.md`) | EWE | TODO |
| T7 | Add `shellcheck` gate for `lunarwing-mt-admin.sh` | MT admin | TODO |

---

## 1. Multi-Tenant Admin Setup

`ic/scripts/lunarwing-mt-admin.sh` — 4,799 lines. Creates one OS user + 10-port block (range 10000–19999) + per-tenant Postgres container + systemd/OpenRC units per tenant. Sourced (not just executed) by `enable-health-fleet.sh` and `upgrade-tenant-version.sh`, so it dispatches via `BASH_SOURCE` guard.

### What it does (per tenant)
1. Validate name (`sanitize_name`, reject reserved prefixes `pg-*`/`proxy-*`/`nanocode-*`/etc).
2. Allocate a 10-port block; write tenant record to `/etc/lunarwing/ports.json`.
3. `useradd` + subuid/subgid for rootless podman + linger + rustup/WASM toolchain.
4. Clone repo into `/home/<t>/lunarwing`.
5. Write env files (lunarwing/bridge/proxy/darkirc-adapter/gotify/worker configs).
6. Start per-tenant Postgres container `lunarwing-pg-<t>`.
7. Render systemd or OpenRC units.
8. Install health/self-heal pipeline (host-global, once).

### Isolation model
- One OS user per tenant; one 10-port block per tenant; one per-tenant Postgres container (random password in 0600 `pg.secret`); rootless podman per tenant; all listeners bind `127.0.0.1` only.

### The new `--enable-darkirc` flag (commit `31a13001`)
Makes DarkIRC opt-in per tenant (previously always provisioned). Default disabled. Persisted as `enable_darkirc` in `ports.json`; read back by `tenant_darkirc_enabled()`. When enabled: appends `DARKIRC_ADAPTER_URL/SECRET` to `lunarwing.env`, writes adapter env + daemon TOML, renders `lunarwing-darkirc-<t>.service` + `lunarwing-darkirc-adapter-<t>.service`, and gates `status`/`patch-env`/start paths.

### Confirmed bug (H2)
`ports_allocate()` at `lunarwing-mt-admin.sh:857-863`: the resume path returns early **without writing `enable_darkirc`** if the tenant already has a `base_port`. But `add_tenant()` at `:4051-4054` still writes adapter env/TOML from the in-memory flag. Result: a half-configured tenant — adapter env exists, but `lunarwing.env` lacks the URL/SECRET, no units render, no services start. No documented way to enable darkirc on an existing tenant except hand-editing `ports.json`.

### Other findings
- **L1 / Hardcoded `8443` health port** — comment at `:2232-2236` argues it's safe (probe runs inside container netns, port not published). Commit `175d2686` flags it as unfinished. Breaks if netns is shared.
- **M1 / `chmod 777` workspace dirs** — any local host user can read/tamper with any tenant's workspace (bind-mounted into containers). Should be `0750`/`0770`.
- **M2 / `tokens` cleartext** — `show_tokens()` prints full gateway bearer tokens to stdout. Add `--reveal` gate or redacted-by-default.
- **L2 / Hardcoded TensorZero IP** — `DEFAULT_TENSORZERO_URL` pins `192.168.1.157`; override via `LUNARWING_MT_TENSORZERO_URL`.
- **Idempotency** is otherwise strong: secrets preserved on re-run, port blocks reused, `restore-tenant` requires `--yes`.

---

## 2. DarkIRC Adapter + Daemon

A **three-process per-tenant stack**: WASM channel (`ic/channels-src/darkirc/src/lib.rs`) → Python HTTP adapter (`adapter/darkirc_adapter.py`) → external `darkirc` daemon (built from darkfi via `make darkirc`). Transport is loopback HTTP (not a Unix socket — the `BRIDGE_SOCKET` line in `darkirc.env` is stale).

### Architecture
```
LunarWing host → WASM darkirc.wasm ─HTTP/Bearer→ adapter (Python asyncio)
   adapter ─raw IRC/TCP→ darkirc daemon ─P2P/Tor→ DarkFi network
```
- WASM channel: poll-driven (`on_poll` ≥3s), `on_respond`/`on_broadcast`/`on_status`. Secret injected by host as Bearer; HTTP allowlisted to `127.0.0.1`.
- Adapter: Python stdlib-only (NOT aiohttp despite docs). Hand-rolled HTTP server (3 routes) + minimal IRC client. Reconnect with exponential backoff (5s→300s). `deque(maxlen=500)` inbound buffer (silent drop on overflow).
- Daemon: per-tenant TOML config, per-tenant ChaCha keypairs. Built by `build_darkirc` in the admin script (clones darkfi as tenant user, `make darkirc`, installs to `/usr/local/bin/darkirc` as root).

### Confirmed bug (H1)
`ic/channels-src/darkirc/src/lib.rs:354`:
```rust
format!("{}...", &message[..MAX_IRC_MESSAGE_BYTES - 3])
```
Byte-index slice at 397 panics if that byte isn't a char boundary — any emoji/CJK/accented status >400 bytes traps the WASM instance. The send path uses safe `split_message`; this one path diverges. **Fix:** use `split_message(...).next()` or `floor_char_boundary`.

### Other findings
- **M3 / Auth off by default** — `ADAPTER_SECRET=""` skips the bearer check; shipped `.service` has the line commented out. Five fallbacks to `http://127.0.0.1:6680` in `lib.rs` mean a failed env injection could route a tenant to another tenant's adapter.
- **M4 / Destructive `/poll`** — `popleft` before HTTP response delivered → message loss on crash. No ACK, no persistence.
- **M5 / No body-size limit** — `reader.readexactly(content_length)` trusts the header → OOM DoS.
- **M6 / Non-constant-time comparison** — use `hmac.compare_digest`.
- **L3 / Duplicated source trees** — `darkirc_channel_for_ironclaw/darkirc/` and `ic/channels-src/darkirc/` are byte-identical. Host builds from `ic/channels-src/`; the root copy risks staleness.
- **L4 / Stale docs** — `aiohttp` dependency claim (adapter is stdlib-only); `darkirc_keypair.yaml` claim (no such file is generated); Unix-socket line in `darkirc.env`.
- **Minor** — pairing codes logged at Info (`lib.rs:422`); nick-collision loop unbounded (`darkirc_adapter.py:282`); partial-success treated as full success (`lib.rs:546`).

### Test coverage
- Strong Rust unit tests on `split_message` (byte safety, CRLF normalization, unicode scripts).
- Python tests on `_split_message_bytes` (`test_split.py`).
- Host regression test `darkirc_adapter_url_injected_from_env` in `setup.rs:644-679`.
- **Gaps:** no E2E test loads the real WASM; no adapter integration test with a mock IRC server; the QA scenarios in `DARKIRC_MT_ADAPTER.md` are explicitly marked "not yet executed"; H1 (`on_status`) has zero coverage.

---

## 3. External Worker Enhancements (EWE)

Two independent subsystems share `ic/src/orchestrator/`:
- **(A) Docker sandbox workers** — internal HTTP API on `:50051`, per-job bearer tokens (`TokenStore`, constant-time), `SandboxReaper` orphan cleanup, bind-mount validation.
- **(B) External workers (EWE)** — the focus. A WebSocket **client** speaking the `ironclaw-agent-v1` subprotocol. `Envelope { id, type, timestamp, payload }` with message types `ready`/`task_request`/`task_progress`/`task_result`/`cancel`/`pong`.

EWE is an 11-task plan (see `EXTERNAL-WORKER-PLAN-UPGRADES.md` + `EXTERNAL-WORKER-UPGRADES-PROGRESS.md`), all marked complete. Concrete deltas: typed `TaskContext` (replaces `"context": {}`), `ExternalTaskStatus` enum, multi-instance `WorkerEndpoint` config, `WorkerConnectionPool` (`max_idle_per_endpoint: 2`, `idle_timeout: 300s`), round-robin `LoadBalancer`, credential injection via `SecretsStore` into `TaskContext.environment`.

### Confirmed bug (H3)
`ic/src/orchestrator/external_worker.rs:443-446`: `next_endpoint()` always round-robins (`fetch_add % len`) regardless of strategy. There is no strategy check and no `active_connections` tracking. Selecting `LeastConnections` silently behaves as RoundRobin. The plan's Task 6 acceptance ("picks minimum") was never satisfied. **Fix:** either implement `active_connections` counting, or remove `LeastConnections` from the enum to stop misleading operators.

### Other findings
- **M8 / No shutdown drain** — `main.rs:1217` sends a shutdown broadcast but never wires it to `pool.drain()`; WS connections die without a close frame. No background `evict_stale()` task (only opportunistic at `execute_task` start).
- **M9 / Failover is connection-only** — retries to the next endpoint only on `ExternalWorkerConnectionFailed`, not on `ProtocolError`/timeout. A worker that dies mid-task after handshake isn't retried. (`BUG-external-worker-loadbalancer-failover-problem.md` is an empty stub.)
- **M7 / `auth_token` plain `Option<String>`** — violates the secrecy rule; no compile-time protection against future leakage.
- **L5 / Production panics** — `LoadBalancer::new` `assert!` (`:433`) and `lb.unwrap()` (`:265`); currently guarded but brittle.
- **L6 / No backpressure** — `max_idle_per_endpoint` bounds only idle conns; a burst of `create_job` calls opens unbounded WS connections. No semaphore.
- **L7 / `ws://` cleartext default** — credentials/prompts traverse in cleartext; no enforcement/warning for remote workers.

### Fault-injection scripts (commit `051aded5`)
`ic/scripts/fault-inject-respawn.sh` (single-kill respawn latency) and `fault-inject-crash-loop.sh` (crash-loop exhaustion → self-heal backstop). **Important:** these test the OpenRC + supervise-daemon + rootless-podman **babysitter layer**, NOT the Rust orchestrator's worker handling (timeouts, cancel, failover, pool poisoning). They require a live OpenRC host and are not in `cargo test`.

### Test coverage
- ~18 unit tests on data structures, config TOML contracts, empty-pool behavior, auth, and the Docker API.
- **T1 — DONE (2026-06-23):** added `ic/tests/external_worker_integration.rs` — a mock worker speaking `ironclaw-agent-v1` on an ephemeral loopback port, exercising the real `ExternalWorkerManager::execute_task` end-to-end. Covers: happy path (progress + result, incl. empty-output fallback), failed result, task timeout → `ExternalWorkerTimeout`, cancel in-flight → `Cancelled`, connection failure → `ExternalWorkerConnectionFailed`, closed-before-ready → `ExternalWorkerProtocolError`, and **connection-pool reuse** (asserts a single TCP accept across two sequential successful tasks). Deterministic across repeated runs; clippy/fmt-clean. No PostgreSQL/Docker required.

### Finding from T1: WebSocket subprotocol echo is mandatory
Writing the mock surfaced a hard protocol requirement: `connect_and_handshake` always sends `Sec-WebSocket-Protocol: ironclaw-agent-v1`, and the client's tungstenite **rejects** the handshake if the server sends no subprotocol back (`WebSocket protocol error: SubProtocol error: Server sent no subprotocol`). The mock had to use `accept_hdr_async` with a callback echoing the subprotocol. **Implication:** the real worker containers (nanocode/codex/pebble) MUST echo `ironclaw-agent-v1` in their WS upgrade response, or every EWE connection fails. Worth verifying in the worker repos (`lunarcode4lunarwing/`, `codex4lunarwing/`, `pebble4lunarwing/`) — if any doesn't echo it, that worker is silently broken against the current orchestrator.

---

## Recommended Starting Points

| Priority | Item | Rationale |
|---|---|---|
| 1 | **H1** DarkIRC `on_status` UTF-8 panic | One-line fix; live WASM trap on non-ASCII status; T2 regression test is cheap |
| 2 | **H3** `LeastConnections` dead code | Silent operator footgun; plan marked it done |
| 3 | **H2** enable-darkirc flag flip | Documented operator workflow is broken |
| 4 | **T1** mock-WS EWE integration test | Biggest test gap across all three areas |
| 5 | **M8** wire `pool.drain()` + background `evict_stale()` | Stale-connection hygiene on shutdown |

### Additional areas to investigate later
- `SandboxReaper` (`reaper.rs`) doesn't cover external-worker WS connections — orphaned/hung WS have no reaper.
- Credential cleanup consistency across the three worker containers (nanocode/codex/pebble); the audit (`EXTERNAL-WORKER-AUDIT-2026-06-23.md`) recommends a chaos test.
- Whether `pebble4lunarwing/` and the worker containers consume `TaskContext.environment` correctly end-to-end.
- T7: a `shellcheck` gate for `lunarwing-mt-admin.sh` (4,799 lines, no static analysis; SC2086 quoting issues likely).

---

## References

- DarkIRC MT flag changelog: `docs/ops/DARKIRC-MULTITENANT-CHANGES-JUN23-FLAG-INFO.md`
- DarkIRC MT runbook: `docs/ops/DARKIRC-MULTITENANT.md`
- EWE plan: `docs/proposals/EXTERNAL-WORKER-PLAN-UPGRADES.md`
- EWE progress: `docs/proposals/EXTERNAL-WORKER-UPGRADES-PROGRESS.md`
- EWE security audit: `docs/proposals/EXTERNAL-WORKER-AUDIT-2026-06-23.md`
- Fault-injection scripts: `ic/scripts/fault-inject-respawn.sh`, `ic/scripts/fault-inject-crash-loop.sh`
