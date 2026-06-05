# Multi-Tenant Quickstart with WeeChat Channel

A linear walkthrough: from zero to a running multi-tenant LunarWing
deployment with the WeeChat IRC channel configured and receiving messages.

---

## Part 1: Multi-Tenant Setup

### 1. Prerequisites

Before you begin, confirm the following are installed:

- **Root or sudo access** on the target machine
- **Docker or Podman** (running and accessible)
- **Rust toolchain** via rustup (`rustup`, `cargo`, targets `wasm32-wasip1`
  and `wasm32-wasip2`)
- **jq** for JSON port registry operations
- **Python 3** with `aiohttp` (`pip install aiohttp`)
- **git** for repo cloning
- **weechat** if you actually want your agent to use weechat as a communication channel

All commands below run from the repository root (e.g., `/home/you/lunarwing`).

---

### 2. Check Dependencies

```bash
sudo ic/scripts/lunarwing-mt-admin.sh doctor
```

Fix any `[FAIL]` items before continuing. Common fixes:

- Missing WASM targets: `rustup target add wasm32-wasip1 wasm32-wasip2`
- Missing aiohttp: `pip install aiohttp`
- Docker not running: `sudo systemctl start docker`

---

### 3. Add Your First Tenant

```bash
sudo ic/scripts/lunarwing-mt-admin.sh add-tenant ruffles --docker-group
```

This single command does all of the following:

1. Creates an OS user `ruffles` and adds it to the docker/podman group.
2. Enables systemd linger (`loginctl enable-linger ruffles`) so services
   survive logout, or renders OpenRC init scripts on non-systemd hosts.
3. Allocates a contiguous block of 10 ports from `/etc/lunarwing/ports.json`
   (e.g., `10000`-`10009`).
4. Clones the source repo into `/home/ruffles/lunarwing/`.
5. Generates environment files (`lunarwing.env`, `xmpp-bridge.env`,
   `proxy.env`) in `/home/ruffles/lunarwing/env/`, all mode `0600`.
6. Starts a per-tenant PostgreSQL container (`lunarwing-pg-ruffles`) bound to
   `127.0.0.1:<postgres-port>`.
7. Renders systemd user units (or OpenRC init scripts) for all four services.

---

### 4. Build Binaries

```bash
sudo ic/scripts/lunarwing-mt-admin.sh build-tenant ruffles --with-wasm
```

The `--with-wasm` flag builds WASM channels (including the weechat channel)
and WASM tools alongside the main binary and XMPP bridge.

Builds are flock-serialized (`/var/lock/lunarwing-build.lock`) so only one
tenant compiles at a time. This prevents OOM on memory-constrained hosts.

---

### 5. Install WASM Extensions

```bash
sudo ic/scripts/lunarwing-mt-admin.sh install-wasm ruffles
```

This copies built WASM binaries and their capabilities JSON into the tenant's
state directories:

- Channels go to `/home/ruffles/lunarwing/state/channels/`
  (e.g., `weechat.wasm`, `weechat.capabilities.json`)
- Tools go to `/home/ruffles/lunarwing/state/tools/`
  (e.g., `gotify-tool.wasm`, `gotify-tool.capabilities.json`)

---

### 6. Start the Tenant

```bash
sudo ic/scripts/lunarwing-mt-admin.sh start-tenant ruffles
```

This starts four services:

| Service | Description |
|---------|-------------|
| `lunarwing-ruffles.service` | Main AI agent daemon |
| `xmpp-bridge-ruffles.service` | XMPP/OMEMO bridge |
| `lunarwing-proxy-ruffles.service` | TensorZero LLM proxy |
| `lunarwing-weechat-adapter-ruffles.service` | WeeChat WebSocket adapter |

The main service has `Wants=` on the other three, so they all come up
together when you start it.

---

### 7. Verify and Log In

```bash
# Check everything is running
sudo ic/scripts/lunarwing-mt-admin.sh status ruffles

# Get the gateway auth token
sudo ic/scripts/lunarwing-mt-admin.sh tokens ruffles
```

The web gateway binds to `127.0.0.1` by default. Access from the same
machine at `http://127.0.0.1:10000` (where `10000` is the tenant's gateway
port).

From a remote machine, use SSH port forwarding:

```bash
ssh -L 10000:127.0.0.1:10000 user@host
```

Then open `http://localhost:10000` in your browser and paste the token.

---

### 8. Day-to-Day Management

| Task | Command |
|------|---------|
| Stop | `sudo ic/scripts/lunarwing-mt-admin.sh stop-tenant ruffles` |
| Restart | `sudo ic/scripts/lunarwing-mt-admin.sh restart-tenant ruffles` |
| Logs (systemd) | `sudo -u ruffles XDG_RUNTIME_DIR=/run/user/$(id -u ruffles) journalctl --user -u lunarwing-ruffles.service -f` |
| Logs (OpenRC) | `tail -f /home/ruffles/lunarwing/logs/lunarwing.log` |
| All tenants | `sudo ic/scripts/lunarwing-mt-admin.sh list-tenants` |
| Remove (keep data) | `sudo ic/scripts/lunarwing-mt-admin.sh remove-tenant ruffles` |
| Remove (purge) | `sudo ic/scripts/lunarwing-mt-admin.sh remove-tenant ruffles --purge` |

---

## Part 2: Configuring the WeeChat Channel

### 9. How It Works

```
LunarWing         WS Adapter              WeeChat            IRC Networks
(WASM poll) ----> (HTTP API) <--WS--> (relay API v2) <---> libera, darkirc, ...
            <---- (buffered lines)
```

The WASM channel cannot hold a persistent WebSocket connection (sandbox
limitation). Instead, the WS adapter maintains a WebSocket to WeeChat's relay
and buffers recent messages. The WASM channel polls the adapter's HTTP API
every 3 seconds for new lines. Outbound messages (agent responses) go
directly to WeeChat's REST API.

---

### 10. Set Up WeeChat Relay

In WeeChat, run these commands to enable the API relay:

```
/relay add api 10005
/set relay.network.password "your-relay-password"
/set relay.network.bind_address "127.0.0.1"
```

The port (`10005` in this example) is the tenant's `weechat` port -- offset
`+5` from the base port. Find it with:

```bash
sudo ic/scripts/lunarwing-mt-admin.sh status ruffles
```

Look for the `weechat` column in the output (e.g., `10005` if the base port
is `10000`).

Verify the relay is running inside WeeChat:

```
/relay list
```

---

### 11. Test the Relay

From the host machine, confirm WeeChat's relay is reachable:

```bash
curl -u "plain:your-relay-password" http://127.0.0.1:10005/api/version
```

You should see WeeChat version info in JSON. If you get a connection refused
error, check that WeeChat is running, the port matches, and the bind address
is `127.0.0.1`.

---

### 12. Configure the WASM Channel

Edit the tenant's capabilities config:

```bash
sudo -u ruffles nano /home/ruffles/lunarwing/state/channels/weechat.capabilities.json
```

Find the `"config"` section at the bottom of the file and update it:

```json
{
  "config": {
    "display_name": "WeeChat",
    "relay_url": "http://127.0.0.1:10005",
    "connection_mode": "auto",
    "ws_adapter_url": "http://127.0.0.1:10009",
    "dm_policy": "allowlist",
    "group_policy": "allowlist",
    "allow_from": "yournick",
    "networks": "",
    "verbose_drops": false
  }
}
```

Field reference:

| Field | Description |
|-------|-------------|
| `relay_url` | WeeChat's relay API endpoint. Use the tenant's `weechat` port (offset +5). |
| `connection_mode` | `auto` (prefers adapter, falls back to direct HTTP), `websocket` (adapter only), or `http` (direct polling only). Use `auto`. |
| `ws_adapter_url` | The adapter's local HTTP API. Use the tenant's `weechat_adapter` port (offset +9). |
| `dm_policy` | Who can DM the agent: `open`, `allowlist`, or `pairing`. |
| `group_policy` | How group/channel messages are handled: `open`, `allowlist`, or `deny`. |
| `allow_from` | Comma-separated list of allowed IRC nicks or `nick!user@host` hostmasks. Use `*` for everyone. |
| `networks` | Comma-separated allowlist of IRC networks (empty = all networks allowed). |
| `verbose_drops` | Set `true` to log filtered-out messages for debugging. |

---

### 13. Set the Relay Password

The adapter needs the relay password to authenticate with WeeChat. Set it in
the tenant's environment file:

```bash
sudo -u ruffles nano /home/ruffles/lunarwing/env/lunarwing.env
```

Add or update these lines:

```
RELAY_URL=http://127.0.0.1:10005
RELAY_PASSWORD=your-relay-password
```

The WeeChat adapter service reads this env file via its `EnvironmentFile=`
directive and passes the values to `ws_adapter.py`.

---

### 14. Verify the Adapter Is Running

```bash
# Check adapter service status (systemd)
sudo -u ruffles XDG_RUNTIME_DIR=/run/user/$(id -u ruffles) \
  systemctl --user status lunarwing-weechat-adapter-ruffles.service

# Test the adapter's health endpoint
curl http://127.0.0.1:10009/api/health
```

A healthy response looks like:

```json
{
  "status": "ok",
  "ws_connected": true,
  "ws_error": null,
  "buffered_buffers": 5,
  "buffer_list_count": 12
}
```

If `ws_connected` is `false`, check that `RELAY_URL` and `RELAY_PASSWORD` are
correct in `lunarwing.env` and that WeeChat's relay is running.

---

### 15. Restart and Test

```bash
sudo ic/scripts/lunarwing-mt-admin.sh restart-tenant ruffles
```

Check the adapter logs for a successful connection:

```bash
sudo -u ruffles XDG_RUNTIME_DIR=/run/user/$(id -u ruffles) \
  journalctl --user -u lunarwing-weechat-adapter-ruffles.service --no-pager -n 20
```

Look for lines like:

```
WeeChat WS adapter listening on http://127.0.0.1:10009
Connected to WeeChat WebSocket
```

Then check the main daemon logs for channel activity:

```bash
sudo -u ruffles XDG_RUNTIME_DIR=/run/user/$(id -u ruffles) \
  journalctl --user -u lunarwing-ruffles.service --no-pager -n 20
```

Look for:

```
Loaded WASM channel: weechat
Polling tick - calling on_poll channel=weechat
```

Send a test message from IRC to the bot's nick. If `dm_policy` is `pairing`,
you will get a pairing code back. If `dm_policy` is `allowlist`, make sure
your nick is in `allow_from`.

---

### 16. Policies and Filtering

#### DM Policy

| Value | Behavior |
|-------|----------|
| `open` | Any IRC user can DM the agent. |
| `allowlist` | Only nicks/hostmasks in `allow_from` can DM. |
| `pairing` | Unknown users receive a pairing code. Approve on the host: |

```bash
sudo -u ruffles lunarwing pairing approve weechat CODE123
sudo -u ruffles lunarwing pairing list weechat
```

#### Group Policy

| Value | Behavior |
|-------|----------|
| `open` | Agent responds to all channel messages. |
| `allowlist` | Only messages from `allow_from` nicks trigger the agent. |
| `deny` | Agent ignores all group/channel messages. |

#### Network Filtering

Restrict which IRC networks the agent monitors:

```json
"networks": "libera,darkirc"
"exclude_networks": "testnet"
```

Empty `networks` means all networks are allowed. `exclude_networks` takes
priority over `networks`.

#### Sender Allowlist

```json
"allow_from": "sun,alice!~user@example.com"
```

Supported formats:

- Bare nick: `sun`
- Full hostmask: `alice!~user@example.com`
- Wildcard (everyone): `*`

---

## Part 3: Reference

### 17. Port Map

Each tenant gets a contiguous block of 10 ports. The base port is allocated
from the range `10000`-`19999`.

| Offset | Name | Service |
|--------|------|---------|
| +0 | gateway | Web UI, REST API, WebSocket |
| +1 | http | HTTP webhook endpoint |
| +2 | bridge | XMPP bridge HTTP API |
| +3 | postgres | PostgreSQL container |
| +4 | proxy | TensorZero LLM proxy |
| +5 | weechat | WeeChat relay (configure WeeChat to bind here) |
| +6 | orchestrator | Job orchestrator API |
| +7 | nanocode_wss | Nanocode worker WebSocket |
| +8 | pebble_wss | Pebble worker WebSocket |
| +9 | weechat_adapter | WeeChat WS adapter HTTP API |

Example: tenant `ruffles` with base port `10000` gets gateway on `10000`,
WeeChat relay on `10005`, adapter on `10009`.

---

### 18. Multiple Tenants

```bash
# Add four tenants at once
sudo ic/scripts/lunarwing-mt-admin.sh add-tenants "Ruffles,Miyuki,Sparkie,Starforce" --docker-group

# Build all sequentially
sudo ic/scripts/lunarwing-mt-admin.sh build-all --with-wasm

# Install WASM for all
sudo ic/scripts/lunarwing-mt-admin.sh install-wasm-all

# Start each
for t in ruffles miyuki sparkie starforce; do
  sudo ic/scripts/lunarwing-mt-admin.sh start-tenant "$t"
done

# View all tenants and ports
sudo ic/scripts/lunarwing-mt-admin.sh list-tenants
```

---

### 19. Troubleshooting

#### Relay not reachable

- Check WeeChat's relay is active: run `/relay list` inside WeeChat.
- Verify the bind address is `127.0.0.1` (not `""` which means disabled).
- Verify the port matches the tenant's `weechat` port.
- Test with curl: `curl -u "plain:password" http://127.0.0.1:10005/api/version`

#### Adapter not starting

- Check `RELAY_URL` and `RELAY_PASSWORD` are set in
  `/home/ruffles/lunarwing/env/lunarwing.env`.
- Verify Python 3 and `aiohttp` are installed: `python3 -c "import aiohttp"`.
- Check adapter logs:
  ```bash
  sudo -u ruffles XDG_RUNTIME_DIR=/run/user/$(id -u ruffles) \
    journalctl --user -u lunarwing-weechat-adapter-ruffles.service --no-pager -n 40
  ```

#### No messages received

- Verify `allow_from` includes the sender's IRC nick.
- Check network filtering (is the IRC network in `networks`?).
- Confirm polling is happening in the daemon logs:
  ```
  Polling tick - calling on_poll channel=weechat
  ```
- Test the adapter directly:
  `curl http://127.0.0.1:10009/api/health`

#### "HTTP not allowed" error

The WASM sandbox restricts outbound HTTP. The `weechat.capabilities.json`
file includes an allowlist for `127.0.0.1` and `localhost` by default. If you
changed the relay or adapter to a different address, add it to
`capabilities.http.allowlist`.

#### Services don't survive reboot

- **systemd**: Check linger is enabled:
  ```bash
  loginctl show-user ruffles | grep Linger
  ```
  If `Linger=no`, enable it: `sudo loginctl enable-linger ruffles`

- **OpenRC**: Add services to the default runlevel:
  ```bash
  rc-update add lunarwing-ruffles default
  ```

#### Build fails with OOM

The flock prevents concurrent builds, but a single build can still OOM on
low-RAM hosts (Rust compilation is memory-intensive). Options:

- Limit parallelism: `export CARGO_BUILD_JOBS=1`
- Use debug profile (faster, less memory): `export LUNARWING_MT_PROFILE=debug`
- Add swap space

---

### 20. Further Reading

- [Production Multi-Tenant Reference](../ops/MULTITENANCY-PRODUCTION.md) --
  full configuration reference, port registry schema, security model
- [WeeChat Relay Channel](ironclaw_weechat_wss/README.md) -- channel
  protocol details, architecture, and development
- [WeeChat Relay Installation](ironclaw_weechat_wss/weechat_relay/INSTALL.md)
  -- standalone installation guide
- [Single-Tenant Test Harness](../ops/HARNESS-SINGLE-TENANT.md) -- for
  development/testing without production isolation
- [Multi-Tenant Test Harness](../ops/MULTITENANCY-HARNESS.md) -- ephemeral
  multi-tenant testing environment
