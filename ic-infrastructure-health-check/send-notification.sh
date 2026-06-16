#!/bin/bash
# Send Gotify Notification for Health Check Results

set -euo pipefail

# Configuration
GOTIFY_URL="${GOTIFY_URL:-http://localhost:3000}"
GOTIFY_TOKEN="${GOTIFY_TOKEN:-}"

# Arguments
status="${1:-unknown}"
report_file="${2:-}"

# Exit if no Gotify token configured
if [ -z "$GOTIFY_TOKEN" ]; then
    echo "GOTIFY_TOKEN not set, skipping notification"
    exit 0
fi

# Determine priority based on status
priority=3
title="Infrastructure Health Check"
message=""

case $status in
    "healthy")
        # Don't send notification for healthy status
        exit 0
        ;;
    "degraded")
        priority=6
        title="⚠️ Infrastructure Degraded"
        ;;
    "critical")
        priority=8
        title="🚨 Infrastructure Critical"
        ;;
    *)
        priority=5
        title="📊 Infrastructure Health Unknown"
        ;;
esac

# Build message from latest report. Two shapes are passed in: a full health
# report (.overall_status/.components/.alerts) from infrastructure-health-check,
# and a per-service escalation object ({escalated,service,reason,...}) from
# self-heal's escalate_service. The escalation shape lacks .overall_status, so
# the old renderer hit `null | ascii_upcase`, jq-aborted under set -e, and the
# page was silently dropped. Branch on .escalated and null-default every field so
# a malformed/unexpected shape can never abort before curl.
if [ -n "$report_file" ] && [ -f "$report_file" ]; then
    message=$(jq -r --arg report_file "$report_file" '
        if .escalated == true then
            "🚨 Service escalation — manual intervention\n" +
            "Service: " + (.service // "?") + "\n" +
            "Reason:  " + (.reason // "?") + "\n" +
            "Retries: " + ((.retries // 0) | tostring) + "\n" +
            "Action:  " + (.action // "manual_intervention_required") + "\n" +
            "Time:    " + (.timestamp // "?")
        else
            "Overall: " + ((.overall_status // "unknown") | ascii_upcase) + "\n\n" +
            "Components:\n" + ([.components[]? | "- " + (.component // "?") + ": " + (.status // "?")] | join("\n")) +
            "\n\n" +
            (if ((.alerts // []) | length) > 0 then "Issues:\n" + ([.alerts[]? | "- " + (.message // "?")] | join("\n")) + "\n\n" else "" end) +
            "Full report: " + $report_file
        end
    ' "$report_file" 2>/dev/null) || message="Infrastructure alert ($status); report at $report_file"
else
    message="Infrastructure health check completed with status: $status"
fi

# Build the JSON payload with jq so newlines/quotes in the message are escaped
# correctly (the previous hand-built JSON broke on the message's literal newlines).
payload=$(jq -n --arg title "$title" --arg message "$message" --argjson priority "$priority" \
    '{title: $title, message: $message, priority: $priority}')

# Send to Gotify
http_code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 10 --max-time 15 \
    -X POST "$GOTIFY_URL/message" \
    -H "Content-Type: application/json" \
    -H "X-Gotify-Key: $GOTIFY_TOKEN" \
    -d "$payload")

if [ "$http_code" = "200" ]; then
    echo "Notification sent: $title"
else
    echo "Notification FAILED (HTTP $http_code): $title" >&2
    exit 1
fi
