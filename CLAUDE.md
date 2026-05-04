# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Is

**LunarWing** is a hard fork of IronClaw (originally by NearAI), started February 2026. The core daemon lives in `ic/`. The product name is LunarWing; `ic/` and `ironclaw` are internal/binary names from upstream.

This is a self-hosted, privacy-first AI agent. The fork prioritizes XMPP/OMEMO, Gotify, scheduled routines, systemd deployment, and open-protocol channels. Proprietary channels (Slack, Discord, Telegram) are intentionally unsupported. Upstream compatibility is not a goal.

## Build & Test

All Rust work happens inside `ic/`. Rust edition 2024, MSRV 1.92. Run from `ic/`:

```bash
cargo fmt
cargo clippy --all --benches --tests --examples --all-features  # zero warnings required
cargo test                          # unit tests
cargo test --features integration   # + PostgreSQL tests
cargo test test_name -- --nocapture # single test
cargo build --release --bin ironclaw
RUST_LOG=ironclaw=debug cargo run
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

`run.sh` defaults `AGENT_NAME=lunarwing`, `ALLOW_PRIVATE_IPS=1`, `PGSSLMODE=disable`, `HTTP_PORT=9098`. It runs `target/release/ironclaw run`.

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

`ic/scripts/lunarwing-xmpp-test-env.sh` is the full-stack test harness. It manages PostgreSQL, TensorZero proxy, XMPP bridge, WASM artifacts, and the daemon in an isolated environment.

```bash
cd ic
scripts/lunarwing-xmpp-test-env.sh init           # create isolated env
scripts/lunarwing-xmpp-test-env.sh build          # build all binaries
scripts/lunarwing-xmpp-test-env.sh up             # bring up full stack
scripts/lunarwing-xmpp-test-env.sh verify         # health checks
scripts/lunarwing-xmpp-test-env.sh down           # tear down
scripts/lunarwing-xmpp-test-env.sh doctor         # diagnose dependencies
```

Key env vars: `LUNARWING_TEST_ROOT` (default `/tmp/lunarwing-xmpp-test`), `LUNARWING_TEST_DATABASE_KIND` (`postgres`|`libsql`), `LUNARWING_TEST_PROFILE` (`debug`|`release`).

See `ic/testing/lunarwing-xmpp/README.md` for full recipes.

## Repo Structure

```
ic/                         # Main daemon (Rust) — see ic/CLAUDE.md
  src/                      # Source tree
  crates/                   # ironclaw_common, ironclaw_safety, ironclaw_skills, ironclaw_engine
  channels-src/             # WASM channel sources (xmpp, weechat, darkirc, etc.)
  tools-src/                # WASM tool sources (gotify, github, google-*, etc.)
  bridges/xmpp-bridge/      # Standalone XMPP bridge service (separate process)
  migrations/               # Refinery DB migrations (PostgreSQL + libSQL)
  tests/                    # Integration + E2E tests
  testing/lunarwing-xmpp/   # Full-stack test harness docs
  systemd/                  # Systemd unit files
  scripts/                  # Operational + build scripts
codex4ironclaw/             # Persistent Codex Worker container — see codex4ironclaw/CLAUDE.md
nanocode-config/            # Nanocode worker container config — see nanocode-config/CLAUDE.md
ic-infrastructure-health-check/  # Health check service
tensorzero-proxy-configurations/ # TensorZero HTTP proxy routing config
replv2git/                  # REPLv2 related tooling
xmpp_bridge/                # XMPP bridge support resources
ic_sm/                      # Supporting service resources
docs/                       # Documentation
custom_*/                   # Design docs for fork-specific features (bridges, channels, tools, etc.)
```

> `ic/customic/` is unused and will be removed. Ignore it.

## Key Guidance Docs

Before modifying complex areas, read the relevant spec. Specs are authoritative.

| Area | Spec |
|------|------|
| Agent rules & repo contract | `AGENTS.md` |
| Fork goals & protected behavior | `FORK_CONTEXT.md` |
| Main daemon development | `ic/CLAUDE.md` |
| Agent loop, sessions, routines | `ic/src/agent/CLAUDE.md` |
| Web gateway / REST / WebSocket | `ic/src/channels/web/CLAUDE.md` |
| Database dual-backend | `ic/src/db/CLAUDE.md` |
| LLM providers | `ic/src/llm/CLAUDE.md` |
| Tools system | `ic/src/tools/README.md` |
| Workspace / memory | `ic/src/workspace/README.md` |
| E2E tests | `ic/tests/e2e/CLAUDE.md` |
| Network security policy | `ic/src/NETWORK_SECURITY.md` |

## Architecture Overview

- **Channels** normalize external input into `IncomingMessage`; `ChannelManager` merges all active streams.
- **Agent** owns session/turn handling, the LLM↔tool loop, approvals, and routines.
- **AppBuilder** is the composition root — wires DB, secrets, LLMs, tools, workspace, extensions, hooks before the agent starts.
- **Web gateway** is a browser-facing API/UI over the same agent/session/tool systems, not a separate product path.
- **XMPP bridge** runs as a separate systemd service; OMEMO happens in the bridge, not the main daemon.
- **WASM sandbox** (wasmtime) provides isolated execution for third-party tools and channels.
- **Dual DB backend**: PostgreSQL (primary) + libSQL/Turso. All new persistence must support both.
- **TensorZero proxy** routes LLM calls via `openai_compatible` backend, enabling function-call routing and model training feedback loops. Default local endpoint: `http://192.168.1.157:3002`.

Key extensibility traits: `Database`, `Channel`, `Tool`, `LlmProvider`, `EmbeddingProvider`, `Hook`, `Tunnel`.

## Protected Runtime Behavior

Do not break without explicit approval:

- XMPP bridge operation and OMEMO encrypted chat (1:1 and group)
- XMPP group chat self-message suppression and live rate-limit control
- Gotify WASM tool usage
- WASM channel/tool loading
- Scheduled routines and manual routine runs
- Gateway status/config endpoints
- Systemd deployment units and watchdog service/timer

## Service Operations

- `xmpp-bridge.service` has `PartOf=ironclaw.service` — IronClaw restarts can cascade to the bridge. Do not assume the bridge caused a stop just because both restarted.
- Use `scripts/xmpp-rate-limit.sh` for live XMPP outbound rate-limit changes (`status`, `set <n>`, `off`, `reset`). Requires `XMPP_BRIDGE_TOKEN`.
- Use `scripts/xmpp-configure.sh` for bridge room/configuration checks.
- Watchdog: `scripts/lunarwing-watchdog.sh` (systemd) or `scripts/lunarwing-watchdog-openrc.sh` (OpenRC). Install via `scripts/install-lunarwing-watchdog.sh` (auto-detects init system).
- Prefer read-only diagnostics first (`systemctl status`, `journalctl`, gateway endpoints) before restarting services.
- If harness `verify` only fails the TensorZero proxy check, inspect the upstream `TENSORZERO_URL` before treating the local service install as broken.
- **Do not restart services or deploy binaries unless explicitly asked.**

## Deployment & Secrets

Secrets may live in `/home/cmc/.ironclaw/.env`, systemd service environment, DB rows, or WASM auth state. Never print secret values in logs, diffs, or responses.

For live DB checks, use read-only SQL unless the user explicitly requests mutation. Stop the service before mutating routine state; back up the DB first.

## Gotify Pattern

Gotify is a WASM tool, not a channel. Routines needing Gotify notifications should call the `gotify` tool in their prompt and return the same message as backup output. See `docs/GOTIFY_ROUTINE_PROMPT.md` for the working prompt pattern.

## XMPP / OMEMO Known Behavior

- Bridge rejects conflicting runtime config with HTTP 409 until restarted.
- OMEMO encrypted group chat may take several messages after restart before decrypting reliably.
- Group OMEMO requires the room to be configured as encrypted in both client setup and bridge/runtime config.

## Debugging

```bash
RUST_LOG=ironclaw=trace cargo run                        # verbose all modules
RUST_LOG=ironclaw::agent=debug cargo run                 # agent loop only
RUST_LOG=ironclaw=debug,tower_http=debug cargo run       # + HTTP request logging
```

## Harness Environment Defaults

The harness and `run.sh` intentionally set `ALLOW_PRIVATE_IPS=1`, `DATABASE_SSLMODE=disable`, and `PGSSLMODE=disable` for private-network Postgres/TensorZero test setups. Preserve those defaults unless explicitly changing the network or SSL assumptions.
