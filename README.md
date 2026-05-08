# LunarWing

## Claws are overrated. So, grow your wings and fly...

### Secure, Performant, Privacy-Focused AI Agent Software

[LunarWing](https://lunarwing.org/)

<img width="512" height="512" alt="darklogo" src="https://github.com/user-attachments/assets/28e6abcb-16fe-43e5-8c44-6d2d734c64f3" />

LunarWing is a hard fork of the Ironclaw project originally developed by NearAI, started February 2026. The fork has grown far beyond the upstream project's capabilities.

LunarWing is a self-hosted, privacy-first AI agent. The fork prioritizes XMPP/OMEMO, Gotify, scheduled routines, systemd deployment, and open-protocol channels. Proprietary channels (Slack, Discord, Telegram) are intentionally unsupported. Upstream compatibility is not a goal.

The LunarWing project maintains the AGPLv3 license on the core project and all extensions, tools, and channels.

## Why "LunarWing"?

**Lunar** -- We are firm believers in the Lunarpunk philosophy. See our MANIFESTO for more information as well as the philosophical journal, *Agorism in the 21st Century*.

**Wing** -- Wings are extensions of the body which allow flight. We chose the term `wing` to differentiate ourselves from most open source agentic software which uses the term `claw`. We are not required to remain on the ground.

## Features

LunarWing adds real privacy-respecting tools and channels, with full secret support, right out of the box:

### Channels & Communication
* **XMPP with OMEMO** -- WASM channel, bridge service, and core code changes for full encrypted chat (1:1 and group)
* **Weechat** -- WASM channel allowing the agent to use Weechat as an IRC/DarkIRC/Signal/XMPP/Slack/Matrix/Rocketchat client
* **DarkIRC** -- DarkFi WASM channel

### Tools & Notifications
* **Gotify** -- WASM tool for agent-initiated push notifications

### Worker Containers
* **Codex Worker** -- Persistent OpenAI Codex worker container with optional ACP bridge support and persistent mounted storage (`codex4ironclaw/`)
* **Nanocode Worker** -- Persistent NanoGPT community Nanocode worker container with optional ACP bridge and persistent storage (`nanocode4ironclaw/`)
* **Built-in Worker** -- Native worker running inside the LunarWing daemon (`ic/src/worker/`)
* **Sandbox Worker** -- Docker-isolated execution sandbox (`ic/src/sandbox/`)

### Infrastructure & Operations
* Specialized secret management wrapper scripts for both PostgreSQL and libSQL
* Optional systemd and OpenRC services for LunarWing, channel bridges, and healthcheck services
* Improved scheduling system with native retry and exponential backoff for transient failures, stuck-run recovery, configurable lightweight execution timeouts, and automatic sweeping of orphaned routine runs
* Self-healing healthchecks for channel bridge services, the daemon, and the routines system. Infrastructure health checks auto-detect init system (systemd, OpenRC, launchd)
* Production multi-tenant deployment via `ic/scripts/lunarwing-mt-admin.sh` with per-user OS isolation, port registry, and support for systemd, macOS (launchd), and OpenRC
* TensorZero HTTP proxy support for model routing, function-call routing, and training feedback loops

### Development & Testing
* Automated test suite with trace-replay E2E testing (no real LLM required)
* Worker test harness for all 4 worker types with Docker Compose isolation (`tests/`)
* REPLv2 server and client with better output formatting and subagent support
* Support for external agentic coding tools developed independently from upstream
* Cross-platform test harness (`lunarwing-xmpp-test-env.sh`) with launchd (macOS), systemd (Linux), and OpenRC support

### Philosophy

LunarWing developers care about your freedom as a user. We do not support proprietary platforms in our official repository. All WASM tools and channels that developers wish to create for proprietary platforms can be maintained elsewhere. We focus on self-hostable communication layers and open protocols.

The LunarWing core development team is not affiliated with NearAI.

Our core team uses a self-hosted Vikunja kanban board to track tasks.

## Instance Setup

LunarWing supports a preseeded instance layout for fresh installs.

### PostgreSQL

```bash
ic/scripts/setup-instance.sh \
  --base-dir /srv/lunarwing \
  --database postgres \
  --database-url 'postgres://user:pass@db:5432/lunarwing' \
  --llm-api-key unneeded \
  --run-onboard
```

### libSQL

```bash
ic/scripts/setup-instance.sh \
  --base-dir /srv/lunarwing-dev \
  --database libsql \
  --libsql-path /srv/lunarwing-dev/lunarwing.db \
  --run-onboard
```

### With Preseeded Secrets

```bash
ic/scripts/setup-instance.sh \
  --base-dir /srv/lunarwing-secure \
  --database postgres \
  --database-url 'postgres://user:pass@db:5432/lunarwing' \
  --agent-name lunarwing \
  --gateway-token 'replace-me-gateway-token' \
  --secrets-master-key '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef' \
  --llm-api-key unneeded \
  --run-onboard
```

Setup writes:
- `$LUNARWING_BASE_DIR/config.toml`
- `$LUNARWING_BASE_DIR/.env`
- `$LUNARWING_BASE_DIR/workspace-template/*.md`

Preferred env var: `LUNARWING_BASE_DIR` (legacy alias `IRONCLAW_BASE_DIR` still accepted).

### Setup Options

| Flag | Effect |
|------|--------|
| `--agent-name` | Writes `[agent].name` to `config.toml` |
| `--gateway-token` | Writes `GATEWAY_AUTH_TOKEN` to `.env` |
| `--secrets-master-key` | Writes `SECRETS_MASTER_KEY` to `.env` (64-char hex) |

`SECRETS_MASTER_KEY` enables the encrypted secrets store without depending on the OS keychain. On Linux, `lunarwing onboard --quick` generates and persists this value automatically when it is missing. macOS prefers keychain storage by default.

### Config Defaults

```
llm_backend = "openai_compatible"
openai_compatible_base_url = "http://192.168.1.157:3002"
selected_model = "tensorzero::function_name::lunarwing"
agent.name = "lunarwing"
```

Seed files:
- Runtime config template: [ic/deploy/config.toml](ic/deploy/config.toml)
- Persona and memory seeds: [ic/deploy/workspace-template/](ic/deploy/workspace-template/)

At runtime, workspace files are imported from `$LUNARWING_BASE_DIR/workspace-template/` before generic built-in seeds, so files such as `SOUL.md`, `IDENTITY.md`, `BOOTSTRAP.md`, `TOOLS.md`, and `USER.md` can be customized per instance.

## Running Locally

```bash
cd ic
LUNARWING_BASE_DIR=/path/to/instance ./run.sh
```

`run.sh` defaults `AGENT_NAME=lunarwing` and passes through any explicit `AGENT_NAME`, `LUNARWING_BASE_DIR`, or legacy `IRONCLAW_BASE_DIR` you export. It does not inject LLM URL or model defaults, so fresh instances use `config.toml` unless you override with env vars.

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

Matrix test suite for all 4 worker types (Codex, Nanocode, Built-in, Sandbox) running in Docker Compose isolation. Validates health endpoints, WebSocket protocol, error handling, and resource cleanup.

```bash
cd tests
pip install -r requirements.txt
python runner.py --mode smoke     # happy paths only (CI)
python runner.py --mode full      # + chaos scenarios (nightly)
python runner.py --worker codex   # single worker type
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

- REPLv2 server and client: see `REPLv2_Client_and_Server.md`
- Development guide: see [ic/CLAUDE.md](ic/CLAUDE.md)
- Architecture docs: see [docs/](docs/)
