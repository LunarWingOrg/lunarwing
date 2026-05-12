# Release Notes for LunarWing v1.0.5

**Release Date:** 2026-05-12

## Overview

This release focuses on production multi-tenant operations: comprehensive migration guides for moving existing IronClaw installations (both PostgreSQL and libSQL backends) into the MT admin framework, critical fixes to the MT admin script for Docker sandbox and pgvector initialization reliability, and documentation improvements across the board.

## New Features

### IronClaw-to-MT Migration Guides
- **PostgreSQL migration** (`docs/guides/MIGRATE_IRONCLAW_TO_MT.md`): Step-by-step guide for migrating a single-instance IronClaw PostgreSQL installation into a production multi-tenant LunarWing deployment. Covers database dump/restore with `--no-owner`, workspace file migration, secrets/master key transfer, XMPP bridge reconfiguration, and rollback procedures.
- **libSQL migration** (`docs/guides/MIGRATE_IRONCLAW_LIBSQL_TO_MT.md`): Cross-backend migration guide for moving libSQL/SQLite-based IronClaw instances into MT PostgreSQL tenants. Covers type mapping (UUID, TIMESTAMPTZ, JSONB, BOOLEAN), CSV export/import workflow, sequence resets, vector column handling, and a minimal migration option for small instances.

### Nanocode External Worker Improvements
- Added dotenv override example file for nanocode worker configuration
- Added troubleshooting documentation for nanocode external worker mode
- Reorganized nanocode image build directory structure

## Fixes

### MT Admin Script
- **PG readiness timeout**: Increased PostgreSQL container readiness check from 30 seconds to 90 seconds. The pgvector Docker image (`pgvector/pgvector:pg16`) can take 30-40 seconds on first initialization, causing false-negative failures during `add-tenant`.
- **Docker sandbox PATH**: Added `Environment=PATH=...` to the systemd user unit template for tenant daemon services. Without this, the daemon process could not find the `docker` binary, causing sandbox job creation to fail with "docker is not installed or running" despite Docker being fully accessible to the tenant user.

## Documentation

### New
- `docs/guides/MIGRATE_IRONCLAW_TO_MT.md` — PostgreSQL migration to MT
- `docs/guides/MIGRATE_IRONCLAW_LIBSQL_TO_MT.md` — libSQL cross-backend migration to MT
- `docs/guides/ironclaw_weechat_wss/weechat_relay/TROUBLESHOOTING.md` — WeeChat channel troubleshooting
- `nanocode4ironclaw/TROUBLESHOOTING.md` — Nanocode worker troubleshooting
- `MIGRATION_GUIDES.MD` — Index of all available migration paths
- `codex4ironclaw/DEPRECATE.md` — Deprecation notice for codex worker (superseded by nanocode)

### Updated
- `MANIFESTO.md` — Minor updates

### Removed
- `AUDIT.md`, `RIPOUTCLAUDECODE.md`, `IDEA_TRACKING.md` — Superseded by Vikunja task tracking

## Migration Notes

### Migrating from IronClaw (PostgreSQL) to MT

```bash
# 1. Create tenants
sudo ic/scripts/lunarwing-mt-admin.sh add-tenant <name> --docker-group

# 2. Dump existing database (service does NOT need to be stopped)
pg_dump -h 127.0.0.1 -p 5432 -U ironclaw -d ironclaw \
  --no-owner --no-privileges --clean --if-exists > /tmp/ironclaw-dump.sql

# 3. Restore into tenant PG container
PGPASSWORD=lunarwing psql -h 127.0.0.1 -p <tenant_pg_port> -U lunarwing -d lunarwing \
  < /tmp/ironclaw-dump.sql

# 4. Copy workspace files
sudo cp -r ~/.ironclaw/projects /home/<tenant>/lunarwing/state/
sudo cp -r ~/.ironclaw/workspace-template /home/<tenant>/lunarwing/state/
sudo chown -R <tenant>:<tenant> /home/<tenant>/lunarwing/state/

# 5. Build and start
sudo ic/scripts/lunarwing-mt-admin.sh build-tenant <name> --with-wasm
sudo ic/scripts/lunarwing-mt-admin.sh start-tenant <name>
```

Refinery auto-applies pending migrations (e.g. V18 routine retry columns) on first startup. See the full guide for XMPP bridge setup, secrets migration, and troubleshooting.

### Known Issues

- XMPP OMEMO sessions must be re-established after migration. Copying the OMEMO store from the old instance results in stale ratchet state. Recommended: let the bridge generate fresh keys and re-trust the new device on your XMPP client.
- Prosody's `offline` module should be disabled for agent JIDs to prevent message replay floods on bridge reconnect. Add `modules_disabled = { "offline" }` to the VirtualHost config.
- Nanocode worker logs session ID validation warnings (`must start with "prt"`) — these are cosmetic and do not affect execution.

## Upgrade from v1.0.4

1. Pull the latest code: `git pull origin staging`
2. Rebuild the daemon: `cd ic && cargo build --release --bin lunarwing`
3. For MT deployments: `sudo ic/scripts/lunarwing-mt-admin.sh build-all --with-wasm`
4. Existing MT tenants need their systemd units re-rendered to pick up the PATH fix (or manually add `Environment=PATH=/usr/local/bin:/usr/bin:/bin:/home/<tenant>/.cargo/bin` to the `[Service]` section)

## Full Commit Log

35 commits since v1.0.4. Key changes:

- Comprehensive migration documentation (IronClaw PostgreSQL and libSQL to MT)
- MT admin PG readiness timeout increase (30s → 90s)
- MT admin systemd unit PATH fix for Docker sandbox access
- Nanocode worker documentation and configuration improvements
- Repository cleanup and Vikunja task tracking migration
- Release planning updates for v1.0.5 and v1.0.6 roadmap

---

**Docker Images:**
- `lunarwing-worker:latest` (sandbox worker)
- `ironclaw-worker-nanocode:latest` (nanocode external worker)

**Binaries:**
- `lunarwing` (main daemon)
- `xmpp-bridge` (XMPP bridge service)
