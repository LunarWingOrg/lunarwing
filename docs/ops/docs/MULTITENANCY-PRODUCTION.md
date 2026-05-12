# Production Multi-Tenant Deployment

This document describes the production multi-tenant system managed by `ic/scripts/lunarwing-mt-admin.sh`. Each tenant is a real OS user with its own repo clone, build artifacts, services, PostgreSQL container, TensorZero proxy, and XMPP bridge.

## Overview

The admin script runs as root and handles:

1. **OS user creation** with `loginctl enable-linger` (systemd) or system-level services with `User=` directives (OpenRC/Gentoo)
2. **Port allocation** from a centralized registry at `/etc/lunarwing/ports.json`
3. **Per-user repo clone** and sequential builds (flock-serialized to avoid OOM)
4. **Per-user PostgreSQL container** (Docker or Podman)
5. **Per-user TensorZero proxy** on its own port
6. **Per-user XMPP bridge** with its own JID
7. **Service unit generation** for systemd (user-level) or OpenRC (system-level)

## Full Run Walkthrough

Step-by-step commands to set up a fresh multi-tenant deployment from scratch. Run all commands from the repo root (`/home/sun/lunarwing`).

### Step 1: Verify dependencies

```bash
sudo ic/scripts/lunarwing-mt-admin.sh doctor
```

Fix any `[FAIL]` items before proceeding.

### Step 2: Add tenants

Add all tenants at once. Names are comma-separated and will be lowercased automatically.

```bash
sudo ic/scripts/lunarwing-mt-admin.sh add-tenants "Ruffles,Miyuki,Sparkie,Starforce" --docker-group
```

This creates OS users, allocates port blocks, clones the repo, generates env files, starts PostgreSQL containers, and renders service units for each tenant.

### Step 3: Build binaries

Build all tenants sequentially (flock prevents concurrent builds to avoid OOM):

```bash
sudo ic/scripts/lunarwing-mt-admin.sh build-all
```

Or build one at a time:

```bash
sudo ic/scripts/lunarwing-mt-admin.sh build-tenant ruffles
```

Include WASM extensions:

```bash
sudo ic/scripts/lunarwing-mt-admin.sh build-all --with-wasm
```

### Step 4: Start services

```bash
sudo ic/scripts/lunarwing-mt-admin.sh start-tenant ruffles
sudo ic/scripts/lunarwing-mt-admin.sh start-tenant miyuki
sudo ic/scripts/lunarwing-mt-admin.sh start-tenant sparkie
sudo ic/scripts/lunarwing-mt-admin.sh start-tenant starforce
```

### Step 5: Verify

```bash
# List all tenants and their ports
sudo ic/scripts/lunarwing-mt-admin.sh list-tenants

# Check a specific tenant
sudo ic/scripts/lunarwing-mt-admin.sh status ruffles

# Get gateway auth tokens to log into the web UI
sudo ic/scripts/lunarwing-mt-admin.sh tokens
```

### Step 6: Access gateways

Gateways bind to `127.0.0.1` by default. From the same machine, open a browser to `http://127.0.0.1:<gateway-port>` and paste the token from step 5.

From a remote machine, use SSH port forwarding:

```bash
ssh -L 10000:127.0.0.1:10000 -L 10010:127.0.0.1:10010 \
    -L 10020:127.0.0.1:10020 -L 10030:127.0.0.1:10030 user@host
```

Then access `http://localhost:10000`, `http://localhost:10010`, etc.

### Step 7: Manage

```bash
# Stop a tenant
sudo ic/scripts/lunarwing-mt-admin.sh stop-tenant sparkie

# Restart a tenant
sudo ic/scripts/lunarwing-mt-admin.sh restart-tenant sparkie

# Remove a tenant (stop services, deallocate ports, preserve user home)
sudo ic/scripts/lunarwing-mt-admin.sh remove-tenant sparkie

# Remove a tenant completely (delete user and home directory)
sudo ic/scripts/lunarwing-mt-admin.sh remove-tenant sparkie --purge
```

### Viewing logs

Systemd:
```bash
# As the tenant user
journalctl --user -u lunarwing-ruffles.service -f

# As root
sudo -u ruffles XDG_RUNTIME_DIR=/run/user/$(id -u ruffles) journalctl --user -u lunarwing-ruffles.service -f
```

OpenRC:
```bash
tail -f /home/ruffles/lunarwing/logs/lunarwing.log
```

## Prerequisites

- Root or sudo access for the admin script
- Docker or Podman installed and running
- Rust toolchain (rustup, cargo) accessible to tenant users
- `jq` for port registry JSON operations
- Python 3 for the TensorZero proxy
- Git for repo cloning

Run `sudo scripts/lunarwing-mt-admin.sh doctor` to verify all dependencies.

## Quick Start

### Single tenant

```bash
cd /path/to/lunarwing/ic

# Add a tenant (creates user, allocates ports, clones repo, generates env, starts PG)
sudo scripts/lunarwing-mt-admin.sh add-tenant ruffles --docker-group

# Build binaries for the tenant (flock-serialized, OOM-safe)
sudo scripts/lunarwing-mt-admin.sh build-tenant ruffles

# Start all services
sudo scripts/lunarwing-mt-admin.sh start-tenant ruffles

# Check status
sudo scripts/lunarwing-mt-admin.sh status ruffles

# View gateway auth token
sudo scripts/lunarwing-mt-admin.sh tokens ruffles
```

### Multiple tenants at once

```bash
# Add four tenants in one command
sudo scripts/lunarwing-mt-admin.sh add-tenants "Ruffles,Miyuki,Sparkie,Starforce" --docker-group

# Build all tenants sequentially
sudo scripts/lunarwing-mt-admin.sh build-all

# Start each tenant
sudo scripts/lunarwing-mt-admin.sh start-tenant ruffles
sudo scripts/lunarwing-mt-admin.sh start-tenant miyuki
sudo scripts/lunarwing-mt-admin.sh start-tenant sparkie
sudo scripts/lunarwing-mt-admin.sh start-tenant starforce

# List all tenants with their port allocations
sudo scripts/lunarwing-mt-admin.sh list-tenants
```

### Teardown

```bash
# Stop services (preserves data)
sudo scripts/lunarwing-mt-admin.sh stop-tenant ruffles

# Remove tenant entirely (stop services, deallocate ports, remove user + home dir)
sudo scripts/lunarwing-mt-admin.sh remove-tenant ruffles --purge
```

## Port Allocation

### Registry

The port registry lives at `/etc/lunarwing/ports.json` (root-owned, world-readable). It is written atomically (write to temp file, `mv` into place) to prevent corruption.

### Port blocks

Each tenant gets a contiguous block of 10 ports from the range `10000-19999`, supporting up to 1000 tenants.

| Offset | Service | Description |
|--------|---------|-------------|
| +0 | gateway | Web gateway (browser UI, WebSocket, REST API) |
| +1 | http | HTTP webhook endpoint |
| +2 | bridge | XMPP bridge HTTP API |
| +3 | postgres | PostgreSQL container port |
| +4 | proxy | TensorZero LLM proxy |
| +5 | weechat | WeeChat relay (reserved) |
| +6-9 | reserved | Future expansion |

### Example allocation

| Tenant | Base | Gateway | HTTP | Bridge | PG | Proxy | WeeChat |
|--------|------|---------|------|--------|----|-------|---------|
| ruffles | 10000 | 10000 | 10001 | 10002 | 10003 | 10004 | 10005 |
| miyuki | 10010 | 10010 | 10011 | 10012 | 10013 | 10014 | 10015 |
| sparkie | 10020 | 10020 | 10021 | 10022 | 10023 | 10024 | 10025 |
| starforce | 10030 | 10030 | 10031 | 10032 | 10033 | 10034 | 10035 |

### Registry schema

```json
{
  "version": 1,
  "range": { "start": 10000, "end": 19999 },
  "block_size": 10,
  "tenants": {
    "ruffles": {
      "base_port": 10000,
      "user": "ruffles",
      "created_at": "2026-05-04T12:00:00Z",
      "ports": {
        "gateway": 10000,
        "http": 10001,
        "bridge": 10002,
        "postgres": 10003,
        "proxy": 10004,
        "weechat": 10005,
        "reserved_0": 10006,
        "reserved_1": 10007,
        "reserved_2": 10008,
        "reserved_3": 10009
      }
    }
  }
}
```

## Per-Tenant Directory Layout

```
/home/<tenant>/lunarwing/
  ic/                          # Git clone of the LunarWing repo
    target/<profile>/lunarwing  # Built main binary
    bridges/xmpp-bridge/
      target/<profile>/xmpp-bridge  # Built bridge binary
  env/
    lunarwing.env              # Main daemon env (mode 0600)
    xmpp-bridge.env            # Bridge env
    proxy.env                  # TensorZero proxy env
  state/                       # LUNARWING_BASE_DIR
    channels/                  # WASM channel artifacts
    tools/                     # WASM tool artifacts
    xmpp/                      # XMPP OMEMO state
  logs/                        # Log files (OpenRC) or symlink to journal
  run/                         # PID files, sockets
```

## Services Per Tenant

### Systemd (user-level with linger)

Each tenant gets 3 user-level systemd units installed to `~/.config/systemd/user/`:

| Unit | Description |
|------|-------------|
| `lunarwing-<name>.service` | Main daemon (Wants bridge + proxy) |
| `xmpp-bridge-<name>.service` | XMPP bridge (PartOf main) |
| `ironclaw-proxy-<name>.service` | TensorZero proxy |

The main unit has `Wants=` on the bridge and proxy, so starting it pulls in the sidecars. `loginctl enable-linger` keeps services running after the user logs out.

Admin manages these via:
```bash
sudo -u <tenant> XDG_RUNTIME_DIR=/run/user/<uid> systemctl --user <command> <unit>
```

Tenant can also manage their own services directly:
```bash
systemctl --user status lunarwing-<name>.service
journalctl --user -u lunarwing-<name>.service -f
```

### OpenRC (system-level with User= directives)

Each tenant gets 3 init scripts in `/etc/init.d/` with corresponding `/etc/conf.d/` files:

| Init script | Conf.d |
|-------------|--------|
| `/etc/init.d/lunarwing-<name>` | `/etc/conf.d/lunarwing-<name>` |
| `/etc/init.d/xmpp-bridge-<name>` | `/etc/conf.d/xmpp-bridge-<name>` |
| `/etc/init.d/ironclaw-proxy-<name>` | `/etc/conf.d/ironclaw-proxy-<name>` |

All use `supervise-daemon` with `command_user` set to the tenant. Dependency wiring ensures proxy and bridge start before the main daemon.

```bash
rc-service lunarwing-<name> start
rc-service lunarwing-<name> status
```

## PostgreSQL

Each tenant gets its own Docker/Podman container named `lunarwing-pg-<name>`, bound to `127.0.0.1:<allocated-port>:5432`. Default credentials: `lunarwing/lunarwing/lunarwing` (user/password/database).

The container is created with `--restart unless-stopped` so it survives host reboots (when using Docker). For Podman, consider generating a systemd unit via `podman generate systemd`.

## Container Runtime

The script supports both Docker and Podman. Detection priority:

1. `LUNARWING_CONTAINER_RUNTIME` env var override (`docker` or `podman`)
2. If only Podman is installed, use Podman
3. Otherwise default to Docker

All container operations use the detected runtime — no Docker-specific commands are hardcoded.

## Build Serialization

Only one tenant builds at a time, enforced by an flock on `/var/lock/lunarwing-build.lock`. This prevents OOM on memory-constrained hosts when multiple tenants need to compile Rust.

```bash
# Build one tenant
sudo scripts/lunarwing-mt-admin.sh build-tenant ruffles

# Build all tenants sequentially
sudo scripts/lunarwing-mt-admin.sh build-all

# Include WASM extensions
sudo scripts/lunarwing-mt-admin.sh build-all --with-wasm
```

## Security Considerations

- Env files are mode `0600`, owned by the tenant user
- Gateway tokens are auto-generated (64-char hex) per tenant
- Secrets master keys are unique per tenant
- Each tenant runs in its own user scope (cgroup on systemd)
- PostgreSQL containers bind to `127.0.0.1` only
- All HTTP services bind to `127.0.0.1` by default
- Systemd units include `NoNewPrivileges=true` and `PrivateTmp=true`

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `LUNARWING_SERVICE_MANAGER` | auto-detect | Force `systemd` or `openrc` |
| `LUNARWING_CONTAINER_RUNTIME` | auto-detect | Force `docker` or `podman` |
| `LUNARWING_MT_PROFILE` | `release` | Build profile (`release` or `debug`) |
| `LUNARWING_MT_SOURCE_REPO` | parent of script | Path to source repo to clone from |
| `LUNARWING_MT_TENSORZERO_URL` | `http://192.168.1.157:3000` | Default upstream TensorZero URL |

## Command Reference

```
add-tenant <name> [options]      Create user, allocate ports, clone repo,
                                 generate env, render and install services
  --docker-group                 Add user to docker/podman group
  --xmpp-jid <jid>              XMPP JID for this tenant
  --xmpp-password <pass>        XMPP password (generated if omitted)
  --tensorzero-url <url>         Upstream TensorZero URL

add-tenants <names> [options]    Comma-separated list (e.g. "Ruffles,Miyuki")
  --docker-group                 Add user to docker/podman group
  --xmpp-domain <domain>        XMPP domain for JIDs (default: xmpp.localhost)
  --tensorzero-url <url>         Upstream TensorZero URL

remove-tenant <name>             Stop services, deallocate ports
  --purge                        Also delete OS user and home directory

build-tenant <name>              Build binaries for one tenant (flock-serialized)
  --with-wasm                    Also build WASM extensions

build-all                        Build each tenant sequentially
  --with-wasm                    Also build WASM extensions

start-tenant <name>              Start all services for a tenant
stop-tenant <name>               Stop all services for a tenant
restart-tenant <name>            Stop then start

list-tenants                     Show all tenants with ports
status <name>                    Detailed status for one tenant
tokens [name]                    Print gateway auth tokens (all or one)
doctor                           System dependency and health checks
```

## Relationship to Test Harness

The test harness (`ic/scripts/lunarwing-xmpp-test-env.sh`) provides `mt-init`, `mt-up`, `mt-verify`, `mt-down` commands for ephemeral multi-tenancy testing in `/tmp/`. It runs everything under the current user with direct process management.

The production admin script (`lunarwing-mt-admin.sh`) is for persistent deployments with proper OS-level isolation. Key differences:

| Aspect | Test harness | Production admin |
|--------|-------------|-----------------|
| Users | Current user only | Dedicated OS user per tenant |
| State | `/tmp/lunarwing-mt-*` | `/home/<tenant>/lunarwing/` |
| Services | Direct processes or user systemd | User systemd with linger or system OpenRC |
| Ports | Hardcoded offsets | Registry-allocated blocks |
| Build | Shared build artifacts | Per-user builds, flock-serialized |
| PostgreSQL | Shared or per-tenant containers | Per-tenant containers |
| Lifecycle | Ephemeral (test and discard) | Persistent (survives reboot) |

## Health Checks

The infrastructure health check suite (`ic-infrastructure-health-check/`) auto-detects the init system and runs the appropriate service health check:

- **systemd**: runs `health-systemd.sh` (checks unit active state, restart count, timer metadata)
- **OpenRC**: runs `health-openrc.sh` (checks `rc-service` status, PID liveness)

On OpenRC, `health-openrc.sh` auto-discovers multi-tenant services by scanning `/etc/init.d/` for `lunarwing-*`, `xmpp-bridge-*`, and `ironclaw-proxy-*` patterns. No configuration needed — all tenants are automatically monitored. Override with `SERVICES="svc1 svc2"` if needed.

The init system detection can be forced via `LUNARWING_SERVICE_MANAGER=systemd` or `LUNARWING_SERVICE_MANAGER=openrc`.

## Routine System Improvements

All tenants benefit from the routine resilience features:

- **Native retry with backoff**: When a routine fails with a retryable error (LLM timeout, empty response, execution timeout), it is automatically retried with exponential backoff. Per-routine `RetryPolicy` defaults: 3 retries, 60s initial delay, 2x backoff, 1h max delay. Retries use the existing `next_fire_at` column and cron ticker — no extra infrastructure. Non-retryable errors (auth, config, DB) skip retry entirely.
- **Lightweight timeout**: Lightweight routine executions are wrapped in `tokio::time::timeout` (default 300s, configurable via `ROUTINES_LIGHTWEIGHT_TIMEOUT_SECS`)
- **Stuck-run sweeper**: On every cron tick, the engine sweeps lightweight runs stuck in `running` beyond the timeout threshold and marks them as failed, unblocking the routine for future fires
- **FullJob crash recovery**: `sync_dispatched_runs()` recovers orphaned full-job runs from previous process crashes

These mechanisms prevent a single failed routine from permanently blocking itself due to a stale `running` status in the database.

## Troubleshooting

### Services don't start after reboot

- systemd: Verify linger is enabled: `loginctl show-user <tenant> | grep Linger`
- OpenRC: Add services to default runlevel: `rc-update add lunarwing-<name> default`

### PostgreSQL container won't start

- Check if the port is already in use: `ss -tlnp | grep <port>`
- Check container logs: `docker logs lunarwing-pg-<name>` or `podman logs lunarwing-pg-<name>`

### Build fails with OOM

- The flock on `/var/lock/lunarwing-build.lock` ensures only one build at a time
- If still OOMing, increase swap or use `LUNARWING_MT_PROFILE=debug` (faster but larger binaries)
- Check `CARGO_BUILD_JOBS` to limit parallel rustc instances

### Tenant user can't access Docker

- Verify group membership: `id <tenant>`
- User may need to log out and back in after being added to the docker group
- For Podman rootless, ensure `subuid`/`subgid` ranges are allocated: `grep <tenant> /etc/subuid`

### Gateway not accessible from network

- Gateways bind to `127.0.0.1` by default
- Use SSH port forwarding: `ssh -L <port>:127.0.0.1:<port> <host>`
- Or edit the tenant's `lunarwing.env` to set `GATEWAY_HOST=0.0.0.0` and restart
