#!/usr/bin/env bash
# Regression tests for lunarwing-self-heal.sh remediation target selection.
#
# Guards the jq operator-precedence bug where the init-system sub-unit pass
# (systemd/openrc/launchd `.metrics.units[]`) silently extracted nothing because
# `|` binds looser than `,` in jq, so each alternative's trailing string literal
# was piped into the next alternative's `.metrics` index and aborted the filter.
# That failure was masked by `2>/dev/null || true`, so a broken units sweep would
# have passed unnoticed without an assertion like the ones below.
#
# Run:  bash tests/test-self-heal.sh   (exit 0 = pass, 1 = fail)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF_HEAL="$SCRIPT_DIR/../lunarwing-self-heal.sh"

fail=0
pass=0
assert_contains() { # haystack needle msg
    if grep -qF -- "$2" <<<"$1"; then
        printf 'PASS: %s\n' "$3"; pass=$((pass + 1))
    else
        printf 'FAIL: %s\n      expected to find: %s\n' "$3" "$2"; fail=$((fail + 1))
    fi
}
assert_absent() { # haystack needle msg
    if grep -qF -- "$2" <<<"$1"; then
        printf 'FAIL: %s\n      unexpected match: %s\n' "$3" "$2"; fail=$((fail + 1))
    else
        printf 'PASS: %s\n' "$3"; pass=$((pass + 1))
    fi
}

[[ -x "$SELF_HEAL" ]] || { echo "FATAL: $SELF_HEAL not found/executable"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/selfheal-regress.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
REPORT="$TMP/report.json"
mkdir -p "$TMP/self-heal"

# Report with: a degraded standard component (gateway), a no-remedy component
# (omemo), and a systemd component whose metrics.units list mixes healthy and
# unhealthy sub-units. The unhealthy sub-unit is the regression's focus.
jq -n '{
  timestamp: "2026-06-08T00:00:00Z",
  overall_status: "critical",
  components: [
    {component:"gateway", status:"degraded", metrics:{}},
    {component:"omemo",   status:"critical", metrics:{}},
    {component:"systemd", status:"degraded", metrics:{units:[
      {name:"lunarwing-watchdog.service", status:"healthy"},
      {name:"clickhouse-server.service",  status:"critical"}
    ]}}
  ],
  alerts: []
}' > "$REPORT"

out="$(LUNARWING_BASE_DIR="$TMP" LUNARWING_SERVICE_MANAGER=systemd \
       SELF_HEAL_STATE_DIR="$TMP/self-heal" \
       "$SELF_HEAL" --dry-run --report "$REPORT" --backoff 0 2>&1)"

# Core regression: the unhealthy systemd sub-unit MUST be selected for restart.
assert_contains "$out" "systemctl restart clickhouse-server.service" \
    "unhealthy systemd sub-unit is targeted for remediation"
# The standard degraded component still maps via SERVICE_MAP.
assert_contains "$out" "systemctl restart lunarwing" \
    "degraded gateway component maps to lunarwing service"
# Healthy sub-units must be left alone.
assert_absent "$out" "restart lunarwing-watchdog.service" \
    "healthy systemd sub-unit is NOT restarted"
# No-remedy components are skipped, never restarted.
assert_absent "$out" "restart omemo" \
    "no-remedy component (omemo) is not restarted"
# The jq filter must not have aborted (would print a jq error to the captured output).
assert_absent "$out" "Cannot index string" \
    "pass-2 jq filter does not abort with a precedence error"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
