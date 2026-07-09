# WeeChat Services for Multi-Tenant Deployments

How WeeChat IRC access is managed as init services in LunarWing multi-tenant deployments. Each tenant runs a WeeChat instance in a tmux session plus a Python WebSocket adapter that bridges WeeChat's relay API to an HTTP endpoint polled by the LunarWing WASM channel.

For general multi-tenant setup, see [`MULTITENANCY-PRODUCTION.md`](MULTITENANCY-PRODUCTION.md).

## Architecture

```
WASM channel (poll) ──GET──► ws_adapter.py (port base+9)
                              │
                              ▼
                          WebSocket
                              │
                              ▼
                         WeeChat relay (port base+5, 127.0.0.1)

WASM channel (send) ──POST──► WeeChat relay (direct)
```

Three components per tenant:

| Component | Process | Description |
|-----------|---------|-------------|
| WeeChat | `weechat` in tmux | IRC client, runs relay API on `127.0.0.1:<base+5>` |
| WS adapter | `ws_adapter.py` | Bridges WeeChat's WebSocket relay to a local HTTP API |
| WASM channel | `weechat_relay_channel` | Polls the adapter every 3s; sends directly to the relay |

The adapter script lives at `lunarwing_weechat_wss/weechat_relay/ws_adapter.py` in the source repo.

## Service Dependency Chain

```
weechat-<name> → lunarwing-weechat-adapter-<name> → lunarwing-<name>
```

WeeChat must be running before the adapter starts. The adapter must be running before the main daemon starts. The MT admin script wires this automatically via `Requires=`/`After=` (systemd) or `need`/`before` (OpenRC).

## Port Allocation

WeeChat uses two ports from each tenant's 10-port block (allocated from `/etc/lunarwing/ports.json`):

| Offset | Port name | Service |
|--------|-----------|---------|
| +5 | `weechat` | WeeChat relay API |
| +9 | `weechat_adapter` | WS adapter HTTP endpoint |

Example: a tenant with base port `10050` gets WeeChat relay on `10055` and adapter on `10059`.

Both ports bind to `127.0.0.1` only.

## Environment Variables

The following are written to `lunarwing.env` by the MT admin script:

| Variable | Value | Consumed by | Description |
|----------|-------|-------------|-------------|
| `RELAY_URL` | `http://127.0.0.1:<base+5>` | adapter **+ WASM channel** | WeeChat relay endpoint |
| `WS_ADAPTER_URL` | `http://127.0.0.1:<base+9>` | WASM channel | Full adapter URL the in-process WASM channel polls |
| `RELAY_PASSWORD` | auto-generated 32-char token | adapter + WeeChat **+ WASM channel** | Shared secret; the WASM authenticates to the adapter with it |
| `ADAPTER_PORT` | `<base+9>` | adapter | Bare HTTP port the standalone adapter listens on |
| `WEECHAT_ADAPTER_PORT` | `<base+9>` | adapter | Alias of `ADAPTER_PORT` |

`RELAY_PASSWORD` is generated per tenant during `add-tenant` and must match the password configured inside WeeChat (see [WeeChat Relay Setup](#weechat-relay-setup)).

> **Per-tenant ports & the in-process WASM channel.** The LunarWing daemon
> (which hosts the WeeChat WASM channel in-process) sources `relay_url`,
> `ws_adapter_url`, and `relay_password` from `RELAY_URL`, `WS_ADAPTER_URL`, and
> `RELAY_PASSWORD` at startup. Without these the channel falls back to the
> hardcoded `:9001`/`:6681` defaults and silently fails for every tenant whose
> ports differ. See the archived `WEECHAT-MULTITENANT-PORT-BUG.md` in `docs/internal/history/archive/ops/`.
> Existing tenants need `WS_ADAPTER_URL` backfilled — run `mt-admin patch-env <name>`.

## Generated Service Units

### Systemd (user-level)

Units are installed to `~/.config/systemd/user/` per tenant.

**`weechat-<name>.service`**

```ini
[Unit]
Description=WeeChat IRC client (<name>)
After=network.target

[Service]
Type=forking
ExecStart=/usr/bin/tmux -L weechat-<name> new-session -d -s weechat '/usr/bin/weechat --dir /home/<name>/.config/weechat'
ExecStop=/usr/bin/tmux -L weechat-<name> kill-session -t weechat
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
```

Uses `Type=forking` because tmux daemonizes after creating the session.

**`lunarwing-weechat-adapter-<name>.service`**

```ini
[Unit]
Description=LunarWing WeeChat WS adapter (<name>)
After=network.target weechat-<name>.service
Requires=weechat-<name>.service
PartOf=lunarwing-<name>.service

[Service]
Type=simple
WorkingDirectory=<repo>/lunarwing_weechat_wss/weechat_relay
EnvironmentFile=<env_dir>/lunarwing.env
ExecStart=/usr/bin/python3 <repo>/lunarwing_weechat_wss/weechat_relay/ws_adapter.py
Restart=on-failure
RestartSec=5
NoNewPrivileges=true

[Install]
WantedBy=default.target
```

The `PartOf=lunarwing-<name>.service` means stopping the main daemon also stops the adapter.

**Main daemon unit** (`lunarwing-<name>.service`) includes WeeChat services in its dependency list:

```ini
After=... weechat-<name>.service lunarwing-weechat-adapter-<name>.service
Wants=... weechat-<name>.service lunarwing-weechat-adapter-<name>.service
```

### OpenRC (system-level)

Init scripts are installed to `/etc/init.d/` with conf.d files in `/etc/conf.d/`.

**`/etc/init.d/weechat-<name>`**

Runs WeeChat in a tmux session via `start-stop-daemon`. The `start()` function creates the tmux session; `stop()` kills it with `tmux kill-session`. Configurable via conf.d variables: `weechat_user`, `weechat_group`, `weechat_home`.

Dependency wiring:

```
depend() {
    need net
    use dns
    after firewall
    before lunarwing-weechat-adapter-<name> lunarwing-<name>
}
```

**`/etc/init.d/lunarwing-weechat-adapter-<name>`**

Uses `supervise-daemon` with automatic respawn (`respawn_delay=5`, `respawn_max=5`, `respawn_period=60`). Reads env from the tenant's `lunarwing.env`. Logs to `<log_dir>/weechat-adapter.log` and `<log_dir>/weechat-adapter.err`.

Dependency wiring:

```
depend() {
    need net weechat-<name>
    use dns
    after firewall weechat-<name>
    before lunarwing-<name>
}
```

**Conf.d for the main daemon** (`/etc/conf.d/lunarwing-<name>`) includes:

```
lunarwing_rc_need="xmpp-bridge-<name> lunarwing-proxy-<name> weechat-<name> lunarwing-weechat-adapter-<name>"
```

## WeeChat Relay Setup

After starting the WeeChat service for the first time, the relay must be configured inside WeeChat. Attach to the tmux session and run these commands in WeeChat:

```
/relay add api <weechat_port>
/set relay.network.password "<RELAY_PASSWORD>"
/set relay.network.bind_address "127.0.0.1"
```

Replace `<weechat_port>` with the tenant's allocated relay port (base+5) and `<RELAY_PASSWORD>` with the value from `lunarwing.env`.

Save the configuration so it persists across restarts:

```
/save
```

## Manual Operations

### Attach to WeeChat

Each tenant's WeeChat runs in a named tmux socket:

```bash
# As the tenant user
tmux -L weechat-<name> attach -t weechat

# As root
sudo -u <name> tmux -L weechat-<name> attach -t weechat
```

Detach with `Ctrl-b d` (standard tmux detach).

### Check service status

Systemd:
```bash
# As root (for any tenant)
sudo -u <name> XDG_RUNTIME_DIR=/run/user/$(id -u <name>) \
  systemctl --user status weechat-<name>.service \
                          lunarwing-weechat-adapter-<name>.service

# As the tenant user
systemctl --user status weechat-<name>.service
systemctl --user status lunarwing-weechat-adapter-<name>.service
```

OpenRC:
```bash
rc-service weechat-<name> status
rc-service lunarwing-weechat-adapter-<name> status
```

### View logs

Systemd:
```bash
sudo -u <name> XDG_RUNTIME_DIR=/run/user/$(id -u <name>) \
  journalctl --user -u weechat-<name>.service -f

sudo -u <name> XDG_RUNTIME_DIR=/run/user/$(id -u <name>) \
  journalctl --user -u lunarwing-weechat-adapter-<name>.service -f
```

OpenRC:
```bash
tail -f /home/<name>/lunarwing/logs/weechat.log
tail -f /home/<name>/lunarwing/logs/weechat-adapter.log
```

### Restart services

Restart WeeChat and the adapter together (the dependency chain handles ordering):

Systemd:
```bash
sudo -u <name> XDG_RUNTIME_DIR=/run/user/$(id -u <name>) \
  systemctl --user restart weechat-<name>.service
```

OpenRC:
```bash
rc-service weechat-<name> restart
rc-service lunarwing-weechat-adapter-<name> restart
```

## Adding WeeChat to an Existing Tenant

If a tenant was created before WeeChat services were added, re-render units and add the environment variables manually.

### 1. Add env vars to `lunarwing.env`

```bash
# Get the tenant's WeeChat ports
sudo ic/scripts/lunarwing-mt-admin.sh status <name>

# Edit the env file (as the tenant user or root)
# Add these lines:
RELAY_URL=http://127.0.0.1:<weechat_port>
RELAY_PASSWORD=<generate-a-token>
ADAPTER_PORT=<weechat_adapter_port>
WEECHAT_ADAPTER_PORT=<weechat_adapter_port>
WS_ADAPTER_URL=http://127.0.0.1:<weechat_adapter_port>
```

> `RELAY_URL`, `WS_ADAPTER_URL`, and `RELAY_PASSWORD` are what the in-process
> WASM channel reads — omitting `WS_ADAPTER_URL` makes the channel poll the
> hardcoded `:6681` default. `mt-admin patch-env <name>` adds `WS_ADAPTER_URL`
> (and `RELAY_URL` if missing) idempotently.

Generate a relay password:

```bash
openssl rand -hex 16
```

### 2. Create WeeChat config directory

```bash
sudo -u <name> mkdir -p /home/<name>/.config/weechat
```

### 3. Re-render service units

```bash
# Stop the tenant first
sudo ic/scripts/lunarwing-mt-admin.sh stop-tenant <name>

# Re-render (regenerates all units including WeeChat)
sudo ic/scripts/lunarwing-mt-admin.sh render-units <name>

# Reload and start
sudo ic/scripts/lunarwing-mt-admin.sh start-tenant <name>
```

### 4. Configure the WeeChat relay

Attach to the tmux session and run the relay setup commands (see [WeeChat Relay Setup](#weechat-relay-setup)).

## Troubleshooting

### Adapter fails to connect to WeeChat relay

**Symptom**: Adapter logs show connection refused or timeout errors.

1. Verify WeeChat is running: `tmux -L weechat-<name> list-sessions`
2. Verify the relay is configured inside WeeChat: attach and run `/relay list`
3. Confirm the relay port matches `RELAY_URL` in `lunarwing.env`
4. Confirm `relay.network.bind_address` is `127.0.0.1` (not `0.0.0.0` or empty)

### WeeChat relay not configured

**Symptom**: WeeChat is running but the adapter cannot authenticate.

The relay must be set up manually inside WeeChat on first start. Attach to the tmux session and run the `/relay add api <port>` commands described in [WeeChat Relay Setup](#weechat-relay-setup).

### tmux session died

**Symptom**: `tmux -L weechat-<name> list-sessions` returns "no server running" or "no sessions".

Restart the WeeChat service:

```bash
# Systemd
sudo -u <name> XDG_RUNTIME_DIR=/run/user/$(id -u <name>) \
  systemctl --user restart weechat-<name>.service

# OpenRC
rc-service weechat-<name> restart
```

If the tmux socket file is stale (exists but no server), remove it first:

```bash
rm -f /tmp/tmux-$(id -u <name>)/weechat-<name>
```

### WASM channel reports no messages

**Symptom**: LunarWing is running but not receiving IRC messages.

1. Check the adapter is running and healthy (see [Check service status](#check-service-status))
2. Verify `WEECHAT_ADAPTER_PORT` is set in `lunarwing.env`
3. Confirm the `weechat_relay_channel` WASM module is installed in the tenant's `state/channels/` directory
4. Check the daemon logs for WASM channel load errors

### Password mismatch

**Symptom**: Adapter connects but authentication fails.

The `RELAY_PASSWORD` in `lunarwing.env` must exactly match the value set inside WeeChat via `/set relay.network.password`. Attach to WeeChat and verify:

```
/set relay.network.password
```

If they differ, update one to match the other and restart the adapter.

### CLI pairing approve fails with "no pairing file"

**Symptom**: `lunarwing pairing approve weechat <CODE>` returns `Invalid channel: no pairing file`, even though the pairing request is visible via IRC and the gateway API works.

The CLI resolves the pairing store from `LUNARWING_BASE_DIR`. In multi-tenant deployments this is set per-tenant in `lunarwing.env` (typically `/home/<name>/lunarwing/state`), but it is not exported into the tenant user's shell environment. Running `sudo -u <name> lunarwing pairing approve ...` without that variable causes the CLI to look in the wrong directory.

Either source the env file first, or pass `LUNARWING_BASE_DIR` explicitly:

```bash
# Option A: pass the variable inline
sudo -u <name> LUNARWING_BASE_DIR=/home/<name>/lunarwing/state \
  lunarwing pairing approve weechat <CODE>

# Option B: source the env file
sudo -u <name> bash -c '
  set -a
  source /home/<name>/lunarwing/env/lunarwing.env
  set +a
  lunarwing pairing approve weechat <CODE>
'
```

Alternatively, use the gateway API (no env vars needed):

```bash
curl -sf -X POST http://127.0.0.1:<gateway_port>/api/pairing/weechat/approve \
  -H "Authorization: Bearer <GATEWAY_AUTH_TOKEN>" \
  -H "Content-Type: application/json" \
  -d '{"code":"<CODE>"}'
```

