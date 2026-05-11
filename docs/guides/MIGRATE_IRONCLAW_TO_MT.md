# Migrating an IronClaw Instance to a Multi-Tenant LunarWing Setup

This guide covers migrating an existing single-instance IronClaw PostgreSQL installation into a production multi-tenant LunarWing deployment managed by `lunarwing-mt-admin.sh`.

For single-instance (non-MT) migration, see `MIGRATE_IRONCLAW_TO_LUNARWING.md`.

## Prerequisites

- A running IronClaw instance with PostgreSQL (e.g. `~/.ironclaw/` with `DATABASE_URL` pointing to a Postgres database)
- The LunarWing repo cloned and accessible
- Root/sudo access for MT admin operations
- Docker or Podman installed

## Overview

The MT admin script creates isolated tenants, each with its own OS user, PostgreSQL container, port block, and service units. Migration involves:

1. Setting up the MT environment and creating tenants
2. Dumping the existing IronClaw PostgreSQL database
3. Restoring the dump into the target tenant's PostgreSQL container
4. Copying workspace files (projects, tools, config) into the tenant's base directory
5. Adjusting configuration for the new port layout
6. Starting the tenant and letting Refinery auto-apply any pending migrations

## Step 1: Clean Up Previous MT Test Installations (if any)

If you have leftover tenants from prior test runs, remove them first. Old v1 port registry entries (missing the `orchestrator` port) will cause issues with the current MT admin script.

```bash
# Remove each old tenant (without --purge to preserve home dirs, or with --purge for full cleanup)
sudo ic/scripts/lunarwing-mt-admin.sh remove-tenant <old-tenant> --purge

# Verify clean state
cat /etc/lunarwing/ports.json
```

The registry should show `"tenants": {}` or only tenants you intend to keep.

## Step 2: Create Tenants

Create tenants one at a time if pgvector initialization is slow (the readiness check waits up to 90 seconds):

```bash
sudo ic/scripts/lunarwing-mt-admin.sh add-tenant <name> --docker-group
```

Or create multiple at once:

```bash
sudo ic/scripts/lunarwing-mt-admin.sh add-tenants "Alice,Bob,Charlie" --docker-group
```

Each tenant gets a 10-port block starting from 10000. Verify with:

```bash
sudo ic/scripts/lunarwing-mt-admin.sh list-tenants
```

### Port layout per tenant

| Offset | Service |
|--------|---------|
| +0 | Gateway (web UI, WebSocket, REST) |
| +1 | HTTP webhook |
| +2 | XMPP bridge |
| +3 | PostgreSQL |
| +4 | TensorZero proxy |
| +5 | WeeChat relay |
| +6 | Orchestrator |
| +7-9 | Reserved |

### Troubleshooting: PG readiness timeout

The pgvector Docker image (`pgvector/pgvector:pg16`) can take 30-40 seconds on first init. If `add-tenant` fails with "PostgreSQL did not become ready", the container is likely still initializing. Check with:

```bash
docker logs lunarwing-pg-<tenant>
```

If the logs show "database system is ready to accept connections", re-run `add-tenant` after removing and re-adding:

```bash
sudo ic/scripts/lunarwing-mt-admin.sh remove-tenant <name>
sudo ic/scripts/lunarwing-mt-admin.sh add-tenant <name> --docker-group
```

The existing container will be restarted rather than recreated.

## Step 3: Dump the IronClaw Database

The IronClaw service does **not** need to be stopped for this step. `pg_dump` takes a consistent snapshot using transaction isolation.

```bash
pg_dump -h 127.0.0.1 -p 5432 -U ironclaw -d ironclaw \
  --no-owner --no-privileges --clean --if-exists \
  > /tmp/ironclaw-dump.sql
```

Flags explained:
- `--no-owner`: strips ownership so tables get owned by whoever restores (the `lunarwing` DB user in the tenant container)
- `--no-privileges`: strips GRANT/REVOKE statements
- `--clean --if-exists`: adds `DROP IF EXISTS` before each `CREATE`, safe for restoring into a fresh database

Adjust `-p 5432`, `-U ironclaw`, and `-d ironclaw` to match your IronClaw installation's `DATABASE_URL`.

## Step 4: Restore into the Target Tenant

Find the tenant's PostgreSQL port from the registry:

```bash
jq '.tenants.<tenant>.ports.postgres' /etc/lunarwing/ports.json
```

Restore the dump. The MT admin creates all tenant PG containers with user `lunarwing`, password `lunarwing`, database `lunarwing`:

```bash
psql -h 127.0.0.1 -p <tenant_pg_port> -U lunarwing -d lunarwing \
  < /tmp/ironclaw-dump.sql
```

You will see some harmless notices about objects not existing (from the `DROP IF EXISTS` statements hitting the empty database). Errors on `DROP EXTENSION plpgsql` or similar system objects are also safe to ignore.

Verify the restore:

```bash
psql -h 127.0.0.1 -p <tenant_pg_port> -U lunarwing -d lunarwing \
  -c "SELECT version FROM refinery_schema_history ORDER BY version DESC LIMIT 1;"
```

This should show the migration version from your IronClaw database (e.g. `17`).

## Step 5: Copy Workspace Files

The tenant's base directory is `/home/<tenant>/lunarwing/state/`. Copy the workspace content from the IronClaw installation:

```bash
IRONCLAW_DIR=/home/<your_user>/.ironclaw
TENANT_STATE=/home/<tenant>/lunarwing/state

# Copy workspace files
sudo cp -r "$IRONCLAW_DIR/projects"           "$TENANT_STATE/"
sudo cp -r "$IRONCLAW_DIR/tools"              "$TENANT_STATE/"
sudo cp -r "$IRONCLAW_DIR/channels"           "$TENANT_STATE/"
sudo cp -r "$IRONCLAW_DIR/workspace-template" "$TENANT_STATE/"
sudo cp -r "$IRONCLAW_DIR/xmpp"              "$TENANT_STATE/"  # if using XMPP

# Fix ownership
sudo chown -R <tenant>:<tenant> "$TENANT_STATE"
```

### Secrets / master key

The `secrets` table contains AES-256-GCM encrypted data. The master key is stored in the OS keychain, tied to the original user. To migrate secrets:

1. Export the master key from the original user's keychain
2. Place it in the tenant user's keychain or home directory
3. Ensure `LUNARWING_BASE_DIR` is set correctly in the tenant's env file so the daemon can find it

If you cannot migrate the key, the encrypted secrets will be unreadable. Re-enter them via the LunarWing CLI or web gateway after starting the tenant.

## Step 6: Update Tenant Configuration

The MT admin generates `config.toml` and env files automatically in `/home/<tenant>/lunarwing/env/`. If you need to carry over custom settings from the IronClaw `config.toml`:

```bash
# Check what the MT admin generated
sudo cat /home/<tenant>/lunarwing/env/lunarwing.env

# Compare with your IronClaw config
cat /home/<your_user>/.ironclaw/config.toml
```

Key differences from single-instance to MT:
- `DATABASE_URL` now points to `127.0.0.1:<tenant_pg_port>` instead of `:5432`
- `HTTP_PORT` uses the tenant's gateway port
- `ORCHESTRATOR_PORT` is allocated (not present in old setups)
- TensorZero proxy URL may differ per tenant

## Step 7: Build and Start the Tenant

```bash
# Build binaries (flock-serialized to prevent OOM)
sudo ic/scripts/lunarwing-mt-admin.sh build-tenant <tenant> --with-wasm

# Start services
sudo ic/scripts/lunarwing-mt-admin.sh start-tenant <tenant>

# Verify
sudo ic/scripts/lunarwing-mt-admin.sh status <tenant>
```

On first startup, Refinery will auto-apply any pending migrations (e.g. V18 routine retry columns if your IronClaw DB was at V17).

Check logs for migration output:

```bash
# systemd
sudo -u <tenant> XDG_RUNTIME_DIR=/run/user/$(id -u <tenant>) journalctl --user -u lunarwing-<tenant>.service -f

# or check the log file
sudo tail -f /home/<tenant>/lunarwing/logs/lunarwing.log
```

## Step 8: Verify the Migration

```bash
# Check gateway is responding
curl -s http://127.0.0.1:<gateway_port>/api/status

# Get the auth token
sudo ic/scripts/lunarwing-mt-admin.sh tokens <tenant>

# Connect to the web UI
# From the same machine: http://127.0.0.1:<gateway_port>
# Remote: ssh -L <gateway_port>:127.0.0.1:<gateway_port> user@host
```

Verify data integrity:
- Memory documents are accessible via the web UI or `memory_search` tool
- Routines appear in the routines list
- Conversation history is preserved
- XMPP bridge connects (if configured)

## Rollback

The original IronClaw installation is untouched throughout this process. To roll back:

```bash
# Stop the tenant
sudo ic/scripts/lunarwing-mt-admin.sh stop-tenant <tenant>

# Restart the original IronClaw service
sudo systemctl start ironclaw
```

The IronClaw database at port 5432 was never modified. The dump was read-only.

## What Changes vs What Stays the Same

| Item | Changes? | Notes |
|------|----------|-------|
| Database contents | Preserved | Dump/restore is lossless; migrations auto-apply |
| Database owner | `ironclaw` -> `lunarwing` | `--no-owner` flag handles this |
| Database port | 5432 -> tenant port | MT containers bind to allocated ports |
| Workspace files | Preserved | Copied into tenant state dir |
| Secrets (encrypted) | Requires key migration | Master key must be copied to tenant user |
| Service units | New MT-style units | Generated by `add-tenant`, replace old single-instance units |
| Config format | Same | `config.toml` format is unchanged |
| XMPP bridge | New per-tenant bridge | Separate JID and port per tenant |
