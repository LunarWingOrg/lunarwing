#!/bin/bash
# Health Check: launchd agents (macOS)
# Checks: agent load state, PID liveness, last exit status
# Output: JSON to stdout
# Exit codes: 0=healthy, 1=degraded, 2=critical

set -euo pipefail

AGENTS_DIR="${HOME}/Library/LaunchAgents"

discover_agents() {
  local agents=()

  for plist in "${AGENTS_DIR}"/com.lunarwing.*.plist; do
    [[ -f "$plist" ]] || continue
    local label
    label="$(basename "$plist" .plist)"
    agents+=("$label")
  done

  if [[ ${#agents[@]} -eq 0 ]]; then
    agents=("com.lunarwing.daemon")
  fi

  printf '%s\n' "${agents[@]}"
}

if [[ -n "${AGENTS:-}" ]]; then
  read -r -a AGENTS_ARR <<<"$AGENTS"
else
  mapfile -t AGENTS_ARR < <(discover_agents)
fi

issues=()
agent_results=()
overall_status="healthy"
overall_exit=0

agent_json() {
  local name="$1" state="$2" pid="$3" exit_status="$4" status="$5"
  cat <<EOF
  {
    "name": "$name",
    "state": "$state",
    "pid": $pid,
    "last_exit_status": $exit_status,
    "status": "$status"
  }
EOF
}

for label in "${AGENTS_ARR[@]}"; do
  local_status="healthy"
  local_exit=0
  state="unknown"
  pid=0
  exit_status=0

  output="$(launchctl list "$label" 2>&1)" || true
  list_rc=$?

  if [[ $list_rc -ne 0 ]] || ! printf '%s' "$output" | grep -q "$label"; then
    state="not_loaded"
    local_status="critical"
    local_exit=2
    issues+=("agent not loaded: $label")
  else
    raw_pid="$(printf '%s' "$output" | awk -v lbl="$label" '$3==lbl{print $1}')"
    raw_exit="$(printf '%s' "$output" | awk -v lbl="$label" '$3==lbl{print $2}')"

    if [[ "$raw_pid" == "-" || -z "$raw_pid" ]]; then
      state="stopped"
      pid=0
      exit_status="${raw_exit:-0}"
      local_status="critical"
      local_exit=2
      issues+=("$label not running (pid=-)")
    else
      pid="$raw_pid"
      exit_status="${raw_exit:-0}"

      if [[ "$exit_status" != "0" ]]; then
        state="running"
        local_status="degraded"
        local_exit=1
        issues+=("$label last exit status non-zero: $exit_status")
      else
        state="running"
      fi
    fi
  fi

  if [[ $local_exit -gt $overall_exit ]]; then
    overall_exit=$local_exit
    if [[ $overall_exit -eq 2 ]]; then
      overall_status="critical"
    else
      overall_status="degraded"
    fi
  fi

  agent_results+=("$(agent_json "$label" "$state" "$pid" "$exit_status" "$local_status")")
done

issues_json="[]"
if [[ ${#issues[@]} -gt 0 ]]; then
  issues_json=$(printf '%s\n' "${issues[@]}" | jq -R . | jq -s .)
fi

agents_json=$(printf '%s\n' "${agent_results[@]}" | jq -s .)

cat <<EOF
{
  "component": "launchd",
  "status": "$overall_status",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "metrics": {
    "agents": $agents_json
  },
  "issues": $issues_json
}
EOF

exit $overall_exit
