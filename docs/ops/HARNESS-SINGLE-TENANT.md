# Single-Tenant Harness

How to run one isolated LunarWing instance using the test harness.

For full detail on every step, see [`ic/testing/lunarwing-xmpp/README.md`](../../ic/testing/lunarwing-xmpp/README.md).
For running two isolated tenants side-by-side, see [`MULTITENANCY-HARNESS.md`](MULTITENANCY-HARNESS.md).

## Important: Build Behaviour

`up` does **not** build anything automatically. If binaries or WASM artifacts are missing, the stack will fail to start or the gateway will report zero channels and tools. Always run the build steps explicitly before `up`.

## Quick Start

```bash
cd ic

# 1. Create isolated env, state, run, and log dirs
scripts/lunarwing-xmpp-test-env.sh init

# 2. Build daemon + bridge + all 20 WASM channels/tools
scripts/lunarwing-xmpp-test-env.sh build --with-wasm

# 3. Install WASM artifacts into the test state dir
scripts/lunarwing-xmpp-test-env.sh install-wasm

# 4. Start full stack: postgres → proxy → bridge → daemon
scripts/lunarwing-xmpp-test-env.sh up

# 5. Run health checks
scripts/lunarwing-xmpp-test-env.sh verify

# 6. Tear down
scripts/lunarwing-xmpp-test-env.sh down
```

## Platform Support

Single-tenant `up`/`down` always uses **direct PID management** regardless of platform — no init system involvement. This works on macOS, Linux (systemd or OpenRC), and any other Unix.

| Platform | Service management | Notes |
|----------|--------------------|-------|
| macOS | Direct PID files | Docker Desktop required for PostgreSQL |
| Linux (systemd) | Direct PID files | systemd units only used with `render-systemd` + manual install |
| Linux (OpenRC) | Direct PID files | Same as above, no rc-service involvement |

## macOS Prerequisites

On macOS, the WASM toolchain requires additional setup before `build --with-wasm`:

```bash
# Both WASM targets are needed
rustup target add wasm32-wasip1 wasm32-wasip2

# WASM build tools
cargo install wasm-tools cargo-component --locked
```

**PATH ordering matters** — Homebrew's `rustc` lacks WASM targets. The rustup toolchain bin must come first:

```bash
export PATH="$HOME/.rustup/toolchains/stable-$(rustc -vV | awk '/host/{print $2}')/bin:$HOME/.cargo/bin:$PATH"
which rustc   # must show ~/.rustup/toolchains/... not /opt/homebrew/bin/rustc
```

## Platform Testing Status

- **macOS:** tested end-to-end — `init`, `build --with-wasm`, `install-wasm`, `up`, `verify`, `down` all verified
- **Linux (systemd):** implemented, not recently re-verified with the current harness version
- **Linux (OpenRC):** **not tested end-to-end** — code path exists but has never been run on a real OpenRC system (Gentoo, Alpine, etc.); treat as best-effort until validated

## Key Env Vars

| Variable | Default | Description |
|----------|---------|-------------|
| `LUNARWING_TEST_ROOT` | `$TMPDIR/lunarwing-xmpp-test` | Isolated state root |
| `LUNARWING_TEST_PROFILE` | `debug` | Build profile (`debug` or `release`) |
| `LUNARWING_TEST_DATABASE_KIND` | `postgres` | `postgres` or `libsql` |
| `LUNARWING_TEST_PG_PORT` | `5432` | PostgreSQL container port |
| `LUNARWING_TEST_GATEWAY_PORT` | `8765` | Gateway HTTP port |
| `LUNARWING_TEST_BRIDGE_BIND` | `127.0.0.1:8787` | Bridge HTTP bind |

## Full Reference

See [`ic/testing/lunarwing-xmpp/README.md`](../../ic/testing/lunarwing-xmpp/README.md) for:
- Picking and persisting a test root
- Inspecting generated env files
- Bridge smoke testing without live XMPP
- Configuring live XMPP credentials
- Running LunarWing via systemd user units
- Troubleshooting and cleanup
