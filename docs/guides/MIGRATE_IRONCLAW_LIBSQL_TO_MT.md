# Migrating an IronClaw libSQL Instance to a Multi-Tenant LunarWing Setup

This guide covers migrating an existing single-instance IronClaw installation that uses libSQL (SQLite) as its database backend into a production multi-tenant LunarWing deployment with PostgreSQL.

For PostgreSQL-to-PostgreSQL migration, see `MIGRATE_IRONCLAW_TO_MT.md`.
For single-instance (non-MT) migration, see `MIGRATE_IRONCLAW_TO_LUNARWING.md`.

## Prerequisites

- An IronClaw instance with libSQL backend (the database file is typically `ironclaw.db` in the base directory)
- The LunarWing repo cloned and accessible
- Root/sudo access for MT admin operations
- Docker or Podman installed
- `sqlite3` CLI tool

## Overview

This is a **cross-backend migration** — libSQL and PostgreSQL store the same logical data but use different physical types. The MT admin creates tenants with PostgreSQL containers, so we need to export from SQLite and import with type conversions.

The migration strategy:
1. Create the MT tenant (gives a fresh PostgreSQL with the full schema already applied via migrations)
2. Export data from the libSQL database
3. Import into the tenant's PostgreSQL with appropriate type casting
4. Copy workspace files
5. Start the tenant

## Type Mapping

libSQL and PostgreSQL represent the same data differently:

| PostgreSQL | libSQL | CSV Import Behavior |
|-----------|--------|-------------------|
| `UUID` | `TEXT` | Auto-cast (PG parses UUID strings) |
| `TIMESTAMPTZ` | `TEXT` (ISO-8601) | Auto-cast (PG parses ISO-8601) |
| `JSONB` | `TEXT` (JSON string) | Auto-cast (PG parses JSON strings) |
| `BOOLEAN` | `INTEGER` (0/1) | Auto-cast (PG accepts 0/1 for boolean) |
| `NUMERIC` | `TEXT` | Auto-cast (PG parses numeric strings) |
| `TEXT[]` | `TEXT` (JSON array) | **Needs transform** (`["a","b"]` → `{a,b}`) |
| `VECTOR` | `BLOB` | **Needs binary conversion** |

Most types convert automatically via CSV import. Arrays and vectors require special handling.

## Step 1: Create the MT Tenant

Follow the standard MT setup from `MIGRATE_IRONCLAW_TO_MT.md`:

```bash
sudo ic/scripts/lunarwing-mt-admin.sh add-tenant <name> --docker-group
```

This gives you a fresh PostgreSQL container with the full schema (all migrations applied). Verify:

```bash
jq '.tenants.<name>.ports.postgres' /etc/lunarwing/ports.json
PGPASSWORD=lunarwing psql -h 127.0.0.1 -p <tenant_pg_port> -U lunarwing -d lunarwing -c "\dt"
```

## Step 2: Identify Data to Migrate

Check what tables have data in your libSQL database:

```bash
LIBSQL_DB=/path/to/.ironclaw/ironclaw.db

sqlite3 "$LIBSQL_DB" "
  SELECT name, (SELECT COUNT(*) FROM pragma_table_info(name)) as cols
  FROM sqlite_master
  WHERE type='table' AND name NOT LIKE 'sqlite_%'
  ORDER BY name;
"
```

Check row counts:

```bash
sqlite3 "$LIBSQL_DB" "
  SELECT 'routines', COUNT(*) FROM routines
  UNION ALL SELECT 'conversations', COUNT(*) FROM conversations
  UNION ALL SELECT 'conversation_messages', COUNT(*) FROM conversation_messages
  UNION ALL SELECT 'memory_documents', COUNT(*) FROM memory_documents
  UNION ALL SELECT 'memory_chunks', COUNT(*) FROM memory_chunks
  UNION ALL SELECT 'secrets', COUNT(*) FROM secrets
  UNION ALL SELECT 'settings', COUNT(*) FROM settings
  UNION ALL SELECT 'routine_runs', COUNT(*) FROM routine_runs
  UNION ALL SELECT 'agent_jobs', COUNT(*) FROM agent_jobs;
"
```

## Step 3: Export from libSQL

Export each table with data as CSV:

```bash
LIBSQL_DB=/path/to/.ironclaw/ironclaw.db
EXPORT_DIR=/tmp/ironclaw-export
mkdir -p "$EXPORT_DIR"

# Core tables (likely needed)
sqlite3 "$LIBSQL_DB" -header -csv "SELECT * FROM routines;" > "$EXPORT_DIR/routines.csv"
sqlite3 "$LIBSQL_DB" -header -csv "SELECT * FROM settings;" > "$EXPORT_DIR/settings.csv"
sqlite3 "$LIBSQL_DB" -header -csv "SELECT * FROM secrets;" > "$EXPORT_DIR/secrets.csv"
sqlite3 "$LIBSQL_DB" -header -csv "SELECT * FROM memory_documents;" > "$EXPORT_DIR/memory_documents.csv"
sqlite3 "$LIBSQL_DB" -header -csv "SELECT * FROM memory_chunks;" > "$EXPORT_DIR/memory_chunks.csv"
sqlite3 "$LIBSQL_DB" -header -csv "SELECT * FROM leak_detection_patterns;" > "$EXPORT_DIR/leak_detection_patterns.csv"

# History tables (optional — large, only needed if you want full history)
sqlite3 "$LIBSQL_DB" -header -csv "SELECT * FROM conversations;" > "$EXPORT_DIR/conversations.csv"
sqlite3 "$LIBSQL_DB" -header -csv "SELECT * FROM conversation_messages;" > "$EXPORT_DIR/conversation_messages.csv"
sqlite3 "$LIBSQL_DB" -header -csv "SELECT * FROM routine_runs;" > "$EXPORT_DIR/routine_runs.csv"
sqlite3 "$LIBSQL_DB" -header -csv "SELECT * FROM agent_jobs;" > "$EXPORT_DIR/agent_jobs.csv"
sqlite3 "$LIBSQL_DB" -header -csv "SELECT * FROM job_events;" > "$EXPORT_DIR/job_events.csv"
sqlite3 "$LIBSQL_DB" -header -csv "SELECT * FROM job_actions;" > "$EXPORT_DIR/job_actions.csv"
sqlite3 "$LIBSQL_DB" -header -csv "SELECT * FROM tool_failures;" > "$EXPORT_DIR/tool_failures.csv"
```

## Step 4: Handle Array Columns

Some columns store arrays differently between backends. Identify them before import:

```bash
# Check if any exported data contains JSON arrays that PG expects as TEXT[]
grep -l '^\[' "$EXPORT_DIR"/*.csv
```

If you find JSON arrays (e.g. `["value1","value2"]`) in columns that PostgreSQL expects as `TEXT[]`, convert them:

```bash
# Example: convert JSON array to PG array format in a specific column
# ["a","b","c"] → {a,b,c}
sed -i 's/\["\([^]]*\)"\]/{\1}/g' "$EXPORT_DIR/affected_file.csv"
```

In practice, most LunarWing tables use JSONB (not TEXT[]) for complex data, so this step is often unnecessary — JSONB columns accept JSON strings as-is.

## Step 5: Import into PostgreSQL

```bash
PG_PORT=<tenant_pg_port>  # from ports.json

PGPASSWORD=lunarwing psql -h 127.0.0.1 -p "$PG_PORT" -U lunarwing -d lunarwing <<'SQL'
-- Disable triggers and constraints during import
SET session_replication_role = 'replica';

-- Clear any seed data that might conflict (e.g. leak_detection_patterns)
TRUNCATE leak_detection_patterns CASCADE;

-- Import core tables
\copy settings FROM '/tmp/ironclaw-export/settings.csv' WITH (FORMAT csv, HEADER true)
\copy secrets FROM '/tmp/ironclaw-export/secrets.csv' WITH (FORMAT csv, HEADER true)
\copy memory_documents FROM '/tmp/ironclaw-export/memory_documents.csv' WITH (FORMAT csv, HEADER true)
\copy memory_chunks FROM '/tmp/ironclaw-export/memory_chunks.csv' WITH (FORMAT csv, HEADER true)
\copy routines FROM '/tmp/ironclaw-export/routines.csv' WITH (FORMAT csv, HEADER true)
\copy leak_detection_patterns FROM '/tmp/ironclaw-export/leak_detection_patterns.csv' WITH (FORMAT csv, HEADER true)

-- Import history tables (optional)
\copy conversations FROM '/tmp/ironclaw-export/conversations.csv' WITH (FORMAT csv, HEADER true)
\copy conversation_messages FROM '/tmp/ironclaw-export/conversation_messages.csv' WITH (FORMAT csv, HEADER true)
\copy routine_runs FROM '/tmp/ironclaw-export/routine_runs.csv' WITH (FORMAT csv, HEADER true)
\copy agent_jobs FROM '/tmp/ironclaw-export/agent_jobs.csv' WITH (FORMAT csv, HEADER true)
\copy job_events FROM '/tmp/ironclaw-export/job_events.csv' WITH (FORMAT csv, HEADER true)
\copy job_actions FROM '/tmp/ironclaw-export/job_actions.csv' WITH (FORMAT csv, HEADER true)
\copy tool_failures FROM '/tmp/ironclaw-export/tool_failures.csv' WITH (FORMAT csv, HEADER true)

-- Re-enable triggers
SET session_replication_role = 'origin';
SQL
```

### Handling import errors

If a `\copy` fails due to type mismatch:

1. Check the specific column and error message
2. Inspect the CSV: `head -2 /tmp/ironclaw-export/table.csv` to see headers and a sample row
3. Compare with the PG schema: `\d table_name` in psql
4. Fix the CSV data or use an INSERT with explicit casting:

```sql
-- Example: manually insert with type cast for a problematic column
INSERT INTO some_table (id, data, is_active)
SELECT id, data::jsonb, (is_active::int)::boolean
FROM temp_import_table;
```

## Step 6: Reset Sequences

After importing, PostgreSQL sequences need to be updated so new inserts don't collide with imported IDs:

```bash
PGPASSWORD=lunarwing psql -h 127.0.0.1 -p "$PG_PORT" -U lunarwing -d lunarwing <<'SQL'
-- Reset all sequences to max(id) + 1
DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN
        SELECT c.relname AS table_name, a.attname AS column_name,
               pg_get_serial_sequence(c.relname::text, a.attname::text) AS seq_name
        FROM pg_class c
        JOIN pg_attribute a ON a.attrelid = c.oid
        WHERE pg_get_serial_sequence(c.relname::text, a.attname::text) IS NOT NULL
          AND c.relkind = 'r'
    LOOP
        EXECUTE format('SELECT setval(%L, COALESCE((SELECT MAX(%I) FROM %I), 0) + 1, false)',
            r.seq_name, r.column_name, r.table_name);
    END LOOP;
END $$;
SQL
```

## Step 7: Handle Vector Columns

If your libSQL database has vector embeddings in `memory_chunks` (used for semantic search), these are stored as BLOBs in SQLite but as pgvector `VECTOR` type in PostgreSQL. The CSV export won't handle these correctly.

Options:
1. **Skip vectors** — let LunarWing re-generate embeddings on startup or on next memory access. The text content is preserved; only the search index vectors are lost.
2. **Export as hex and convert** — more complex, requires knowing the vector dimensions:

```bash
# Export vector column as hex
sqlite3 "$LIBSQL_DB" "SELECT id, hex(embedding) FROM memory_chunks WHERE embedding IS NOT NULL;" > "$EXPORT_DIR/vectors.txt"
```

Then write a script to convert the hex BLOBs to pgvector format (`[0.1, 0.2, ...]`). This is usually not worth the effort — regenerating embeddings is simpler.

To clear the vector column and let it regenerate:

```sql
UPDATE memory_chunks SET embedding = NULL;
```

## Step 8: Copy Workspace Files

Same as the PostgreSQL migration. The tenant's `LUNARWING_BASE_DIR` is `/home/<tenant>/lunarwing/state/`:

```bash
sudo cp -r /path/to/.ironclaw/projects /home/<tenant>/lunarwing/state/ && \
sudo cp -r /path/to/.ironclaw/workspace-template /home/<tenant>/lunarwing/state/ && \
sudo cp -r /path/to/.ironclaw/xmpp /home/<tenant>/lunarwing/state/ && \
sudo chown -R <tenant>:<tenant> /home/<tenant>/lunarwing/state/
```

Skip: `.env`, `ironclaw.db`, `ironclaw.pid`, `history`, `memory_hygiene_state.json`, `tools/`, `channels/` (rebuilt via `build-tenant --with-wasm`).

## Step 9: Secrets / Master Key

Same as PostgreSQL migration — the `secrets` table has AES-256-GCM encrypted data tied to the original user's keychain. Copy the master key to the tenant user's home directory.

## Step 10: Build and Start

```bash
sudo ic/scripts/lunarwing-mt-admin.sh build-tenant <name> --with-wasm
sudo ic/scripts/lunarwing-mt-admin.sh start-tenant <name>
sudo ic/scripts/lunarwing-mt-admin.sh status <name>
```

## Step 11: Verify

```bash
# Check data is accessible
PGPASSWORD=lunarwing psql -h 127.0.0.1 -p <tenant_pg_port> -U lunarwing -d lunarwing \
  -c "SELECT COUNT(*) FROM routines; SELECT COUNT(*) FROM memory_documents;"

# Check gateway
curl -s http://127.0.0.1:<gateway_port>/api/status

# Get auth token
sudo ic/scripts/lunarwing-mt-admin.sh tokens <name>
```

## Minimal Migration (Recommended for Small Instances)

If you don't need full conversation history, migrate only the essential tables:

| Table | Why |
|-------|-----|
| `routines` | Scheduled tasks and their configuration |
| `secrets` | Encrypted API keys and credentials |
| `settings` | Agent preferences |
| `memory_documents` | Workspace memory content |
| `memory_chunks` | Memory search index (vectors can be regenerated) |
| `leak_detection_patterns` | Custom leak detection rules |

Skip: `conversations`, `conversation_messages`, `agent_jobs`, `job_events`, `job_actions`, `routine_runs`, `tool_failures`, `estimation_snapshots`, `llm_calls`. This is all history that doesn't affect agent operation.

## Troubleshooting

### Boolean column errors

If you get errors like `invalid input syntax for type boolean`:

```bash
# Convert 0/1 to true/false in the CSV
sed -i 's/,0,/,false,/g; s/,1,/,true,/g; s/,0$/,false/; s/,1$/,true/' "$EXPORT_DIR/affected_table.csv"
```

### JSONB column errors

If a column expects JSONB but the CSV contains unescaped JSON:

```bash
# Check if the JSON is valid
python3 -c "import csv, json; [json.loads(row[COL_INDEX]) for row in csv.reader(open('/tmp/ironclaw-export/table.csv'))]"
```

PostgreSQL's `\copy` handles JSON in CSV correctly as long as the JSON is properly quoted in the CSV format (which sqlite3's `-csv` mode does).

### UUID column errors

If UUIDs were stored without hyphens in libSQL:

```sql
-- After import, if needed:
UPDATE table_name SET id = regexp_replace(id, '(.{8})(.{4})(.{4})(.{4})(.{12})', '\1-\2-\3-\4-\5');
```

### Foreign key violations

If importing history tables fails due to foreign key constraints, import in dependency order:
1. `conversations` (referenced by `conversation_messages`)
2. `agent_jobs` (referenced by `job_events`, `job_actions`)
3. Then child tables

Or use `SET session_replication_role = 'replica'` (shown in Step 5) to skip constraint checks during import.

## Tips

* You may use ic/scripts/export-libsql.sh to help export your libsql ironclaw database to csv

## Rollback

The original libSQL database file is never modified. To roll back:

```bash
sudo ic/scripts/lunarwing-mt-admin.sh stop-tenant <name>
# Restart original IronClaw service pointing at the original ironclaw.db
```
