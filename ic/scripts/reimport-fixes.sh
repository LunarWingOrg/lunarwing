#!/usr/bin/env bash
set -euo pipefail

#change these obviously
LIBSQL_DB="/home/cmc/kageho_old/.ironclaw/ironclaw.db"
EXPORT_DIR="/tmp/kageho-export"
PG_PORT=10023
PG_USER=lunarwing
PG_DB=lunarwing
PG_PASS=lunarwing

PSQL="PGPASSWORD=$PG_PASS psql -h 127.0.0.1 -p $PG_PORT -U $PG_USER -d $PG_DB"

echo "=== Fix 1: Secrets (binary BYTEA columns) ==="

# Export secrets with hex-encoded binary columns
python3 << 'PYEOF'
import sqlite3, csv, sys

db = sqlite3.connect("/home/cmc/kageho_old/.ironclaw/ironclaw.db")
cur = db.execute("SELECT id, user_id, name, encrypted_value, key_salt, provider, expires_at, last_used_at, usage_count, created_at, updated_at FROM secrets")

with open("/tmp/kageho-export/secrets_hex.csv", "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["id","user_id","name","encrypted_value_hex","key_salt_hex","provider","expires_at","last_used_at","usage_count","created_at","updated_at"])
    for row in cur:
        r = list(row)
        # Convert binary columns to hex strings
        r[3] = row[3].hex() if isinstance(row[3], bytes) else row[3]
        r[4] = row[4].hex() if isinstance(row[4], bytes) else row[4]
        w.writerow(r)

db.close()
print(f"  Exported secrets with hex encoding")
PYEOF

# Clear and reimport secrets
eval $PSQL << 'SQL'
DELETE FROM secrets;

CREATE TEMP TABLE secrets_import (
    id TEXT, user_id TEXT, name TEXT,
    encrypted_value_hex TEXT, key_salt_hex TEXT,
    provider TEXT, expires_at TEXT, last_used_at TEXT,
    usage_count TEXT, created_at TEXT, updated_at TEXT
);

\copy secrets_import FROM '/tmp/kageho-export/secrets_hex.csv' WITH (FORMAT csv, HEADER true)

INSERT INTO secrets (id, user_id, name, encrypted_value, key_salt, provider, expires_at, last_used_at, usage_count, created_at, updated_at)
SELECT
    id::uuid, user_id, name,
    decode(encrypted_value_hex, 'hex'),
    decode(key_salt_hex, 'hex'),
    provider,
    NULLIF(expires_at, '')::timestamptz,
    NULLIF(last_used_at, '')::timestamptz,
    usage_count::bigint,
    created_at::timestamptz,
    updated_at::timestamptz
FROM secrets_import;

DROP TABLE secrets_import;
SELECT COUNT(*) AS secrets_imported FROM secrets;
SQL

echo ""
echo "=== Fix 2: Settings (JSON quoting issues) ==="

# Re-export settings using Python for reliable CSV handling
python3 << 'PYEOF'
import sqlite3, csv

db = sqlite3.connect("/home/cmc/kageho_old/.ironclaw/ironclaw.db")
cur = db.execute("SELECT user_id, key, value, updated_at FROM settings")

with open("/tmp/kageho-export/settings_fixed.csv", "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["user_id","key","value","updated_at"])
    count = 0
    for row in cur:
        w.writerow(row)
        count += 1

db.close()
print(f"  Exported {count} settings rows via Python csv")
PYEOF

eval $PSQL << 'SQL'
DELETE FROM settings;
\copy settings(user_id,key,value,updated_at) FROM '/tmp/kageho-export/settings_fixed.csv' WITH (FORMAT csv, HEADER true)
SELECT COUNT(*) AS settings_imported FROM settings;
SQL

echo ""
echo "=== Fix 3: Agent jobs (multiline descriptions) ==="

python3 << 'PYEOF'
import sqlite3, csv

db = sqlite3.connect("/home/cmc/kageho_old/.ironclaw/ironclaw.db")
cur = db.execute("""
    SELECT id, marketplace_job_id, conversation_id, title, description,
           category, status, source, user_id, project_dir, job_mode,
           budget_amount, budget_token, bid_amount, estimated_cost,
           estimated_time_secs, estimated_value, actual_cost, actual_time_secs,
           success, failure_reason, stuck_since, repair_attempts,
           created_at, started_at, completed_at, max_tokens, total_tokens_used
    FROM agent_jobs
""")

with open("/tmp/kageho-export/agent_jobs_fixed.csv", "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["id","marketplace_job_id","conversation_id","title","description",
                "category","status","source","user_id","project_dir","job_mode",
                "budget_amount","budget_token","bid_amount","estimated_cost",
                "estimated_time_secs","estimated_value","actual_cost","actual_time_secs",
                "success","failure_reason","stuck_since","repair_attempts",
                "created_at","started_at","completed_at","max_tokens","total_tokens_used"])
    count = 0
    for row in cur:
        w.writerow(row)
        count += 1

db.close()
print(f"  Exported {count} agent_jobs rows via Python csv")
PYEOF

eval $PSQL << 'SQL'
SET session_replication_role = 'replica';
DELETE FROM job_actions;
DELETE FROM job_events;
DELETE FROM agent_jobs;

\copy agent_jobs(id,marketplace_job_id,conversation_id,title,description,category,status,source,user_id,project_dir,job_mode,budget_amount,budget_token,bid_amount,estimated_cost,estimated_time_secs,estimated_value,actual_cost,actual_time_secs,success,failure_reason,stuck_since,repair_attempts,created_at,started_at,completed_at,max_tokens,total_tokens_used) FROM '/tmp/kageho-export/agent_jobs_fixed.csv' WITH (FORMAT csv, HEADER true)
SELECT COUNT(*) AS agent_jobs_imported FROM agent_jobs;
SET session_replication_role = 'origin';
SQL

echo ""
echo "=== Fix 3b: Re-import job_events and job_actions ==="

python3 << 'PYEOF'
import sqlite3, csv

db = sqlite3.connect("/home/cmc/kageho_old/.ironclaw/ironclaw.db")

for table, cols in [
    ("job_events", ["id","job_id","event_type","data","created_at"]),
    ("job_actions", ["id","job_id","sequence_num","tool_name","input","output_raw","output_sanitized","sanitization_warnings","cost","duration_ms","success","error_message","created_at"]),
]:
    cur = db.execute(f"SELECT {','.join(cols)} FROM {table}")
    with open(f"/tmp/kageho-export/{table}_fixed.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(cols)
        count = 0
        for row in cur:
            w.writerow(row)
            count += 1
    print(f"  Exported {count} {table} rows via Python csv")

db.close()
PYEOF

eval $PSQL << 'SQL'
SET session_replication_role = 'replica';

\echo '  job_events...'
\copy job_events(id,job_id,event_type,data,created_at) FROM '/tmp/kageho-export/job_events_fixed.csv' WITH (FORMAT csv, HEADER true)

\echo '  job_actions...'
\copy job_actions(id,job_id,sequence_num,tool_name,input,output_raw,output_sanitized,sanitization_warnings,cost,duration_ms,success,error_message,created_at) FROM '/tmp/kageho-export/job_actions_fixed.csv' WITH (FORMAT csv, HEADER true)

SET session_replication_role = 'origin';
SQL

echo ""
echo "=== Fix 4: Reset sequences (public schema only) ==="

eval $PSQL << 'SQL'
DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN
        SELECT c.relname AS table_name, a.attname AS column_name,
               pg_get_serial_sequence(c.relname::text, a.attname::text) AS seq_name
        FROM pg_class c
        JOIN pg_attribute a ON a.attrelid = c.oid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE pg_get_serial_sequence(c.relname::text, a.attname::text) IS NOT NULL
          AND c.relkind = 'r'
          AND n.nspname = 'public'
    LOOP
        EXECUTE format('SELECT setval(%L, COALESCE((SELECT MAX(%I) FROM %I), 0) + 1, false)',
            r.seq_name, r.column_name, r.table_name);
    END LOOP;
END $$;
\echo 'Sequences reset.'
SQL

echo ""
echo "=== Final verification ==="

eval $PSQL << 'SQL'
SELECT 'routines' as tbl, COUNT(*) FROM routines
UNION ALL SELECT 'secrets', COUNT(*) FROM secrets
UNION ALL SELECT 'settings', COUNT(*) FROM settings
UNION ALL SELECT 'memory_documents', COUNT(*) FROM memory_documents
UNION ALL SELECT 'memory_chunks', COUNT(*) FROM memory_chunks
UNION ALL SELECT 'conversations', COUNT(*) FROM conversations
UNION ALL SELECT 'conversation_messages', COUNT(*) FROM conversation_messages
UNION ALL SELECT 'routine_runs', COUNT(*) FROM routine_runs
UNION ALL SELECT 'agent_jobs', COUNT(*) FROM agent_jobs
UNION ALL SELECT 'job_events', COUNT(*) FROM job_events
UNION ALL SELECT 'job_actions', COUNT(*) FROM job_actions
ORDER BY 1;
SQL
