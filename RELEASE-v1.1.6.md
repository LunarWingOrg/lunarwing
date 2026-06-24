# Release Notes for LunarWing v1.1.6 — Codename `Reversible Extinction`

**Release Date:** To Be Determined

## Overview

Per the release cadence (`docs/ops/RELEASE_CADENCE.md`), **even-numbered releases focus on new features and capability expansion**. v1.1.6 is a feature release, and its centerpiece is the **External Worker Enhancement (EWE)** suite — a set of upgrades that transform the orchestrator's external-worker integration from a stateless one-shot caller into an efficient persistent work-delegation system with a real connection pool, typed task context, multi-instance load balancing, and credential injection. The EWE plan (`docs/proposals/EXTERNAL-WORKER-PLAN-UPGRADES.md`, 11 tasks) is fully implemented and tested.

The second major theme is **DarkIRC multi-tenant hardening**: the DarkIRC adapter and WASM channel are now opt-in per tenant (`--enable-darkirc`), and a comprehensive security/robustness pass closes the adapter's auth, delivery, and DoS gaps.

A third focus is the **v8 ports schema**: dedicated per-tenant health ports for the nanocode and pebble workers, finally giving the host self-heal pipeline a direct `/health` probe path that was impossible with the hardcoded port model.

Additional features include **per-tenant nanocode model/baseURL overrides**, a **rootless-podman babysitter** with fault-injection test scripts, a **shellcheck quality gate** for the multi-tenant admin script, a legacy upgrade script which can perform in place upgrades of LunarWing agents from the legacy 1.0.0-1.0.5 period up to 1.1.2 safely and effectively (with rollback in case something goes wrong), and the decision to **deprecate the codex worker** (following OpenAI's removal of chat completions support).

This release **does not** add database schema changes.

---

## Changes

### External Worker Enhancements (EWE)

The orchestrator's external-worker subsystem (`ic/src/orchestrator/external_worker.rs`) has been upgraded across 11 task areas. Full plan + progress: `docs/proposals/EXTERNAL-WORKER-PLAN-UPGRADES.md`, `docs/proposals/EXTERNAL-WORKER-UPGRADES-PROGRESS.md`.

#### Connection Pool

A new `WorkerConnectionPool` (`max_idle_per_endpoint: 2`, `idle_timeout: 300s`) reuses WebSocket streams across sequential tasks to the same worker endpoint, avoiding the connect+handshake cost on every call. Connections are returned to the pool only on task success (failures drop the connection to avoid corruption). Stale connections are evicted both opportunistically (at the start of each `execute_task`) and by a **background eviction task** (60s interval, shutdown-cancelled) added in M8.

#### Load Balancer — RoundRobin + LeastConnections (with active-connection tracking)

- **`LoadBalancer`** selects an endpoint per `execute_task` call. Two strategies: `RoundRobin` (lock-free `AtomicUsize` cycle) and `LeastConnections` (picks the endpoint with the fewest in-flight tasks via per-endpoint `AtomicUsize` counters).
- **`EndpointLease`** (RAII guard): `acquire()` increments the active count; `Drop` decrements it. The lease is `Send+Sync`, held for the task's lifetime on both the synchronous (`wait=true`) and fire-and-forget (`wait=false`, moved into `tokio::spawn`) paths.
- The lease derefs to `WorkerEndpoint`, so call sites access `.url` / `.auth_token` transparently.
- **Circuit-breaker failover (M9):** `acquire_excluding(excluded_urls)` skips endpoints that just failed on retry, so `LeastConnections` doesn't re-pick the dead one. Both strategies now get multi-endpoint failover (previously RoundRobin-only).

#### Graceful Drain + Background Eviction (M8)

- `WorkerConnectionPool::drain()` now sends a WS `Close(None)` frame to each pooled connection (bounded 2s per connection) before clearing — a graceful shutdown handshake instead of an abrupt TCP drop.
- `ExternalWorkerManager::spawn_eviction_task(shutdown_rx)` runs `evict_stale()` every 60s as a background `tokio::spawn`, cancelled by the shutdown broadcast.
- Both are wired into `main.rs`: the eviction task is spawned after `shutdown_tx` is created, and `drain_pool()` is called in the shutdown block (alongside MCP/webhook shutdown).

#### Typed TaskContext + Credential Injection

- **`TaskContext`** struct (`project_dir`, `conversation_history: Vec<ConversationMessage>`, `environment: HashMap<String,String>`, `user_id`, `metadata`) replaces the previous `"context": {}` placeholder. All fields are `#[serde(default)]` for backward compatibility with older workers.
- **`ExternalTaskStatus`** enum (`Success`/`Failed`/`Cancelled`/`TimedOut`/`Partial(String)`) replaces the stringly-typed `status: String` compared with `== "success"`.
- **`build_task_context()` + credential injection** (`job.rs`): `CreateJobTool::execute_external()` resolves `CredentialGrant`s via `SecretsStore::get_decrypted()` into `TaskContext.environment`, and populates `conversation_history` from `conv_`-prefixed metadata keys. The `create_job` tool's `parameters_schema` now exposes `project_dir` and `credentials` for external mode.

#### Multi-Instance Config

- **`WorkerEndpoint`** (`url`, `auth_token`, `weight`) + **`endpoints: Vec<WorkerEndpoint>`** on `ExternalWorkerConfig` / `ExternalWorkerSettings`. Legacy single-`url`/`auth_token` form still works via `endpoints()` fallback.
- **`LoadBalanceStrategy`** enum (`RoundRobin` default, `LeastConnections`) in `[[sandbox.external_workers]]` TOML.

#### Bearer Token — `secrecy::SecretString` (M7)

The external-worker `auth_token` is now `Option<SecretString>` at every layer (`WorkerEndpoint`, `ExternalWorkerConfig`, `ExternalWorkerSettings`). The token can no longer be accidentally logged (`Debug` auto-redacts to `[REDACTED]`) or serialized out (`#[serde(skip_serializing)]`). Exposed to `&str` only at the single use site (`format!("Bearer {token}")` in `connect_and_handshake`). Verified with two end-to-end auth integration tests (`auth_correct_token_succeeds`, `auth_wrong_token_rejected`).

#### Pebble Worker — Subprotocol Echo Fix

The pebble worker (`pebble4lunarwing/src/bridge.rs`) validated the `ironclaw-agent-v1` subprotocol offered by the client but **did not echo it back** in the upgrade response — causing the orchestrator's tungstenite to reject every pebble connection with *"Server sent no subprotocol"*. **Fixed**: the `accept_hdr_async` callback now inserts `Sec-WebSocket-Protocol: ironclaw-agent-v1` into the response. This was a confirmed production bug — the EWE live-QA evidently never exercised the pebble WS path.

#### Integration Tests (T1)

`ic/tests/external_worker_integration.rs` — a mock worker speaking `ironclaw-agent-v1` on an ephemeral loopback port, exercising the real `ExternalWorkerManager::execute_task` end-to-end. 10 tests: happy path (progress + result, incl. empty-output fallback), failed result, task timeout → `ExternalWorkerTimeout`, cancel in-flight → `Cancelled`, connection failure → `ExternalWorkerConnectionFailed`, closed-before-ready → `ExternalWorkerProtocolError`, connection-pool reuse (asserts single TCP accept across two sequential tasks), and two auth tests (correct accepted, wrong → connection failure). Deterministic across repeated runs. No PostgreSQL/Docker required.

### DarkIRC Multi-Tenant Hardening

#### Opt-In Per Tenant — `--enable-darkirc` Flag (H2)

DarkIRC provisioning is now **opt-in per tenant** via `add-tenant --enable-darkirc` (previously always provisioned). The flag is persisted as `enable_darkirc` in `/etc/lunarwing/ports.json`. When enabled: writes `DARKIRC_ADAPTER_URL`/`SECRET` to `lunarwing.env`, generates the adapter env + daemon TOML, renders the darkirc + adapter units, and gates `status`/`patch-env`/start paths.

A **resume-path flag flip** bug (H2) was also fixed: re-running `add-tenant <existing> --enable-darkirc` now correctly flips the registry flag (via `ports_enable_darkirc`), so the tenant doesn't end up half-configured.

#### Adapter Security Hardening (M3, M4, M5, M6)

A comprehensive security/robustness pass on the Python adapter (`darkirc_adapter.py`) + WASM channel (`lib.rs`):

- **M6 — Constant-time auth:** `!=` replaced with `hmac.compare_digest` for the bearer comparison, eliminating a timing oracle on the secret.
- **M5 — Body-size cap:** `Content-Length` capped at `MAX_BODY_BYTES=64KiB`; oversize → 413, malformed/non-numeric → 400 (previously `int()` would throw uncaught → connection drop). Prevents OOM DoS on the hand-rolled HTTP server.
- **M3 — Fail-closed on missing adapter URL:** `default_adapter_url()` → empty (no `:6680` fallback). A misconfigured tenant whose env injection fails now gets a graceful error instead of silently routing to a potentially-wrong `:6680` adapter. The `on_start` handler skips writing an empty URL; the adapter logs a WARNING on missing `ADAPTER_SECRET`. The `:6680` cross-tenant path is eliminated.
- **M4 — At-least-once delivery:** `/poll` now holds the served batch in a `pending_ack` deque; a new `/ack` endpoint clears it. The WASM `on_poll` POSTs `/ack` after emitting. If the host crashes before acking, the next `/poll` re-serves the batch — no more message loss on crash. Duplicates are avoided in normal flow (the ack happens synchronously before the next poll tick ≥3s later).

#### Adapter Integration Tests (T4)

`adapter/test_adapter_integration.py` — mock IRC server + real adapter subprocess, 8 tests: health, auth (wrong/no token → 401), oversize → 413, malformed CL → 400, poll+ack no-duplicate, poll-without-ack redelivers (at-least-once), `/send` forwards PRIVMSG to IRC server.

#### UTF-8 Truncation Panic Fix (H1)

`ic/channels-src/darkirc/src/lib.rs` `on_status` sliced `&message[..MAX_IRC_MESSAGE_BYTES - 3]` — a byte-index that panics if it lands mid-codepoint (any emoji/CJK/accented status >400 bytes would trap the WASM instance). **Fixed** with a `truncate_for_status()` helper using `floor_char_boundary`. Regression tests cover ASCII, 2-byte/3-byte/4-byte scripts, and boundary-straddling.

### v8 Ports Schema — Dedicated Per-Tenant Worker Health Ports

The v7 base block was full (10/10) and the worker `HEALTH_PORT` was a hardcoded `8443` across ~10 sites — never registry-allocated, never published, so the host self-heal could only read container-runtime health state (no direct `curl`). **v8** names two existing extended slots as dedicated health ports (no renumber, no `block_size` change):
- `extended_ports.reserved_3 → nanocode_health` (= `extended_base + 3`)
- `extended_ports.reserved_4 → pebble_health` (= `extended_base + 4`)

**Publish-alias design**: the container still listens on `8443` internally (matches the image's baked HEALTHCHECK → no image rebuild); the per-tenant host port is published → container `8443` (`PublishPort=127.0.0.1:<health>:8443` in the Quadlet, `-p` in the imperative path), giving the host a direct `/health` probe path.

Delivered: standalone `ic/scripts/migrate-ports-v8.sh` (idempotent, backup, collision check, rollback hint), `ports_migrate_v8()` in mt-admin (auto-runs on any mt-admin invocation), `ports_allocate` emits the new slots for fresh tenants, and all three init paths (systemd Quadlet, OpenRC, imperative) publish the port. Live-verified on a production tenant (`curl http://127.0.0.1:20013/health` returns `{"status":"ok",...}`).

### Nanocode Per-Tenant Model/baseURL Overrides

Nanocode worker LLM model + TensorZero baseURL can now be overridden per tenant without rebuilding the image:
- **`add-tenant`/`add-tenants` flags:** `--nanocode-model <model>` / `--nanocode-base-url <url>`.
- **Existing tenants:** `configure-nanocode <name> --model <model> --base-url <url>` (mirrors `configure-pebble`).
- Values stored in `lunarwing.env` as `NANOCODE_MODEL` / `NANOCODE_BASE_URL`; both init paths (systemd Quadlet `Environment=` + OpenRC `-e`) inject them into the container.
- The worker `entrypoint.sh` materializes an overridden `.nanocode/nanocode.json` (python JSON edit) when either var is set; else keeps the symlink default. No image rebuild.
- Live-verified on a production tenant: `model=tensorzero::function_name::baud`, `baseURL=http://192.168.1.157:3000/openai/v1`.

### Worker Image Management — ID Comparison + Prune Fix

`_ensure_tenant_image()` now compares the **image ID** (not just name existence) between the admin (root) store and the tenant's rootless store — so a rebuilt image actually reaches tenants instead of being silently held back by a stale same-named copy. After loading, `image prune -f` drops the now-untagged old image so updates don't accumulate GBs of layers (the root cause of disk-thrash during image refresh operations).

### Rootless-Podman Babysitter + Fault Injection Scripts

- **`ic/scripts/lunarwing-ctr-babysit.sh`** — a parent-supervisor that wraps `podman wait` to detect container exits and respawn within seconds (via supervise-daemon on OpenRC, or a systemd-timer on systemd), closing the crash-recovery-latency gap (previously ~30 min worst case via the 15-minute self-heal sweep).
- **`ic/scripts/fault-inject-respawn.sh`** — single-kill respawn latency test: kills a worker container, polls until `supervise-daemon` respawns it, asserts `elapsed ≤ threshold` (default 4s). Validates the babysitter.
- **`ic/scripts/fault-inject-crash-loop.sh`** — crash-loop exhaustion → self-heal backstop: kills repeatedly to exhaust the respawn budget, asserts the unit enters `failed`, then optionally invokes the self-heal pipeline. Validates the full degradation → remediation → escalation path.

These test the **OpenRC + supervise-daemon + rootless-podman babysitter layer**, NOT the Rust orchestrator's worker handling (which is covered by T1). They require a live OpenRC host and are not in `cargo test`.

### Codex Worker Deprecation

Following OpenAI's removal of the chat completions API (which the codex worker depends on), **codex (`codex4lunarwing/`) is deprecated** and will be removed in a future release very soon. Nanocode and pebble workers remain fully supported. This is the reason why it's not been getting updates or getting routed into the other mechanisms as a first class citizen.

### Cargo Test Fixes

16 previously-failing cargo tests were investigated and fixed (tracked in `docs/proposals/CARGO_TESTS_FIX.md`). The remaining failures are a small handful of env-dependent e2e tests unrelated to core functionality.

### Shellcheck Quality Gate (T7)

- Fixed 3 existing shellcheck warnings on `lunarwing-mt-admin.sh` (SC2120 `require_root` references `$*` with no args; SC2155 `local x=$(...)` masking return; SC2034 unused `repo_dir`).
- Added `ic/scripts/.shellcheckrc` + `ic/scripts/check-mt-admin.sh` (gate script: `shellcheck -S warning`, exits 0/1/2). The gate passes clean (0 warnings).

---

## Bug Fixes

- **DarkIRC `on_status` UTF-8 panic (H1).** A byte-index slice at `message[..397]` panicked if byte 397 fell inside a multibyte codepoint. Any emoji/CJK/accented status message >400 bytes would trap the WASM instance. Fixed with `truncate_for_status()` using `floor_char_boundary`. Regression tests cover ASCII, accented Latin, Japanese, Korean, Arabic, emoji, and boundary-straddling.
- **`--enable-darkirc` could not be enabled on an existing tenant (H2).** The resume path in `ports_allocate()` returned early without writing `enable_darkirc` to the registry, while `add_tenant()` still wrote adapter env/TOML from the in-memory flag — leaving the tenant half-configured. Fixed with `ports_enable_darkirc()` (one-directional, idempotent).
- **`LeastConnections` load balancer was dead code (H3).** `next_endpoint()` always round-robins regardless of strategy — selecting `LeastConnections` silently behaved as RoundRobin. Replaced with a strategy-aware `acquire()` + `EndpointLease` with per-endpoint active-connection tracking.
- **DarkIRC adapter bearer comparison was non-constant-time (M6).** Replaced `!=` with `hmac.compare_digest`.
- **DarkIRC adapter had no body-size limit (M5).** Added `MAX_BODY_BYTES=64KiB` cap; oversize → 413, malformed CL → 400.
- **DarkIRC adapter `:6680` silent fallback (M3).** `default_adapter_url()` → empty; fail-closed when no tenant-specific URL configured.
- **DarkIRC `/poll` was destructive — message loss on crash (M4).** Added `pending_ack` + `/ack` endpoint for at-least-once delivery.
- **Pebble worker did not echo the `ironclaw-agent-v1` WS subprotocol.** Caused every pebble connection from the orchestrator to fail with "Server sent no subprotocol". Fixed the `accept_hdr_async` callback.
- **No graceful pool drain on shutdown (M8).** WS connections were abruptly dropped without a Close frame. `drain()` now sends Close(None) with a 2s bound per connection.
- **Failover was RoundRobin-only (M9).** LeastConnections multi-endpoint configs got no failover. Removed the gate; added circuit-breaker (`acquire_excluding`).
- **`_ensure_tenant_image` skipped re-transfer when image name existed (stale copy held back updates).** Now compares image IDs; prunes old image after load.
- **Hardcoded `8443` health port (L1).** Resolved by the v8 ports schema (dedicated per-tenant health ports).
- **Shellcheck warnings in `lunarwing-mt-admin.sh`.** Fixed SC2120, SC2155, SC2034.

---

## Documentation

- `docs/proposals/SESSION-AUDIT-MT-DARKIRC-EWE-2026-06-23.md` — the comprehensive session audit tracker covering all three feature areas (MT admin, DarkIRC, EWE) with verified findings and fix records.
- `docs/proposals/EXTERNAL-WORKER-PLAN-UPGRADES.md` + `EXTERNAL-WORKER-UPGRADES-PROGRESS.md` — the 11-task EWE plan + progress tracker.
- `docs/proposals/EXTERNAL-WORKER-AUDIT-2026-06-23.md` — EWE security audit (TaskContext population, credential cleanup analysis, residual risks).
- `docs/ops/DARKIRC-MULTITENANT-CHANGES-JUN23-FLAG-INFO.md` — changelog for the `--enable-darkirc` opt-in flag.
- `docs/ops/DARKIRC-MULTITENANT.md` — updated DarkIRC multi-tenant runbook.
- `docs/proposals/CARGO_TESTS_FIX.md` — cargo test fix tracking.
- `docs/ops/GOALS_1.1.6.md` — v1.1.6 pre-release checklist.
- Worker docs updated: `lunarcode4lunarwing/CLAUDE.md` (env var table + TensorZero routing note), `.env.example` (override vars).
- `pebble4lunarwing/CLAUDE.md` — confirmed as current.

---

## Known Issues (not a complete list — see `docs/bugs` and `docs/proposals` for more)

- **Worker failover is connection-failure-only (not protocol-error/timeout).** The circuit-breaker (`acquire_excluding`) retries to the next endpoint only on `ExternalWorkerConnectionFailed`. A worker that accepts the WS, completes the handshake, then dies mid-task returns `ExternalWorkerProtocolError` and is **not** retried. This is deliberate (retrying a partially-executed task risks side effects) but may be revisited.
- **No backpressure / concurrency cap on external worker tasks.** `max_idle_per_endpoint` bounds only idle pooled connections, not in-flight tasks. A burst of `create_job` calls opens unbounded WS connections (no semaphore). Mitigated on loopback but could be an issue for remote worker endpoints.
- **`LoadBalancer::new` uses `assert!` + `lb.unwrap()`.** Currently safe (the manager always passes ≥1 endpoint via `endpoints()` fallback) but violates the repo's no-panics-in-production rule. Tracked as L5.
- **`tokens` command prints bearer tokens in cleartext.** `show_tokens()` outputs full gateway tokens to stdout with no `--reveal` gate. Tracked as M2.
- **`chmod 777` on worker workspace dirs.** Needed because workers run as non-root container users mapped to subuids, but it means any local host user can read/tamper with tenant workspaces. The proper fix requires a `:U` bind-mount flag or UID coordination. Tracked as M1.
- **Hardcoded `DEFAULT_TENSORZERO_URL` (192.168.1.157).** Override via `LUNARWING_MT_TENSORZERO_URL`. The nanocode baseURL is now separately configurable per tenant. Tracked as L2.
- **XMPP inbound file transfer — live e2e validation still pending.** The full receive pipeline is unit-tested but has not been exercised end-to-end against a real server.
- **Inbound XMPP downloads have no SSRF guard.** The client fetches sender-supplied URLs without blocking private/loopback IPs.
- **Kawarimi cross-machine migration is PostgreSQL-only.** libSQL tenants are refused by the migration tooling.
- **Machine migration is a cutover with per-tenant downtime.**
- **WeeChat health-glob flap.** An optional/stopped weechat backend matches the `lunarwing-*` health-discovery glob. Known Workaround: only enable weechat units for tenants that use it
- **`podman save | load` image distribution is slow.** The `_ensure_tenant_image` prune fix addresses accumulation but not transfer speed. A shared read-only image store remains a future optimization
- **`/api/logs/download` has no UI button.** The endpoint exists but the gateway UI button has not been added
- **Multica bridge remains pre-release/experimental.**

---

## Upgrade Notes

1. **No new database migrations.** v1.1.6 adds no schema changes. PostgreSQL 15+ remains required. **Back up your database before upgrading.**
2. **Ports registry auto-migrates v7 → v8.** Any `lunarwing-mt-admin.sh` invocation runs `ports_migrate_v8()` automatically. The standalone `ic/scripts/migrate-ports-v8.sh` can also be run explicitly (it backs up + validates + is idempotent). Existing tenants' port numbers are unchanged (rename-only: `reserved_3/4 → nanocode_health/pebble_health`).
3. **To gain the dedicated health port, re-render + restart worker units.** After the v8 migration, run `render-units <tenant>` (or `restart-tenant <tenant>`) so the new `PublishPort=127.0.0.1:<health>:8443` line is applied. No worker image rebuild is needed (the container stays on `8443` internally).
4. **Multi-tenant operators with DarkIRC:** DarkIRC is now opt-in. Existing tenants that had DarkIRC will need `--enable-darkirc` on the next `add-tenant` re-run (or the flag is already in the registry if it was set before). Disabling DarkIRC post-provision remains a manual teardown (`docs/ops/DARKIRC-MULTITENANT.md`).
5. **Nanocode model/baseURL overrides are optional.** No action needed if you use the defaults. To override per tenant: `configure-nanocode <name> --model <model> --base-url <url>`, then restart the worker.
6. **Codex worker is deprecated.** The codex worker image (`codex4lunarwing/`) still builds but is no longer actively maintained. Nanocode and pebble workers are the supported paths forward.

---

## Features and changes deferred to future releases

The full canonical list lives in `docs/ops/ROADMAP_2026.MD`

---

## Release Cadence

**A brief note about release cadence.** LunarWing abides by a release cadence to organize `feature`- and `polish`-focused releases — even-numbered releases (like this one) focus on new features and capability expansion, while odd-numbered releases focus on bug fixes, security improvements, and polishing. For details see `docs/ops/RELEASE_CADENCE.md`. Occasionally, exceptions may be made, but the goal is to stay within this paradigm.

## Testing

### In accordance with developer guidelines, a testing period precedes each release.

#### The pre-release checklist lives in `docs/ops/GOALS_1.1.6.md`; the full checklist is in `docs/ops/PRE-RELEASE-TESTING.md`; automated coverage is driven by `ic/scripts/release-test.sh` and `docs/guides/TESTING_GUIDE.md`.

##### Once evaluation begins in earnest, no new changes besides urgent fixes will be accepted into staging during the evaluation period.

