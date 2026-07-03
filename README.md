# LunarWing Introduction

## Claws are overrated. So, grow your wings and fly...

### Secure, privacy-focused AI agents you can self-host.

LunarWing is an agentic software framework built in Rust. It connects AI agents to privacy-respecting communication layers — IRC, DarkIRC, XMPP with OMEMO, and more — with real secret management baked in from the start.

It's a hard fork of NearAI's IronClaw, diverging significantly since February 2026. LunarWing is not affiliated with NearAI.

## Why LunarWing

- **Self-hostable end to end** — runs entirely on your own infrastructure, no third-party dependencies required.
- **Privacy-first channels** — XMPP/OMEMO, WeeChat relay, and DarkIRC (opt-in as of v1.1.8). No Slack, Discord, or Telegram — by design.
- **WASM plugin system** — extend agents with tools and channel adapters compiled to WebAssembly.
- **Built-in secret management** — specialized wrappers for Postgres and LibSQL credential handling.
- **Self-healing infrastructure** — advanced healthchecks and automatic recovery for LunarWing, channel bridges, adapters, daemons, and even scheduled routines.
- **TensorZero integration** — HTTP proxy with optimized tool_choice routing for local and remote model providers.
- **Lunarpunk values** — AGPLv3 forever. Free software, free infrastructure, no compromises.

<p align="center">
  <img src="./logo_new_black_bg.png" alt="LunarWing" width="400">
</p>

## Quick Links

- Website: [lunarwing.org](https://lunarwing.org)
- Source: [github.com/LunarWingOrg/lunarwing](https://github.com/LunarWingOrg/lunarwing)
- IRC: `#lunarwing` on [irc.libera.chat](https://web.libera.chat/?channel=#lunarwing) (port 6697, TLS)
- License: [AGPL-3.0](https://www.gnu.org/licenses/agpl-3.0.en.html)

[LunarWing](https://lunarwing.org/)

[![zread](https://img.shields.io/badge/Ask_Zread-_.svg?style=for-the-badge&color=00b0aa&labelColor=000000&logo=data%3Aimage%2Fsvg%2Bxml%3Bbase64%2CPHN2ZyB3aWR0aD0iMTYiIGhlaWdodD0iMTYiIHZpZXdCb3g9IjAgMCAxNiAxNiIgZmlsbD0ibm9uZSIgeG1sbnM9Imh0dHA6Ly93d3cudzMub3JnLzIwMDAvc3ZnIj4KPHBhdGggZD0iTTQuOTYxNTYgMS42MDAxSDIuMjQxNTZDMS44ODgxIDEuNjAwMSAxLjYwMTU2IDEuODg2NjQgMS42MDE1NiAyLjI0MDFWNC45NjAxQzEuNjAxNTYgNS4zMTM1NiAxLjg4ODEgNS42MDAxIDIuMjQxNTYgNS42MDAxSDQuOTYxNTZDNS4zMTUwMiA1LjYwMDEgNS42MDE1NiA1LjMxMzU2IDUuNjAxNTYgNC45NjAxVjIuMjQwMUM1LjYwMTU2IDEuODg2NjQgNS4zMTUwMiAxLjYwMDEgNC45NjE1NiAxLjYwMDFaIiBmaWxsPSIjZmZmIi8%2BCjxwYXRoIGQ9Ik00Ljk2MTU2IDEwLjM5OTlIMi4yNDE1NkMxLjg4ODEgMTAuMzk5OSAxLjYwMTU2IDEwLjY4NjQgMS42MDE1NiAxMS4wMzk5VjEzLjc1OTlDMS42MDE1NiAxNC4xMTM0IDEuODg4MSAxNC4zOTk5IDIuMjQxNTYgMTQuMzk5OUg0Ljk2MTU2QzUuMzE1MDIgMTQuMzk5OSA1LjYwMTU2IDE0LjExMzQgNS42MDE1NiAxMy43NTk5VjExLjAzOTlDNS42MDE1NiAxMC42ODY0IDUuMzE1MDIgMTAuMzk5OSA0Ljk2MTU2IDEwLjM5OTlaIiBmaWxsPSIjZmZmIi8%2BCjxwYXRoIGQ9Ik0xMy43NTg0IDEuNjAwMUgxMS4wMzg0QzEwLjY4NSAxLjYwMDEgMTAuMzk4NCAxLjg4NjY0IDEwLjM5ODQgMi4yNDAxVjQuOTYwMUMxMC4zOTg0IDUuMzEzNTYgMTAuNjg1IDUuNjAwMSAxMS4wMzg0IDUuNjAwMUgxMy43NTg0QzE0LjExMTkgNS42MDAxIDE0LjM5ODQgNS4zMTM1NiAxNC4zOTg0IDQuOTYwMVYyLjI0MDFDMTQuMzk4NCAxLjg4NjY0IDE0LjExMTkgMS42MDAxIDEzLjc1ODQgMS42MDAxWiIgZmlsbD0iI2ZmZiIvPgo8cGF0aCBkPSJNNCAxMkwxMiA0TDQgMTJaIiBmaWxsPSIjZmZmIi8%2BCjxwYXRoIGQ9Ik00IDEyTDEyIDQiIHN0cm9rZT0iI2ZmZiIgc3Ryb2tlLXdpZHRoPSIxLjUiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPgo8L3N2Zz4K&logoColor=ffffff)](https://zread.ai/LunarWingOrg/lunarwing)

![CodeRabbit Pull Request Reviews](https://img.shields.io/coderabbit/prs/github/LunarWingOrg/lunarwing?utm_source=oss&utm_medium=github&utm_campaign=LunarWingOrg%2Flunarwing&labelColor=171717&color=FF570A&link=https%3A%2F%2Fcoderabbit.ai&label=CodeRabbit+Reviews)

[![Chat on IRC](https://img.shields.io/badge/IRC-%23lunarwing-00b0aa?style=for-the-badge&labelColor=000000)](https://web.libera.chat/?channel=#lunarwing)

##### End of Introduction
---

# Finer Details

The LunarWing project began in February 2026. Initially a hard fork of the Ironclaw project to support custom tools and channels, the project eventually evolved to introduce deep infrastructural changes over time.

LunarWing is a self-hosted, privacy-first AI agent. The fork prioritizes useful tools, bridges, and channels such as XMPP/OMEMO, Gotify, scheduled routines with fallbacks, systemd deployment, OpenRC, and open-protocol channels. Proprietary service centered channels (Slack, Discord, Telegram) are intentionally unsupported within the monorepo and are gradually being fully removed.

The LunarWing project strictly maintains the AGPLv3 license on the core project and all extensions, tools, and channels. We will use the same license across our other repositories if legally possible.

## Why "LunarWing"?

**Lunar** -- We are firm believers in Lunarpunk.

**Wing** -- Wings are extensions of the body which allow flight. We chose the term `wing` to differentiate ourselves from most open source agentic software which uses the term `claw`. We are not required to remain on the ground.

## Features

LunarWing adds real privacy-respecting tools and channels, with full secret support, right out of the box:

### Channels & Communication
* **XMPP with OMEMO** -- WASM channel, bridge service, and core code changes for full encrypted chat (1:1 and group), with XEP-0363 HTTP file upload support
* **Weechat** -- WASM channel allowing the agent to use Weechat as an IRC/DarkIRC/Signal/XMPP/Slack/Matrix/Rocketchat client
* **Enjin** -- optional weechat plugin to enable E2E for normal IRC
* **DarkIRC** -- DarkIRC WASM channel, p2p e2e protocol from DarkFi. **As of v1.1.8, DarkIRC is hard-disabled by default** — services are not created and the binary is not built unless explicitly opted in via `--enable-darkirc` (on `add-tenant`/`start-tenant`) and `build-darkirc`. Existing tenants are unaffected until their units are re-rendered.

### Tools & Notifications
* **Gotify** -- WASM tool for agent-initiated push notifications
* **LunarVision (Vision Service / OCR Sidecar)** -- Standalone Rust service for OCR (Tesseract) and vision-language analysis (Qwen3-VL), with smart routing, PaddleOCR fallback, disk-backed cache persistence, an API-versioned HTTP surface with an OpenAPI spec, and a self-reported `/health` endpoint. Runs rootless under Podman (`projects/ocr-sidecar/`)
* **vision-analyze WASM Tool** -- Native WASM tool for image analysis via the LunarVision sidecar; rewritten from scratch in v1.1.7 and re-registered with the WASM toolset (`ic/tools-src/vision-analyze/`)
* **Lunartica** -- Free Open Source Self Hostable Agent Coordination Platform (separate repo)

### Worker Containers
* **Nanocode Worker** -- Persistent NanoGPT community Nanocode worker container with optional ACP bridge, git/ssh key support, persistent storage, and development tools (`lunarcode4lunarwing/`)
* **Pebble Worker** -- Persistent Rust-based Pebble agentic coding harness worker with NDJSON event streaming and health endpoints (`pebble4lunarwing/`)
* **Opencode Worker** -- Persistent [opencode](https://opencode.ai) (sst/opencode) worker container speaking the `ironclaw-agent-v1` WebSocket protocol, with the `@opencode-ai/sdk`, optional Paseo MCP integration, git/ssh key support, and health endpoints (`opencode4lunarwing/`)
* **Reworked Built-in Worker - Debloated** -- Native worker running inside the LunarWing daemon getting debloated, rip out obsolete worker modes in favor of specialized worker container support (`ic/src/worker/`)
* **Reworked Sandbox Worker - Debloated** -- Docker-isolated execution sandbox, debloated (`ic/src/sandbox/`)

### Infrastructure & Operations
* **Agent SSH Harness** (introduced v1.1.7, tooling completed v1.1.8) -- A centralized, per-tenant SSH bridge that lets worker containers authenticate to a host over SSH **without the private key ever touching disk** inside the container (or on the host outside the encrypted secrets store). Key material lives AES-256-GCM-encrypted in the secrets store and is served to workers over a per-tenant `ssh-agent` Unix socket; the agent signs challenges in memory. Host-key verification is fail-closed. **v1.1.8 added the consuming tools:** a built-in in-process Rust `ssh` tool (delivery Option 2), a `ssh_git` tool for git-over-SSH through the harness, and a WASM `ssh` guest tool (delivery Option 3). `start-tenant` now uploads the staged key, bounces the daemon once to load it, and starts workers after the socket is real. Enabled by default for new tenants; configurable via `configure-ssh` and the `[ssh]` section of `config.toml`. Live-validated on systemd and OpenRC.
* Specialized secret management wrapper scripts for both PostgreSQL and libSQL
* Optional systemd, launchd, and OpenRC services for LunarWing, channel bridges, and healthcheck services
* Improved scheduling system with native retry and exponential backoff for transient failures, stuck-run recovery, configurable lightweight execution timeouts, and automatic sweeping of orphaned routine runs
* Self-healing healthchecks for channel bridge services, the daemon, and the routines system. Infrastructure health checks auto-detect init system (systemd, OpenRC, launchd)
* Production multi-tenant deployment via `scripts/lunarwing-mt-admin.sh` with per-user OS isolation, port registry (v11 schema — dedicated per-tenant ports for workers, DarkIRC, and the LunarVision sidecar), and support for systemd, macOS (launchd), and OpenRC
* TensorZero HTTP proxy support for model routing, function-call routing, and training feedback loops
* Support for embedded memory search models
* Reflex compiler for LLM-free fast-path execution of recurring prompts with exact, fuzzy (Jaro-Winkler), and semantic matching, auto-promotion, and stale pattern eviction
* Supervised mode (`--supervised`) for human-gated tool execution — all tool actions require explicit approval regardless of tier
* Response suppression and future cancellation with soft timeout and secondary hard-kill mechanism

### Development & Testing
* Automated test suite with trace-replay E2E testing (no real LLM required)
* Worker test harness for all worker types with Docker Compose isolation (`tests/`)
* REPLv2 server and client with better output formatting and subagent support, backout and approval support included
* Support for external agentic coding tools via external worker mode
* Cross-platform test harness (`lunarwing-xmpp-test-env.sh`) with launchd (macOS), systemd (Linux), and OpenRC support as well as a production-grade developer testing suite

### Philosophy

LunarWing developers care about your freedom as a user. We do not support proprietary platforms in our official repository. All WASM tools and channels that developers wish to create for proprietary platforms can be maintained elsewhere. We focus on self-hostable communication layers and open protocols.

The LunarWing core development team is not affiliated with NearAI.

Our core team uses a self-hosted Vikunja kanban board to track tasks. Additionally, we use our own LunarWing agents to keep track of project progress.

#### As of now, we are entirely self-funded and work on this project on a voluntary basis. No VCs, Corporate Overlords, or sponsorships/grants. This will be updated in the future if it changes.

## Instance Setup

There are two ways to run LunarWing: a **single local instance** (the fastest way to try it) and **multi-tenant production** (the way it is deployed for real, with per-tenant OS isolation). The multi-tenant path is the maintained, primary deployment model.

### Quick local instance (onboarding wizard)

The fastest way to a running agent is to build the release binary and let the onboarding wizard configure everything. On first run with no database configured, `lunarwing run` auto-triggers **quick onboarding**, which defaults every non-LLM choice (embedded libSQL at `~/.lunarwing/lunarwing.db`, keychain-or-env secrets) and only prompts for the inference provider and model.

```bash
cd ic
cargo build --release
./target/release/lunarwing run          # auto-triggers quick onboarding on first run
# or explicitly:
./target/release/lunarwing onboard --quick
```

If you want to run a local instance repeatedly without rebuilding, `ic/run.sh` wraps the release binary with sane dev defaults (`HTTP_PORT=9098`, `ALLOW_PRIVATE_IPS=1`, `PGSSLMODE=disable`, `AGENT_NAME=lunarwing`, 2s start delay). It does **not** inject LLM URL or model defaults — those come from `config.toml` or env vars:

```bash
cd ic
LUNARWING_BASE_DIR=/path/to/instance ./run.sh
```

`run.sh` bridges `LUNARWING_BASE_DIR` to the legacy `IRONCLAW_BASE_DIR` for older code paths. macOS prefers keychain storage for secrets by default; on Linux, `lunarwing onboard --quick` generates and persists a `SECRETS_MASTER_KEY` automatically when one is missing.

### Multi-tenant production (`lunarwing-mt-admin.sh`) — primary path

This is how LunarWing is actually deployed. Each tenant is a real OS user with its own home, repo clone, release build, rootless Podman container store, per-tenant PostgreSQL, per-tenant secrets, a 10-port block, and per-tenant systemd (or OpenRC) service units. Full walkthrough: [docs/guides/MT-ADMIN-QUICKSTART.md](docs/guides/MT-ADMIN-QUICKSTART.md). Production reference: [docs/ops/MULTITENANCY-PRODUCTION.md](docs/ops/MULTITENANCY-PRODUCTION.md).

Prerequisites: root/sudo, Docker **or** Podman, `jq`, `git`. No host Rust toolchain needed — `add-tenant` installs a per-tenant rustup toolchain with WASM targets.

```bash
# 1. Check dependencies
sudo ic/scripts/lunarwing-mt-admin.sh doctor

# 2. Provision a tenant (creates OS user, allocates ports, clones repo,
#    writes env files, starts per-tenant PostgreSQL, renders service units)
sudo ic/scripts/lunarwing-mt-admin.sh add-tenant ruffles --docker-group

# 3. Build the tenant's release binary (+ WASM tools)
sudo ic/scripts/lunarwing-mt-admin.sh build-tenant ruffles --with-wasm
sudo ic/scripts/lunarwing-mt-admin.sh install-wasm ruffles

# 4. Start it
sudo ic/scripts/lunarwing-mt-admin.sh start-tenant ruffles

# 5. Inspect
sudo ic/scripts/lunarwing-mt-admin.sh status ruffles     # service + container health
sudo ic/scripts/lunarwing-mt-admin.sh tokens ruffles     # gateway auth token, ports, etc.
```

The gateway binds `127.0.0.1` by default; for remote access, tunnel the HTTP port over SSH (e.g. `ssh -L 10000:127.0.0.1:10000 user@host`, then open `http://localhost:10000`). Batch provisioning is supported: `add-tenants "Ruffles,Miyuki,Sparkie" --docker-group` then `build-all --with-wasm` / `install-wasm-all`.

Additional worker containers (nanocode, pebble, opencode) can be attached at build time with `--with-nanocode` / `--with-pebble` / `--with-opencode`. DarkIRC is opt-in (`--enable-darkirc` + `build-darkirc`). See the quickstart for the full flag reference.

### Preseeding persona files before first run (optional)

LunarWing supports a preseeded workspace layout: you can give an agent a custom identity and memories *before* its first interaction. At runtime, workspace files are imported from `$LUNARWING_BASE_DIR/workspace-template/` before the generic built-in seeds, so the persona and memory files under [ic/deploy/workspace-template/](ic/deploy/workspace-template/) can be customized per instance: `SOUL.md`, `IDENTITY.md`, `AGENTS.md`, `TOOLS.md`, `USER.md`, `MEMORY.md`, `HEARTBEAT.md`.

`ic/scripts/setup-instance.sh` is a legacy helper that writes `config.toml`, `.env`, and copies the workspace template, then invokes onboarding. It still functions, but is **not actively maintained** — the maintained paths are the onboarding wizard (single instance) and `lunarwing-mt-admin.sh` (multi-tenant). If you only need to preseed persona files, copy them into `$LUNARWING_BASE_DIR/workspace-template/` manually and run `lunarwing onboard --quick`.

### Config defaults

The shipped runtime config template is [ic/deploy/config.toml](ic/deploy/config.toml). Defaults: `llm_backend = "openai_compatible"`, `selected_model = "tensorzero::function_name::lunarwing"`, `agent.name = "lunarwing"`. The default `openai_compatible_base_url` in the template points at a TensorZero proxy; override it via env or `config.toml` for your environment.

`SECRETS_MASTER_KEY` (a 64-char hex value) enables the encrypted secrets store without depending on the OS keychain. On Linux, `lunarwing onboard --quick` generates and persists this automatically when missing; in multi-tenant setups `lunarwing-mt-admin.sh` provisions it per tenant.

## Upgrading & Migration

LunarWing ships dedicated tooling for two distinct operations, both driven by `ic/scripts/lunarwing-mt-admin.sh` and documented under `docs/ops/`:

- **Same-host version upgrade** — bump an existing tenant from an older LunarWing release to a newer one in place. The general-purpose upgrader is `ic/scripts/upgrade-tenant-version.sh` (PostgreSQL, rootful Docker; supports `--target <version>` and a read-only dry-run by default, `--apply` to execute). A readiness preflight is available via `ic/scripts/upgrade-preflight.sh`. See `docs/ops/MT-LEGACY-UPGRADE-NOTES.md` for the full runbook and gates.

- **Cross-host migration (Kawarimi)** — move a tenant to a different host while leaving the old one as a rollback standby. The flow is `export-tenant.sh <tenant>` on the source (produces a `0600` bundle: `pg_dump`, env manifests, OMEMO store + workspace) → `import-tenant.sh <bundle.tar>` on the target. **PostgreSQL-only**; libSQL tenants are refused. This is a cutover with per-tenant downtime. See `docs/guides/MIGRATE_IRONCLAW_TO_LUNARWING.md` and `docs/ops/MT-MACHINE-MIGRATION.md`.

Both paths are **hardened but should be rehearsed** against a non-production tenant before being trusted on live data. Always back up first (`mt-admin.sh backup-tenant <name>`).

## Testing

### Rust Unit & Integration Tests

```bash
cd ic
cargo test                          # unit tests
cargo test --features integration   # + PostgreSQL tests
cargo test test_name -- --nocapture # single test with output
```

### E2E Tests (Python/Playwright)

Browser-based E2E tests against a live instance with a mock LLM. See [ic/tests/e2e/CLAUDE.md](ic/tests/e2e/CLAUDE.md).

```bash
cd ic/tests/e2e
python -m venv .venv && source .venv/bin/activate
pip install -e .
playwright install chromium
pytest scenarios/
```

### Worker Test Harness

Matrix test suite for all external worker types (nanocode, pebble, opencode), plus the built-in and sandbox workers. Validates health endpoints, WebSocket protocol, error handling, and resource cleanup.

```bash
cd tests
pip install -r requirements.txt
python runner.py --mode smoke     # happy paths only (CI)
python runner.py --mode full      # + chaos scenarios (nightly)
python runner.py --worker nanocode   # single worker type
```

See [tests/README.md](tests/README.md) for the full test matrix and mock service architecture.

### Integration Test Harness

`ic/scripts/lunarwing-xmpp-test-env.sh` is the full-stack test harness for PostgreSQL, TensorZero proxy, XMPP bridge, WASM artifacts, and the daemon. Works on Linux and macOS.

- Single-tenant quick start: see [docs/ops/HARNESS-SINGLE-TENANT.md](docs/ops/HARNESS-SINGLE-TENANT.md)
- Multi-tenant quick start: see [docs/ops/MULTITENANCY-HARNESS.md](docs/ops/MULTITENANCY-HARNESS.md)
- Full single-tenant reference: [ic/testing/lunarwing-xmpp/README.md](ic/testing/lunarwing-xmpp/README.md)

## Watchdog Scheduler

```bash
sudo ic/scripts/install-lunarwing-watchdog.sh
```

Behavior depends on the detected service manager:

- **systemd**: installs `lunarwing-watchdog.service` + `lunarwing-watchdog.timer`
- **OpenRC**: installs `lunarwing-watchdog-openrc` + either an hourly hook or a managed root `fcrontab` entry

The OpenRC default is intentionally conservative:
- If `cronie`, `crond`, or `dcron` is already present, the installer keeps the cron-hourly path
- If no cron daemon is present but `fcron` is available, the installer uses `fcron` automatically

Force a specific OpenRC mode:

```bash
sudo LUNARWING_WATCHDOG_SCHEDULER=fcron ic/scripts/install-lunarwing-watchdog.sh
sudo LUNARWING_WATCHDOG_SCHEDULER=hourly ic/scripts/install-lunarwing-watchdog.sh
```

Use `LUNARWING_WATCHDOG_CRON_DIR=/path/to/hourly-dir` for nonstandard directory layouts.

## Fresh Recreate Recipes

### PostgreSQL + XMPP + systemd

See the documented recipe in [ic/testing/lunarwing-xmpp/README.md](ic/testing/lunarwing-xmpp/README.md).

### libSQL with Custom Gateway Token

```bash
cd ic

export BASE=/tmp/lunarwing-libsql
export GATEWAY_TOKEN='replace-me-gateway-token'
export LLM_API_KEY='unneeded'

rm -rf "$BASE"

scripts/setup-instance.sh \
  --base-dir "$BASE" \
  --database libsql \
  --libsql-path "$BASE/lunarwing.db" \
  --llm-base-url http://127.0.0.1:3002/openai/v1 \
  --llm-model tensorzero::function_name::lunarwing \
  --llm-api-key "$LLM_API_KEY" \
  --agent-name lunarwing \
  --run-onboard

python3 - <<'PY'
import os
from pathlib import Path

path = Path(os.environ["BASE"]) / ".env"
values = {
    "LUNARWING_BASE_DIR": os.environ["BASE"],
    "GATEWAY_ENABLED": "true",
    "GATEWAY_HOST": "127.0.0.1",
    "GATEWAY_PORT": "8765",
    "GATEWAY_AUTH_TOKEN": os.environ["GATEWAY_TOKEN"],
}

lines = path.read_text().splitlines()
seen = set()
out = []
for line in lines:
    if "=" in line and not line.lstrip().startswith("#"):
        key, _ = line.split("=", 1)
        if key in values:
            out.append(f"{key}={values[key]}")
            seen.add(key)
            continue
    out.append(line)
for key, value in values.items():
    if key not in seen:
        out.append(f"{key}={value}")
path.write_text("\n".join(out) + "\n")
PY

LUNARWING_BASE_DIR="$BASE" ./target/debug/lunarwing run
```

## Further Reading

Full documentation index: [docs/README.md](docs/README.md)

### By topic

- **Architecture & design:** [docs/architecture/](docs/architecture/) — Engine V2, semantic memory, WeeChat, XMPP file transfers, self-heal wiring
- **How-to guides:** [docs/guides/](docs/guides/) — setup, migration, embeddings, vision/OCR sidecar, TensorZero, REPLv2
- **Operations & multi-tenancy:** [docs/ops/](docs/ops/) — production MT, per-tenant config, harness guides, worker containers, release cadence
- **Release notes:** [docs/releases/](docs/releases/) — v1.0.7 → v1.1.8 (latest: [RELEASE-v1.1.8.md](docs/releases/RELEASE-v1.1.8.md))
- **Bug tracker:** [docs/bugs/README.md](docs/bugs/README.md)
- **Active proposals:** [docs/proposals/](docs/proposals/)
- **Vision service:** [projects/ocr-sidecar/README.md](projects/ocr-sidecar/README.md)
- **Testing guide:** [docs/guides/TESTING_GUIDE.md](docs/guides/TESTING_GUIDE.md)

## Community

### Interested in development or otherwise general discussion of LunarWing?

[![Chat on IRC](https://img.shields.io/badge/IRC-%23lunarwing-00b0aa?style=for-the-badge&labelColor=000000)](https://web.libera.chat/?channel=#lunarwing)

#### See: COMMUNITY.md for more information
