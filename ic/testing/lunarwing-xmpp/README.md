# LunarWing XMPP Test Environment Setup

This is the practical setup guide for the local LunarWing and XMPP bridge test
environment created by `scripts/lunarwing-xmpp-test-env.sh`.

The test environment is isolated from your normal `~/.lunarwing` state. By
default it lives at:

```bash
/tmp/lunarwing-xmpp-test
```

Use this harness when you want to test:

- the `xmpp-bridge` sidecar HTTP API
- bearer-token enforcement on the bridge
- live XMPP bridge configuration
- LunarWing running against isolated state
- service behavior (systemd user units on Linux, launchd agents on macOS, direct PID management everywhere)

The harness is cross-platform. Single-tenant `up`/`down` uses direct PID management on all platforms. Multi-tenant commands (`mt-*`) auto-detect the init system and use launchd on macOS, systemd on Linux, or fall back to direct management. The `doctor` command reports service status for the detected platform.

**Platform testing status:**
- macOS (launchd): tested end-to-end — `mt-init`, `build --with-wasm`, `mt-up`, `mt-verify`, `mt-down` all verified
- Linux (systemd): implemented, not recently re-verified with current harness version
- Linux (OpenRC): **implemented but not FULLY tested end-to-end on a real Gentoo machine yet (will be done very soon though)** — the code path exists but has never been run on a real OpenRC system yet (Gentoo, Alpine, Artix, postmarketOS, Devuan, Hyberbola, etc.); treat as best-effort until validated...

The `customic/` tree is not part of this setup.

## 1. Pick a Test Root

Use the default `/tmp` root for throwaway tests:

```bash
cd /home/cmc/lunarwing/ic
scripts/lunarwing-xmpp-test-env.sh init
```

Use a persistent root when you want the same env, logs, database, and OMEMO
store after reboot:

```bash
cd /home/cmc/lunarwing/ic
export LUNARWING_TEST_ROOT="$HOME/.local/state/lunarwing-xmpp-test"
scripts/lunarwing-xmpp-test-env.sh init
```

Keep that `LUNARWING_TEST_ROOT` exported for later commands in the same shell.
If you open a new shell, export it again before using the harness.

## 2. Inspect the Generated Files

After `init`, the harness creates:

```text
$LUNARWING_TEST_ROOT/
  env/
    lunarwing.env
    xmpp-bridge.env
  logs/
  run/
  state/
    xmpp/
  systemd/    # systemd unit files (Linux)
  launchd/    # launchd plist files (macOS)
```

If `LUNARWING_TEST_ROOT` is not set, replace it with
`/tmp/lunarwing-xmpp-test` in the paths above.

The env files are mode `0600`. They may contain tokens and XMPP passwords.
Do not paste their contents into chat, issues, logs, or command output.

Use the example files in this directory only as references:

- `testing/lunarwing-xmpp/lunarwing.env.example`
- `testing/lunarwing-xmpp/xmpp-bridge.env.example`

Edit the generated env files, not the examples.

The generated `env/lunarwing.env` is already seeded for the common private-lab
stack used by this harness:

- `IRONCLAW_SOCKET=$LUNARWING_TEST_ROOT/run/ironclaw.sock`
- `LUNARWING_SOCKET=$LUNARWING_TEST_ROOT/run/lunarwing.sock`
- `DATABASE_BACKEND=postgres`
- `DATABASE_SSLMODE=disable`
- `PGSSLMODE=disable`
- `ALLOW_PRIVATE_IPS=1`
- `LLM_BACKEND=openai_compatible`
- `LLM_BASE_URL=http://127.0.0.1:3002/openai/v1`
- `LLM_MODEL=tensorzero::function_name::ironclaw`
- `WASM_CHANNELS_ENABLED=true`

Do not remove those defaults unless you are intentionally changing the test
network, database SSL mode, or provider path.

## macOS Setup

On macOS, the WASM toolchain requires additional setup before the first `build --with-wasm` or `mt-up`:

```bash
# Both WASM targets are needed (wasip1 for channels/tools, wasip2 for some components)
rustup target add wasm32-wasip1 wasm32-wasip2

# WASM build tools
cargo install wasm-tools cargo-component --locked
```

**PATH ordering matters.** Homebrew installs its own `rustc` which lacks WASM targets. The rustup-managed toolchain must come first:

```bash
export PATH="$HOME/.rustup/toolchains/stable-$(rustc -vV | awk '/host/{print $2}')/bin:$HOME/.cargo/bin:$PATH"
which rustc   # must show ~/.rustup/toolchains/... not /opt/homebrew/bin/rustc
```

If `rustc` resolves to the Homebrew copy, all `cargo component build` invocations will fail with `can't find crate for 'core'`.

Docker Desktop must be running. If the `pgvector/pgvector:pg16` image is not cached locally, `mt-up` will pull it on first run. For multi-tenant harness usage, see `MULTITENANCY-HARNESS.md`.

## Fresh Recreate Recipes

### PostgreSQL + harness (all platforms)

Use this when you want a full clean harness with custom database credentials,
custom gateway and bridge tokens. The harness auto-detects the platform and
uses the appropriate service management (launchd on macOS, systemd or OpenRC on Linux,
direct PID management otherwise).

The built-in `start-postgres` helper still creates `lunarwing:lunarwing@.../lunarwing`.
If you need custom PostgreSQL credentials, create the container yourself and
point `LUNARWING_TEST_DATABASE_URL` at it as shown below.

```bash
cd /home/cmc/lunarwing/ic

export LUNARWING_TEST_ROOT=/tmp/lunarwing-fresh-harness
export PG_CONTAINER=lunarwing-test-postgres
export PG_PORT=55432
export PG_USER=lunarwing
export PG_PASS='replace-me-db-pass'
export PG_DB=lunarwing
export GATEWAY_TOKEN='replace-me-gateway-token'
export BRIDGE_TOKEN='replace-me-bridge-token'
export XMPP_PASSWORD='replace-me-xmpp-password'
export LLM_API_KEY='unneeded'

# Linux (systemd): stop and remove old units
systemctl --user stop lunarwing-test.service xmpp-bridge-test.service lunarwing-proxy-test.service 2>/dev/null || true
rm -f ~/.config/systemd/user/lunarwing-test.service ~/.config/systemd/user/xmpp-bridge-test.service ~/.config/systemd/user/lunarwing-proxy-test.service
systemctl --user daemon-reload 2>/dev/null || true
# macOS: remove old launchd agents (if any)
launchctl unload ~/Library/LaunchAgents/com.lunarwing.test.*.plist 2>/dev/null || true
rm -f ~/Library/LaunchAgents/com.lunarwing.test.*.plist 2>/dev/null || true
docker rm -f "$PG_CONTAINER" 2>/dev/null || true
rm -rf "$LUNARWING_TEST_ROOT"

docker run -d \
  --name "$PG_CONTAINER" \
  -e POSTGRES_USER="$PG_USER" \
  -e POSTGRES_PASSWORD="$PG_PASS" \
  -e POSTGRES_DB="$PG_DB" \
  -p "127.0.0.1:${PG_PORT}:5432" \
  pgvector/pgvector:pg16

until docker exec "$PG_CONTAINER" pg_isready -U "$PG_USER" -d "$PG_DB" >/dev/null 2>&1; do sleep 1; done

export LUNARWING_TEST_PG_CONTAINER="$PG_CONTAINER"
export LUNARWING_TEST_PG_PORT="$PG_PORT"
export LUNARWING_TEST_DATABASE_URL="postgres://${PG_USER}:${PG_PASS}@127.0.0.1:${PG_PORT}/${PG_DB}"

scripts/lunarwing-xmpp-test-env.sh init

python3 - <<'PY'
import os
from pathlib import Path

root = Path(os.environ["LUNARWING_TEST_ROOT"])
updates = {
    root / "env/lunarwing.env": {
        "LLM_API_KEY": os.environ["LLM_API_KEY"],
        "GATEWAY_AUTH_TOKEN": os.environ["GATEWAY_TOKEN"],
    },
    root / "env/xmpp-bridge.env": {
        "XMPP_BRIDGE_TOKEN": os.environ["BRIDGE_TOKEN"],
        "XMPP_PASSWORD": os.environ["XMPP_PASSWORD"],
    },
}

for path, values in updates.items():
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

scripts/lunarwing-xmpp-test-env.sh build --with-wasm
scripts/lunarwing-xmpp-test-env.sh install-wasm
scripts/lunarwing-xmpp-test-env.sh render-systemd
mkdir -p ~/.config/systemd/user
cp "$LUNARWING_TEST_ROOT/systemd/"*.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user restart lunarwing-test.service
scripts/lunarwing-xmpp-test-env.sh gateway-status
scripts/lunarwing-xmpp-test-env.sh verify
```

`build` also compiles the actual REPLv2 client with `cargo build --release`
from:

- `/home/sun/lw_workspace/lunarwing/replv2git/git-ironclaw-unix-socket-client-repo`

The expected binary is:

- `/home/sun/lw_workspace/lunarwing/replv2git/git-ironclaw-unix-socket-client-repo/target/release/unix-socket-client-v2`

To target the active harness daemon cleanly:

```bash
scripts/lunarwing-xmpp-test-env.sh repl
```

The socket filename is now `lunarwing.sock`, but the harness now places it
under the per-instance `run/` directory, so parallel harness roots do not
fight over a single global socket path.

You can still pass explicit client flags through the helper:

```bash
scripts/lunarwing-xmpp-test-env.sh repl -- --socket /tmp/other.sock
```

If you only want bridge API smoke tests, leave `XMPP_PASSWORD` empty and skip
live XMPP configuration until later.

### libSQL fresh instance

The XMPP harness is PostgreSQL-first. For a clean libSQL recreate, use the
instance bootstrap script instead of `lunarwing-xmpp-test-env.sh`.
There is no database password in this mode; the only secrets below are the
gateway token and optional LLM API key.

```bash
cd /home/cmc/lunarwing/ic

export BASE=/tmp/lunarwing-libsql
export GATEWAY_TOKEN='replace-me-gateway-token'
export LLM_API_KEY='unneeded'

rm -rf "$BASE"

scripts/setup-instance.sh \
  --base-dir "$BASE" \
  --database libsql \
  --libsql-path "$BASE/lunarwing.db" \
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

LUNARWING_BASE_DIR="$BASE" ./target/debug/lunarwing run
```

That flow still seeds `config.toml` plus `workspace-template/` from `deploy/`,
so `SOUL.md`, `IDENTITY.md`, `HEARTBEAT.md`, and the other instance files start
from the LunarWing templates.

## 3. Build the Test Binaries

Build both the current LunarWing binary and the bridge:

```bash
scripts/lunarwing-xmpp-test-env.sh build
```

This builds:

```text
target/debug/lunarwing
bridges/xmpp-bridge/target/debug/xmpp-bridge
```

The binary is named `lunarwing`.

For release binaries:

```bash
export LUNARWING_TEST_PROFILE=release
scripts/lunarwing-xmpp-test-env.sh build
```

Use the same `LUNARWING_TEST_PROFILE` for later `start-*`, `smoke`, and
`render-systemd` commands.

For the full extension set used by the current harness docs, build and install
the WASM artifacts before trying a service-backed run:

```bash
scripts/lunarwing-xmpp-test-env.sh build --with-wasm
```

## Service Names

The harness intentionally renders test services by default:

```text
lunarwing-test.service
xmpp-bridge-test.service
```

Those names avoid clobbering a real user or system service named
`lunarwing.service`, `lunarwing.service`, or `xmpp-bridge.service`.

When you want the generated units to use the real LunarWing name, set both
service-name variables before rendering:

```bash
export LUNARWING_TEST_SERVICE_NAME=lunarwing.service
export LUNARWING_TEST_BRIDGE_SERVICE_NAME=xmpp-bridge.service
scripts/lunarwing-xmpp-test-env.sh render-systemd
```

The harness uses the same names everywhere it generates dependencies:

- the bridge unit gets `PartOf=$LUNARWING_TEST_SERVICE_NAME`
- the LunarWing unit gets `Wants=` and `After=` for
  `$LUNARWING_TEST_BRIDGE_SERVICE_NAME`
- `configure-bridge --restart` passes the bridge service name through
  `XMPP_BRIDGE_SERVICE`

For generated user services, `configure-bridge --restart` uses
`systemctl --user` by default. For a machine-level service, set:

```bash
export LUNARWING_TEST_SYSTEMCTL_SCOPE=system
```

If you use the watchdog with a renamed service, point it at the same main unit:

```bash
LUNARWING_WATCHDOG_SERVICE=lunarwing.service scripts/lunarwing-watchdog.sh
```

## 4. Run the Local Bridge Smoke Test

The bridge does not need live XMPP credentials for API smoke testing.

```bash
scripts/lunarwing-xmpp-test-env.sh smoke
```

That command:

1. starts `xmpp-bridge` if it is not already running
2. calls `/v1/status` without a bearer token and expects rejection
3. calls `/v1/status` with the generated token and expects success
4. prints bridge status
5. stops the bridge unless `LUNARWING_TEST_KEEP_BRIDGE=1` is set

To keep the bridge running after the smoke test:

```bash
LUNARWING_TEST_KEEP_BRIDGE=1 scripts/lunarwing-xmpp-test-env.sh smoke
```

Manual bridge commands:

```bash
scripts/lunarwing-xmpp-test-env.sh start-bridge
scripts/lunarwing-xmpp-test-env.sh bridge-auth-check
scripts/lunarwing-xmpp-test-env.sh bridge-status
scripts/lunarwing-xmpp-test-env.sh stop-bridge
```

## 5. Configure Live XMPP

Only do this after the local bridge smoke test passes.

Open the generated bridge env file:

```bash
${EDITOR:-nano} "${LUNARWING_TEST_ROOT:-/tmp/lunarwing-xmpp-test}/env/xmpp-bridge.env"
```

Set:

```bash
XMPP_JID=your-account@example.org
XMPP_PASSWORD=your-xmpp-password
XMPP_ALLOW_ROOMS_JSON=["room@conference.example.org"]
```

Optional but useful:

```bash
XMPP_ALLOW_FROM_JSON=["trusted-user@example.org"]
XMPP_DM_POLICY=allowlist
XMPP_ENCRYPTED_ROOMS_JSON=[]
XMPP_RESOURCE=lunarwing-test
```

Start the bridge and apply the live config:

```bash
scripts/lunarwing-xmpp-test-env.sh start-bridge
scripts/lunarwing-xmpp-test-env.sh configure-bridge --show-status room@conference.example.org
```

If you use `XMPP_ALLOW_ROOMS_JSON` instead of command-line room args:

```bash
scripts/lunarwing-xmpp-test-env.sh configure-bridge --show-status
```

Check status:

```bash
scripts/lunarwing-xmpp-test-env.sh bridge-status
```

## 6. Set a Safe Outbound Rate Limit

Before sending live test traffic, set a conservative outbound cap:

```bash
scripts/lunarwing-xmpp-test-env.sh rate-limit status
scripts/lunarwing-xmpp-test-env.sh rate-limit set 20 --reset
```

To pause outbound sends:

```bash
scripts/lunarwing-xmpp-test-env.sh rate-limit off --reset
```

To clear the rolling counter while keeping the current cap:

```bash
scripts/lunarwing-xmpp-test-env.sh rate-limit reset
```

The live override resets when `xmpp-bridge` restarts.

## 7. Run LunarWing Against the Test State

If you only need bridge testing, skip this section.

The harness starts LunarWing with the isolated `IRONCLAW_BASE_DIR` from
`env/lunarwing.env`:

```bash
scripts/lunarwing-xmpp-test-env.sh start-lunarwing
scripts/lunarwing-xmpp-test-env.sh lunarwing-status
scripts/lunarwing-xmpp-test-env.sh gateway-status
```

If you built and installed the WASM channel artifacts first, `gateway-status`
should report `enabled_channels` containing `gateway` plus installed channels
such as `xmpp` and `weechat`.

Stop it with:

```bash
scripts/lunarwing-xmpp-test-env.sh stop-lunarwing
```

Default command:

```bash
target/debug/lunarwing --no-onboard run
```

If LunarWing needs onboarding or provider credentials, run onboarding against
the isolated env:

```bash
set -a
. "${LUNARWING_TEST_ROOT:-/tmp/lunarwing-xmpp-test}/env/lunarwing.env"
set +a
target/debug/lunarwing onboard
```

Then start LunarWing again through the harness.

To pass a custom command line:

```bash
scripts/lunarwing-xmpp-test-env.sh start-lunarwing -- --no-onboard --no-db run
```

## 8. Generate User-Systemd Units

This is the preferred install-style test path on systemd hosts. It keeps the
Postgres-backed harness alive after the invoking shell exits, which is more
reliable than leaving `up` running from an interactive or agent-managed shell.

Generate test units using the current checkout, test root, and profile:

```bash
scripts/lunarwing-xmpp-test-env.sh render-systemd
```

Install them for your user:

```bash
mkdir -p ~/.config/systemd/user
cp "${LUNARWING_TEST_ROOT:-/tmp/lunarwing-xmpp-test}/systemd/"*.service ~/.config/systemd/user/
systemctl --user daemon-reload
```

Before using the full Postgres-backed path, make sure Docker is running because
the harness starts PostgreSQL in a local container.

The generated units inherit the current harness env file, including
`ALLOW_PRIVATE_IPS=1`, `DATABASE_SSLMODE=disable`, and `PGSSLMODE=disable`.

Starting `lunarwing-test.service` is enough; it already pulls in
`xmpp-bridge-test.service` and `lunarwing-proxy-test.service` through
`Wants=` / `After=`:

```bash
systemctl --user restart lunarwing-test.service
systemctl --user status lunarwing-test.service
systemctl --user status xmpp-bridge-test.service
systemctl --user status lunarwing-proxy-test.service
```

Use read-only diagnostics first:

```bash
systemctl --user show xmpp-bridge-test.service
journalctl --user -u xmpp-bridge-test.service -n 100 --no-pager
scripts/lunarwing-xmpp-test-env.sh bridge-status
```

Stop services:

```bash
systemctl --user stop lunarwing-test.service
systemctl --user stop xmpp-bridge-test.service
```

The bridge unit has `PartOf=lunarwing-test.service`, so LunarWing service stops
can also stop the bridge.

If the test stack is already running from manual `start-*` commands, stop those
first so the service-managed units can bind the same ports cleanly.

The built-in Rust service installer is separate from this test renderer. Running
`lunarwing service install` now detects the host service manager:

- systemd: installs the user unit as `lunarwing.service` and attempts to disable
  the legacy `lunarwing.service` user unit when it exists
- OpenRC: installs `/etc/init.d/lunarwing` and `/etc/init.d/xmpp-bridge`

For production system services, use the committed templates instead of the
generated user-service units:

```bash
sudo install -o root -g root -m 0644 systemd/xmpp-bridge.service /etc/systemd/system/xmpp-bridge.service
sudo install -o root -g root -m 0644 systemd/lunarwing.service /etc/systemd/system/lunarwing.service
sudo systemctl daemon-reload
sudo systemctl enable --now xmpp-bridge.service
sudo systemctl enable --now lunarwing.service
```

Those templates expect `/etc/lunarwing/lunarwing.env` and
`/etc/lunarwing/xmpp-bridge.env` for production config and secrets.

The committed `lunarwing.service` and OpenRC templates already seed
`ALLOW_PRIVATE_IPS=1` and `PGSSLMODE=disable` for private-network Postgres and
OpenAI-compatible lab setups. Override those in `/etc/lunarwing/lunarwing.env`
only when your deployment needs different SSL or network behavior.

Install the production watchdog scheduler with:

```bash
sudo scripts/install-lunarwing-watchdog.sh
```

On systemd hosts, that installs `lunarwing-watchdog.timer` and
`lunarwing-watchdog.service`.

On OpenRC hosts, the same installer now detects OpenRC and installs the
OpenRC wrapper plus either an hourly scheduler hook or a managed root
`fcrontab` entry.

The default `auto` mode is conservative:

- if `cronie`, `crond`, or `dcron` is already present, the installer keeps the
  cron-hourly path and does not switch you over to `fcron`
- if no cron-hourly daemon is present but `fcron` is available, the installer
  uses `fcron` instead

Force one mode explicitly with:

```bash
sudo LUNARWING_WATCHDOG_SCHEDULER=fcron scripts/install-lunarwing-watchdog.sh
sudo LUNARWING_WATCHDOG_SCHEDULER=hourly scripts/install-lunarwing-watchdog.sh
```

`LUNARWING_WATCHDOG_CRON_DIR` still applies when you want the hourly-hook path
in a nonstandard directory layout.

Migration note: the installer disables/removes old `ironclaw-watchdog` units,
wrappers, and hourly hooks before installing the renamed watchdog.

## 9. Future Targeted Checks

Keep these as follow-up harness checks when the current setup work is stable:

- `Live XMPP end-to-end`: use a real test JID/password plus one DM target or
  room to prove `/v1/configure`, polling, and outbound send work against a real
  XMPP service.
- `Secrets-only XMPP password`: remove `XMPP_PASSWORD` from `lunarwing.env`,
  insert it through the secret-management scripts, restart, and confirm the
  channel still loads from the secrets store.
- `Gotify real send`: add a real `gotify_app_token`, set `gotify_url`, and make
  the tool send one notification.
- `Dual-instance socket isolation`: run two harness roots at once and confirm
  each gets its own `run/lunarwing.sock` and `repl` attaches to the correct
  daemon.
- `Init idempotence`: run `init` twice on the same root after customizing env
  values and confirm the harness preserves user-edited tokens, DB mode, agent
  name, and XMPP fields.
- `DB parity`: repeat the same secret insert, restart, and verify flow once on
  `libsql` and once on `postgres` to catch backend-specific regressions.
- `Service restart behavior`: restart only `lunarwing-test.service` and confirm
  the DB, seeded docs, REPL socket, and XMPP migration all recover cleanly.

## 10. Troubleshoot

Run:

```bash
scripts/lunarwing-xmpp-test-env.sh doctor
scripts/lunarwing-xmpp-test-env.sh logs 120
```

Common issues:

- `HTTP 000` from `doctor` means nothing is listening on the bridge port.
- `401` or `403` from `bridge-status` usually means the wrong token or env file.
- `gateway-status` missing `xmpp` or `weechat` usually means WASM channels were
  not installed yet; rerun `build --with-wasm` or `install-wasm`.
- `gateway-status` now reports the requested harness channels as `xmpp`,
  `weechat`, and `darkirc`. The Gotify tool shows up in
  `/api/extensions/tools` as `gotify-tool`.
- A system bridge may already be using `127.0.0.1:8787`; change
  `XMPP_BRIDGE_BIND` in the generated bridge env file.
- `configure-bridge` requires `jq`, `curl`, `XMPP_BRIDGE_TOKEN`, and
  `XMPP_PASSWORD`.
- If the generated systemd unit points at a missing binary, rerun `build` with
  the same `LUNARWING_TEST_PROFILE` used for `render-systemd`.
- `verify` treats the proxy as healthy when `:3002` returns any HTTP response.
  That confirms the local shim is running even if the upstream TensorZero
  service returns `404` or `500` for `GET /openai/v1/models`.

## 11. Clean Up

Stop harness-managed processes:

```bash
scripts/lunarwing-xmpp-test-env.sh stop-lunarwing
scripts/lunarwing-xmpp-test-env.sh stop-bridge
```

Stop user services if you installed them:

```bash
systemctl --user stop lunarwing-test.service
systemctl --user stop xmpp-bridge-test.service
```

Remove generated throwaway state only when you are sure you do not need the
logs, database, or OMEMO store:

```bash
rm -rf "${LUNARWING_TEST_ROOT:-/tmp/lunarwing-xmpp-test}"
```
