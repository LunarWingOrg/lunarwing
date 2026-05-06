# Migrating an Existing IronClaw Agent to LunarWing

This guide covers migrating a running IronClaw instance with a PostgreSQL database to LunarWing. The database schema is fully compatible -- Refinery migrations auto-apply on first startup. No data loss occurs.

## Prerequisites

- A running IronClaw instance with PostgreSQL
- Access to the IronClaw base directory (`~/.ironclaw` or custom `IRONCLAW_BASE_DIR`)
- Rust toolchain (edition 2024, MSRV 1.92)

## Step 1: Stop IronClaw and Back Up

```bash
# systemd
sudo systemctl stop ironclaw
sudo systemctl stop xmpp-bridge    # if running

# OpenRC
sudo rc-service ironclaw stop
sudo rc-service xmpp-bridge stop   # if running

# Back up the database
pg_dump -Fc ironclaw > ironclaw-pre-migration.dump
```

## Step 2: Build LunarWing

```bash
cd ic
cargo build --release --bin lunarwing

# If using the XMPP bridge:
cd bridges/xmpp-bridge && cargo build --release && cd ../..

# If using WASM extensions:
scripts/build-wasm-extensions.sh
```

## Step 3: Database

The PostgreSQL database requires no manual schema changes. LunarWing runs the same Refinery migration chain (V1--V18) and will auto-apply any new migrations on first startup.

Optionally rename the database:

```bash
psql -c "ALTER DATABASE ironclaw RENAME TO lunarwing;"
```

If you rename it, update `DATABASE_URL` in your `.env` to match (e.g., change `/ironclaw` to `/lunarwing` in the connection string). If you leave the database name as `ironclaw`, no URL change is needed.

## Step 4: Update Environment

Edit your instance `.env` file (typically `~/.ironclaw/.env` or `$IRONCLAW_BASE_DIR/.env`):

```bash
# Optional: rename the env var (IRONCLAW_BASE_DIR still works as a legacy fallback)
LUNARWING_BASE_DIR=/path/to/instance

# Required: update the log filter
RUST_LOG=lunarwing=info    # was ironclaw=info
```

You do not need to rename the base directory itself on disk. LunarWing reads whichever path `LUNARWING_BASE_DIR` (or `IRONCLAW_BASE_DIR`) points to.

## Step 5: Update config.toml

In `$BASE_DIR/config.toml`, update the agent name if desired:

```toml
[agent]
name = "lunarwing"    # was "ironclaw" -- cosmetic only
```

The `selected_model` field references TensorZero function names. If yours contains `ironclaw`, note that the TensorZero function name `tensorzero::function_name::ironclaw` is intentionally preserved and does not need renaming.

## Step 6: Update Service Units

### systemd

Replace your IronClaw unit files with the LunarWing ones from `ic/systemd/`:

```bash
# Remove old units
sudo systemctl disable ironclaw
sudo rm /etc/systemd/system/ironclaw.service

# Install new units
sudo cp ic/systemd/lunarwing.service /etc/systemd/system/
sudo cp ic/systemd/xmpp-bridge.service /etc/systemd/system/   # if using XMPP bridge
sudo systemctl daemon-reload
sudo systemctl enable lunarwing
```

Update `ExecStart=` to point at the new binary path (`.../lunarwing` instead of `.../ironclaw`). The XMPP bridge service has `PartOf=lunarwing.service` -- verify the unit name matches.

### OpenRC

Replace init scripts similarly. New OpenRC scripts are in `ic/systemd/` (`.openrc` and `.confd` files).

### Watchdog

If the watchdog is installed, re-run the installer to pick up the new binary name:

```bash
sudo ic/scripts/install-lunarwing-watchdog.sh
```

The installer auto-detects the init system and cleans up old `ironclaw-watchdog` installations.

## Step 7: Socket Path

LunarWing creates `lunarwing.sock` instead of `ironclaw.sock`. Update any scripts or REPL clients that connect via the Unix socket:

- Default location: `$XDG_RUNTIME_DIR/lunarwing.sock` or `$BASE_DIR/lunarwing.sock`
- The legacy `IRONCLAW_SOCKET` env var is still accepted

## Step 8: Start LunarWing

```bash
# systemd
sudo systemctl start lunarwing

# OpenRC
sudo rc-service lunarwing start

# Manual
cd ic
LUNARWING_BASE_DIR=/path/to/instance ./run.sh
```

Check the logs to confirm migrations applied cleanly:

```bash
journalctl -u lunarwing -f
# or
RUST_LOG=lunarwing=debug cargo run
```

## What Does NOT Need Changing

| Item | Why |
|------|-----|
| PostgreSQL data and schema | Fully compatible; migrations auto-apply |
| Workspace files (`SOUL.md`, `IDENTITY.md`, `USER.md`, etc.) | Same format and layout |
| WASM tool/channel auth state | Credential store schema is unchanged |
| Base directory contents (`.env`, `config.toml`, `workspace-template/`) | Same layout, read from whatever path the env var points to |
| `config.toml` LLM settings | Backend config format is unchanged |
| TensorZero proxy configuration | Function name `tensorzero::function_name::ironclaw` is intentionally preserved |
| WebSocket subprotocol | `ironclaw-agent-v1` is an external protocol, intentionally not renamed |

## Rollback

If something goes wrong:

```bash
sudo systemctl stop lunarwing
pg_restore -d ironclaw ironclaw-pre-migration.dump
# Re-enable old IronClaw service units
sudo systemctl start ironclaw
```

The database backup from Step 1 restores the original state. LunarWing does not delete or overwrite any IronClaw data.
