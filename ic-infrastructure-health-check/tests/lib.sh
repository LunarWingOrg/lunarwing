#!/usr/bin/env bash
# Shared test harness for the LunarWing self-heal chaos suite.
#
# Sourced by test-self-heal-matrix.sh (dry-run unit matrix) and
# chaos-harness.sh (end-to-end, non-dry-run against a mock init system).
# Provides:
#   - assertion helpers + pass/fail counters
#   - a per-suite sandbox ($ROOT, auto-cleaned) and sandbox builder `sb`
#   - synthetic health-report + state-file helpers
#   - `run_dry` / `run_raw`            : drive the script under test
#   - `src_fn`                          : unit-test pure functions in isolation
#   - `mk_mockbin` + `run_chaos` + svc  : a fake init system for chaos scenarios
#
# A sourcing suite is expected to have already done `set -uo pipefail`
# (NOT `set -e` — assertions rely on non-zero exits being captured).

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SH="${SELF_HEAL_SCRIPT:-$LIB_DIR/../lunarwing-self-heal.sh}"

[[ -x "$SH" ]] || { echo "FATAL: self-heal script not found/executable at $SH"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 1; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/selfheal-chaos.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

# ── Assertions ───────────────────────────────────────────────────────────────

fail=0; pass=0
ok()  { printf 'PASS: %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL: %s\n      %s\n' "$1" "$2"; fail=$((fail + 1)); }

assert_contains() { if grep -qF -- "$2" <<<"$1"; then ok "$3"; else bad "$3" "expected substring: $2"; fi; }
assert_absent()   { if grep -qF -- "$2" <<<"$1"; then bad "$3" "unexpected substring: $2"; else ok "$3"; fi; }
assert_eq()       { if [[ "$1" == "$2" ]]; then ok "$3"; else bad "$3" "got [$1] want [$2]"; fi; }
assert_ne()       { if [[ "$1" != "$2" ]]; then ok "$3"; else bad "$3" "got [$1], expected it to differ"; fi; }
assert_range()    { # val lo hi msg
    if [[ "$1" =~ ^-?[0-9]+$ && "$1" -ge "$2" && "$1" -le "$3" ]]; then ok "$4"
    else bad "$4" "got [$1] not in [$2,$3]"; fi; }

# Print the per-suite tally and yield the suite's exit status (0 = all green).
finish() {
    printf '\n%d passed, %d failed\n' "$pass" "$fail"
    [[ "$fail" -eq 0 ]]
}

# ── Sandbox + report/state helpers ───────────────────────────────────────────

# A sandbox doubles as LUNARWING_BASE_DIR; self-heal state lives in <sb>/self-heal.
sb() { local d; d="$(mktemp -d "$ROOT/sb.XXXXXX")"; mkdir -p "$d/self-heal"; printf '%s' "$d"; }

# report <sb> <jq-expr>   — write a synthetic health-check report.json.
report() { jq -n "$2" > "$1/report.json"; }

# seed_state <sb> <jq-expr>  — pre-seed state.json (jq -n object expression).
seed_state() { jq -n "$2" > "$1/self-heal/state.json"; }

# state_of <sb> [jq-filter] — read back state.json (compact). Empty if absent.
state_of() { jq -c "${2:-.}" "$1/self-heal/state.json" 2>/dev/null; }

now() { date +%s; }

# A degraded-gateway report is the common fixture across many cases.
# shellcheck disable=SC2034  # part of the lib's API; read by the sourcing suites
GW='{components:[{component:"gateway",status:"degraded",metrics:{}}]}'

# mk_check <sb> <comp> <status>  — drop a fake health-<comp>.sh into <sb>/checks
# that always reports <status>, and echo the checks dir. Lets a dry-run verify
# resolve deterministically without touching the host's real services.
mk_check() {
    local sb="$1" comp="$2" status="$3" dir="$1/checks"
    mkdir -p "$dir"
    {
        echo '#!/usr/bin/env bash'
        echo "echo '{\"status\":\"$status\"}'"
    } > "$dir/health-$comp.sh"
    chmod +x "$dir/health-$comp.sh"
    printf '%s' "$dir"
}

# ── Drivers (dry-run unit matrix) ────────────────────────────────────────────

# run_dry <sb> [ENV=VAL ...] [-- <script args>]
#   Always --dry-run, auto-targets <sb>/report.json, settle backoff 0 (fast).
run_dry() {
    local sb="$1"; shift
    local -a envs=() args=()
    while [[ $# -gt 0 && "$1" != "--" ]]; do envs+=("$1"); shift; done
    [[ "${1:-}" == "--" ]] && shift
    args=("$@")
    env LUNARWING_BASE_DIR="$sb" SELF_HEAL_STATE_DIR="$sb/self-heal" GOTIFY_TOKEN='' "${envs[@]}" \
        "$SH" --dry-run --report "$sb/report.json" --backoff 0 "${args[@]}" 2>&1
}

# run_raw <sb> [ENV=VAL ...] [-- <script args>]   — no implicit flags; captures
# the exit code into the global RC. Use for report-discovery / arg-parse / exit
# tests where --report or --dry-run must NOT be force-injected.
RC=0
run_raw() {
    local sb="$1"; shift
    local -a envs=() args=()
    while [[ $# -gt 0 && "$1" != "--" ]]; do envs+=("$1"); shift; done
    [[ "${1:-}" == "--" ]] && shift
    args=("$@")
    local out
    out="$(env LUNARWING_BASE_DIR="$sb" SELF_HEAL_STATE_DIR="$sb/self-heal" GOTIFY_TOKEN='' "${envs[@]}" \
        "$SH" "${args[@]}" 2>&1)"
    # shellcheck disable=SC2034  # RC is read by the sourcing suites after run_raw
    RC=$?
    printf '%s' "$out"
}

# ── Pure-function harness ────────────────────────────────────────────────────
#
# Source the script body (everything before the HARNESS_ENTRY_POINT marker) and
# call one function, fully isolated in a `bash -c` subshell so the script's
# `set -e` and one-time config never leak into the suite. Lets us unit-test
# compute_backoff, jq state helpers, etc. deterministically.

_BODY=""
_ensure_body() {
    [[ -n "$_BODY" && -f "$_BODY" ]] && return 0
    # We source everything before the HARNESS_ENTRY_POINT sentinel in the
    # script. Guard that anchor (and the result) so a future restructure of
    # lunarwing-self-heal.sh fails HERE with a clear message instead of silently
    # yielding a truncated body and cryptic downstream errors. (Baud review P1.)
    grep -qE '^# HARNESS_ENTRY_POINT$' "$SH" || {
        echo "FATAL: src_fn: no '# HARNESS_ENTRY_POINT' sentinel in $SH — the" \
             "extraction boundary moved; add the marker before main() in" \
             "lunarwing-self-heal.sh, then update lib.sh:_ensure_body" >&2
        exit 1
    }
    _BODY="$ROOT/self-heal-body.sh"
    sed '/^# HARNESS_ENTRY_POINT$/,$d' "$SH" > "$_BODY"
    if [[ ! -s "$_BODY" ]] || ! grep -qE '^compute_backoff\(\)' "$_BODY"; then
        echo "FATAL: src_fn: extracted body looks wrong (empty, or missing" \
             "compute_backoff) — check lib.sh:_ensure_body against $SH" >&2
        exit 1
    fi
}

# src_fn [ENV=VAL ...] -- <fn> [args...]   — echoes the function's stdout.
# The body carries the script's top-level arg-parse loop and `set -e`; we source
# it with positional args cleared (so the loop is a no-op) and only THEN call the
# target function, all inside `bash -c` so nothing leaks back into the suite.
src_fn() {
    _ensure_body
    local -a envs=()
    while [[ $# -gt 0 && "$1" != "--" ]]; do envs+=("$1"); shift; done
    [[ "${1:-}" == "--" ]] && shift
    # shellcheck disable=SC2016  # body must stay unexpanded; args are passed positionally
    env "${envs[@]}" bash -c '
        b="$1"; shift
        f="$1"; shift
        a=("$@")
        set --                       # neutralize the body arg-parser
        source "$b"
        if [[ ${#a[@]} -gt 0 ]]; then "$f" "${a[@]}"; else "$f"; fi
    ' _ "$_BODY" "$@" 2>/dev/null
}

# ── Mock init system (chaos: real restarts, no real services) ────────────────
#
# mk_mockbin <sb> installs fake systemctl/rc-service/sudo + per-component health
# scripts into <sb>/bin, all driven by files under <sb>/svcstate:
#   <svc>              -> "up" | "down"      (service liveness)
#   restarts/<svc>     -> integer            (restart attempts observed)
#   fail/<svc>         -> marker             (restart command returns non-zero)
#   stuck/<svc>        -> marker             (restart "succeeds" but stays down)
# Point the run at it with run_chaos (sets PATH + SVC_STATE_DIR + HEALTH dir).

mk_mockbin() {
    local sb="$1" bin="$1/bin" ss="$1/svcstate"
    mkdir -p "$bin" "$ss/restarts" "$ss/fail" "$ss/stuck"

    cat > "$bin/systemctl" <<'EOF'
#!/usr/bin/env bash
SS="${SVC_STATE_DIR:?}"
sub="${1:-}"; shift || true
case "$sub" in
  --user) exec "$0" "$@" ;;                      # systemctl --user <...>  → recurse
  is-active)
    svc=""; for a in "$@"; do case "$a" in --quiet|--user) ;; *) svc="$a";; esac; done
    [[ "$(cat "$SS/$svc" 2>/dev/null)" == up ]] ;;
  restart)
    svc=""; for a in "$@"; do case "$a" in --user) ;; *) svc="$a";; esac; done
    [[ -f "$SS/fail/$svc" ]] && { echo "mock systemctl: restart $svc failed" >&2; exit 1; }
    n=$(cat "$SS/restarts/$svc" 2>/dev/null || echo 0); echo $((n+1)) > "$SS/restarts/$svc"
    [[ -f "$SS/stuck/$svc" ]] || echo up > "$SS/$svc" ;;
  *) exit 0 ;;
esac
EOF

    cat > "$bin/rc-service" <<'EOF'
#!/usr/bin/env bash
SS="${SVC_STATE_DIR:?}"
svc="${1:-}"; action="${2:-}"
case "$action" in
  status) [[ "$(cat "$SS/$svc" 2>/dev/null)" == up ]] ;;
  restart)
    [[ -f "$SS/fail/$svc" ]] && { echo "mock rc-service: restart $svc failed" >&2; exit 1; }
    n=$(cat "$SS/restarts/$svc" 2>/dev/null || echo 0); echo $((n+1)) > "$SS/restarts/$svc"
    [[ -f "$SS/stuck/$svc" ]] || echo up > "$SS/$svc" ;;
  *) exit 0 ;;
esac
EOF

    # Mock sudo: drop leading `-n`, `-u <user>`, `env`, `VAR=VAL`, then exec the
    # rest — so `sudo -u t env XDG=.. systemctl --user restart u` hits our fake
    # systemctl with no privilege required.
    #
    # It is built for the EXACT invocations lunarwing-self-heal.sh makes for
    # per-tenant systemd USER units (see _systemd_user_restart/_systemd_user_active):
    #   sudo -u <user> env XDG_RUNTIME_DIR=/run/user/<uid> systemctl --user restart   <unit>
    #   sudo -u <user> env XDG_RUNTIME_DIR=/run/user/<uid> systemctl --user is-active --quiet <unit>
    # (a leading -n may also appear). If the script ever introduces a sudo flag
    # we don't model (-E, -i, -g, --preserve-env=...), warn loudly so the
    # resulting failure reads as mock drift, not a real defect. (Baud review P1.)
    cat > "$bin/sudo" <<'EOF'
#!/usr/bin/env bash
args=("$@"); i=0
while [[ $i -lt ${#args[@]} ]]; do
  case "${args[$i]}" in
    -n)  ;;                         # non-interactive
    -u)  i=$((i+1)) ;;              # -u <user>: also skip the username
    env) ;;                         # the `env` prefix
    -*)  echo "mock sudo: unrecognized flag '${args[$i]}' — update mk_mockbin (sudo invocation drift)" >&2
         break ;;
    *=*) ;;                         # VAR=VAL handed to env (no leading dash)
    *)   break ;;                   # start of the actual command
  esac
  i=$((i+1))
done
exec "${args[@]:$i}"
EOF

    # Per-component health checks used by post-restart verification.
    local comp svc
    for pair in gateway:lunarwing xmpp:xmpp-bridge tensorzero:tensorzero-gateway clickhouse:clickhouse-server; do
        comp="${pair%%:*}"; svc="${pair##*:}"
        cat > "$bin/health-$comp.sh" <<EOF
#!/usr/bin/env bash
SS="\${SVC_STATE_DIR:?}"
if [[ "\$(cat "\$SS/$svc" 2>/dev/null)" == up ]]; then printf '{"status":"healthy"}\n'
else printf '{"status":"critical"}\n'; fi
EOF
    done

    chmod +x "$bin"/*
}

# Service-state mutators / readers (chaos).
svc_up()    { echo up   > "$1/svcstate/$2"; }
svc_down()  { echo down > "$1/svcstate/$2"; }
svc_state() { cat "$1/svcstate/$2" 2>/dev/null || echo absent; }
svc_fail()  { : > "$1/svcstate/fail/$2"; }     # restart command will fail
svc_stuck() { : > "$1/svcstate/stuck/$2"; }    # restart "succeeds" but stays down
restarts_of() { cat "$1/svcstate/restarts/$2" 2>/dev/null || echo 0; }

# run_chaos <sb> <manager> [ENV=VAL ...] [-- <script args>]
#   Real run (NO --dry-run) against the mock init system. Settle 0 so verify is
#   immediate. GOTIFY_TOKEN='' keeps escalation from hitting the network.
run_chaos() {
    local sb="$1" mgr="$2"; shift 2
    local -a envs=() args=()
    while [[ $# -gt 0 && "$1" != "--" ]]; do envs+=("$1"); shift; done
    [[ "${1:-}" == "--" ]] && shift
    args=("$@")
    env PATH="$sb/bin:$PATH" SVC_STATE_DIR="$sb/svcstate" \
        LUNARWING_BASE_DIR="$sb" SELF_HEAL_STATE_DIR="$sb/self-heal" \
        LUNARWING_SERVICE_MANAGER="$mgr" SELF_HEAL_HEALTH_CHECK_DIR="$sb/bin" \
        GOTIFY_TOKEN='' "${envs[@]}" \
        "$SH" --report "$sb/report.json" --backoff 0 "${args[@]}" 2>&1
}
