#!/bin/bash
# Health Check: systemd units (services/timers)
# Checks: active state, restart count, last/next timer fire, flapping
# Output: JSON to stdout
# Exit codes: 0=healthy, 1=degraded, 2=critical

set -euo pipefail

# Units to check (override via env)
UNITS_DEFAULT=(
  "lunarwing.service"
  "xmpp-bridge.service"
  "tensorzero-gateway.service"
)

# Allow override: UNITS="a.service b.timer"
if [ -n "${UNITS:-}" ]; then
  read -r -a UNITS_ARR <<<"$UNITS"
else
  UNITS_ARR=("${UNITS_DEFAULT[@]}")
fi

issues=()
unit_results=()
overall_status="healthy"
overall_exit=0

unit_json() {
  local name="$1" active="$2" sub="$3" restarts="$4" extra="$5" status="$6"
  cat <<EOF
  {
    "name": "$name",
    "active_state": "$active",
    "sub_state": "$sub",
    "restart_count": $restarts,
    "status": "$status",
    "extra": $extra
  }
EOF
}

for unit in "${UNITS_ARR[@]}"; do
  if ! systemctl list-unit-files "$unit" >/dev/null 2>&1 && ! systemctl status "$unit" >/dev/null 2>&1; then
    issues+=("unit not found: $unit")
    unit_results+=("$(unit_json "$unit" "missing" "missing" 0 "{}" "critical")")
    overall_status="critical"; overall_exit=2
    continue
  fi

  active=$(systemctl show -p ActiveState --value "$unit" 2>/dev/null || echo "unknown")
  sub=$(systemctl show -p SubState --value "$unit" 2>/dev/null || echo "unknown")
  restarts=$(systemctl show -p NRestarts --value "$unit" 2>/dev/null || echo 0)
  restarts=${restarts:-0}

  extra="{}"
  status="healthy"
  exit_code=0

  if [[ "$unit" == *.timer ]]; then
    last=$(systemctl show -p LastTriggerUSec --value "$unit" 2>/dev/null || echo "")
    next=$(systemctl show -p NextElapseUSecRealtime --value "$unit" 2>/dev/null || echo "")
    extra=$(jq -n --arg last "$last" --arg next "$next" '{last_trigger:$last,next_elapse:$next}')
  else
    since=$(systemctl show -p ActiveEnterTimestamp --value "$unit" 2>/dev/null || echo "")
    extra=$(jq -n --arg since "$since" '{active_since:$since}')
  fi

  if [ "$active" != "active" ]; then
    status="critical"; exit_code=2
    issues+=("$unit not active: $active/$sub")
  elif [ "$restarts" -ge 3 ]; then
    status="degraded"; exit_code=1
    issues+=("$unit restart count elevated: $restarts")
  fi

  if [ $exit_code -gt $overall_exit ]; then
    overall_exit=$exit_code
    overall_status=$([ $overall_exit -eq 2 ] && echo critical || echo degraded)
  fi

  unit_results+=("$(unit_json "$unit" "$active" "$sub" "$restarts" "$extra" "$status")")
done

# ── Per-tenant systemd USER units (multi-tenant) ────────────────────────────
# When a tenant registry exists, also probe each tenant's systemd *user* units
# (lunarwing-<t>, xmpp-bridge-<t>) on the tenant user's bus, and surface them so
# self-heal can remediate them. No-op on single-instance hosts (no registry
# file) — existing behavior is unchanged. Requires root to reach other users'
# --user buses; any unit we cannot positively load is skipped (no false
# criticals). Parallels the tenant discovery in health-openrc.sh.
TENANTS_FILE="${SELF_HEAL_TENANTS_FILE:-${LUNARWING_TENANTS_FILE:-/etc/lunarwing/ports.json}}"
if [ -r "$TENANTS_FILE" ] && command -v jq >/dev/null 2>&1; then
  _tenant_uctl() {  # <user> <uid> <args...> -> systemctl --user output (empty on failure)
    local u="$1" uid="$2"; shift 2
    sudo -n -u "$u" env XDG_RUNTIME_DIR="/run/user/$uid" systemctl --user "$@" 2>/dev/null || true
  }
  while IFS=$'\t' read -r tname tuser; do
    [ -n "$tname" ] && [ -n "$tuser" ] || continue
    tuid=$(id -u "$tuser" 2>/dev/null || echo "")
    [ -n "$tuid" ] || continue
    for tunit in "lunarwing-$tname.service" "xmpp-bridge-$tname.service"; do
      [ "$(_tenant_uctl "$tuser" "$tuid" show -p LoadState --value "$tunit")" = "loaded" ] || continue
      uactive=$(_tenant_uctl "$tuser" "$tuid" show -p ActiveState --value "$tunit"); uactive=${uactive:-unknown}
      usub=$(_tenant_uctl "$tuser" "$tuid" show -p SubState --value "$tunit"); usub=${usub:-unknown}
      urestarts=$(_tenant_uctl "$tuser" "$tuid" show -p NRestarts --value "$tunit"); urestarts=${urestarts:-0}
      ustatus="healthy"; uexit=0
      if [ "$uactive" != "active" ]; then
        ustatus="critical"; uexit=2; issues+=("$tunit ($tuser) not active: $uactive/$usub")
      elif [ "$urestarts" -ge 3 ]; then
        ustatus="degraded"; uexit=1; issues+=("$tunit ($tuser) restart count elevated: $urestarts")
      fi
      if [ $uexit -gt $overall_exit ]; then
        overall_exit=$uexit
        overall_status=$([ $overall_exit -eq 2 ] && echo critical || echo degraded)
      fi
      unit_results+=("$(unit_json "$tunit" "$uactive" "$usub" "$urestarts" "$(jq -n --arg u "$tuser" '{tenant_user:$u}')" "$ustatus")")
    done
  done < <(jq -r '.tenants // {} | to_entries[] | "\(.key)\t\(.value.user)"' "$TENANTS_FILE" 2>/dev/null || true)
fi

issues_json="[]"
if [ ${#issues[@]} -gt 0 ]; then
  issues_json=$(printf '%s\n' "${issues[@]}" | jq -R . | jq -s .)
fi

units_json=$(printf '%s\n' "${unit_results[@]}" | jq -s .)

cat <<EOF
{
  "component": "systemd",
  "status": "$overall_status",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "metrics": {
    "units": $units_json
  },
  "issues": $issues_json
}
EOF

exit $overall_exit
