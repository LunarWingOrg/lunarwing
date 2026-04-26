# LunarWing and XMPP Bridge Testing

This guide sets up an isolated local environment for the project currently
branded as LunarWing. Some binaries, environment variables, and service names
still use `ironclaw`; keep those names until the codebase is renamed.

The goal is to test in layers:

1. Build the LunarWing and bridge binaries.
2. Smoke-test the local bridge HTTP API and bearer-token enforcement.
3. Configure the bridge against a live XMPP account when needed.
4. Run LunarWing and the bridge under either the script harness or user systemd.

The `customic/` tree is intentionally not part of this workflow.

## Quick Start

From the repo's `ic/` directory:

```bash
scripts/lunarwing-xmpp-test-env.sh init
scripts/lunarwing-xmpp-test-env.sh build
scripts/lunarwing-xmpp-test-env.sh smoke
```

For a command-by-command setup walkthrough, see
[`testing/lunarwing-xmpp/README.md`](../testing/lunarwing-xmpp/README.md).
That guide now also includes copy-paste "Fresh Recreate Recipes" for both the
Postgres-backed user-systemd harness and the separate libSQL bootstrap path.

The default test root is `/tmp/lunarwing-xmpp-test`. Export an override when
you want the state to survive reboots:

```bash
export LUNARWING_TEST_ROOT="$HOME/.local/state/lunarwing-xmpp-test"
scripts/lunarwing-xmpp-test-env.sh init
```

Generated files:

- `env/lunarwing.env` for the LunarWing daemon.
- `env/xmpp-bridge.env` for the XMPP bridge.
- `state/` for the isolated `IRONCLAW_BASE_DIR`, libSQL database, and OMEMO
  store.
- `logs/` and `run/` for harness-managed processes.
- `systemd/` for generated user-service unit files.

The env files are created with mode `0600`. They may contain live XMPP passwords
and bridge tokens, so do not paste their contents into chat, issues, or logs.

The generated `env/lunarwing.env` is already seeded for the common private-lab
stack used by this harness:

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

## Bridge API Smoke Tests

The bridge can start without live XMPP credentials. This is useful for testing
the local HTTP sidecar boundary before touching an external XMPP account:

```bash
scripts/lunarwing-xmpp-test-env.sh start-bridge
scripts/lunarwing-xmpp-test-env.sh bridge-auth-check
scripts/lunarwing-xmpp-test-env.sh bridge-status
scripts/lunarwing-xmpp-test-env.sh stop-bridge
```

`bridge-auth-check` verifies two things:

- `GET /v1/status` without the bearer token is rejected.
- `GET /v1/status` with the generated bearer token succeeds.

The smoke test does the same sequence and stops the bridge unless
`LUNARWING_TEST_KEEP_BRIDGE=1` is set.

## Live XMPP Configuration

Edit the generated bridge env file:

```bash
${LUNARWING_TEST_ROOT:-/tmp/lunarwing-xmpp-test}/env/xmpp-bridge.env
```

Set at least:

- `XMPP_JID`
- `XMPP_PASSWORD`
- `XMPP_ALLOW_ROOMS_JSON`, or pass room JIDs as command arguments

Then configure the running bridge through the existing wrapper:

```bash
scripts/lunarwing-xmpp-test-env.sh start-bridge
scripts/lunarwing-xmpp-test-env.sh configure-bridge --show-status room@conference.example.org
```

For live outbound safety, use the rate-limit wrapper:

```bash
scripts/lunarwing-xmpp-test-env.sh rate-limit status
scripts/lunarwing-xmpp-test-env.sh rate-limit set 20 --reset
scripts/lunarwing-xmpp-test-env.sh rate-limit off
```

The rate-limit command changes the live bridge override only. Restarting the
bridge resets the override back to bridge configuration defaults.

## Running LunarWing Locally

The harness can start the current `ironclaw` binary with isolated state:

```bash
scripts/lunarwing-xmpp-test-env.sh start-lunarwing
scripts/lunarwing-xmpp-test-env.sh lunarwing-status
scripts/lunarwing-xmpp-test-env.sh stop-lunarwing
```

By default this runs:

```bash
target/debug/ironclaw --no-onboard run
```

Use your isolated `IRONCLAW_BASE_DIR` for onboarding or live credentials instead
of sharing `~/.ironclaw`:

```bash
set -a
. /tmp/lunarwing-xmpp-test/env/lunarwing.env
set +a
target/debug/ironclaw onboard
```

For alternate runtime flags, pass the full argument list after `--`:

```bash
scripts/lunarwing-xmpp-test-env.sh start-lunarwing -- --no-onboard --no-db run
```

## User Systemd Method

This is the preferred install-style test path on systemd hosts. It keeps the
Postgres-backed harness alive after the invoking shell exits, which is more
reliable than leaving `up` running from an interactive or agent-managed shell.

Generate user-service units from your current checkout and test root:

```bash
scripts/lunarwing-xmpp-test-env.sh render-systemd
mkdir -p ~/.config/systemd/user
cp /tmp/lunarwing-xmpp-test/systemd/*.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user restart lunarwing-test.service
```

The default generated service names are deliberately test-scoped:

- `lunarwing-test.service`
- `xmpp-bridge-test.service`

To render actual service names, set both names before `render-systemd`:

```bash
export LUNARWING_TEST_SERVICE_NAME=lunarwing.service
export LUNARWING_TEST_BRIDGE_SERVICE_NAME=xmpp-bridge.service
scripts/lunarwing-xmpp-test-env.sh render-systemd
```

The bridge `PartOf=`, LunarWing `Wants=` / `After=`, and
`configure-bridge --restart` path all use the same configured bridge/main
service names, so renaming the main unit does not leave stale
`ironclaw.service` links in the generated test units.

For generated user services, `configure-bridge --restart` uses `systemctl --user`
by default. For machine-level services, set
`LUNARWING_TEST_SYSTEMCTL_SCOPE=system`.

Before using the full Postgres-backed path, make sure Docker is running because
the harness starts PostgreSQL in a local container.

The generated units inherit the current harness env file, including
`ALLOW_PRIVATE_IPS=1`, `DATABASE_SSLMODE=disable`, and `PGSSLMODE=disable`.

Starting `lunarwing-test.service` is enough; it already pulls in
`xmpp-bridge-test.service` and `ironclaw-proxy-test.service` through
`Wants=` / `After=`.

Use read-only diagnostics before restarting anything:

```bash
systemctl --user status xmpp-bridge-test.service
systemctl --user show xmpp-bridge-test.service
journalctl --user -u xmpp-bridge-test.service -n 100 --no-pager
scripts/lunarwing-xmpp-test-env.sh bridge-status
```

If the test stack is already running from manual `start-*` commands, stop those
first so the service-managed units can bind the same ports cleanly.

The generated bridge unit has `PartOf=` pointing at the configured LunarWing
service name, so LunarWing service stops can also stop the bridge. Do not
assume the bridge caused a LunarWing stop just because both units changed state
together.

The built-in Rust service manager also uses the LunarWing name now.
`ironclaw service install` detects the host service manager:

- systemd: installs `~/.config/systemd/user/lunarwing.service` and, when the
  bridge binary is available, `xmpp-bridge.service`
- OpenRC: installs `/etc/init.d/lunarwing` and `/etc/init.d/xmpp-bridge`

During systemd installs it attempts to disable the legacy user unit
`ironclaw.service` if that old unit file exists, preventing both daemon names
from being enabled together.

## System Service Method

Production-ready system service templates live in:

- `systemd/lunarwing.service`
- `systemd/xmpp-bridge.service`

They assume:

- a dedicated `lunarwing` system user and group
- binaries at `/usr/local/bin/ironclaw` and `/usr/local/bin/xmpp-bridge`
- state under `/var/lib/lunarwing`
- logs under `/var/log/lunarwing`
- root-readable env files under `/etc/lunarwing`

Create the service account and config directory:

```bash
sudo useradd --system --home-dir /var/lib/lunarwing --shell /usr/sbin/nologin lunarwing
sudo install -d -o root -g root -m 0750 /etc/lunarwing
sudo install -d -o lunarwing -g lunarwing -m 0750 /var/lib/lunarwing /var/log/lunarwing
```

Keep secrets in root-readable env files:

- `/etc/lunarwing/lunarwing.env`
- `/etc/lunarwing/xmpp-bridge.env`

The committed `lunarwing.service` and OpenRC templates already seed
`ALLOW_PRIVATE_IPS=1` and `PGSSLMODE=disable` for private-network Postgres and
OpenAI-compatible lab setups. Override those in `/etc/lunarwing/lunarwing.env`
only when your deployment needs different SSL or network behavior.

Use `EnvironmentFile=` instead of inline `Environment=` entries for tokens,
database URLs, provider keys, webhook secrets, or XMPP passwords. The bridge
should remain loopback-bound:

```ini
XMPP_BRIDGE_BIND=127.0.0.1:8787
```

Install and start the services:

```bash
sudo install -o root -g root -m 0644 systemd/xmpp-bridge.service /etc/systemd/system/xmpp-bridge.service
sudo install -o root -g root -m 0644 systemd/lunarwing.service /etc/systemd/system/lunarwing.service
sudo systemctl daemon-reload
sudo systemctl enable --now xmpp-bridge.service
sudo systemctl enable --now lunarwing.service
```

Install the production watchdog timer when you want systemd to check and restart
`lunarwing.service` hourly:

```bash
sudo scripts/install-lunarwing-watchdog.sh
sudo systemctl status lunarwing-watchdog.timer --no-pager
sudo journalctl -u lunarwing-watchdog.service -n 100 --no-pager
```

Migration note: `install-lunarwing-watchdog.sh` disables and removes old
`ironclaw-watchdog` units and the old `/usr/local/sbin/ironclaw-watchdog`
binary before installing the renamed watchdog, so two watchdog timers do not
run side by side.

The current app binary is still named `ironclaw`. If you install a renamed
`lunarwing` binary, change `ExecStart=` in `systemd/lunarwing.service`.

Inspect `systemctl status`, `systemctl show`, `journalctl`, and `/v1/status`
before restarting services.

## Troubleshooting

Run:

```bash
scripts/lunarwing-xmpp-test-env.sh doctor
scripts/lunarwing-xmpp-test-env.sh logs 120
```

Common checks:

- `curl` is required for bridge API calls.
- `jq` is required by the existing configure and rate-limit wrappers.
- `cargo` is required for `build`.
- `bridge-status` returning `401` or `403` usually means the wrong token or env
  file is being used.
- `gateway-status` now reports the requested harness channels as `xmpp`,
  `weechat`, and `darkirc`. The Gotify tool shows up in
  `/api/extensions/tools` as `gotify-tool`.
- A running system bridge on port `8787` can conflict with the harness bridge.
  Change `XMPP_BRIDGE_BIND` in the test env file when needed.
- If `verify` only fails `TensorZero proxy responds at :3002`, the local proxy
  may still be bound correctly. That check depends on the upstream
  `TENSORZERO_URL` answering the proxy's `/openai/v1/models` readiness probe.
