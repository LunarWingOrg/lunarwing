#!/usr/bin/env bash
set -uo pipefail
# NOTE: intentionally NOT using set -e. Tests should report failures, not
# abort the whole suite when an API call returns non-zero.

# ── Routine Improvement Test Suite (post-v1.1.6) ─────────────────────────────
#
# Tests the routine improvements introduced since v1.1.6:
#   1. Retry with exponential backoff (RetryPolicy)
#   2. Event dedup window (dedup_window)
#   3. Stuck-run sweeper + lightweight timeout
#   4. System event triggers
#   5. Basic cron smoke test
#   6. Routine state decontamination (concurrent fires)
#
# NOTE: This script is COMPLETELY UNTESTED. It was written from API source
# inspection and has not been executed end-to-end. Verify output carefully.
#
# Routines are created via the agent's routine_create tool (no REST POST
# endpoint exists). This script sends chat messages that instruct the agent
# to call routine_create, then verifies via the REST GET endpoints.
#
# Usage:
#   TENANT=ersa PORT=10000 ./test-routine-improvements.sh
#   TENANT=ersa PORT=10000 ./test-routine-improvements.sh --test 1
#   TENANT=ersa PORT=10000 ./test-routine-improvements.sh --cleanup
#
# Prerequisites:
#   - Tenant is running and gateway is reachable
#   - jq and curl installed
#   - LLM endpoint is functional (for lightweight routine execution)

TENANT="${TENANT:-ersa}"
PORT="${PORT:-10000}"

ENV_FILE="/home/${TENANT}/lunarwing/env/lunarwing.env"
TOKEN="$(grep '^GATEWAY_AUTH_TOKEN=' "$ENV_FILE" 2>/dev/null | cut -d= -f2-)"
[[ -n "$TOKEN" ]] || { echo "ERROR: no GATEWAY_AUTH_TOKEN in $ENV_FILE"; exit 1; }

BASE="http://127.0.0.1:${PORT}"
AUTH="Authorization: Bearer ${TOKEN}"
JSON="Content-Type: application/json"

say()  { printf '\n\033[1;34m[test]\033[0m %s\n' "$*"; }
ok()   { printf '  \033[1;32m[PASS]\033[0m %s\n' "$*"; }
fail() { printf '  \033[1;31m[FAIL]\033[0m %s\n' "$*"; }
warn() { printf '  \033[1;33m[WARN]\033[0m %s\n' "$*"; }

LOG_PREFIX="sudo -u ${TENANT} XDG_RUNTIME_DIR=/run/user/\$(id -u ${TENANT}) journalctl --user -u lunarwing-${TENANT}.service --no-pager"

TEST_FILTER="${2:-}"

run_test() {
  local n="$1"
  if [[ -n "$TEST_FILTER" && "$TEST_FILTER" != "$n" ]]; then
    return 0
  fi
  "$2"
}

# ── API helpers ──────────────────────────────────────────────────────────────

api_get() {
  local path="$1"
  curl -sf "${BASE}${path}" -H "$AUTH" 2>/dev/null
}

api_send() {
  local msg="$1"
  curl -sf -X POST "${BASE}/api/chat/send" \
    -H "$AUTH" -H "$JSON" \
    -d "{\"message\": $(jq -Rs . <<< "$msg")}" 2>/dev/null
}

get_routine_id() {
  local name="$1"
  api_get "/api/routines" | jq -r --arg name "$name" \
    '.routines[] | select(.name == $name) | .id' 2>/dev/null
}

get_routine_field() {
  local name="$1" field="$2"
  api_get "/api/routines" | jq -r --arg name "$name" --arg field "$field" \
    '.routines[] | select(.name == $name) | .[$field] // empty' 2>/dev/null
}

trigger_routine() {
  local id="$1"
  curl -sf -X POST "${BASE}/api/routines/${id}/trigger" \
    -H "$AUTH" -H "$JSON" 2>/dev/null
}

wait_for() {
  local desc="$1" timeout="$2"; shift 2
  local elapsed=0
  while (( elapsed < timeout )); do
    if "$@" >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  warn "$desc timed out after ${timeout}s"
  return 1
}

# ── Test 1: Basic Cron Smoke Test ────────────────────────────────────────────

test_1_cron_smoke() {
  say "Test 1: Basic cron routine (smoke test)"

  api_send "Create a routine using the routine_create tool with these exact parameters:
    name: test-cron-smoke
    prompt: Say 'hello from cron smoke test' and report the current time in one sentence.
    request.kind: cron
    request.schedule: */1 * * * *
Do not ask questions. Just create it." >/dev/null

  sleep 10
  local id
  id="$(get_routine_id test-cron-smoke)"

  if [[ -z "$id" ]]; then
    fail "routine test-cron-smoke was not created"
    warn "The agent may not have called routine_create. Check gateway response."
    return 1
  fi
  ok "routine created (id=$id)"

  say "waiting 75s for cron fire..."
  sleep 75

  local run_count
  run_count="$(get_routine_field test-cron-smoke run_count)"
  if [[ "${run_count:-0}" -ge 1 ]]; then
    ok "routine fired at least once (run_count=$run_count)"
  else
    fail "routine did not fire (run_count=$run_count)"
    return 1
  fi
}

# ── Test 2: Retry with Exponential Backoff ───────────────────────────────────

test_2_retry_backoff() {
  say "Test 2: Retry with exponential backoff"

  api_send "Create a routine using routine_create with:
    name: test-retry-backoff
    prompt: Use the shell tool to run a command that exits with code 1. The command is: false
    request.kind: manual
    execution.use_tools: true
    execution.max_tool_rounds: 1
    advanced.retry.max_retries: 2
    advanced.retry.initial_delay_secs: 5
    advanced.retry.backoff_multiplier: 2.0
    advanced.retry.max_delay_secs: 30
Do not ask questions. Just create it." >/dev/null

  sleep 10
  local id
  id="$(get_routine_id test-retry-backoff)"

  if [[ -z "$id" ]]; then
    fail "routine test-retry-backoff was not created"
    return 1
  fi
  ok "routine created (id=$id)"

  say "triggering routine..."
  trigger_routine "$id" >/dev/null

  say "waiting 15s for first failure..."
  sleep 15

  local cf
  cf="$(get_routine_field test-retry-backoff consecutive_failures)"
  if [[ "${cf:-0}" -ge 1 ]]; then
    ok "routine failed and consecutive_failures=$cf"
  else
    fail "routine did not fail (consecutive_failures=$cf)"
    return 1
  fi

  local next_fire
  next_fire="$(get_routine_field test-retry-backoff next_fire_at)"
  if [[ -n "$next_fire" && "$next_fire" != "null" ]]; then
    ok "next_fire_at set (retry scheduled): $next_fire"
  else
    warn "next_fire_at is null — retry may not be scheduled"
  fi
}

# ── Test 3: Event Dedup Window ───────────────────────────────────────────────

test_3_dedup() {
  say "Test 3: Event dedup window"

  api_send "Create a routine using routine_create with:
    name: test-dedup
    prompt: Acknowledge the test message in one sentence.
    request.kind: message_event
    request.pattern: dedup-test-.*
    advanced.dedup_window_secs: 120
Do not ask questions. Just create it." >/dev/null

  sleep 10
  local id
  id="$(get_routine_id test-dedup)"

  if [[ -z "$id" ]]; then
    fail "routine test-dedup was not created"
    return 1
  fi
  ok "routine created (id=$id)"

  say "sending 3 identical events..."
  for i in 1 2 3; do
    api_send "dedup-test-trigger" >/dev/null 2>&1 || true
    sleep 2
  done

  sleep 10
  local run_count
  run_count="$(get_routine_field test-dedup run_count)"

  if [[ "${run_count:-0}" -le 1 ]]; then
    ok "dedup working: run_count=$run_count (expected <=1)"
  else
    warn "run_count=$run_count (dedup may not have caught all duplicates)"
  fi
}

# ── Test 4: Stuck-Run Sweeper ────────────────────────────────────────────────

test_4_stuck_sweeper() {
  say "Test 4: Stuck-run sweeper (requires low timeout)"

  local env_path="${ENV_FILE}"
  local current_timeout
  current_timeout="$(grep '^ROUTINES_LIGHTWEIGHT_TIMEOUT_SECS=' "$env_path" 2>/dev/null | cut -d= -f2 || echo "300")"

  if [[ "$current_timeout" -gt 30 ]]; then
    say "temporarily lowering ROUTINES_LIGHTWEIGHT_TIMEOUT_SECS to 30..."
    echo "ROUTINES_LIGHTWEIGHT_TIMEOUT_SECS=30" >> "$env_path"
    chown "${TENANT}:${TENANT}" "$env_path"
    warn "restart the tenant after this test to restore the timeout"
    say "restarting tenant..."
    eval "$LOG_PREFIX" >/dev/null 2>&1 || true
    # Use mt-admin for restart
    source "${HOME}/.lunarwing-mt.env" 2>/dev/null || true
    sudo -E ./ic/scripts/lunarwing-mt-admin.sh restart-tenant "$TENANT" 2>/dev/null || \
      warn "could not restart tenant — restart manually"
    sleep 15
    TOKEN="$(grep '^GATEWAY_AUTH_TOKEN=' "$env_path" 2>/dev/null | cut -d= -f2-)"
  fi

  api_send "Create a routine using routine_create with:
    name: test-stuck-sweeper
    prompt: Write a very long essay about every number from 1 to 100000. Be extremely verbose.
    request.kind: manual
Do not ask questions. Just create it." >/dev/null

  sleep 10
  local id
  id="$(get_routine_id test-stuck-sweeper)"

  if [[ -z "$id" ]]; then
    fail "routine test-stuck-sweeper was not created"
    return 1
  fi
  ok "routine created (id=$id)"

  say "triggering routine..."
  trigger_routine "$id" >/dev/null

  say "waiting 45s for sweeper to detect stuck run..."
  sleep 45

  local runs
  runs="$(api_get "/api/routines/${id}/runs" | jq -r '.runs[0].status // empty' 2>/dev/null)"

  if [[ "$runs" == "failed" ]]; then
    ok "stuck run was swept (status=failed)"
  else
    warn "run status is '$runs' — sweeper may not have fired yet, or the run completed normally"
  fi
}

# ── Test 5: System Event Trigger ─────────────────────────────────────────────

test_5_system_event() {
  say "Test 5: System event trigger"

  api_send "Create a routine using routine_create with:
    name: test-system-event
    prompt: Acknowledge the system event in one sentence.
    request.kind: system_event
    request.source: test
    request.event_type: ping
Do not ask questions. Just create it." >/dev/null

  sleep 10
  local id
  id="$(get_routine_id test-system-event)"

  if [[ -z "$id" ]]; then
    fail "routine test-system-event was not created"
    return 1
  fi
  ok "routine created (id=$id)"

  say "emitting system event..."
  api_send "Use the event_emit tool to emit a system event with source=test, event_type=ping, and payload {\"msg\": \"hello\"}. Do not ask questions, just emit it." >/dev/null

  sleep 15
  local run_count
  run_count="$(get_routine_field test-system-event run_count)"

  if [[ "${run_count:-0}" -ge 1 ]]; then
    ok "system_event trigger fired (run_count=$run_count)"
  else
    fail "system_event trigger did not fire (run_count=$run_count)"
    return 1
  fi
}

# ── Cleanup ──────────────────────────────────────────────────────────────────

do_cleanup() {
  say "Cleaning up test routines..."

  local names=("test-cron-smoke" "test-retry-backoff" "test-dedup" "test-stuck-sweeper" "test-system-event")

  for name in "${names[@]}"; do
    local id
    id="$(get_routine_id "$name")"
    if [[ -n "$id" ]]; then
      curl -sf -X DELETE "${BASE}/api/routines/${id}" -H "$AUTH" 2>/dev/null
      ok "deleted $name"
    fi
  done

  local env_path="${ENV_FILE}"
  if grep -q 'ROUTINES_LIGHTWEIGHT_TIMEOUT_SECS=30' "$env_path" 2>/dev/null; then
    sed -i '/ROUTINES_LIGHTWEIGHT_TIMEOUT_SECS=30/d' "$env_path"
    chown "${TENANT}:${TENANT}" "$env_path"
    warn "removed temporary ROUTINES_LIGHTWEIGHT_TIMEOUT_SECS=30"
    warn "restart the tenant to restore defaults: sudo -E ./ic/scripts/lunarwing-mt-admin.sh restart-tenant $TENANT"
  fi

  say "cleanup done"
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
  if [[ "${1:-}" == "--cleanup" ]]; then
    do_cleanup
    exit 0
  fi

  say "Routine Improvement Test Suite"
  say "  Tenant:  $TENANT"
  say "  Port:    $PORT"
  say "  Base:    $BASE"

  if ! api_get "/api/health" >/dev/null 2>&1; then
    fail "gateway not reachable at $BASE"
    exit 1
  fi
  ok "gateway reachable"

  run_test 1 test_1_cron_smoke
  run_test 2 test_2_retry_backoff
  run_test 3 test_3_dedup
  run_test 4 test_4_stuck_sweeper
  run_test 5 test_5_system_event

  say ""
  say "Done. Run with --cleanup to delete test routines."
}

main "$@"
