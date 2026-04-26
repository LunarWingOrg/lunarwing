# LunarWing

## Secure, Privacy focused AI Agent

### Our website:
[LunarWing](https://lunarwing.org/)

<img width="512" height="512" alt="darklogo" src="https://github.com/user-attachments/assets/28e6abcb-16fe-43e5-8c44-6d2d734c64f3" />

The LunarWing project is a hard fork of the Ironclaw project originally developed by NearAI. The fork was initially started in Febuary 2026 and continues to expand far beyond what NearAI's project is currently capable of.

LunarWing adds much needed features to the project. There are far too many improvements to merge them all upstream.

## Why "LunarWing"?: 

### `Lunar` - We are firm believers in the Lunarpunk philosophy. See our MANIFESTO for more information.

### `Wing` - Wings are extensions of the body which allow flight. We can soar and we believe we will soar to even greater heights in time. (Wings can often serve other purposes as well.) We are not required to remain on the ground. Our imagination has enabled us to innovate in this space, where others have not been able to.

The LunarWing project team maintains AGPLv3 license forever as well as AGPLv3 license on its extensions, tools, and channels.

The LunarWing project was created with free open source software in mind. The LunarWing project is dedicated free open source infrastructure.

The LunarWing project adds real privacy respecting tools and channels, with full secret support, right out of the box. These include, but are not limited to:
* Gotify (Tool, WASM, agents can send notifications via gotify)
* Weechat (Channel, utilize weechat as an IRC client for an agent to communicate, WASM)
* DarkIRC (Channel, Darkfi WASM)
* XMPP with OMEMO (wasm channel, bridge service, and core code changes had to be made to accomodate properly)
* Persistent Codex (developed primarily by OpenAI) Worker Container with optional support for ACP via a specialized bridge, optional persistent mounted storage, and much more! (Custom Woker Container)
* Persistent Nanocode (developed and maintained by the NanoGPT community) Worker Container with optional support for ACP via a specialized bridge, optional persistent mounted storage, and much more! (Custom Worker container)

LunarWing developers actually care about your freedom as a user. This means that we simply do not support adding tools and channels to our official repository which we do not think allign with our values (see MANIFESTO). We do not force users to shy away from said tools and channels, but we will not be supporting them in our main monorepo here. All wasm tools and channels that develepors wish to create and maintain for LunarWing can be done so elsewhere. We simply do not have the time or patience or willingness to develop and support certain proprietary platforms for LunarWing. Especially not when we feel there is so much more important work to accomplish for this project. What we DO care about is self-hostable communciation layers. We will NOT continue to develop or support proprietary channels such as Slack, Telegram, or Discord due to ethical reasons but also because we feel that it is not our place to do so.

The LunarWing core development team is ACTUALLY serious about security and privacy, unlike the vast majority of "Claw" software.

LunarWing and its core contributers are not affiliated with NearAI.

## A Partial List of Brand New Additional Features which LunarWing introduces which are not in the upstream repository:

* Specialized secret management wrapper scripts for both Postgres (we've enhanced postgres with finer tuned controls in our project) and LibSQL. See Secrets_Manager for more details.
* Optional systemd and openrc services for Lunarwing, channel bridges, and Healthcheck services (Please note that utilizing some of the new channel bridges currently breaks multi-tenancy in certain ways. This is still being worked on)
* Improved Scheduling System designed by Ruffles
* Support for external agentic coding tools developed independently from upstream.
* Better support for logging common errors which still plague the upstream project.
* Self healing, advanced healthchecks for channel bridge services, the running LunarWing binary/daemon/service itself, and even optional self healing solutions for routines in the case of routine failures.
* Automated Testing Suite for development work
* Function calls, Inference, and feedback for models (see Tensorzero for examples)

## Additionally, we support custom HTTP proxies for TensorZero routing setups with optimized tool_choice routing for open source coding agent applications as well as other various purposes.
### The Project Scope:
Our scope is large and is mainly concerned with adding many essential features from Upstream which are still missing, including more advanced health checking and self-repair mechanisms. The LunarWing team is more interested in providing useful features instead of support for proprietary chinese document editing tools or other unecessary crapware. Our vision for LunarWing is expressed in our MANIFESTO.

#### Our core team utilizes a self-hoste Vikunja kanban board to keep track of tasks.

## Instance Setup Defaults

LunarWing supports a preseeded instance layout for fresh installs. The easiest
way to prepare one is:

```bash
ic/scripts/setup-instance.sh \
  --base-dir /srv/lunarwing \
  --database postgres \
  --database-url 'postgres://user:pass@db:5432/lunarwing' \
  --llm-api-key unneeded \
  --run-onboard
```

For a local libSQL setup:

```bash
ic/scripts/setup-instance.sh \
  --base-dir /srv/lunarwing-dev \
  --database libsql \
  --libsql-path /srv/lunarwing-dev/ironclaw.db \
  --run-onboard
```

To preseed the instance name, gateway token, and env-backed secrets master key
as part of setup:

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

This writes:
- `$LUNARWING_BASE_DIR/config.toml`
- `$LUNARWING_BASE_DIR/.env`
- `$LUNARWING_BASE_DIR/workspace-template/*.md`

Preferred env var: `LUNARWING_BASE_DIR`
Legacy alias still accepted: `IRONCLAW_BASE_DIR`

Current seeded config defaults:
- `llm_backend = "openai_compatible"`
- `openai_compatible_base_url = "http://192.168.1.157:3002"`
- `selected_model = "tensorzero::function_name::ironclaw"`
- `agent.name = "lunarwing"`

Useful setup-time values:
- `--agent-name` writes `[agent].name` to `config.toml`
- `--gateway-token` writes `GATEWAY_AUTH_TOKEN` to `.env`
- `--secrets-master-key` writes `SECRETS_MASTER_KEY` to `.env`

`SECRETS_MASTER_KEY` must be a 64-character hex string. Use this when you want
the encrypted secrets store and secret-management scripts to work without
depending on the OS keychain.

During `ironclaw onboard --quick`, Linux/non-macOS setups now generate and
persist this value automatically to the selected instance `.env` when it is
missing. macOS still prefers keychain storage by default.

Those files are created automatically for a missing base dir on normal startup
too, not only through the onboarding wizard.

For a simple local launcher wrapper, use:

```bash
cd ic
LUNARWING_BASE_DIR=/path/to/instance ./run.sh
```

`ic/run.sh` defaults `AGENT_NAME=lunarwing` and will pass through any explicit
`AGENT_NAME`, `LUNARWING_BASE_DIR`, or legacy `IRONCLAW_BASE_DIR` you export.
It does not inject LLM URL or model defaults, so fresh instances use
`config.toml` unless you explicitly override them with env vars.

Seed source files in this repository:
- Runtime config template: [ic/deploy/config.toml](ic/deploy/config.toml)
- Persona and memory seeds: [ic/deploy/workspace-template/](ic/deploy/workspace-template/)

At runtime those workspace files are imported from
`$LUNARWING_BASE_DIR/workspace-template/` before generic built-in seeds, so
files such as `SOUL.md`, `IDENTITY.md`, `BOOTSTRAP.md`, `TOOLS.md`, and
`USER.md` can be customized on disk per instance.

### Fresh Recreate Recipes

For the full PostgreSQL + XMPP + user-systemd harness, including custom
database credentials and custom gateway/bridge tokens, use the documented
recipe in
[ic/testing/lunarwing-xmpp/README.md](ic/testing/lunarwing-xmpp/README.md).

### Watchdog Scheduler

For production healthchecks, use:

```bash
sudo ic/scripts/install-lunarwing-watchdog.sh
```

Behavior depends on the detected service manager:

- `systemd`: installs `lunarwing-watchdog.service` plus `lunarwing-watchdog.timer`
- `OpenRC`: installs `lunarwing-watchdog-openrc` plus either an hourly hook or a
  managed root `fcrontab` entry

The OpenRC default is intentionally conservative:

- if `cronie`, `crond`, or `dcron` is already present, the installer keeps the
  cron-hourly path and does not switch you to `fcron`
- if no cron-hourly daemon is present but `fcron` is available, the installer
  uses `fcron` automatically

Force a specific OpenRC mode with:

```bash
sudo LUNARWING_WATCHDOG_SCHEDULER=fcron ic/scripts/install-lunarwing-watchdog.sh
sudo LUNARWING_WATCHDOG_SCHEDULER=hourly ic/scripts/install-lunarwing-watchdog.sh
```

Use `LUNARWING_WATCHDOG_CRON_DIR=/path/to/hourly-dir` when you need the
hourly-hook path in a nonstandard directory layout.

For a clean libSQL recreate with a custom gateway token:

```bash
cd ic

export BASE=/tmp/lunarwing-libsql
export GATEWAY_TOKEN='replace-me-gateway-token'
export LLM_API_KEY='unneeded'

rm -rf "$BASE"

scripts/setup-instance.sh \
  --base-dir "$BASE" \
  --database libsql \
  --libsql-path "$BASE/ironclaw.db" \
  --llm-base-url http://127.0.0.1:3002/openai/v1 \
  --llm-model tensorzero::function_name::ironclaw \
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

LUNARWING_BASE_DIR="$BASE" ./target/debug/ironclaw run
```

### See: ic/testing/lunarwing-xmpp/README.md for more information and latest instructions

#### also check REPLv2_Client_and_Server.md for information on REPLv2 Server and Client repos...
