#!/usr/bin/env bash
set -euo pipefail

#change these obviously
EXPORT_DIR="/tmp/lunarwing-export"
PG_PORT=10023
PG_USER=lunarwing
PG_DB=lunarwing
PG_PASS=changeme

PSQL="PGPASSWORD=$PG_PASS psql -h 127.0.0.1 -p $PG_PORT -U $PG_USER -d $PG_DB -v export_dir='$EXPORT_DIR'"

echo "=== Pre-processing CSVs ==="

# Fix memory_chunks: remove _rowid column, null out binary embedding
echo "  Fixing memory_chunks.csv (removing _rowid, nulling embedding)..."
python3 -c "
import csv, sys
with open('$EXPORT_DIR/memory_chunks.csv') as f:
    reader = csv.DictReader(f)
    out_cols = ['id','document_id','chunk_index','content','created_at']
    writer = csv.DictWriter(sys.stdout, fieldnames=out_cols)
    writer.writeheader()
    for row in reader:
        writer.writerow({c: row[c] for c in out_cols})
" > "$EXPORT_DIR/memory_chunks_fixed.csv"

echo "  Done."

echo ""
echo "=== Importing into PostgreSQL (port $PG_PORT) ==="

eval $PSQL <<'SQL'
\set settings_csv :export_dir '/settings.csv'
\set secrets_csv :export_dir '/secrets.csv'
\set memory_documents_csv :export_dir '/memory_documents.csv'
\set memory_chunks_fixed_csv :export_dir '/memory_chunks_fixed.csv'
\set routines_csv :export_dir '/routines.csv'
\set leak_detection_patterns_csv :export_dir '/leak_detection_patterns.csv'
\set conversations_csv :export_dir '/conversations.csv'
\set conversation_messages_csv :export_dir '/conversation_messages.csv'
\set routine_runs_csv :export_dir '/routine_runs.csv'
\set agent_jobs_csv :export_dir '/agent_jobs.csv'
\set job_events_csv :export_dir '/job_events.csv'
\set job_actions_csv :export_dir '/job_actions.csv'
\set tool_failures_csv :export_dir '/tool_failures.csv'

-- Disable FK checks during import
SET session_replication_role = 'replica';

-- Clear seed data that might conflict
TRUNCATE leak_detection_patterns CASCADE;

-- === Core tables ===

\echo '  settings...'
\copy settings(user_id,key,value,updated_at) FROM :'settings_csv' WITH (FORMAT csv, HEADER true)

\echo '  secrets...'
\copy secrets(id,user_id,name,encrypted_value,key_salt,provider,expires_at,last_used_at,usage_count,created_at,updated_at) FROM :'secrets_csv' WITH (FORMAT csv, HEADER true)

\echo '  memory_documents...'
\copy memory_documents(id,user_id,agent_id,path,content,created_at,updated_at,metadata) FROM :'memory_documents_csv' WITH (FORMAT csv, HEADER true)

\echo '  memory_chunks (without embedding)...'
\copy memory_chunks(id,document_id,chunk_index,content,created_at) FROM :'memory_chunks_fixed_csv' WITH (FORMAT csv, HEADER true)

\echo '  routines (V18 retry cols will use defaults)...'
\copy routines(id,name,description,user_id,enabled,trigger_type,trigger_config,action_type,action_config,cooldown_secs,max_concurrent,dedup_window_secs,notify_channel,notify_user,notify_on_success,notify_on_failure,notify_on_attention,state,last_run_at,next_fire_at,run_count,consecutive_failures,created_at,updated_at) FROM :'routines_csv' WITH (FORMAT csv, HEADER true)

\echo '  leak_detection_patterns...'
\copy leak_detection_patterns(id,name,pattern,severity,action,enabled,created_at) FROM :'leak_detection_patterns_csv' WITH (FORMAT csv, HEADER true)

-- === History tables ===

\echo '  conversations...'
\copy conversations(id,channel,user_id,thread_id,started_at,last_activity,metadata,source_channel) FROM :'conversations_csv' WITH (FORMAT csv, HEADER true)

\echo '  conversation_messages...'
\copy conversation_messages(id,conversation_id,role,content,created_at) FROM :'conversation_messages_csv' WITH (FORMAT csv, HEADER true)

\echo '  routine_runs...'
\copy routine_runs(id,routine_id,trigger_type,trigger_detail,started_at,completed_at,status,result_summary,tokens_used,job_id,created_at) FROM :'routine_runs_csv' WITH (FORMAT csv, HEADER true)

\echo '  agent_jobs...'
\copy agent_jobs(id,marketplace_job_id,conversation_id,title,description,category,status,source,user_id,project_dir,job_mode,budget_amount,budget_token,bid_amount,estimated_cost,estimated_time_secs,estimated_value,actual_cost,actual_time_secs,success,failure_reason,stuck_since,repair_attempts,created_at,started_at,completed_at,max_tokens,total_tokens_used) FROM :'agent_jobs_csv' WITH (FORMAT csv, HEADER true)

\echo '  job_events...'
\copy job_events(id,job_id,event_type,data,created_at) FROM :'job_events_csv' WITH (FORMAT csv, HEADER true)

\echo '  job_actions...'
\copy job_actions(id,job_id,sequence_num,tool_name,input,output_raw,output_sanitized,sanitization_warnings,cost,duration_ms,success,error_message,created_at) FROM :'job_actions_csv' WITH (FORMAT csv, HEADER true)

\echo '  tool_failures...'
\copy tool_failures(id,tool_name,error_message,error_count,first_failure,last_failure,last_build_result,repaired_at,repair_attempts) FROM :'tool_failures_csv' WITH (FORMAT csv, HEADER true)

-- Re-enable FK checks
SET session_replication_role = 'origin';

-- === Reset sequences ===
\echo '  Resetting sequences...'
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

-- === Verify ===
\echo ''
\echo '=== Verification ==='
SELECT 'routines' as tbl, COUNT(*) FROM routines
UNION ALL SELECT 'secrets', COUNT(*) FROM secrets
UNION ALL SELECT 'memory_documents', COUNT(*) FROM memory_documents
UNION ALL SELECT 'memory_chunks', COUNT(*) FROM memory_chunks
UNION ALL SELECT 'conversations', COUNT(*) FROM conversations
UNION ALL SELECT 'conversation_messages', COUNT(*) FROM conversation_messages
UNION ALL SELECT 'routine_runs', COUNT(*) FROM routine_runs
UNION ALL SELECT 'agent_jobs', COUNT(*) FROM agent_jobs
UNION ALL SELECT 'settings', COUNT(*) FROM settings
ORDER BY 1;
SQL

echo ""
echo "=== Import complete ==="
