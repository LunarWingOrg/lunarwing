#!/usr/bin/env bash
# Phase 1 unit matrix for lunarwing-self-heal.sh — sections A–N of
# docs/proposals/CHAOS_ENGINEERING_TEST_PLAN.md.
#
# Every case runs against a synthetic health report in a throwaway sandbox and
# asserts on stderr output, state.json mutations, and exit codes. It is safe to
# run on any host: restarts are always --dry-run (never executed), the real
# component health probes are never invoked (verify is forced with fake
# health-*.sh fixtures), and the only real command ever reached is a read-only
# `systemctl is-active` — and even that is shadowed by a mock for the cases that
# assert on it. No live service is touched.
#
# Run:  bash tests/test-self-heal-matrix.sh   (exit 0 = all pass)

set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

# A copy of the script in its own dir, so SCRIPT_DIR-relative lookups
# (send-notification.sh, health checks) resolve to fixtures we control. Used by
# the escalation cases, which must run non-dry to exercise the write+notify path
# (the escalate branch returns before any restart, so no service is touched).
mk_tool() {
    local t="$1/tool"
    mkdir -p "$t"
    cp "$SH" "$t/lunarwing-self-heal.sh"; chmod +x "$t/lunarwing-self-heal.sh"
    printf '%s' "$t"
}

echo "=== Section A: Report discovery & init ==="

# A1 — no report found (empty base dir, no --report) → die, exit 1.
# Run from an empty CWD: find_latest_report pipes `find ... | xargs ls -t`, and
# GNU xargs with no input still runs `ls -t` against CWD — an empty CWD keeps
# that from accidentally resolving a stray file as "the report". (The footgun
# itself is noted as a script follow-up; here we pin the intended no-report path.)
a1="$(sb)"; a1cwd="$a1/cwd-empty"; mkdir -p "$a1cwd"
oA1="$(cd "$a1cwd" && env LUNARWING_BASE_DIR="$a1" SELF_HEAL_STATE_DIR="$a1/self-heal" GOTIFY_TOKEN='' \
    LUNARWING_SERVICE_MANAGER=systemd "$SH" --dry-run 2>&1)"; a1rc=$?
assert_contains "$oA1" "no health-check report found" "A1: empty report dir dies"
assert_eq "$a1rc" "1" "A1: exit 1 when no report"

# A2 — malformed report JSON → die, exit 1.
a2="$(sb)"; printf 'this is not json{' > "$a2/report.json"
oA2="$(run_raw "$a2" LUNARWING_SERVICE_MANAGER=systemd -- --dry-run --report "$a2/report.json")"; RC=$?
assert_contains "$oA2" "report is not valid JSON" "A2: invalid JSON dies"
assert_eq "$RC" "1" "A2: exit 1 on malformed report"

# A3 — only *-summary* files present → auto-discovery excludes them → die.
# (Empty CWD again, for the same xargs reason as A1.)
a3="$(sb)"; mkdir -p "$a3/workspace/reports/health"
report "$a3" '{components:[{component:"gateway",status:"degraded",metrics:{}}]}'
mv "$a3/report.json" "$a3/workspace/reports/health/2026-06-13T00:00:00Z-summary.json"
a3cwd="$a3/cwd-empty"; mkdir -p "$a3cwd"
oA3="$(cd "$a3cwd" && env LUNARWING_BASE_DIR="$a3" SELF_HEAL_STATE_DIR="$a3/self-heal" GOTIFY_TOKEN='' \
    LUNARWING_SERVICE_MANAGER=systemd "$SH" --dry-run 2>&1)"
assert_contains "$oA3" "no health-check report found" "A3: summary-only dir excluded from discovery"

# A4 — explicit --report beats auto-discovery: a healthy report sits in the
# discovery dir, but the degraded one we point at is the one acted on.
a4="$(sb)"; mkdir -p "$a4/workspace/reports/health"
jq -n '{components:[{component:"gateway",status:"healthy",metrics:{}}]}' \
    > "$a4/workspace/reports/health/2026-06-13T00:00:00Z.json"
report "$a4" "$GW"
oA4="$(run_dry "$a4" LUNARWING_SERVICE_MANAGER=systemd SELF_HEAL_GRACE_CHECKS=1 SELF_HEAL_VERIFY_HEALTH=false)"
assert_contains "$oA4" "would run: systemctl restart lunarwing" "A4: explicit --report is honored over discovery"

echo "=== Section B: Target selection & service mapping ==="

b_map() {  # b_map <id> <component> <status> <expected-service>
    local id="$1" comp="$2" st="$3" svc="$4" s o
    s="$(sb)"; report "$s" "{components:[{component:\"$comp\",status:\"$st\",metrics:{}}]}"
    o="$(run_dry "$s" LUNARWING_SERVICE_MANAGER=systemd SELF_HEAL_GRACE_CHECKS=1 SELF_HEAL_VERIFY_HEALTH=false)"
    assert_contains "$o" "would run: systemctl restart $svc" "$id: $comp → $svc"
}
b_map B1 gateway    degraded lunarwing
b_map B2 xmpp       critical xmpp-bridge
b_map B3 tensorzero critical tensorzero-gateway
b_map B4 clickhouse critical clickhouse-server

b_skip() {  # b_skip <id> <component> <expected-log-fragment>
    local id="$1" comp="$2" frag="$3" s o
    s="$(sb)"; report "$s" "{components:[{component:\"$comp\",status:\"critical\",metrics:{}}]}"
    o="$(run_dry "$s" LUNARWING_SERVICE_MANAGER=systemd SELF_HEAL_GRACE_CHECKS=1 SELF_HEAL_VERIFY_HEALTH=false)"
    assert_contains "$o" "$frag" "$id: $comp skipped/logged"
    assert_absent   "$o" "would run: systemctl restart" "$id: $comp triggers no restart"
}
b_skip B5 omemo     "SKIP: component 'omemo' has no standalone service"
b_skip B6 ratelimit "SKIP: component 'ratelimit' has no standalone service"
b_skip B7 models    "SKIP: component 'models' has no standalone service"
b_skip B8 gibberish "WARNING: no service mapping for component 'gibberish'"

# B9 — three unhealthy logical components, all targeted in one run.
b9="$(sb)"; report "$b9" '{components:[
  {component:"gateway",   status:"degraded",metrics:{}},
  {component:"xmpp",      status:"critical",metrics:{}},
  {component:"tensorzero",status:"critical",metrics:{}}]}'
oB9="$(run_dry "$b9" LUNARWING_SERVICE_MANAGER=systemd SELF_HEAL_GRACE_CHECKS=1 SELF_HEAL_VERIFY_HEALTH=false)"
assert_contains "$oB9" "would run: systemctl restart lunarwing"          "B9: gateway targeted"
assert_contains "$oB9" "would run: systemctl restart xmpp-bridge"        "B9: xmpp targeted"
assert_contains "$oB9" "would run: systemctl restart tensorzero-gateway" "B9: tensorzero targeted"

echo "=== Section C: Init-system sub-unit remediation ==="

# C1 — systemd sub-unit critical → restart that unit; healthy sibling untouched.
c1="$(sb)"; report "$c1" '{components:[{component:"systemd",status:"degraded",metrics:{units:[
  {name:"clickhouse-server.service",status:"critical"},
  {name:"lunarwing-watchdog.service",status:"healthy"}]}}]}'
oC1="$(run_dry "$c1" LUNARWING_SERVICE_MANAGER=systemd SELF_HEAL_GRACE_CHECKS=1 SELF_HEAL_VERIFY_HEALTH=false)"
assert_contains "$oC1" "would run: systemctl restart clickhouse-server.service" "C1: critical systemd sub-unit restarted"
assert_absent   "$oC1" "restart lunarwing-watchdog.service"                     "C2: healthy sub-unit not restarted"

# C3 — OpenRC service critical → rc-service restart.
c3="$(sb)"; report "$c3" '{components:[{component:"openrc",status:"critical",metrics:{services:[
  {name:"clickhouse-server",status:"critical"}]}}]}'
oC3="$(run_dry "$c3" LUNARWING_SERVICE_MANAGER=openrc SELF_HEAL_GRACE_CHECKS=1 SELF_HEAL_VERIFY_HEALTH=false)"
assert_contains "$oC3" "would run: rc-service clickhouse-server restart" "C3: OpenRC sub-unit via rc-service"

# C4 — launchd agent unhealthy → launchctl stop/start.
c4="$(sb)"; report "$c4" '{components:[{component:"launchd",status:"degraded",metrics:{agents:[
  {name:"com.lunarwing.gateway",status:"degraded"}]}}]}'
oC4="$(run_dry "$c4" LUNARWING_SERVICE_MANAGER=launchd SELF_HEAL_GRACE_CHECKS=1 SELF_HEAL_VERIFY_HEALTH=false)"
assert_contains "$oC4" "would run: launchctl stop/start com.lunarwing.gateway" "C4: launchd agent via launchctl"

# C5 — multiple sub-units in one manager's block are each remediated. (A host
# runs a single init system, so "mixed init systems" is modeled as several
# sub-units under the active manager.)
c5="$(sb)"; report "$c5" '{components:[{component:"openrc",status:"critical",metrics:{services:[
  {name:"clickhouse-server",status:"critical"},
  {name:"tensorzero-gateway",status:"critical"}]}}]}'
oC5="$(run_dry "$c5" LUNARWING_SERVICE_MANAGER=openrc SELF_HEAL_GRACE_CHECKS=1 SELF_HEAL_VERIFY_HEALTH=false)"
assert_contains "$oC5" "would run: rc-service clickhouse-server restart"  "C5: first sub-unit remediated"
assert_contains "$oC5" "would run: rc-service tensorzero-gateway restart" "C5: second sub-unit remediated"

# C6 — logical "gateway" degraded while systemd reports lunarwing.service
# healthy. The logical service key ("lunarwing") and the init-unit key
# ("lunarwing.service") differ, so there is no cross-suppression: the logical
# degrade is still remediated, and the healthy init unit is left alone. (This
# documents the real precedence; see the plan's implementation-status note.)
c6="$(sb)"; report "$c6" '{components:[
  {component:"gateway",status:"degraded",metrics:{}},
  {component:"systemd",status:"healthy",metrics:{units:[{name:"lunarwing.service",status:"healthy"}]}}]}'
oC6="$(run_dry "$c6" LUNARWING_SERVICE_MANAGER=systemd SELF_HEAL_GRACE_CHECKS=1 SELF_HEAL_VERIFY_HEALTH=false)"
assert_contains "$oC6" "would run: systemctl restart lunarwing" "C6: logical degrade still remediated"
assert_absent   "$oC6" "restart lunarwing.service"             "C6: healthy init unit not restarted"

echo "=== Section D: Per-tenant systemd user units ==="

# Registry maps tenants to OS users that do not exist on the test host; the
# restart command line is asserted (dry-run), and post-restart verify resolves
# `id -u` to a miss and returns without ever invoking sudo.
d_ports() { echo '{"tenants":{"acme":{"user":"acme"},"globex":{"user":"globex"}}}' > "$1/ports.json"; }

# D1 — tenant proxy unit (ironclaw-proxy-<t>) → systemctl --user as tenant user.
d1="$(sb)"; d_ports "$d1"
report "$d1" '{components:[{component:"systemd",status:"critical",metrics:{units:[
  {name:"ironclaw-proxy-acme.service",status:"critical"}]}}]}'
oD1="$(run_dry "$d1" LUNARWING_SERVICE_MANAGER=systemd SELF_HEAL_GRACE_CHECKS=1 SELF_HEAL_VERIFY_HEALTH=false SELF_HEAL_TENANTS_FILE="$d1/ports.json")"
assert_contains "$oD1" "sudo -n -u acme"                                       "D1: tenant proxy restarts as tenant user"
assert_contains "$oD1" "systemctl --user restart ironclaw-proxy-acme.service"  "D1: uses systemd --user bus"

# D2 — tenant bridge unit (xmpp-bridge-<t>).
d2="$(sb)"; d_ports "$d2"
report "$d2" '{components:[{component:"systemd",status:"critical",metrics:{units:[
  {name:"xmpp-bridge-globex.service",status:"critical"}]}}]}'
oD2="$(run_dry "$d2" LUNARWING_SERVICE_MANAGER=systemd SELF_HEAL_GRACE_CHECKS=1 SELF_HEAL_VERIFY_HEALTH=false SELF_HEAL_TENANTS_FILE="$d2/ports.json")"
assert_contains "$oD2" "sudo -n -u globex"                                       "D2: tenant bridge restarts as tenant user"
assert_contains "$oD2" "systemctl --user restart xmpp-bridge-globex.service"     "D2: uses systemd --user bus"

# D3 — unit names a tenant absent from the registry → falls through to the
# system bus (plain systemctl restart), no sudo.
d3="$(sb)"; d_ports "$d3"
report "$d3" '{components:[{component:"systemd",status:"critical",metrics:{units:[
  {name:"lunarwing-ghosttenant.service",status:"critical"}]}}]}'
oD3="$(run_dry "$d3" LUNARWING_SERVICE_MANAGER=systemd SELF_HEAL_GRACE_CHECKS=1 SELF_HEAL_VERIFY_HEALTH=false SELF_HEAL_TENANTS_FILE="$d3/ports.json")"
assert_contains "$oD3" "would run: systemctl restart lunarwing-ghosttenant.service" "D3: unknown tenant falls back to system unit"
assert_absent   "$oD3" "sudo -u"                                                    "D3: no per-user restart for unknown tenant"

# D4 — TENANTS_FILE missing entirely → graceful fall-through, no crash.
d4="$(sb)"
report "$d4" '{components:[{component:"systemd",status:"critical",metrics:{units:[
  {name:"lunarwing-acme.service",status:"critical"}]}}]}'
oD4="$(run_dry "$d4" LUNARWING_SERVICE_MANAGER=systemd SELF_HEAL_GRACE_CHECKS=1 SELF_HEAL_VERIFY_HEALTH=false SELF_HEAL_TENANTS_FILE="$d4/does-not-exist.json")"
assert_contains "$oD4" "would run: systemctl restart lunarwing-acme.service" "D4: missing registry → system fallback, no crash"
assert_absent   "$oD4" "sudo -u"                                            "D4: missing registry → no per-user restart"

# D-unit — unit_tenant() resolution (pure function).
assert_eq "$(src_fn -- unit_tenant lunarwing-proxy-acme.service)" "acme"   "D: unit_tenant lunarwing-proxy-<t>"
assert_eq "$(src_fn -- unit_tenant ironclaw-proxy-acme.service)"  "acme"   "D: unit_tenant ironclaw-proxy-<t>"
assert_eq "$(src_fn -- unit_tenant xmpp-bridge-globex.service)"   "globex" "D: unit_tenant xmpp-bridge-<t>"
assert_eq "$(src_fn -- unit_tenant lunarwing-acme.service)"       "acme"   "D: unit_tenant lunarwing-<t>"
assert_eq "$(src_fn -- unit_tenant lunarwing.service)"            ""       "D: unit_tenant base unit → no tenant"
assert_eq "$(src_fn -- unit_tenant clickhouse-server.service)"    ""       "D: unit_tenant foreign unit → no tenant"

echo "=== Section E: Grace period ==="

# E1/E2 — grace=2: first observation defers, second restarts (state persists).
e="$(sb)"; report "$e" "$GW"
oE1="$(run_dry "$e" LUNARWING_SERVICE_MANAGER=systemd SELF_HEAL_GRACE_CHECKS=2 SELF_HEAL_VERIFY_HEALTH=false)"
assert_contains "$oE1" "GRACE: lunarwing unhealthy 1/2"            "E1: first observation defers (grace 1/2)"
assert_absent   "$oE1" "would run: systemctl restart lunarwing"   "E1: no restart during grace"
oE2="$(run_dry "$e" LUNARWING_SERVICE_MANAGER=systemd SELF_HEAL_GRACE_CHECKS=2 SELF_HEAL_VERIFY_HEALTH=false)"
assert_contains "$oE2" "would run: systemctl restart lunarwing"   "E2: restart fires once grace met"

# E3 — grace=1: restart on the first observation.
e3="$(sb)"; report "$e3" "$GW"
oE3="$(run_dry "$e3" LUNARWING_SERVICE_MANAGER=systemd SELF_HEAL_GRACE_CHECKS=1 SELF_HEAL_VERIFY_HEALTH=false)"
assert_contains "$oE3" "would run: systemctl restart lunarwing" "E3: grace=1 restarts immediately"

# E4 — healthy in between resets the streak (grace counts from 1 again).
e4="$(sb)"; report "$e4" "$GW"
run_dry "$e4" LUNARWING_SERVICE_MANAGER=systemd SELF_HEAL_GRACE_CHECKS=2 SELF_HEAL_VERIFY_HEALTH=false >/dev/null  # obs=1
report "$e4" '{components:[{component:"gateway",status:"healthy",metrics:{}}]}'                                    # recover
run_dry "$e4" LUNARWING_SERVICE_MANAGER=systemd SELF_HEAL_GRACE_CHECKS=2 SELF_HEAL_VERIFY_HEALTH=false >/dev/null  # clears streak
report "$e4" "$GW"                                                                                                 # unhealthy again
oE4="$(run_dry "$e4" LUNARWING_SERVICE_MANAGER=systemd SELF_HEAL_GRACE_CHECKS=2 SELF_HEAL_VERIFY_HEALTH=false)"
assert_contains "$oE4" "GRACE: lunarwing unhealthy 1/2"          "E4: healthy-in-between resets the grace streak"
assert_absent   "$oE4" "would run: systemctl restart lunarwing" "E4: no restart on the reset first observation"

echo "=== Section F: Backoff & retry spacing (compute_backoff) ==="

# F1 — exponential, attempt 1 → full jitter in [0, base].
assert_range "$(src_fn SELF_HEAL_BACKOFF_BASE=60 -- compute_backoff 1)" 0 60 "F1: exp attempt=1 in [0,base]"
# F2 — exponential, attempt 3 → full jitter in [0, base*4]; honors the cap.
assert_range "$(src_fn SELF_HEAL_BACKOFF_BASE=60 -- compute_backoff 3)" 0 240 "F2: exp attempt=3 in [0,base*4]"
assert_range "$(src_fn SELF_HEAL_BACKOFF_BASE=60 SELF_HEAL_BACKOFF_MAX=100 -- compute_backoff 5)" 0 100 "F2: exp capped at BACKOFF_MAX"
# F4 — linear strategy is deterministic (= base, no jitter).
assert_eq "$(src_fn SELF_HEAL_BACKOFF_STRATEGY=linear SELF_HEAL_BACKOFF_BASE=300 -- compute_backoff 7)" "300" "F4: linear strategy deterministic"
# F5 — attempt > 20 overflow guard → capped, no exponentiation blow-up.
assert_eq "$(src_fn -- compute_backoff 25)" "3600" "F5: attempt>20 capped to BACKOFF_MAX (no loop blow-up)"
# F6 — large delay (> 32767) uses /dev/urandom path without erroring.
assert_range "$(src_fn SELF_HEAL_BACKOFF_BASE=40000 SELF_HEAL_BACKOFF_MAX=100000 -- compute_backoff 1)" 0 40000 "F6: large-delay urandom jitter path stays in range"
# F7 — invalid / non-positive attempt → 0, no crash.
assert_eq "$(src_fn -- compute_backoff abc)" "0" "F7: non-numeric attempt → 0"
assert_eq "$(src_fn -- compute_backoff 0)"   "0" "F7: zero attempt → 0"
assert_eq "$(src_fn -- compute_backoff -4)"  "0" "F7: negative attempt → 0"

# F3 — backoff gate: now < next_attempt_at → BACKOFF logged, no restart.
f3="$(sb)"; report "$f3" "$GW"
seed_state "$f3" "$(jq -n --argjson n "$(now)" '{lunarwing:{retries:1,consecutive_unhealthy:5,next_attempt_at:($n+9999)}}')"
oF3="$(run_dry "$f3" LUNARWING_SERVICE_MANAGER=systemd SELF_HEAL_GRACE_CHECKS=1 SELF_HEAL_VERIFY_HEALTH=false)"
assert_contains "$oF3" "BACKOFF: lunarwing waiting"             "F3: backoff gate defers retry"
assert_absent   "$oF3" "would run: systemctl restart lunarwing" "F3: no restart while gated"

echo "=== Section G: Max retries & escalation ==="

# G1 — retries at max, still unhealthy → escalate (dry-run logs the notify).
g1="$(sb)"; report "$g1" "$GW"
seed_state "$g1" '{lunarwing:{retries:3,consecutive_unhealthy:5,escalated:false}}'
oG1="$(run_dry "$g1" LUNARWING_SERVICE_MANAGER=systemd SELF_HEAL_GRACE_CHECKS=1 SELF_HEAL_VERIFY_HEALTH=false)"
assert_contains "$oG1" "ESCALATING: lunarwing"                            "G1: max retries escalates"
assert_contains "$oG1" "would send escalation notification for lunarwing" "G1: escalation notification fired"
assert_eq "$(state_of "$g1" '.lunarwing.escalated')" "true"              "G1: state marked escalated"
assert_absent "$oG1" "would run: systemctl restart lunarwing"            "G1: no restart once escalated"

# G2 — already escalated → skip, no restart.
g2="$(sb)"; report "$g2" "$GW"
seed_state "$g2" '{lunarwing:{retries:3,escalated:true}}'
oG2="$(run_dry "$g2" LUNARWING_SERVICE_MANAGER=systemd SELF_HEAL_GRACE_CHECKS=1 SELF_HEAL_VERIFY_HEALTH=false)"
assert_contains "$oG2" "SKIP: lunarwing already escalated"     "G2: escalated service is skipped"
assert_absent   "$oG2" "would run: systemctl restart lunarwing" "G2: no restart for escalated service"

# G3 — escalation writes a JSON report and hands it to the notifier. Non-dry so
# the write path runs; a capturing send-notification.sh saves the report before
# the script removes it. (Escalate returns before any restart — no service hit.)
g3="$(sb)"; report "$g3" "$GW"
seed_state "$g3" '{lunarwing:{retries:3,consecutive_unhealthy:5,escalated:false}}'
g3tool="$(mk_tool "$g3")"
{ echo '#!/usr/bin/env bash'; echo "cp \"\$2\" \"$g3/captured.json\""; } > "$g3tool/send-notification.sh"
chmod +x "$g3tool/send-notification.sh"
env LUNARWING_BASE_DIR="$g3" SELF_HEAL_STATE_DIR="$g3/self-heal" GOTIFY_TOKEN='' \
    LUNARWING_SERVICE_MANAGER=systemd SELF_HEAL_GRACE_CHECKS=1 SELF_HEAL_VERIFY_HEALTH=false \
    "$g3tool/lunarwing-self-heal.sh" --report "$g3/report.json" --backoff 0 >/dev/null 2>&1
assert_eq "$(jq -r '.escalated' "$g3/captured.json" 2>/dev/null)" "true"        "G3: escalation report written (escalated=true)"
assert_eq "$(jq -r '.service'   "$g3/captured.json" 2>/dev/null)" "lunarwing"   "G3: escalation report names the service"
assert_eq "$(jq -r '.reason'    "$g3/captured.json" 2>/dev/null)" "max_retries" "G3: escalation report records the reason"

# G4 — notifier missing → WARNING, no crash (run still completes).
g4="$(sb)"; report "$g4" "$GW"
seed_state "$g4" '{lunarwing:{retries:3,consecutive_unhealthy:5,escalated:false}}'
g4tool="$(mk_tool "$g4")"; rm -f "$g4tool/send-notification.sh"
oG4="$(env LUNARWING_BASE_DIR="$g4" SELF_HEAL_STATE_DIR="$g4/self-heal" GOTIFY_TOKEN='' \
    LUNARWING_SERVICE_MANAGER=systemd SELF_HEAL_GRACE_CHECKS=1 SELF_HEAL_VERIFY_HEALTH=false \
    "$g4tool/lunarwing-self-heal.sh" --report "$g4/report.json" --backoff 0 2>&1)"; g4rc=$?
assert_contains "$oG4" "send-notification.sh not found" "G4: missing notifier warns"
assert_eq "$g4rc" "0" "G4: missing notifier does not crash the run"

echo "=== Section H: Flapping guard ==="

# H1 — 5 restarts inside the window → escalate instead of restarting.
h1="$(sb)"; report "$h1" "$GW"
seed_state "$h1" "$(jq -n --argjson n "$(now)" '{lunarwing:{consecutive_unhealthy:5,restart_history:[($n-10),($n-20),($n-30),($n-40),($n-50)]}}')"
oH1="$(run_dry "$h1" LUNARWING_SERVICE_MANAGER=systemd SELF_HEAL_GRACE_CHECKS=1 SELF_HEAL_FLAP_MAX_RESTARTS=5 SELF_HEAL_VERIFY_HEALTH=false)"
assert_contains "$oH1" "FLAPPING: lunarwing"                              "H1: flapping detected"
assert_contains "$oH1" "would send escalation notification for lunarwing" "H1: flapping escalates"
assert_absent   "$oH1" "would run: systemctl restart lunarwing"           "H1: flapping does not restart"

# H2 — 4 restarts in window (below threshold) → restart proceeds.
h2="$(sb)"; report "$h2" "$GW"
seed_state "$h2" "$(jq -n --argjson n "$(now)" '{lunarwing:{consecutive_unhealthy:5,restart_history:[($n-10),($n-20),($n-30),($n-40)]}}')"
oH2="$(run_dry "$h2" LUNARWING_SERVICE_MANAGER=systemd SELF_HEAL_GRACE_CHECKS=1 SELF_HEAL_FLAP_MAX_RESTARTS=5 SELF_HEAL_VERIFY_HEALTH=false)"
assert_absent   "$oH2" "FLAPPING"                              "H2: 4 < threshold is not flapping"
assert_contains "$oH2" "would run: systemctl restart lunarwing" "H2: restart proceeds below threshold"

# H3 — 5 restarts but all older than the window → restart proceeds.
h3="$(sb)"; report "$h3" "$GW"
seed_state "$h3" "$(jq -n --argjson n "$(now)" '{lunarwing:{consecutive_unhealthy:5,restart_history:[($n-5000),($n-5100),($n-5200),($n-5300),($n-5400)]}}')"
oH3="$(run_dry "$h3" LUNARWING_SERVICE_MANAGER=systemd SELF_HEAL_GRACE_CHECKS=1 SELF_HEAL_FLAP_MAX_RESTARTS=5 SELF_HEAL_FLAP_WINDOW_SECS=3600 SELF_HEAL_VERIFY_HEALTH=false)"
assert_absent   "$oH3" "FLAPPING"                              "H3: out-of-window restarts do not count"
assert_contains "$oH3" "would run: systemctl restart lunarwing" "H3: restart proceeds when history is stale"

# H4 — restart_history is capped. Read the cap from the script under test (so
# this assertion tracks the source rather than hardcoding the constant — Baud
# review P2), seed cap+5 recent entries with a high flap threshold (so it
# restarts rather than escalating), and force verify-fail so the entry (with its
# trimmed history) survives into state.json.
h4="$(sb)"; mk_check "$h4" gateway critical >/dev/null
report "$h4" "$GW"
h4cap="$(grep -oE 'RESTART_HISTORY_MAX=[0-9]+' "$SH" | head -1 | cut -d= -f2)"
[[ "$h4cap" =~ ^[0-9]+$ ]] || h4cap=20          # fallback if the constant is renamed
h4seed=$((h4cap + 5)); h4flap=$((h4seed + 50))  # seed past the cap; never flap
seed_state "$h4" "$(jq -n --argjson n "$(now)" --argjson c "$h4seed" '{lunarwing:{consecutive_unhealthy:5,restart_history:[range(0;$c)|($n-(.*5))]}}')"
run_dry "$h4" LUNARWING_SERVICE_MANAGER=systemd SELF_HEAL_GRACE_CHECKS=1 SELF_HEAL_FLAP_MAX_RESTARTS="$h4flap" \
    SELF_HEAL_VERIFY_HEALTH=true SELF_HEAL_HEALTH_CHECK_DIR="$h4/checks" >/dev/null
assert_eq "$(state_of "$h4" '.lunarwing.restart_history | length')" "$h4cap" "H4: restart_history trimmed to cap ($h4cap, read from script)"

echo "=== Section I: Post-restart verification ==="

# I1 — verify healthy → SUCCESS, state cleared.
i1="$(sb)"; mk_check "$i1" gateway healthy >/dev/null; report "$i1" "$GW"
oI1="$(run_dry "$i1" LUNARWING_SERVICE_MANAGER=systemd SELF_HEAL_GRACE_CHECKS=1 SELF_HEAL_VERIFY_HEALTH=true SELF_HEAL_HEALTH_CHECK_DIR="$i1/checks")"
assert_contains "$oI1" "SUCCESS: lunarwing healthy after restart" "I1: healthy verify clears the service"
assert_eq "$(state_of "$i1")" '{}' "I1: state empty after verified-healthy restart"

# I2 — verify critical → retry bumped.
i2="$(sb)"; mk_check "$i2" gateway critical >/dev/null; report "$i2" "$GW"
oI2="$(run_dry "$i2" LUNARWING_SERVICE_MANAGER=systemd SELF_HEAL_GRACE_CHECKS=1 SELF_HEAL_VERIFY_HEALTH=true SELF_HEAL_HEALTH_CHECK_DIR="$i2/checks")"
assert_contains "$oI2" "VERIFY: gateway still critical"        "I2: still-critical detected"
assert_eq "$(state_of "$i2" '.lunarwing.retries')" "1"        "I2: critical verify counts a retry"

# I3 — verify degraded → retry bumped.
i3="$(sb)"; mk_check "$i3" gateway degraded >/dev/null; report "$i3" "$GW"
oI3="$(run_dry "$i3" LUNARWING_SERVICE_MANAGER=systemd SELF_HEAL_GRACE_CHECKS=1 SELF_HEAL_VERIFY_HEALTH=true SELF_HEAL_HEALTH_CHECK_DIR="$i3/checks")"
assert_contains "$oI3" "VERIFY: gateway still degraded" "I3: still-degraded detected"
assert_eq "$(state_of "$i3" '.lunarwing.retries')" "1" "I3: degraded verify counts a retry"

# I4 — verify inconclusive (unknown) → falls back to is-active (mock = down).
i4="$(sb)"; mk_check "$i4" gateway unknown >/dev/null; mk_mockbin "$i4"; svc_down "$i4" lunarwing; report "$i4" "$GW"
oI4="$(run_dry "$i4" PATH="$i4/bin:$PATH" SVC_STATE_DIR="$i4/svcstate" LUNARWING_SERVICE_MANAGER=systemd \
    SELF_HEAL_GRACE_CHECKS=1 SELF_HEAL_VERIFY_HEALTH=true SELF_HEAL_HEALTH_CHECK_DIR="$i4/checks")"
assert_contains "$oI4" "falling back to is-active"     "I4: inconclusive verify falls back to is-active"
assert_eq "$(state_of "$i4" '.lunarwing.retries')" "1" "I4: is-active(down) counts a retry"

# I5 — verify disabled → is-active only (mock = down).
i5="$(sb)"; mk_mockbin "$i5"; svc_down "$i5" lunarwing; report "$i5" "$GW"
run_dry "$i5" PATH="$i5/bin:$PATH" SVC_STATE_DIR="$i5/svcstate" LUNARWING_SERVICE_MANAGER=systemd \
    SELF_HEAL_GRACE_CHECKS=1 -- --verify-health false >/dev/null
assert_eq "$(state_of "$i5" '.lunarwing.retries')" "1" "I5: --verify-health false uses is-active only"

# I6 — health-check script absent → falls back to is-active, no VERIFY log.
i6="$(sb)"; mk_mockbin "$i6"; svc_down "$i6" lunarwing; mkdir -p "$i6/empty"; report "$i6" "$GW"
oI6="$(run_dry "$i6" PATH="$i6/bin:$PATH" SVC_STATE_DIR="$i6/svcstate" LUNARWING_SERVICE_MANAGER=systemd \
    SELF_HEAL_GRACE_CHECKS=1 SELF_HEAL_VERIFY_HEALTH=true SELF_HEAL_HEALTH_CHECK_DIR="$i6/empty")"
assert_absent "$oI6" "VERIFY:"                          "I6: missing health script → no verify log"
assert_eq "$(state_of "$i6" '.lunarwing.retries')" "1" "I6: missing health script falls back to is-active"

# I7 — health-check script present but not executable → falls back to is-active.
i7="$(sb)"; mk_mockbin "$i7"; svc_down "$i7" lunarwing; mkdir -p "$i7/noexec"
printf '#!/usr/bin/env bash\necho %s\n' "'{\"status\":\"healthy\"}'" > "$i7/noexec/health-gateway.sh"
chmod 644 "$i7/noexec/health-gateway.sh"; report "$i7" "$GW"
oI7="$(run_dry "$i7" PATH="$i7/bin:$PATH" SVC_STATE_DIR="$i7/svcstate" LUNARWING_SERVICE_MANAGER=systemd \
    SELF_HEAL_GRACE_CHECKS=1 SELF_HEAL_VERIFY_HEALTH=true SELF_HEAL_HEALTH_CHECK_DIR="$i7/noexec")"
assert_absent "$oI7" "VERIFY:"                          "I7: non-executable health script → no verify log"
assert_eq "$(state_of "$i7" '.lunarwing.retries')" "1" "I7: non-executable health script falls back to is-active"

echo "=== Section J: Restart failure ==="

# J2 — unknown service manager → WARNING + restart treated as failure (retry).
j2="$(sb)"; report "$j2" "$GW"
oJ2="$(run_dry "$j2" LUNARWING_SERVICE_MANAGER=unknown SELF_HEAL_GRACE_CHECKS=1 SELF_HEAL_VERIFY_HEALTH=false)"
assert_contains "$oJ2" "WARNING: unknown service manager, cannot restart lunarwing" "J2: unknown manager warns"
assert_contains "$oJ2" "FAILURE: restart command failed for lunarwing"             "J2: restart counted as failure"
assert_eq "$(state_of "$j2" '.lunarwing.retries')" "1" "J2: failed restart bumps retry"
# (J1 — restart command returns non-zero — is covered end-to-end in chaos-harness.sh.)

echo "=== Section K: State recovery & pruning ==="

# K1 — report now says healthy → state cleared (report-as-truth recovery).
k1="$(sb)"; report "$k1" '{components:[{component:"gateway",status:"healthy",metrics:{}}]}'
seed_state "$k1" '{lunarwing:{retries:1,consecutive_unhealthy:2}}'
oK1="$(run_dry "$k1" LUNARWING_SERVICE_MANAGER=systemd SELF_HEAL_VERIFY_HEALTH=false)"
assert_contains "$oK1" "RECOVERED: cleared state for lunarwing" "K1: report-as-truth recovery"
assert_eq "$(state_of "$k1")" '{}' "K1: recovered state cleared"

# K2 — stale, non-escalated entry past TTL → pruned. K4 — escalated kept.
k2="$(sb)"; report "$k2" '{components:[{component:"gateway",status:"healthy",metrics:{}}]}'
old=$(( $(now) - 999999 ))
seed_state "$k2" "$(jq -n --argjson o "$old" '{"old-svc":{retries:1,escalated:false,last_attempt:$o},"old-esc":{retries:3,escalated:true,last_attempt:$o}}')"
run_dry "$k2" LUNARWING_SERVICE_MANAGER=systemd SELF_HEAL_VERIFY_HEALTH=false >/dev/null
assert_eq "$(state_of "$k2" 'keys')" '["old-esc"]' "K2/K4: stale pruned, escalated preserved"

# K3 — --prune-ttl 0 disables pruning.
k3="$(sb)"; report "$k3" '{components:[{component:"gateway",status:"healthy",metrics:{}}]}'
seed_state "$k3" "$(jq -n --argjson o "$old" '{"old-svc":{retries:1,escalated:false,last_attempt:$o}}')"
run_dry "$k3" LUNARWING_SERVICE_MANAGER=systemd SELF_HEAL_VERIFY_HEALTH=false -- --prune-ttl 0 >/dev/null
assert_eq "$(state_of "$k3" 'keys')" '["old-svc"]' "K3: --prune-ttl 0 disables pruning"

# K5 — a currently-unhealthy service past TTL is preserved (it is in `seen`).
# Force verify-fail so it stays unhealthy in state across the prune.
k5="$(sb)"; mk_check "$k5" gateway critical >/dev/null; report "$k5" "$GW"
seed_state "$k5" "$(jq -n --argjson o "$old" '{lunarwing:{retries:1,escalated:false,last_attempt:$o},"old-svc":{retries:1,escalated:false,last_attempt:$o}}')"
run_dry "$k5" LUNARWING_SERVICE_MANAGER=systemd SELF_HEAL_GRACE_CHECKS=1 SELF_HEAL_VERIFY_HEALTH=true SELF_HEAL_HEALTH_CHECK_DIR="$k5/checks" >/dev/null
assert_eq "$(state_of "$k5" 'has("lunarwing")')" "true"  "K5: currently-unhealthy entry preserved past TTL"
assert_eq "$(state_of "$k5" 'has("old-svc")')"   "false" "K5: unrelated stale entry still pruned"

echo "=== Section L: Concurrency & locking ==="
if command -v flock >/dev/null 2>&1; then
    l1="$(sb)"; report "$l1" "$GW"
    l1lock="$l1/self-heal/self-heal.lock"; : > "$l1lock"
    exec 201>"$l1lock"; flock 201                       # hold the lock as a rival instance
    oL1="$(run_dry "$l1" LUNARWING_SERVICE_MANAGER=systemd SELF_HEAL_GRACE_CHECKS=1 SELF_HEAL_VERIFY_HEALTH=false)"
    flock -u 201; exec 201>&-                           # release
    assert_contains "$oL1" "another self-heal instance is running" "L1: concurrent run detected and skipped"
    assert_absent   "$oL1" "would run: systemctl restart lunarwing" "L1: no work while another instance holds the lock"
else
    ok "L1: skipped (flock not available)"
    ok "L1: skipped (flock not available)"
fi

# L2 — a normal single run completes without a lock warning.
l2="$(sb)"; report "$l2" "$GW"
oL2="$(run_dry "$l2" LUNARWING_SERVICE_MANAGER=systemd SELF_HEAL_GRACE_CHECKS=1 SELF_HEAL_VERIFY_HEALTH=false)"
assert_contains "$oL2" "Self-Healing complete"           "L2: normal run completes"
assert_absent   "$oL2" "another self-heal instance is running" "L2: no false lock contention"

echo "=== Section O: Truncated-state recovery (6b) ==="

# The state dir under test is $sb/self-heal (run_dry sets SELF_HEAL_STATE_DIR);
# state.json lives there, NOT at $sb. Seed corrupt bytes DIRECTLY — `seed_state`
# pipes through `jq -n`, which would reject malformed JSON and write an empty
# (and therefore valid) file, never exercising the corrupt path.
seed_corrupt() { printf '%s' "$2" > "$1/self-heal/state.json"; }   # raw non-empty invalid JSON
HEALTHY='{components:[{component:"gateway",status:"healthy",metrics:{}}]}'

# O1 — a non-empty, truncated state.json is detected, renamed for forensics, and
# the tick still completes (nothing-to-do path against a healthy report).
o1="$(sb)"; report "$o1" "$HEALTHY"
seed_corrupt "$o1" '{"lunarwing":{"conse'
oO1="$(run_dry "$o1" LUNARWING_SERVICE_MANAGER=systemd SELF_HEAL_GRACE_CHECKS=1 SELF_HEAL_VERIFY_HEALTH=false)"
assert_contains "$oO1" "state.json is corrupt"                "O1: corrupt state is detected and logged"
assert_contains "$oO1" "renamed to state.json.corrupt"        "O1: corrupt file is renamed (forensic slot)"
assert_contains "$oO1" "Self-Healing complete"                "O1: run completes despite corrupt state"
[[ -f "$o1/self-heal/state.json.corrupt" ]] && ok "O1: forensic .corrupt copy preserved" \
    || bad "O1: forensic .corrupt copy preserved" "no state.json.corrupt in $o1/self-heal"
[[ -f "$o1/self-heal/state.json" ]] && ok "O1: fresh state.json rewritten after recovery" \
    || bad "O1: fresh state.json rewritten after recovery" "state.json missing post-run"

# O2 — a genuinely empty (0-byte) state.json is NOT a valid JSON object, so it must
# be quarantined to .corrupt and replaced with a fresh {} (like a truncated file),
# NOT silently treated as valid-empty — otherwise backoff/flap/escalation counters
# reset every tick and never accumulate. Mirrors O1's recovery contract.
o2="$(sb)"; report "$o2" "$HEALTHY"
: > "$o2/self-heal/state.json"
oO2="$(run_dry "$o2" LUNARWING_SERVICE_MANAGER=systemd SELF_HEAL_GRACE_CHECKS=1 SELF_HEAL_VERIFY_HEALTH=false)"
assert_contains "$oO2" "state.json is corrupt"                "O2: empty state quarantined (not silently reset)"
assert_contains "$oO2" "Self-Healing complete"                "O2: empty state runs cleanly after recovery"
[[ -f "$o2/self-heal/state.json.corrupt" ]] && ok "O2: empty state preserved as .corrupt" \
    || bad "O2: empty state preserved as .corrupt" "no state.json.corrupt in $o2/self-heal"

# O3 — the forensic rename is single-slot: a FIXED .corrupt name (no timestamp),
# so repeated corruption overwrites last-wins and never accumulates. Corrupt,
# run (heals state.json), corrupt again, run — exactly one .corrupt file remains.
o3="$(sb)"; report "$o3" "$HEALTHY"
seed_corrupt "$o3" '{"lunarwing":'
run_dry "$o3" LUNARWING_SERVICE_MANAGER=systemd SELF_HEAL_GRACE_CHECKS=1 SELF_HEAL_VERIFY_HEALTH=false >/dev/null
seed_corrupt "$o3" '{"broken'
run_dry "$o3" LUNARWING_SERVICE_MANAGER=systemd SELF_HEAL_GRACE_CHECKS=1 SELF_HEAL_VERIFY_HEALTH=false >/dev/null
corrupt_count="$(find "$o3/self-heal" -maxdepth 1 -name 'state.json.corrupt*' | wc -l | tr -d ' ')"
assert_eq "$corrupt_count" "1" "O3: single-slot rename — exactly one .corrupt file after repeated corruption"

echo "=== Section M: Dry-run mode ==="

# M1 — dry-run emits [DRY-RUN] markers and no real restart.
m1="$(sb)"; report "$m1" "$GW"
oM1="$(run_dry "$m1" LUNARWING_SERVICE_MANAGER=systemd SELF_HEAL_GRACE_CHECKS=1 SELF_HEAL_VERIFY_HEALTH=false)"
assert_contains "$oM1" "[DRY-RUN] would run: systemctl restart lunarwing" "M1: dry-run logs the would-be restart"

# M2 — state tracking still mutates under dry-run (force verify-fail).
m2="$(sb)"; mk_check "$m2" gateway critical >/dev/null; report "$m2" "$GW"
run_dry "$m2" LUNARWING_SERVICE_MANAGER=systemd SELF_HEAL_GRACE_CHECKS=1 SELF_HEAL_VERIFY_HEALTH=true SELF_HEAL_HEALTH_CHECK_DIR="$m2/checks" >/dev/null
assert_eq "$(state_of "$m2" '.lunarwing.retries')" "1" "M2: dry-run still tracks retry state"

echo "=== Section N: CLI argument validation ==="

# N1 — unknown flag → die.
n1="$(sb)"
oN1="$(run_raw "$n1" LUNARWING_SERVICE_MANAGER=systemd -- --bogus)"; RC=$?
assert_contains "$oN1" "unknown arg: --bogus" "N1: unknown flag dies"
assert_eq "$RC" "1" "N1: unknown flag exits 1"

# N2 — --help → usage, exit 0.
n2="$(sb)"
oN2="$(run_raw "$n2" LUNARWING_SERVICE_MANAGER=systemd -- --help)"; RC=$?
assert_contains "$oN2" "Usage: lunarwing-self-heal.sh" "N2: --help prints usage"
assert_eq "$RC" "0" "N2: --help exits 0"

# N3 — flags are parsed and reflected in the config banner.
n3="$(sb)"; report "$n3" "$GW"
oN3="$(run_raw "$n3" LUNARWING_SERVICE_MANAGER=systemd GOTIFY_TOKEN='' -- \
    --dry-run --report "$n3/report.json" --backoff 0 \
    --max-retries 7 --grace-checks 4 --backoff-strategy linear --backoff-base 123 --backoff-max 999 --prune-ttl 0 --verify-health false)"
assert_contains "$oN3" "max-retries=7"   "N3: --max-retries parsed"
assert_contains "$oN3" "grace=4"         "N3: --grace-checks parsed"
assert_contains "$oN3" "backoff=linear"  "N3: --backoff-strategy parsed"
assert_contains "$oN3" "base=123s"       "N3: --backoff-base parsed"
assert_contains "$oN3" "verify=false"    "N3: --verify-health parsed"

finish

