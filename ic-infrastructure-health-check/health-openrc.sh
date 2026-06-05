#!/bin/bash
# Health Check: OpenRC services
# Checks: service state, PID liveness
# Output: JSON to stdout
# Exit codes: 0=healthy, 1=degraded, 2=critical

set -euo pipefail

# Services to check (override via env: SERVICES="xmpp-bridge lunarwing")
# Auto-discovers multi-tenant services from /etc/init.d/ when no override is set.
discover_services() {
  local svcs=()

  # Single-instance defaults
  for svc in lunarwing xmpp-bridge; do
    if [ -x "/etc/init.d/$svc" ]; then
      svcs+=("$svc")
    fi
  done

  # Multi-tenant: lunarwing-<tenant>, xmpp-bridge-<tenant>, lunarwing-proxy-<tenant>
  for initscript in /etc/init.d/lunarwing-* /etc/init.d/xmpp-bridge-* /etc/init.d/lunarwing-proxy-*; do
    [ -x "$initscript" ] || continue
    local name
    name=$(basename "$initscript")
    # Skip the base single-instance names (already added above)
    [[ "$name" = "lunarwing" || "$name" = "xmpp-bridge" ]] && continue
    svcs+=("$name")
  done

  if [ ${#svcs[@]} -eq 0 ]; then
    svcs=("lunarwing" "xmpp-bridge")
  fi

  printf '%s\n' "${svcs[@]}"
}

if [ -n "${SERVICES:-}" ]; then
  read -r -a SERVICES_ARR <<<"$SERVICES"
else
  mapfile -t SERVICES_ARR < <(discover_services)
fi

issues=()
svc_results=()
overall_status="healthy"
overall_exit=0

svc_json() {
  local name="$1" state="$2" pid="$3" status="$4"
  cat <<EOF
  {
    "name": "$name",
    "state": "$state",
    "pid": $pid,
    "status": "$status"
  }
EOF
}

for svc in "${SERVICES_ARR[@]}"; do
  # Check if the init script exists
  if ! rc-service --exists "$svc" >/dev/null 2>&1; then
    issues+=("service not found: $svc")
    svc_results+=("$(svc_json "$svc" "missing" 0 "critical")")
    overall_status="critical"; overall_exit=2
    continue
  fi

  # Get service status
  local_status="healthy"
  local_exit=0
  state="unknown"
  pid=0

  status_output=$(rc-service "$svc" status 2>&1) || true
  rc_exit=$?

  # Parse state from rc-service output (typically "* status: started" or "* status: stopped")
  if echo "$status_output" | grep -qi "started"; then
    state="started"
  elif echo "$status_output" | grep -qi "stopped"; then
    state="stopped"
  elif echo "$status_output" | grep -qi "crashed"; then
    state="crashed"
  elif [ $rc_exit -eq 0 ]; then
    state="started"
  else
    state="stopped"
  fi

  # Try to get PID from pidfile or supervise-daemon
  for pidfile in "/run/${svc}.pid" "/run/${svc}/${svc}.pid" "/var/run/${svc}.pid"; do
    if [ -f "$pidfile" ]; then
      pid=$(cat "$pidfile" 2>/dev/null || echo 0)
      pid=${pid:-0}
      # Validate PID is numeric
      if ! [[ "$pid" =~ ^[0-9]+$ ]]; then
        pid=0
      fi
      break
    fi
  done

  if [ "$state" = "stopped" ] || [ "$state" = "crashed" ]; then
    local_status="critical"; local_exit=2
    issues+=("$svc not running: $state")
  elif [ "$state" = "unknown" ]; then
    local_status="degraded"; local_exit=1
    issues+=("$svc in unexpected state: $state")
  fi

  if [ $local_exit -gt $overall_exit ]; then
    overall_exit=$local_exit
    overall_status=$([ $overall_exit -eq 2 ] && echo critical || echo degraded)
  fi

  svc_results+=("$(svc_json "$svc" "$state" "$pid" "$local_status")")
done

issues_json="[]"
if [ ${#issues[@]} -gt 0 ]; then
  issues_json=$(printf '%s\n' "${issues[@]}" | jq -R . | jq -s .)
fi

svcs_json=$(printf '%s\n' "${svc_results[@]}" | jq -s .)

cat <<EOF
{
  "component": "openrc",
  "status": "$overall_status",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "metrics": {
    "services": $svcs_json
  },
  "issues": $issues_json
}
EOF

exit $overall_exit
