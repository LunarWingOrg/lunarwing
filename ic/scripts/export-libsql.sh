#!/usr/bin/env bash
set -euo pipefail

# Edit these
LIBSQL_DB="/home/user/.ironclaw/ironclaw.db"
EXPORT_DIR="/tmp/ironclaw-export"

mkdir -p "$EXPORT_DIR"

tables=(
    routines
    settings
    secrets
    memory_documents
    memory_chunks
    leak_detection_patterns
    conversations
    conversation_messages
    routine_runs
    agent_jobs
    job_events
    job_actions
    tool_failures
)

for table in "${tables[@]}"; do
    if sqlite3 "$LIBSQL_DB" "SELECT 1 FROM \"$table\" LIMIT 1;" &>/dev/null; then
        sqlite3 "$LIBSQL_DB" <<EOSQL > "$EXPORT_DIR/$table.csv"
.headers on
.mode csv
SELECT * FROM $table;
EOSQL
        count=$(wc -l < "$EXPORT_DIR/$table.csv")
        echo "  $table: $((count - 1)) rows"
    else
        echo "  $table: skipped (table not found)"
    fi
done

echo ""
echo "Exported to $EXPORT_DIR"
ls -lh "$EXPORT_DIR"
