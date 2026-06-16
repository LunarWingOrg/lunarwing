#!/usr/bin/env bash
# Behavior + regression tests for the merged lunarwing-self-heal.sh.
#
# Covers: jq-precedence regression, exponential backoff + jitter (and the
# linear strategy toggle), grace period, flapping guard, post-restart
# verification, state TTL prune (+ --prune-ttl disable), report-as-truth
# recovery, multi-tenant remediation (systemd user units + OpenRC), and the
# CLI flags. All assertions run against --dry-run output / state.json.
#
# Run:  bash tests/test-self-heal.sh   (exit 0 = pass, 1 = fail)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SH="$SCRIPT_DIR/../lunarwing-self-heal.sh"
[[ -x "$SH" ]] || { echo "FATAL: $SH not found/executable"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 1; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/selfheal-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

fail=0; pass=0
ok()  { printf 'PASS: %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL: %s\n      %s\n' "$1" "$2"; fail=$((fail + 1)); }
assert_contains() { grep -qF -- "$2" <<<"$1" && ok "$3" || bad "$3" "expected: $2"; }
assert_absent()   { grep -qF -- "$2" <<<"$1" && bad "$3" "unexpected: $2" || ok "$3"; }
assert_eq()       { [[ "$1" == "$2" ]] && ok "$3" || bad "$3" "got [$1] want [$2]"; }
assert_range()    { # val lo hi msg
    if [[ "$1" =~ ^-?[0-9]+$ && "$1" -ge "$2" && "$1" -le "$3" ]]; then ok "$4"; else bad "$4" "got [$1] not in [$2,$3]"; fi; }

sb() { local d; d="$(mktemp -d "$ROOT/sb.XXXXXX")"; mkdir -p "$d/self-heal"; printf '%s' "$d"; }
report() { jq -n "$2" > "$1/report.json"; }   # <sandbox> <jq-expr>
state_of() { jq -c "${2:-.}" "$1/self-heal/state.json" 2>/dev/null; }
now() { date +%s; }

# run_dry <sb> [ENV=VAL ...] [-- <script args>]
run_dry() {
    local sb="$1"; shift
    local -a envs=() args=()
    while [[ $# -gt 0 && "$1" != "--" ]]; do envs+=("$1"); shift; done
    [[ "${1:-}" == "--" ]] && shift
    args=("$@")
    env LUNARWING_BASE_DIR="$sb" SELF_HEAL_STATE_DIR="$sb/self-heal" "${envs[@]}" \
        "$SH" --dry-run --report "$sb/report.json" --backoff 0 "${args[@]}" 2>&1
}

GW='{components:[{component:"gateway",status:"degraded",metrics:{}}]}'

# ── A: jq-precedence regression + target selection (grace=1) ────────────────
A="$(sb)"; report "$A" '{components:[
  {component:"gateway",status:"degraded",metrics:{}},
  {component:"omemo",  status:"critical",metrics:{}},
  {component:"systemd",status:"degraded",metrics:{units:[
    {name:"lunarwing-watchdog.service",status:"healthy"},
    {name:"clickhouse-server.service", status:"critical"}]}}]}'
oA="$(run_dry "$A" LUNARWING_SERVICE_MANAGER=systemd SELF_HEAL_GRACE_CHECKS=1 SELF_HEAL_VERIFY_HEALTH=false)"
assert_contains "$oA" "systemctl restart clickhouse-server.service" "A: unhealthy systemd sub-unit remediated"
assert_contains "$oA" "systemctl restart lunarwing"                 "A: gateway maps to lunarwing"
assert_absent   "$oA" "restart lunarwing-watchdog.service"          "A: healthy sub-unit not restarted"
assert_absent   "$oA" "restart omemo"                               "A: no-remedy not restarted"
assert_absent   "$oA" "Cannot index string"                        "A: pass-2 jq does not abort"

# ── B: backoff (item 1) ─────────────────────────────────────────────────────
B="$(sb)"; report "$B" "$GW"
run_dry "$B" LUNARWING_SERVICE_MANAGER=systemd SELF_HEAL_GRACE_CHECKS=1 SELF_HEAL_VERIFY_HEALTH=false >/dev/null
nb="$(state_of "$B" '.lunarwing.next_attempt_at')"
assert_range "$((nb - $(now)))" 0 60 "B1: exponential schedules next_attempt_at in [0,60]"
oB2="$(run_dry "$B" LUNARWING_SERVICE_MANAGER=systemd SELF_HEAL_GRACE_CHECKS=1 SELF_HEAL_VERIFY_HEALTH=false)"
# (only asserts the gate when the jittered delay was > 0; if 0 a restart is fine)
if [[ "$((nb - $(now)))" -gt 1 ]]; then
  assert_contains "$oB2" "BACKOFF" "B2: second run gated by backoff"
else ok "B2: backoff was 0 (jitter) — no gate expected"; fi
Bl="$(sb)"; report "$Bl" "$GW"
run_dry "$Bl" LUNARWING_SERVICE_MANAGER=systemd SELF_HEAL_GRACE_CHECKS=1 SELF_HEAL_VERIFY_HEALTH=false \
    SELF_HEAL_BACKOFF_STRATEGY=linear SELF_HEAL_BACKOFF_BASE=300 >/dev/null
assert_range "$(( $(state_of "$Bl" '.lunarwing.next_attempt_at') - $(now) ))" 299 301 "B3: linear strategy is deterministic (now+base)"

# ── C: grace period (item 2) ────────────────────────────────────────────────
C="$(sb)"; report "$C" "$GW"
oC1="$(run_dry "$C" LUNARWING_SERVICE_MANAGER=systemd SELF_HEAL_GRACE_CHECKS=2 SELF_HEAL_VERIFY_HEALTH=false)"
assert_contains "$oC1" "GRACE" "C1: first observation defers (grace)"
assert_absent   "$oC1" "would run: systemctl restart lunarwing" "C1: no restart during grace"
oC2="$(run_dry "$C" LUNARWING_SERVICE_MANAGER=systemd SELF_HEAL_GRACE_CHECKS=2 SELF_HEAL_VERIFY_HEALTH=false)"
assert_contains "$oC2" "would run: systemctl restart lunarwing" "C2: restart fires once grace met"

# ── D: flapping guard (item 2b) ─────────────────────────────────────────────
D="$(sb)"; report "$D" "$GW"
n="$(now)"; jq -n --argjson n "$n" '{lunarwing:{consecutive_unhealthy:5,restart_history:[($n-10),($n-20),($n-30),($n-40),($n-50)]}}' > "$D/self-heal/state.json"
oD="$(run_dry "$D" LUNARWING_SERVICE_MANAGER=systemd SELF_HEAL_GRACE_CHECKS=1 SELF_HEAL_FLAP_MAX_RESTARTS=5 SELF_HEAL_VERIFY_HEALTH=false)"
assert_contains "$oD" "FLAPPING" "D1: flapping detected"
assert_contains "$oD" "would send escalation notification for lunarwing" "D2: flapping escalates"
assert_absent   "$oD" "would run: systemctl restart lunarwing" "D3: flapping not restarted"

# ── E: post-restart verification (item 3) ───────────────────────────────────
E="$(sb)"; mkdir -p "$E/checks"; report "$E" "$GW"
printf '#!/usr/bin/env bash\necho %s\n' "'{\"status\":\"critical\"}'" > "$E/checks/health-gateway.sh"; chmod +x "$E/checks/health-gateway.sh"
oE1="$(run_dry "$E" LUNARWING_SERVICE_MANAGER=systemd SELF_HEAL_GRACE_CHECKS=1 SELF_HEAL_VERIFY_HEALTH=true SELF_HEAL_HEALTH_CHECK_DIR="$E/checks")"
assert_contains "$oE1" "VERIFY: gateway still critical" "E1: verification detects still-unhealthy"
assert_eq "$(state_of "$E" '.lunarwing.retries')" "1"   "E1: failed verify counts as a retry"
E2="$(sb)"; mkdir -p "$E2/checks"; report "$E2" "$GW"
printf '#!/usr/bin/env bash\necho %s\n' "'{\"status\":\"healthy\"}'" > "$E2/checks/health-gateway.sh"; chmod +x "$E2/checks/health-gateway.sh"
oE2="$(run_dry "$E2" LUNARWING_SERVICE_MANAGER=systemd SELF_HEAL_GRACE_CHECKS=1 SELF_HEAL_VERIFY_HEALTH=true SELF_HEAL_HEALTH_CHECK_DIR="$E2/checks")"
assert_contains "$oE2" "SUCCESS: lunarwing healthy after restart" "E2: healthy verify clears the service"
assert_eq "$(state_of "$E2")" '{}' "E2: state cleared after verified-healthy restart"

# ── F: state prune (item 4) + --prune-ttl disable ───────────────────────────
F="$(sb)"; report "$F" '{components:[{component:"gateway",status:"healthy",metrics:{}}]}'
o=$(( $(now) - 999999 ))
jq -n --argjson o "$o" '{"old-svc":{retries:1,escalated:false,last_attempt:$o},"old-esc":{retries:3,escalated:true,last_attempt:$o}}' > "$F/self-heal/state.json"
run_dry "$F" LUNARWING_SERVICE_MANAGER=systemd SELF_HEAL_VERIFY_HEALTH=false >/dev/null
assert_eq "$(state_of "$F" 'keys')" '["old-esc"]' "F1: stale non-escalated pruned, escalated kept"
F2="$(sb)"; report "$F2" '{components:[{component:"gateway",status:"healthy",metrics:{}}]}'
jq -n --argjson o "$o" '{"old-svc":{retries:1,escalated:false,last_attempt:$o}}' > "$F2/self-heal/state.json"
run_dry "$F2" LUNARWING_SERVICE_MANAGER=systemd SELF_HEAL_VERIFY_HEALTH=false -- --prune-ttl 0 >/dev/null
assert_eq "$(state_of "$F2" 'keys')" '["old-svc"]' "F2: --prune-ttl 0 disables pruning"

# ── G: multi-tenant (item 5) ────────────────────────────────────────────────
G="$(sb)"; echo '{"tenants":{"summer":{"user":"summer"}}}' > "$G/ports.json"
report "$G" '{components:[{component:"systemd",status:"degraded",metrics:{units:[{name:"lunarwing-summer.service",status:"critical"}]}}]}'
oG="$(run_dry "$G" LUNARWING_SERVICE_MANAGER=systemd SELF_HEAL_GRACE_CHECKS=1 SELF_HEAL_VERIFY_HEALTH=false SELF_HEAL_TENANTS_FILE="$G/ports.json")"
assert_contains "$oG" "sudo -n -u summer" "G1: systemd tenant unit restarts as tenant user"
assert_contains "$oG" "systemctl --user restart lunarwing-summer.service" "G2: uses systemd --user bus"
H_oc="$(sb)"; report "$H_oc" '{components:[{component:"openrc",status:"degraded",metrics:{services:[{name:"lunarwing-summer",status:"critical"}]}}]}'
oGo="$(run_dry "$H_oc" LUNARWING_SERVICE_MANAGER=openrc SELF_HEAL_GRACE_CHECKS=1 SELF_HEAL_VERIFY_HEALTH=false)"
assert_contains "$oGo" "rc-service lunarwing-summer restart" "G3: OpenRC tenant service via rc-service"

# ── H: report-as-truth recovery ─────────────────────────────────────────────
H="$(sb)"; report "$H" '{components:[{component:"gateway",status:"healthy",metrics:{}}]}'
echo '{"lunarwing":{"retries":1,"consecutive_unhealthy":2}}' > "$H/self-heal/state.json"
oH="$(run_dry "$H" LUNARWING_SERVICE_MANAGER=systemd SELF_HEAL_VERIFY_HEALTH=false)"
assert_contains "$oH" "RECOVERED" "H1: service the report calls healthy is cleared (report-as-truth)"
assert_eq "$(state_of "$H")" '{}' "H1: recovered state cleared without is-active round-trip"

# ── I: CLI flags ────────────────────────────────────────────────────────────
I1="$(sb)"; report "$I1" "$GW"
oI1="$(run_dry "$I1" LUNARWING_SERVICE_MANAGER=systemd SELF_HEAL_VERIFY_HEALTH=false -- --grace-checks 1)"
assert_contains "$oI1" "would run: systemctl restart lunarwing" "I1: --grace-checks 1 restarts on first observation"
I2="$(sb)"; report "$I2" "$GW"
run_dry "$I2" LUNARWING_SERVICE_MANAGER=systemd SELF_HEAL_VERIFY_HEALTH=false -- --grace-checks 1 --backoff-strategy linear --backoff-base 200 >/dev/null
assert_range "$(( $(state_of "$I2" '.lunarwing.next_attempt_at') - $(now) ))" 199 201 "I2: --backoff-strategy/-base flags honored"
I3="$(sb)"; mkdir -p "$I3/checks"; report "$I3" "$GW"
printf '#!/usr/bin/env bash\necho %s\n' "'{\"status\":\"healthy\"}'" > "$I3/checks/health-gateway.sh"; chmod +x "$I3/checks/health-gateway.sh"
run_dry "$I3" LUNARWING_SERVICE_MANAGER=systemd SELF_HEAL_GRACE_CHECKS=1 SELF_HEAL_HEALTH_CHECK_DIR="$I3/checks" -- --verify-health false >/dev/null
assert_eq "$(state_of "$I3" '.lunarwing.retries')" "1" "I3: --verify-health false skips health-check (is-active only)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
