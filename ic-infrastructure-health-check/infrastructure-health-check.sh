#!/bin/bash
# Infrastructure Health Check - Main Entry Point
# Runs all component checks and aggregates results

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT_DIR="${LUNARWING_BASE_DIR:-${IRONCLAW_BASE_DIR:-$HOME/.lunarwing}}/workspace/reports/health"
LOG_FILE="$REPORT_DIR/health.log"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Ensure report directory exists
mkdir -p "$REPORT_DIR"

# Private per-run scratch dir for the parallel check output. Using a unique
# mktemp -d (instead of fixed /tmp/check-*.tmp paths) avoids collisions between
# concurrent instances — e.g. multiple tenants running the check at once — and
# satisfies the repo's "never hardcode /tmp" rule.
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/lunarwing-health.XXXXXX")"
cleanup_workdir() { rm -rf "$WORKDIR"; }
trap cleanup_workdir EXIT

# Initialize results
components=()
overall_status="healthy"
overall_exit_code=0
alerts=()

# Log function - logs to file and stderr (not stdout to avoid JSON contamination)
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >&2
}

# Detect init system (reuses pattern from ic/scripts/install-lunarwing-watchdog.sh)
detect_service_manager() {
  local override="${LUNARWING_SERVICE_MANAGER:-}"
  if [[ -n "$override" ]]; then
    case "${override,,}" in
      systemd) printf 'systemd'; return 0 ;;
      openrc)  printf 'openrc';  return 0 ;;
      launchd) printf 'launchd'; return 0 ;;
    esac
  fi
  [[ "$(uname -s)" == "Darwin" ]] && { printf 'launchd'; return 0; }
  [[ -e /run/openrc/softlevel ]] && { printf 'openrc'; return 0; }
  [[ -e /run/systemd/system ]]   && { printf 'systemd'; return 0; }
  command -v rc-service >/dev/null 2>&1 && ! command -v systemctl >/dev/null 2>&1 && { printf 'openrc'; return 0; }
  command -v systemctl >/dev/null 2>&1 && { printf 'systemd'; return 0; }
  command -v rc-service >/dev/null 2>&1 && { printf 'openrc'; return 0; }
  printf 'unknown'; return 0
}

# Run a health check
run_check() {
    local script=$1
    local component=$2

    log "Running $component health check..."

    local start=$(date +%s)
    local output
    local exit_code=0

    # Run the check with timeout, capture stdout (JSON) and stderr (logs) separately
    local stderr_file
    stderr_file=$(mktemp "$WORKDIR/check-stderr.XXXXXX")
    output=$(timeout 30 "$SCRIPT_DIR/$script" 2>"$stderr_file") || exit_code=$?
    # Append any stderr from the check to the log
    [ -s "$stderr_file" ] && cat "$stderr_file" >> "$LOG_FILE"
    rm -f "$stderr_file"
    local end=$(date +%s)
    local duration=$((end - start))

    if [ $exit_code -eq 124 ]; then
        log "WARNING: $component check timed out after 30 seconds"
        echo "{\"component\": \"$component\", \"status\": \"unknown\", \"error\": \"timeout\"}"
        return 1
    fi

    if [ $exit_code -ne 0 ] && [ -z "$output" ]; then
        log "ERROR: $component check failed with exit code $exit_code (no output)"
        echo "{\"component\": \"$component\", \"status\": \"unknown\", \"error\": \"check_failed\"}"
        return $exit_code
    fi

    # Validate JSON output
    if ! echo "$output" | jq . >/dev/null 2>&1; then
        log "ERROR: $component check returned invalid JSON"
        echo "{\"component\": \"$component\", \"status\": \"unknown\", \"error\": \"invalid_json\"}"
        return 1
    fi

    echo "$output"
    log "$component check completed in ${duration}s (exit: $exit_code)"
    return $exit_code
}

# Run all health checks
log "=== Starting Infrastructure Health Check ==="

# Detect init system before launching checks
SERVICE_MANAGER=$(detect_service_manager)
log "Detected service manager: $SERVICE_MANAGER"

# Run checks in parallel for speed using temp files (stdout only for JSON)
run_check "health-gateway.sh" "gateway" > "$WORKDIR/check-gateway.tmp" 2> "$WORKDIR/log-gateway.tmp" &
run_check "health-xmpp.sh" "xmpp" > "$WORKDIR/check-xmpp.tmp" 2> "$WORKDIR/log-xmpp.tmp" &
run_check "health-omemo.sh" "omemo" > "$WORKDIR/check-omemo.tmp" 2> "$WORKDIR/log-omemo.tmp" &
run_check "health-ratelimit.sh" "ratelimit" > "$WORKDIR/check-ratelimit.tmp" 2> "$WORKDIR/log-ratelimit.tmp" &
run_check "health-clickhouse.sh" "clickhouse" > "$WORKDIR/check-clickhouse.tmp" 2> "$WORKDIR/log-clickhouse.tmp" &
run_check "health-tensorzero.sh" "tensorzero" > "$WORKDIR/check-tensorzero.tmp" 2> "$WORKDIR/log-tensorzero.tmp" &
run_check "health-models.sh" "models" > "$WORKDIR/check-models.tmp" 2> "$WORKDIR/log-models.tmp" &
run_check "health-lunarvision.sh" "lunarvision" > "$WORKDIR/check-lunarvision.tmp" 2> "$WORKDIR/log-lunarvision.tmp" &
case "$SERVICE_MANAGER" in
  systemd) run_check "health-systemd.sh" "systemd" > "$WORKDIR/check-svcmgr.tmp" 2> "$WORKDIR/log-svcmgr.tmp" & ;;
  openrc)  run_check "health-openrc.sh"  "openrc"  > "$WORKDIR/check-svcmgr.tmp" 2> "$WORKDIR/log-svcmgr.tmp" & ;;
  launchd) run_check "health-launchd.sh" "launchd" > "$WORKDIR/check-svcmgr.tmp" 2> "$WORKDIR/log-svcmgr.tmp" & ;;
  *)       log "WARNING: unknown service manager '$SERVICE_MANAGER', skipping service health check" ;;
esac

# Wait for all checks to complete (don't let individual failures kill the script)
wait || true

# Append logs to main log file
for comp in gateway xmpp omemo ratelimit clickhouse tensorzero models lunarvision svcmgr; do
    [ -f "$WORKDIR/log-${comp}.tmp" ] && cat "$WORKDIR/log-${comp}.tmp" >> "$LOG_FILE" && rm -f "$WORKDIR/log-${comp}.tmp"
done

# Read results from temp files
check_gateway=$(cat "$WORKDIR/check-gateway.tmp" 2>/dev/null || echo)
check_xmpp=$(cat "$WORKDIR/check-xmpp.tmp" 2>/dev/null || echo)
check_omemo=$(cat "$WORKDIR/check-omemo.tmp" 2>/dev/null || echo)
check_ratelimit=$(cat "$WORKDIR/check-ratelimit.tmp" 2>/dev/null || echo)
check_clickhouse=$(cat "$WORKDIR/check-clickhouse.tmp" 2>/dev/null || echo)
check_tensorzero=$(cat "$WORKDIR/check-tensorzero.tmp" 2>/dev/null || echo)
check_models=$(cat "$WORKDIR/check-models.tmp" 2>/dev/null || echo)
check_lunarvision=$(cat "$WORKDIR/check-lunarvision.tmp" 2>/dev/null || echo)
check_svcmgr=$(cat "$WORKDIR/check-svcmgr.tmp" 2>/dev/null || echo)

# Cleanup temp files (the WORKDIR itself is removed by the EXIT trap)
rm -f "$WORKDIR"/check-*.tmp

# Collect results
components=(
    "$check_gateway"
    "$check_xmpp"
    "${check_omemo:-}"
    "${check_ratelimit:-}"
    "$check_clickhouse"
    "$check_tensorzero"
    "$check_models"
    "$check_lunarvision"
    "${check_svcmgr:-}"
)

# Aggregate results and determine overall status
for component_json in "${components[@]}"; do
    if [ -n "$component_json" ]; then
        status=$(echo "$component_json" | jq -r '.status // "unknown"')
        component_name=$(echo "$component_json" | jq -r '.component // "unknown"')

        # Update overall status
        case $status in
            "critical")
                overall_status="critical"
                overall_exit_code=2
                alerts+=("{\"component\": \"$component_name\", \"severity\": \"critical\", \"message\": \"$component_name is critical\"}")
                ;;
            "degraded")
                if [ "$overall_status" != "critical" ]; then
                    overall_status="degraded"
                    overall_exit_code=1
                fi
                alerts+=("{\"component\": \"$component_name\", \"severity\": \"warning\", \"message\": \"$component_name is degraded\"}")
                ;;
            "unknown")
                if [ "$overall_status" = "healthy" ]; then
                    overall_status="degraded"
                    overall_exit_code=1
                fi
                alerts+=("{\"component\": \"$component_name\", \"severity\": \"warning\", \"message\": \"$component_name status unknown\"}")
                ;;
        esac
    fi
done

# Build components array (filter out empty entries)
components_json=""
for comp in "$check_gateway" "$check_xmpp" \
    "${check_omemo:-}" "${check_ratelimit:-}" \
    "$check_clickhouse" "$check_tensorzero" \
    "$check_models" "$check_lunarvision" \
    "${check_svcmgr:-}"; do
    if [ -n "$comp" ] && echo "$comp" | jq . >/dev/null 2>&1; then
        if [ -n "$components_json" ]; then
            components_json="$components_json,$comp"
        else
            components_json="$comp"
        fi
    fi
done

# Build alerts array JSON
alerts_json="[]"
if [ ${#alerts[@]} -gt 0 ]; then
    alerts_json=$(printf '%s\n' "${alerts[@]}" | jq -s .)
fi

# Generate final report
report_json=$(cat <<EOF
{
  "timestamp": "$TIMESTAMP",
  "overall_status": "$overall_status",
  "components": [$components_json],
  "alerts": $alerts_json
}
EOF
)

# Validate final JSON
if echo "$report_json" | jq . >/dev/null 2>&1; then
    # Save report
    report_file="$REPORT_DIR/$(date +%Y-%m-%dT%H:%M:%SZ).json"
    echo "$report_json" | jq . > "$report_file"

    # Rotate old reports — keep last 7 days (168 hours)
    find "$REPORT_DIR" -maxdepth 1 -name '*.json' -mtime +7 -delete 2>/dev/null || true
    find "$REPORT_DIR" -maxdepth 1 -name '*-summary.md' -mtime +7 -delete 2>/dev/null || true

    # Generate human-readable summary
    summary_file="$REPORT_DIR/$(date +%Y-%m-%dT%H:%M:%SZ)-summary.md"
    echo "# Infrastructure Health Check - $(date '+%Y-%m-%d %H:%M UTC')" > "$summary_file"
    echo "" >> "$summary_file"
    echo "**Overall Status:** $overall_status" >> "$summary_file"
    echo "" >> "$summary_file"
    echo "## Component Status" >> "$summary_file"
    echo "" >> "$summary_file"

    for component_json in "${components[@]}"; do
        if [ -n "$component_json" ] && echo "$component_json" | jq . >/dev/null 2>&1; then
            comp=$(echo "$component_json" | jq -r '.component')
            status=$(echo "$component_json" | jq -r '.status')
            echo "- **$comp:** $status" >> "$summary_file"
        fi
    done

    echo "" >> "$summary_file"
    echo "## Alerts" >> "$summary_file"
    echo "" >> "$summary_file"

    if [ ${#alerts[@]} -gt 0 ]; then
        for alert in "${alerts[@]}"; do
            comp=$(echo "$alert" | jq -r '.component')
            severity=$(echo "$alert" | jq -r '.severity')
            message=$(echo "$alert" | jq -r '.message')
            echo "- **$severity:** $comp - $message" >> "$summary_file"
        done
    else
        echo "- No alerts" >> "$summary_file"
    fi

    log "Health check completed. Overall status: $overall_status"
    log "Report saved: $report_file"
    log "Summary saved: $summary_file"

    # Output final JSON
    echo "$report_json" | jq .
else
    log "ERROR: Failed to generate valid JSON report"
    echo "{\"error\": \"failed_to_generate_report\", \"timestamp\": \"$TIMESTAMP\"}"
    exit 2
fi

# Send notification if degraded or critical. HEALTHCHECK_NOTIFY=false suppresses
# this per-run notify (e.g. multi-tenant hosts where only self-heal ESCALATIONS
# should page; set in /etc/lunarwing/health.env). Default true = unchanged.
if [ "$overall_status" != "healthy" ] && [ "${HEALTHCHECK_NOTIFY:-true}" = "true" ]; then
    if [ -x "$SCRIPT_DIR/send-notification.sh" ]; then
        "$SCRIPT_DIR/send-notification.sh" "$overall_status" "$report_file" || log "WARNING: Failed to send notification"
    else
        log "WARNING: send-notification.sh not found or not executable at $SCRIPT_DIR/send-notification.sh"
    fi
fi

exit $overall_exit_code
