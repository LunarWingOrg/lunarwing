# Multi-Tenancy Harness

How to run multiple isolated LunarWing instances on the same host using the test harness.

For a single instance, see [`HARNESS-SINGLE-TENANT.md`](HARNESS-SINGLE-TENANT.md).

## Port Map

Every port used by the harness is now configurable via `LUNARWING_TEST_*` env vars.
Set them before running `init` to generate env files with your chosen ports.

| Service | Variable | Default | Description |
|---------|----------|---------|-------------|
| PostgreSQL | `LUNARWING_TEST_PG_PORT` | 5432 | Postgres container host port |
| TensorZero proxy | `LUNARWING_TEST_PROXY_PORT` | 3002 | Local LLM routing proxy |
| TensorZero proxy bind | `LUNARWING_TEST_PROXY_BIND` | 127.0.0.1 | Proxy listen address |

> **Note:** The test harness always starts a proxy for isolation. In production, the proxy is opt-in via `--enable-proxy` (v1.1.9+) — new tenants connect directly to the upstream LLM endpoint by default.

| Gateway (REST API) | `LUNARWING_TEST_GATEWAY_PORT` | 8765 | LunarWing gateway HTTP |
| HTTP webhook | `LUNARWING_TEST_HTTP_PORT` | 9098 | Inbound webhook listener |
| XMPP bridge | `LUNARWING_TEST_BRIDGE_BIND` | 127.0.0.1:8787 | Bridge HTTP bind (host:port) |
| Weechat relay | `LUNARWING_TEST_WEECHAT_PORT` | 9001 | Weechat relay port (future) |

## Example: Two Instances Side-by-Side

### Instance A (defaults)

```bash
cd ic
scripts/lunarwing-xmpp-test-env.sh init
scripts/lunarwing-xmpp-test-env.sh up
```

### Instance B (all ports shifted)

```bash
cd ic
export LUNARWING_TEST_ROOT=/tmp/lunarwing-tenant-b
export LUNARWING_TEST_PG_PORT=5433
export LUNARWING_TEST_PG_CONTAINER=lunarwing-test-postgres-b
export LUNARWING_TEST_PROXY_PORT=3003
export LUNARWING_TEST_GATEWAY_PORT=8766
export LUNARWING_TEST_HTTP_PORT=9099
export LUNARWING_TEST_BRIDGE_BIND=127.0.0.1:8788
export LUNARWING_TEST_WEECHAT_PORT=9002

scripts/lunarwing-xmpp-test-env.sh init
scripts/lunarwing-xmpp-test-env.sh up
```

Both stacks run independently with no port conflicts.

## Secret Management Instructions:

# For tenant A:                                                                                                       
  source /tmp/lunarwing-mt-a/env/lunarwing.env                                                                          
  python3 ic_sm/scripts_4_db/insert_secret_pg.py ...                                                                  
                                                            
  # For tenant B:                                           
  source /tmp/lunarwing-mt-b/env/lunarwing.env                                                                          
  python3 ic_sm/scripts_4_db/insert_secret_pg.py ...

### Each tenant will have own master key and its own database on its own port so source the env vars is the way to go here.

## Notes

- Each instance needs its own `LUNARWING_TEST_ROOT` for isolated state/env/logs/pids.
- Each instance needs its own `LUNARWING_TEST_PG_CONTAINER` name to avoid Docker container conflicts.
- The `DATABASE_URL` is auto-derived from `PG_PORT` unless you override `LUNARWING_TEST_DATABASE_URL` explicitly.
- For libSQL instances, port conflicts are only on the service ports (no database container).
- Systemd unit names are also configurable via `LUNARWING_TEST_SERVICE_NAME`, `LUNARWING_TEST_BRIDGE_SERVICE_NAME`, and `LUNARWING_TEST_PROXY_SERVICE_NAME`.

## Platform Support

The harness is cross-platform. Init system detection is automatic:

| Platform | `mt-up`/`mt-down` method | Service unit format |
|----------|--------------------------|---------------------|
| macOS | launchd user agents | `.plist` in `$TEST_ROOT/launchd/` → `~/Library/LaunchAgents/` |
| Linux (systemd) | systemd user units | `.service` in `$TEST_ROOT/systemd/` → `~/.config/systemd/user/` |
| Linux (OpenRC) | rc-service (direct) | direct process management fallback |
| Other | direct PID management | — |

> **Note — OpenRC not yet been FULLY validated:** The OpenRC path has been implemented but has not been tested end-to-end on a real OpenRC system. (However, this task WILL be completed very soon...) `_mt_detect_init()` correctly identifies OpenRC and `doctor` reports `rc-service` status, but neither `mt-up`/`mt-down` nor single-tenant `up`/`down` have been run on Gentoo, Alpine, or any other OpenRC host. Treat the OpenRC path as best-effort until a full test is completed.

### macOS Prerequisites

Before running `mt-up` on macOS, ensure the WASM toolchain is set up:

```bash
# 1. Both WASM targets are required (wasip1 for channels/tools, wasip2 for the daemon)
rustup target add wasm32-wasip1 wasm32-wasip2

# 2. Install WASM build tools
cargo install wasm-tools cargo-component --locked

# 3. Ensure rustup's rustc precedes Homebrew's in PATH.
#    Homebrew's rustc does NOT ship WASM targets — if it's found first, all
#    cargo component builds will fail with "can't find crate for `core`".
export PATH="$HOME/.rustup/toolchains/stable-$(rustc -vV | awk '/host/{print $2}')/bin:$HOME/.cargo/bin:$PATH"
which rustc   # must show ~/.rustup/toolchains/...
```

Docker Desktop must be running (for PostgreSQL containers). If `docker pull` fails on first run, pull the image manually:

```bash
docker pull pgvector/pgvector:pg16
```

### macOS Quick Start

```bash
cd ic
scripts/lunarwing-xmpp-test-env.sh mt-init
scripts/lunarwing-xmpp-test-env.sh build --with-wasm  # builds daemon, bridge, + all 20 WASM
scripts/lunarwing-xmpp-test-env.sh mt-up              # auto-detects macOS, renders + loads plists
scripts/lunarwing-xmpp-test-env.sh mt-verify
scripts/lunarwing-xmpp-test-env.sh mt-down
```

`mt-up` automatically renders launchd plists and calls `launchctl load` — you do not need to run `mt-render-launchd` separately. Plists are tenant-scoped (`com.lunarwing.test.mt-a.*`, `com.lunarwing.test.mt-b.*`) so both tenants coexist in `~/Library/LaunchAgents/` without label conflicts. `mt-down` unloads all agents and removes them.

### Single-tenant on macOS

Single-tenant `up`/`down` uses direct PID management on all platforms — no launchd involvement needed. Docker (or colima) must be running for the PostgreSQL container.

## Production Multi-Tenancy

For production per-user multi-tenancy with OS-level isolation, see `MULTITENANCY-PRODUCTION.md` and the admin script `ic/scripts/lunarwing-mt-admin.sh`. The production system provides dedicated OS users, registry-allocated port blocks, flock-serialized builds, and per-tenant PostgreSQL containers. It supports both systemd (user-level with linger) and OpenRC (system-level with supervise-daemon).

The test harness documented here is for development/testing only. See the comparison table in `MULTITENANCY-PRODUCTION.md` for the full list of differences.

## Future Work

- Weechat relay port integration (currently reserved, no harness plumbing yet)
- Per-instance worker container ports (lunarcode4lunarwing, pebble4lunarwing, opencode4lunarwing)
- Automatic port conflict detection in `doctor` command
