#!/bin/bash
# Health Check: OpenRC services
# Checks: per-unit service state, auto-discovered for multi-tenant hosts.
# Output: JSON to stdout
# Exit codes: 0=healthy, 1=degraded, 2=critical

set -euo pipefail

# Init-script directory. Overridable so the test suite can point at a fake
# /etc/init.d without touching the host.
INITD_DIR="${INITD_DIR:-/etc/init.d}"

# Per-unit status-probe timeout (seconds). A container unit's status() shells out
# to `podman inspect` as the tenant; with no bound, one wedged tenant could eat
# the orchestrator's whole component budget (a single `timeout 30` around this
# script) and blank remediation for EVERY tenant. 0 disables the wrapper.
STATUS_TIMEOUT="${HEALTH_OPENRC_STATUS_TIMEOUT:-8}"

# Services to check (override via env: SERVICES="xmpp-bridge lunarwing").
# Auto-discovers multi-tenant services from $INITD_DIR when no override is set.
discover_services() {
  local -A seen=()
  local svcs=() initscript name

  # Single-instance defaults.
  for name in lunarwing xmpp-bridge; do
    if [ -x "$INITD_DIR/$name" ] && [ -z "${seen[$name]:-}" ]; then
      seen[$name]=1; svcs+=("$name")
    fi
  done

  # Multi-tenant. The `lunarwing-*` glob already covers lunarwing-<t> AND every
  # per-service unit (lunarwing-proxy-<t>, lunarwing-pg-<t>, lunarwing-nanocode-<t>,
  # lunarwing-pebble-<t>, lunarwing-weechat-<t>, lunarwing-weechat-adapter-<t>), so
  # a separate lunarwing-proxy-* glob would only double-list it. Dedup via `seen`.
  for initscript in "$INITD_DIR"/lunarwing-* "$INITD_DIR"/xmpp-bridge-*; do
    [ -x "$initscript" ] || continue
    name=$(basename "$initscript")
    case "$name" in lunarwing|xmpp-bridge) continue ;; esac   # base names already handled
    [ -n "${seen[$name]:-}" ] && continue
    seen[$name]=1; svcs+=("$name")
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
  local name="$1" state="$2" status="$3"
  cat <<EOF
  {
    "name": "$name",
    "state": "$state",
    "status": "$status"
  }
EOF
}

# Probe one unit, bounded by STATUS_TIMEOUT when `timeout` is available.
# Sets globals STATUS_OUT (text) and STATUS_RC (the REAL exit code; 124/137 mean
# the probe was killed for exceeding the timeout).
probe_status() {
  local svc="$1"
  STATUS_RC=0
  if [ "$STATUS_TIMEOUT" != "0" ] && command -v timeout >/dev/null 2>&1; then
    STATUS_OUT=$(timeout -k 2 "$STATUS_TIMEOUT" rc-service "$svc" status 2>&1) || STATUS_RC=$?
  else
    STATUS_OUT=$(rc-service "$svc" status 2>&1) || STATUS_RC=$?
  fi
}

for svc in "${SERVICES_ARR[@]}"; do
  # Init script must exist.
  if ! rc-service --exists "$svc" >/dev/null 2>&1; then
    issues+=("service not found: $svc")
    svc_results+=("$(svc_json "$svc" "missing" "critical")")
    overall_status="critical"; overall_exit=2
    continue
  fi

  local_status="healthy"
  local_exit=0
  state="unknown"

  probe_status "$svc"

  # NOTE: STATUS_RC is the real exit code. Previously the script ran
  # `status_output=$(rc-service … ) || true; rc_exit=$?`, which captured `true`'s
  # exit (always 0) — so the `elif rc==0 → started` fallback fired for ANY
  # non-keyword output and the `→ stopped`/`→ degraded` branches were dead,
  # silently classifying ambiguous-but-down units as healthy (never remediated).
  if [ "$STATUS_RC" -eq 124 ] || [ "$STATUS_RC" -eq 137 ]; then
    state="timeout"
  elif echo "$STATUS_OUT" | grep -qi "started"; then
    state="started"
  elif echo "$STATUS_OUT" | grep -qi "stopped"; then
    state="stopped"
  elif echo "$STATUS_OUT" | grep -qi "crashed"; then
    state="crashed"
  elif [ "$STATUS_RC" -eq 0 ]; then
    state="started"
  else
    state="stopped"   # non-keyword output AND non-zero exit → down/ambiguous
  fi

  case "$state" in
    stopped|crashed)
      local_status="critical"; local_exit=2
      issues+=("$svc not running: $state")
      ;;
    timeout)
      # Degraded for THIS unit only — the loop continues, so one wedged tenant
      # doesn't blank the whole component (GRACE then absorbs a one-off slow probe).
      local_status="degraded"; local_exit=1
      issues+=("$svc status probe timed out (>${STATUS_TIMEOUT}s)")
      ;;
    unknown)
      local_status="degraded"; local_exit=1
      issues+=("$svc in unexpected state: $state")
      ;;
  esac

  if [ "$local_exit" -gt "$overall_exit" ]; then
    overall_exit=$local_exit
    overall_status=$([ "$overall_exit" -eq 2 ] && echo critical || echo degraded)
  fi

  svc_results+=("$(svc_json "$svc" "$state" "$local_status")")
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
