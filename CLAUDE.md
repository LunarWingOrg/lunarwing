# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Is

**LunarWing** is a hard fork of IronClaw (originally by NearAI), started February 2026. The core daemon lives in `ic/`. The product name is LunarWing; `ic/` is the internal path from upstream.

This is a self-hostable, privacy-first AI agent. The fork prioritizes true freedom, XMPP/OMEMO, Gotify, scheduled routines, systemd deployment, and open-protocol channels. Proprietary channels (Slack, Discord, Telegram) are intentionally unsupported. Ironclaw compatibility is NOT a goal moving forward.

### Binary Rename (ironclaw → lunarwing)

The binary, Cargo package, and all four internal crates have been renamed from `ironclaw` to `lunarwing`:

| What | Old name | New name |
|------|----------|----------|
| Binary | `target/*/ironclaw` | `target/*/lunarwing` |
| Cargo package | `name = "ironclaw"` | `name = "lunarwing"` |
| Internal crates | `ironclaw_common`, `ironclaw_safety`, `ironclaw_skills`, `ironclaw_engine` | `lunarwing_common`, `lunarwing_safety`, `lunarwing_skills`, `lunarwing_engine` |
| Proxy script | `ironclaw-proxy.py` | `lunarwing-proxy.py` |
| Default DB name | `ironclaw` | `lunarwing` |
| Socket file | `ironclaw.sock` | `lunarwing.sock` |
| Service units | `ExecStart=.../ironclaw` | `ExecStart=.../lunarwing` |
| RUST_LOG filter | `ironclaw=info` | `lunarwing=info` |

**Preserved for backward compatibility:**
- `IRONCLAW_BASE_DIR` env var — still accepted as legacy alias for `LUNARWING_BASE_DIR`
- `IRONCLAW_SOCKET` env var — still accepted as legacy alias
- Watchdog cleanup markers (detect old `ironclaw-watchdog` installations)

**Intentionally NOT renamed:**
- `codex4ironclaw/` and `nanocode-config/` directory names
- WebSocket subprotocol `ironclaw-agent-v1` (shared external protocol)
- Keyring service identifiers in `ic_sm/`
- `tensorzero::function_name::ironclaw` TensorZero function name
- GCP resource names in `ic/deploy/cloud-sql-proxy.service`
- `ic/CHANGELOG.md` historical entries

## Build & Test

All Rust work happens inside `ic/`. Rust edition 2024, MSRV 1.92. Run from `ic/`:

```bash
cargo fmt
cargo clippy --all --benches --tests --examples --all-features  # zero warnings required
cargo test                          # unit tests
cargo test --features integration   # + PostgreSQL tests
cargo test test_name -- --nocapture # single test
cargo build --release --bin lunarwing
RUST_LOG=lunarwing=debug cargo run
```

Feature-flag compilation (required for dual-backend work):
```bash
cargo check                                          # postgres (default)
cargo check --no-default-features --features libsql  # libsql only
cargo check --all-features                           # both
```

XMPP bridge (separate binary, build before full workspace):
```bash
cd ic/bridges/xmpp-bridge && cargo build --release
```

WASM channels/tools:
```bash
cd ic && scripts/build-wasm-extensions.sh
```

Pre-commit safety checks (catches UTF-8 slicing, hardcoded /tmp, logging leaks):
```bash
cd ic && scripts/pre-commit-safety.sh
```

## Running Locally

Quick launcher from `ic/`:
```bash
LUNARWING_BASE_DIR=/path/to/instance ./run.sh
```

`run.sh` defaults `AGENT_NAME=lunarwing`, `ALLOW_PRIVATE_IPS=1`, `PGSSLMODE=disable`, `HTTP_PORT=9098`. It runs `target/release/lunarwing run`.

Fresh instance setup:
```bash
ic/scripts/setup-instance.sh \
  --base-dir /srv/lunarwing \
  --database postgres \
  --database-url 'postgres://user:pass@db:5432/lunarwing' \
  --llm-api-key unneeded \
  --run-onboard
```

Env var: `LUNARWING_BASE_DIR` (legacy alias `IRONCLAW_BASE_DIR` still accepted).

## Integration Test Harness

`ic/scripts/lunarwing-xmpp-test-env.sh` is the full-stack test harness. It manages PostgreSQL, TensorZero proxy, XMPP bridge, WASM artifacts, and the daemon in an isolated environment. Works on Linux and macOS.

Single-tenant quick start — see `docs/ops/HARNESS-SINGLE-TENANT.md`. Multi-tenant quick start — see `docs/ops/MULTITENANCY-HARNESS.md`.

Key difference: `up` (single-tenant) does **not** auto-build; `build --with-wasm` and `install-wasm` must be run first. `mt-up` auto-builds and installs WASM before starting services.

Key env vars: `LUNARWING_TEST_ROOT` (default `$TMPDIR/lunarwing-xmpp-test`), `LUNARWING_TEST_DATABASE_KIND` (`postgres`|`libsql`), `LUNARWING_TEST_PROFILE` (`debug`|`release`).

Full single-tenant reference: `ic/testing/lunarwing-xmpp/README.md`.

## Repo Structure

```
ic/                         # Main daemon (Rust) — see ic/CLAUDE.md
  src/                      # Source tree
  crates/                   # lunarwing_common, lunarwing_safety, lunarwing_skills, lunarwing_engine
  channels-src/             # WASM channel sources (xmpp, weechat, darkirc, etc.)
  tools-src/                # WASM tool sources (gotify, github, google-*, etc.)
  bridges/xmpp-bridge/      # Standalone XMPP bridge service (separate process)
  migrations/               # Refinery DB migrations (PostgreSQL + libSQL)
  tests/                    # Integration + E2E tests
  testing/lunarwing-xmpp/   # Full-stack test harness docs
  systemd/                  # Systemd unit files + OpenRC init scripts (.openrc, .confd)
  scripts/                  # Operational + build scripts
codex4ironclaw/             # Persistent Codex Worker container — see codex4ironclaw/CLAUDE.md
nanocode-config/            # Nanocode worker container config — see nanocode-config/CLAUDE.md
nanocode4ironclaw/          # Nanocode worker container — see nanocode4ironclaw/CLAUDE.md
ic-infrastructure-health-check/  # Health check service (auto-detects systemd/OpenRC)
tensorzero-proxy-configurations/ # TensorZero HTTP proxy routing config
replv2git/                  # REPLv2 related tooling
xmpp_bridge/                # XMPP bridge support resources
ic_sm/                      # Supporting service resources
darkirc_channel_for_ironclaw/    # DarkIRC WASM channel source
gotify-wasm/                # Gotify WASM tool source
ironclaw-gotify-tool/       # Gotify tool (legacy standalone)
ironclaw_weechat_wss/       # WeeChat WSS channel source
git-ironclaw-unix-socket-client-repo/  # REPLv2 Unix socket client
git-ironclaw-unix-socket-repl-server-repo/  # REPLv2 Unix socket REPL server
tests/                      # Worker test harness (Docker Compose matrix suite for all 4 worker types)
docs/                       # Documentation (architecture/, guides/, ops/, reference/, internal/)
```

> `ic/customic/` is unused and will be removed. Ignore it.

## Key Guidance Docs

Before modifying complex areas, read the relevant spec. Specs are authoritative.

| Area | Spec |
|------|------|
| Agent rules & repo contract | `AGENTS.md` |
| Fork goals & protected behavior | `docs/internal/FORK_CONTEXT.md` |
| Main daemon development | `ic/CLAUDE.md` |
| Engine V2 architecture | `docs/architecture/ENGINE-V2.md` |
| Engine crate dev guide | `ic/crates/lunarwing_engine/CLAUDE.md` |
| Semantic memory search | `docs/architecture/SEMANTIC-MEMORY-SEARCH.md` |
| Agent loop, sessions, routines | `ic/src/agent/CLAUDE.md` |
| Web gateway / REST / WebSocket | `ic/src/channels/web/CLAUDE.md` |
| Database dual-backend | `ic/src/db/CLAUDE.md` |
| LLM providers | `ic/src/llm/CLAUDE.md` |
| Tools system | `ic/src/tools/README.md` |
| Workspace / memory | `ic/src/workspace/README.md` |
| E2E tests | `ic/tests/e2e/CLAUDE.md` |
| Network security policy | `ic/src/NETWORK_SECURITY.md` |
| Multi-tenancy (production) | `docs/ops/docs/MULTITENANCY-PRODUCTION.md` |
| Single-tenant test harness | `docs/ops/HARNESS-SINGLE-TENANT.md` |
| Multi-tenant test harness | `docs/ops/MULTITENANCY-HARNESS.md` |
| Docs organization | `docs/README.md` |

## Architecture Overview

- **Channels** normalize external input into `IncomingMessage`; `ChannelManager` merges all active streams.
- **Agent** owns session/turn handling, the LLM↔tool loop, approvals, and routines.
- **AppBuilder** is the composition root — wires DB, secrets, LLMs, tools, workspace, extensions, hooks before the agent starts.
- **Web gateway** is a browser-facing API/UI over the same agent/session/tool systems, not a separate product path.
- **XMPP bridge** runs as a separate service (systemd or OpenRC); OMEMO happens in the bridge, not the main daemon.
- **WASM sandbox** (wasmtime) provides isolated execution for third-party tools and channels.
- **Dual DB backend**: PostgreSQL (primary) + libSQL/Turso. All new persistence must support both.
- **TensorZero proxy** routes LLM calls via `openai_compatible` backend, enabling function-call routing and model training feedback loops. Default local endpoint: `http://192.168.1.157:3002`.

Key extensibility traits: `Database`, `Channel`, `Tool`, `LlmProvider`, `EmbeddingProvider`, `Hook`, `Tunnel`.

## External Workers

External workers are persistent containers that speak the `ironclaw-agent-v1` WebSocket protocol. Unlike Docker sandbox jobs (created/destroyed per task), external workers stay running and accept tasks on demand.

### Configuration

Add to `config.toml` under `LUNARWING_BASE_DIR`:

```toml
[[sandbox.external_workers]]
name = "nanocode"
url = "ws://localhost:9090/ws/agent"
timeout_ms = 300000
```

Must be under the existing `[sandbox]` section (TOML doesn't allow duplicate table headers). The agent logs `External workers configured: nanocode` on startup.

### Usage

The agent's `create_job` tool accepts a `mode` parameter matching the worker name:

```
create_job(title: "...", description: "...", mode: "nanocode")
```

### Architecture

- `ic/src/orchestrator/external_worker.rs` — `ExternalWorkerManager`: WebSocket client, task dispatch, progress streaming
- `ic/src/tools/builtin/job.rs` — `execute_external()`: routes `create_job` calls to external workers
- `ic/src/config/sandbox.rs` — `ExternalWorkerConfig`: resolved from `[[sandbox.external_workers]]` in settings
- `ic/src/settings.rs` — `ExternalWorkerSettings`: TOML/JSON serialization for worker endpoints

### Available workers

| Worker | Container | Docs |
|--------|-----------|------|
| `nanocode` | `nanocode4ironclaw/` | `nanocode4ironclaw/CLAUDE.md` |

## Protected Runtime Behavior

Do not break without explicit approval:

- XMPP bridge operation and OMEMO encrypted chat (1:1 and group)
- XMPP group chat self-message suppression and live rate-limit control
- Gotify WASM tool usage
- WASM channel/tool loading
- Scheduled routines, manual routine runs, and stuck-run recovery
- Gateway status/config endpoints
- Systemd and OpenRC deployment units and watchdog service/timer
- Infrastructure health check init-system auto-detection

## Service Operations

- `xmpp-bridge.service` has `PartOf=lunarwing.service` — LunarWing restarts can cascade to the bridge. Do not assume the bridge caused a stop just because both restarted.
- Use `scripts/xmpp-rate-limit.sh` for live XMPP outbound rate-limit changes (`status`, `set <n>`, `off`, `reset`). Requires `XMPP_BRIDGE_TOKEN`.
- Use `scripts/xmpp-configure.sh` for bridge room/configuration checks.
- Watchdog: `scripts/lunarwing-watchdog.sh` (systemd) or `scripts/lunarwing-watchdog-openrc.sh` (OpenRC). Install via `scripts/install-lunarwing-watchdog.sh` (auto-detects init system).
- Prefer read-only diagnostics first (`systemctl status`, `journalctl`, gateway endpoints) before restarting services.
- If harness `verify` only fails the TensorZero proxy check, inspect the upstream `TENSORZERO_URL` before treating the local service install as broken.
- **Do not restart services or deploy binaries unless explicitly asked.**

## Deployment & Secrets

Secrets may live in `/home/cmc/.lunarwing/.env`, systemd service environment, DB rows, or WASM auth state. Never print secret values in logs, diffs, or responses.

For live DB checks, use read-only SQL unless the user explicitly requests mutation. Stop the service before mutating routine state; back up the DB first.

## Gotify Pattern

Gotify is a WASM tool, not a channel. Routines needing Gotify notifications should call the `gotify` tool in their prompt and return the same message as backup output. See `ic/docs/GOTIFY_ROUTINE_PROMPT.md` for the working prompt pattern.

## XMPP / OMEMO Known Behavior

- Bridge rejects conflicting runtime config with HTTP 409 until restarted.
- OMEMO encrypted group chat may take several messages after restart before decrypting reliably.
- Group OMEMO requires the room to be configured as encrypted in both client setup and bridge/runtime config.

## Debugging

```bash
RUST_LOG=lunarwing=trace cargo run                        # verbose all modules
RUST_LOG=lunarwing::agent=debug cargo run                 # agent loop only
RUST_LOG=lunarwing=debug,tower_http=debug cargo run       # + HTTP request logging
```

## Routine System

**Retry with backoff:** Failed routines with retryable errors (LLM timeouts, empty responses, execution timeouts) are automatically retried with exponential backoff. The per-routine `RetryPolicy` (stored in `RoutineGuardrails`) controls: `max_retries` (default 3), `initial_delay_secs` (default 60), `backoff_multiplier` (default 2.0), `max_delay_secs` (default 3600). Retries use the existing `next_fire_at` column — no new scheduler loop. After exhausting retries, the routine falls back to its normal cron schedule. Non-retryable errors (auth, config, DB) skip retry entirely. `RoutineError::is_retryable()` classifies errors.

**Stuck-run recovery:** Lightweight routines are wrapped in `tokio::time::timeout` (default 300s, configurable via `ROUTINES_LIGHTWEIGHT_TIMEOUT_SECS`). A stuck-run sweeper runs on every cron tick to recover lightweight runs that remain in `running` state beyond the timeout. FullJob runs have separate crash recovery via `sync_dispatched_runs()`. Both mechanisms prevent a single failed run from permanently blocking its routine.

Key config env vars: `ROUTINES_ENABLED`, `ROUTINES_MAX_CONCURRENT` (default 10), `ROUTINES_CRON_INTERVAL` (default 15s), `ROUTINES_DEFAULT_COOLDOWN` (default 300s), `ROUTINES_LIGHTWEIGHT_TIMEOUT_SECS` (default 300s).

DB migration `V18__routine_retry.sql` adds retry policy columns to the `routines` table. Both PostgreSQL and libSQL backends support the new fields.

## Infrastructure Health Checks

`ic-infrastructure-health-check/infrastructure-health-check.sh` orchestrates 8 parallel health checks. It auto-detects the init system and conditionally runs either `health-systemd.sh` or `health-openrc.sh` (never both). On OpenRC, `health-openrc.sh` auto-discovers multi-tenant services by scanning `/etc/init.d/` for tenant-specific init scripts.

Override init system detection with `LUNARWING_SERVICE_MANAGER=systemd` or `LUNARWING_SERVICE_MANAGER=openrc`.

## Multi-Tenancy

Production multi-tenant deployments use `ic/scripts/lunarwing-mt-admin.sh`. Each tenant gets a dedicated OS user, port block (10-port range from `/etc/lunarwing/ports.json`), PostgreSQL container, TensorZero proxy, and XMPP bridge. Supports both systemd (user-level with linger) and OpenRC (system-level with supervise-daemon). See `docs/ops/docs/MULTITENANCY-PRODUCTION.md` for the full walkthrough.

The test harness (`ic/scripts/lunarwing-xmpp-test-env.sh`) provides ephemeral multi-tenancy for development and is fully cross-platform. See `docs/ops/MULTITENANCY-HARNESS.md`.

## Test Harness (`lunarwing-xmpp-test-env.sh`)

`ic/scripts/lunarwing-xmpp-test-env.sh` is the full-stack integration test harness. It is cross-platform (Linux and macOS):

- **Single-tenant** (`up`/`down`): always uses direct PID-file process management — works on all platforms
- **Multi-tenant** (`mt-up`/`mt-down`): auto-detects init system via `_mt_detect_init()` and uses the appropriate path:
  - **macOS**: `launchd` — generates `.plist` files in `$TEST_ROOT/launchd/`, installs to `~/Library/LaunchAgents/`
  - **Linux systemd**: user units in `~/.config/systemd/user/`
  - **Linux OpenRC**: system-level init scripts via `rc-service`
  - **Fallback**: direct process management

**Key cross-platform notes:**
- `sed -i` portability: use `_sed_i()` helper (wraps `sed -i ''` on macOS, `sed -i` on Linux) — never call `sed -i` directly
- `LAUNCHD_DIR` (`$TEST_ROOT/launchd/`) mirrors `SYSTEMD_DIR` for plist artifacts
- `render-launchd` / `mt-render-launchd` generate validated plist files (all env vars from env files are embedded inline, since launchd has no `EnvironmentFile=` equivalent)
- `CLI_ENABLED=false` is always injected into launchd plists (prevents blocking stdin in daemon mode)
- Launchd plist labels are tenant-scoped (`com.lunarwing.test.mt-a.daemon`, `com.lunarwing.test.mt-b.daemon`) derived from the test root basename — both tenants coexist in `~/Library/LaunchAgents/` without conflict. Single-tenant plists use the bare label (`com.lunarwing.test.daemon`)
- WASM builds on macOS require `wasm32-wasip1` and `wasm32-wasip2` targets plus `cargo-component` and `wasm-tools`. Homebrew's `rustc` lacks WASM targets — the rustup toolchain bin dir must precede `/opt/homebrew/bin` in `PATH`

**`doctor` command** reports service status for whichever init system is present:
- macOS: launchd agent load status
- Linux systemd: `systemctl --user status`
- Linux OpenRC: `rc-service status`, default runlevel registration, watchdog installation (script, conf.d, cron.hourly/fcrontab)
- None detected: reports PID-file-only mode

## Harness Environment Defaults

The harness and `run.sh` intentionally set `ALLOW_PRIVATE_IPS=1`, `DATABASE_SSLMODE=disable`, and `PGSSLMODE=disable` for private-network Postgres/TensorZero test setups. Preserve those defaults unless explicitly changing the network or SSL assumptions.

## Things to do before 1.0.5 Release:

1. A huge setup harness test using the new, improved MT admin setup harness and extensive test of all channels, tools, and bridges
2. Test routines with custom tools once again
3. Go through docs and update any outdated documentation
4. Start to track ALL new feature planning in Vikunja
5. Ensure bug reports from docs dir are tracked in Vikunja
6. Write up some release notes for 1.0.5 which explain all of the changes since 1.0.4
7. Create a new branch to correspond with release
8. Create gh release tag and add release notes to it like other releases already have rn

## Things to do after 1.0.5 Release:

1. OCR and Image Recog with sidecar plan by Ruffles
2. Add support for Multica for multi-agent coordination (self-hostable free open source software)
3. Continue to remove cruft, along with some of the unsupported channels
4. Rename custom external worker containers and modify any code to refernece such containers, test before 1.0.6

## Things to do before 1.0.6 Release:

1. Ensure all of the previous steps were completed
2. Write up some release notes for 1.0.6 which explain all of the changes since 1.0.5
3. Create a new branch to correspond with release
4. Create gh release tag and add release notes to it like other releases already have rn
