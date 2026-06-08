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

# Pass 1 with the grace period (default 2) is held — the report lists
# clickhouse and gateway as unhealthy once, so they sit in the grace
# counter. The regression we're guarding is the jq filter producing the
# right TARGETS, not whether the restart fires on this first pass.
assert_contains "$out" "GRACE: lunarwing unhealthy streak=1/2" \
    "degraded gateway component enters grace period on first observation"
assert_contains "$out" "GRACE: clickhouse-server.service unhealthy streak=1/2" \
    "unhealthy systemd sub-unit enters grace period on first observation"
# Healthy sub-units must be left alone.
assert_absent "$out" "GRACE: lunarwing-watchdog.service" \
    "healthy systemd sub-unit does NOT enter grace period"
# No-remedy components are skipped, never restarted.
assert_absent "$out" "GRACE: omemo" \
    "no-remedy component (omemo) is not held in grace or restarted"
# The jq filter must not have aborted (would print a jq error to the captured output).
assert_absent "$out" "Cannot index string" \
    "pass-2 jq filter does not abort with a precedence error"

# Pass 2 (same state dir, same report) — grace period elapses, restart fires.
out2="$(LUNARWING_BASE_DIR="$TMP" LUNARWING_SERVICE_MANAGER=systemd \
       SELF_HEAL_STATE_DIR="$TMP/self-heal" \
       "$SELF_HEAL" --dry-run --report "$REPORT" --backoff 0 2>&1)"
assert_contains "$out2" "systemctl restart clickhouse-server.service" \
    "unhealthy systemd sub-unit is targeted for remediation on second consecutive check"
assert_contains "$out2" "systemctl restart lunarwing" \
    "degraded gateway component maps to lunarwing service on second consecutive check"
assert_absent "$out2" "restart lunarwing-watchdog.service" \
    "healthy systemd sub-unit is NOT restarted"

# ── Grace-period (flapping guard) tests ──────────────────────────────────────
# The default GRACE_CHECKS is 2: a service must be unhealthy on two
# consecutive runs before restart. We simulate this by re-using the same
# state directory across two --dry-run invocations.

STATEDIR2="$TMP/self-heal-grace"
mkdir -p "$STATEDIR2"

# Build a report with a single degraded standard component.
jq -n '{
  timestamp: "2026-06-08T00:00:00Z",
  overall_status: "critical",
  components: [
    {component:"gateway", status:"critical", metrics:{}}
  ],
  alerts: []
}' > "$TMP/grace-report.json"

# Pass 1: first unhealthy observation → grace hold, no restart.
out1="$(LUNARWING_BASE_DIR="$TMP" LUNARWING_SERVICE_MANAGER=systemd \
       SELF_HEAL_STATE_DIR="$STATEDIR2" \
       "$SELF_HEAL" --dry-run --report "$TMP/grace-report.json" --backoff 0 2>&1)"
assert_contains "$out1" "GRACE: lunarwing unhealthy streak=1/2" \
    "first unhealthy check is held in grace period"
assert_absent  "$out1" "RESTART: lunarwing" \
    "first unhealthy check does not trigger a restart"

# Pass 2: second consecutive unhealthy observation → restart now.
out2="$(LUNARWING_BASE_DIR="$TMP" LUNARWING_SERVICE_MANAGER=systemd \
       SELF_HEAL_STATE_DIR="$STATEDIR2" \
       "$SELF_HEAL" --dry-run --report "$TMP/grace-report.json" --backoff 0 2>&1)"
assert_contains "$out2" "RESTART: lunarwing" \
    "second consecutive unhealthy check triggers restart"
assert_absent  "$out2" "GRACE:" \
    "second consecutive unhealthy check is not held"

# Pass 3: send a fully-healthy report; the stale-state loop should clear
# the counter so a subsequent unhealthy report goes back to streak=1.
jq -n '{
  timestamp: "2026-06-08T00:00:00Z",
  overall_status: "healthy",
  components: [
    {component:"gateway", status:"healthy", metrics:{}}
  ],
  alerts: []
}' > "$TMP/grace-healthy.json"

out3="$(LUNARWING_BASE_DIR="$TMP" LUNARWING_SERVICE_MANAGER=systemd \
       SELF_HEAL_STATE_DIR="$STATEDIR2" \
       "$SELF_HEAL" --dry-run --report "$TMP/grace-healthy.json" --backoff 0 2>&1)"
assert_contains "$out3" "all components healthy" \
    "healthy report clears state"

# Pass 4: fresh unhealthy after healthy → streak resets to 1.
out4="$(LUNARWING_BASE_DIR="$TMP" LUNARWING_SERVICE_MANAGER=systemd \
       SELF_HEAL_STATE_DIR="$STATEDIR2" \
       "$SELF_HEAL" --dry-run --report "$TMP/grace-report.json" --backoff 0 2>&1)"
assert_contains "$out4" "GRACE: lunarwing unhealthy streak=1/2" \
    "unhealthy after healthy resets grace counter"
assert_absent  "$out4" "RESTART: lunarwing" \
    "unhealthy after healthy does not restart immediately"

# Override GRACE_CHECKS=1 (via env) → first unhealthy should restart immediately.
STATEDIR3="$TMP/self-heal-grace1"
mkdir -p "$STATEDIR3"
out5="$(LUNARWING_BASE_DIR="$TMP" LUNARWING_SERVICE_MANAGER=systemd \
       SELF_HEAL_STATE_DIR="$STATEDIR3" SELF_HEAL_GRACE_CHECKS=1 \
       "$SELF_HEAL" --dry-run --report "$TMP/grace-report.json" --backoff 0 2>&1)"
assert_contains "$out5" "RESTART: lunarwing" \
    "GRACE_CHECKS=1 restarts on first unhealthy observation"
assert_absent  "$out5" "GRACE:" \
    "GRACE_CHECKS=1 does not emit grace hold"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
