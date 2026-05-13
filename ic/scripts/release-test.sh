#!/usr/bin/env bash
# release-test.sh — Automated pre-release smoke tests for LunarWing.
#
# Hits the gateway API to verify core subsystems are alive and responding.
# Assumes a running LunarWing instance (standalone or via the test harness).
#
# Usage:
#   ./scripts/release-test.sh
#   GATEWAY_URL=http://localhost:9098 GATEWAY_AUTH_TOKEN=tok ./scripts/release-test.sh
#
# Exit code: 0 if all tests pass, 1 if any fail.
#
# ─── NOT AUTOMATED BY THIS SCRIPT ────────────────────────────────────────────
#
# The following checklist items from docs/guides/TESTING_GUIDE.md require
# manual verification or infrastructure that this script cannot provide:
#
#   Pre-Release Preparation (lines 13-16)
#     - Release scope documentation, stakeholder alignment, code freeze —
#       these are process/human-judgment steps.
#
#   XMPP channel (line 33)
#     - Requires a live XMPP account, bridge service, and OMEMO setup.
#       Use the test harness (lunarwing-xmpp-test-env.sh) for this.
#
#   WeeChat channel (line 34)
#     - Requires a running WeeChat relay. No test stub exists yet.
#
#   Sandbox worker (line 43)
#     - full_job routines need Docker and a built worker image.
#       Tested indirectly if Docker sandbox tests pass.
#
#   Nanocode external worker (line 47)
#     - Requires the nanocode container running. Use lunarcode4lunarwing/
#       smoke_test.ts for this (docker compose --profile smoke up agent-smoke).
#
#   Docker sandbox worker (line 48)
#     - Requires Docker daemon and lunarwing-worker image built.
#
#   GitHub integration (line 52)
#     - Requires a valid GITHUB_TOKEN with repo access.
#
#   Image tools (line 57)
#     - Requires LLM provider with vision/generation support.
#
#   Web search / LLM context (line 58)
#     - Requires a working LLM backend and search tool config.
#
#   REPL v2 (line 62)
#     - Interactive session — needs the unix socket client.
#
#   Performance & load testing (lines 83-85)
#     - Needs k6/locust harness (not yet written).
#
#   Rollback procedure (lines 89-92)
#     - Inherently manual — DB backup, binary swap, decision to rollback.
#
#   Post-release monitoring (lines 109-112)
#     - Needs Grafana/alerting infrastructure.
#
#   Documentation & release notes (lines 96-98)
#     - Human writing task.
#
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

GATEWAY_URL="${GATEWAY_URL:-http://localhost:9098}"
AUTH="${GATEWAY_AUTH_TOKEN:-}"

# ── Helpers ──────────────────────────────────────────────────────────────────

PASS=0
FAIL=0
SKIP=0
TOTAL=0

red()    { printf '\033[1;31m%s\033[0m' "$*"; }
green()  { printf '\033[1;32m%s\033[0m' "$*"; }
yellow() { printf '\033[1;33m%s\033[0m' "$*"; }
bold()   { printf '\033[1m%s\033[0m' "$*"; }

log_pass() { PASS=$((PASS + 1)); TOTAL=$((TOTAL + 1)); printf '  %s  %s\n' "$(green PASS)" "$1"; }
log_fail() { FAIL=$((FAIL + 1)); TOTAL=$((TOTAL + 1)); printf '  %s  %s\n' "$(red FAIL)" "$1"; }
log_skip() { SKIP=$((SKIP + 1)); TOTAL=$((TOTAL + 1)); printf '  %s  %s\n' "$(yellow SKIP)" "$1"; }

auth_header() {
  if [[ -n "$AUTH" ]]; then
    echo "Authorization: Bearer $AUTH"
  fi
}

# curl wrapper: GET with auth, return HTTP status code
api_get() {
  local path="$1"
  local url="${GATEWAY_URL}${path}"
  if [[ -n "$AUTH" ]]; then
    curl -sf -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $AUTH" "$url" 2>/dev/null || echo "000"
  else
    curl -sf -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || echo "000"
  fi
}

# curl wrapper: GET with auth, return body
api_get_body() {
  local path="$1"
  local url="${GATEWAY_URL}${path}"
  if [[ -n "$AUTH" ]]; then
    curl -sf -H "Authorization: Bearer $AUTH" "$url" 2>/dev/null || echo ""
  else
    curl -sf "$url" 2>/dev/null || echo ""
  fi
}

# curl wrapper: POST with auth and JSON body, return HTTP status code
api_post() {
  local path="$1"
  local body="${2:-{}}"
  local url="${GATEWAY_URL}${path}"
  if [[ -n "$AUTH" ]]; then
    curl -sf -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $AUTH" \
      -H "Content-Type: application/json" -d "$body" "$url" 2>/dev/null || echo "000"
  else
    curl -sf -o /dev/null -w '%{http_code}' -X POST \
      -H "Content-Type: application/json" -d "$body" "$url" 2>/dev/null || echo "000"
  fi
}

# curl wrapper: POST with auth, return body
api_post_body() {
  local path="$1"
  local body="${2:-{}}"
  local url="${GATEWAY_URL}${path}"
  if [[ -n "$AUTH" ]]; then
    curl -sf -X POST -H "Authorization: Bearer $AUTH" \
      -H "Content-Type: application/json" -d "$body" "$url" 2>/dev/null || echo ""
  else
    curl -sf -X POST \
      -H "Content-Type: application/json" -d "$body" "$url" 2>/dev/null || echo ""
  fi
}

# curl wrapper: DELETE with auth, return HTTP status code
api_delete() {
  local path="$1"
  local url="${GATEWAY_URL}${path}"
  if [[ -n "$AUTH" ]]; then
    curl -sf -o /dev/null -w '%{http_code}' -X DELETE -H "Authorization: Bearer $AUTH" "$url" 2>/dev/null || echo "000"
  else
    curl -sf -o /dev/null -w '%{http_code}' -X DELETE "$url" 2>/dev/null || echo "000"
  fi
}

assert_http_ok() {
  local label="$1"
  local status="$2"
  if [[ "$status" =~ ^2[0-9][0-9]$ ]]; then
    log_pass "$label"
  else
    log_fail "$label (HTTP $status)"
  fi
}

assert_body_contains() {
  local label="$1"
  local body="$2"
  local expected="$3"
  if echo "$body" | grep -q "$expected"; then
    log_pass "$label"
  else
    log_fail "$label (expected '$expected' in response)"
  fi
}

# ── Connectivity ─────────────────────────────────────────────────────────────

printf '\n%s\n' "$(bold '=== Gateway Connectivity ===')"

status=$(curl -sf -o /dev/null -w '%{http_code}' "${GATEWAY_URL}/api/health" 2>/dev/null || echo "000")
if [[ "$status" == "000" ]]; then
  printf '\n  %s  Cannot reach %s — is LunarWing running?\n\n' "$(red FATAL)" "$GATEWAY_URL"
  exit 1
fi
assert_http_ok "Health endpoint (/api/health)" "$status"

if [[ -z "$AUTH" ]]; then
  printf '\n  %s  GATEWAY_AUTH_TOKEN not set — authenticated endpoints will be skipped.\n' "$(yellow WARN)"
  printf '         Set it to run the full test suite.\n\n'
fi

# ── Gateway Status ───────────────────────────────────────────────────────────

printf '\n%s\n' "$(bold '=== Gateway Status ===')"

if [[ -n "$AUTH" ]]; then
  body=$(api_get_body "/api/gateway/status")
  assert_body_contains "Gateway status returns uptime" "$body" "uptime"
else
  log_skip "Gateway status (no auth token)"
fi

# ── Database & Config ────────────────────────────────────────────────────────

printf '\n%s\n' "$(bold '=== Database & Config ===')"

assert_http_ok "Web gateway serves pages (/)" "$(api_get "/")"

if [[ -n "$AUTH" ]]; then
  status=$(api_get "/api/settings")
  assert_http_ok "Settings endpoint responds" "$status"

  body=$(api_get_body "/api/settings/export")
  assert_body_contains "Settings export returns data" "$body" "{"
else
  log_skip "Settings endpoint (no auth token)"
  log_skip "Settings export (no auth token)"
fi

# ── Memory / Workspace ───────────────────────────────────────────────────────

printf '\n%s\n' "$(bold '=== Memory & Workspace ===')"

if [[ -n "$AUTH" ]]; then
  status=$(api_get "/api/memory/tree")
  assert_http_ok "Memory tree" "$status"

  status=$(api_get "/api/memory/list?path=.")
  assert_http_ok "Memory list" "$status"

  # Write a test file, read it back, then clean up
  write_status=$(api_post "/api/memory/write" '{"path":"_release_test_probe.txt","content":"release-test-probe"}')
  if [[ "$write_status" =~ ^2[0-9][0-9]$ ]]; then
    log_pass "Memory write"
    read_body=$(api_get_body "/api/memory/read?path=_release_test_probe.txt")
    assert_body_contains "Memory read" "$read_body" "release-test-probe"
    # Clean up
    api_post "/api/memory/write" '{"path":"_release_test_probe.txt","content":""}' >/dev/null 2>&1
  else
    log_fail "Memory write (HTTP $write_status)"
    log_skip "Memory read (write failed)"
  fi

  search_status=$(api_post "/api/memory/search" '{"query":"test"}')
  assert_http_ok "Memory search" "$search_status"
else
  log_skip "Memory tree (no auth token)"
  log_skip "Memory list (no auth token)"
  log_skip "Memory write (no auth token)"
  log_skip "Memory read (no auth token)"
  log_skip "Memory search (no auth token)"
fi

# ── Routines ─────────────────────────────────────────────────────────────────

printf '\n%s\n' "$(bold '=== Routines ===')"

if [[ -n "$AUTH" ]]; then
  status=$(api_get "/api/routines")
  assert_http_ok "List routines" "$status"

  body=$(api_get_body "/api/routines/summary")
  assert_body_contains "Routines summary" "$body" "total"
else
  log_skip "List routines (no auth token)"
  log_skip "Routines summary (no auth token)"
fi

# ── Jobs ─────────────────────────────────────────────────────────────────────

printf '\n%s\n' "$(bold '=== Jobs ===')"

if [[ -n "$AUTH" ]]; then
  status=$(api_get "/api/jobs")
  assert_http_ok "List jobs" "$status"

  body=$(api_get_body "/api/jobs/summary")
  assert_body_contains "Jobs summary" "$body" "{"
else
  log_skip "List jobs (no auth token)"
  log_skip "Jobs summary (no auth token)"
fi

# ── Skills ───────────────────────────────────────────────────────────────────

printf '\n%s\n' "$(bold '=== Skills ===')"

if [[ -n "$AUTH" ]]; then
  status=$(api_get "/api/skills")
  assert_http_ok "List skills" "$status"

  search_status=$(api_post "/api/skills/search" '{"query":"github"}')
  assert_http_ok "Search skills" "$search_status"
else
  log_skip "List skills (no auth token)"
  log_skip "Search skills (no auth token)"
fi

# ── Extensions ───────────────────────────────────────────────────────────────

printf '\n%s\n' "$(bold '=== Extensions ===')"

if [[ -n "$AUTH" ]]; then
  status=$(api_get "/api/extensions")
  assert_http_ok "List extensions" "$status"

  status=$(api_get "/api/extensions/tools")
  assert_http_ok "List registered tools" "$status"

  status=$(api_get "/api/extensions/registry")
  assert_http_ok "Extension registry" "$status"
else
  log_skip "List extensions (no auth token)"
  log_skip "List registered tools (no auth token)"
  log_skip "Extension registry (no auth token)"
fi

# ── Chat / Threads ───────────────────────────────────────────────────────────

printf '\n%s\n' "$(bold '=== Chat & Threads ===')"

if [[ -n "$AUTH" ]]; then
  status=$(api_get "/api/chat/threads")
  assert_http_ok "List threads" "$status"

  # Send a simple message that exercises the time tool (no external deps)
  send_status=$(api_post "/api/chat/send" '{"message":"What time is it? Use the time tool.","thread_id":"release-test"}')
  assert_http_ok "Send chat message" "$send_status"
else
  log_skip "List threads (no auth token)"
  log_skip "Send chat message (no auth token)"
fi

# ── Gotify ───────────────────────────────────────────────────────────────────

printf '\n%s\n' "$(bold '=== Gotify ===')"

if [[ -n "$AUTH" ]]; then
  tools_body=$(api_get_body "/api/extensions/tools")
  if echo "$tools_body" | grep -q '"gotify"'; then
    log_pass "Gotify tool registered"
  else
    log_skip "Gotify tool not installed"
  fi
else
  log_skip "Gotify tool check (no auth token)"
fi

# ── Secret Management ────────────────────────────────────────────────────────

printf '\n%s\n' "$(bold '=== Secrets ===')"

if [[ -n "$AUTH" ]]; then
  # secret_list is a tool, so we test it via a chat message
  # For now, just verify the secrets subsystem doesn't crash the settings export
  body=$(api_get_body "/api/settings/export")
  if echo "$body" | grep -qi "secret\|token\|key\|password"; then
    # Check that actual values aren't leaked (should be redacted or absent)
    if echo "$body" | grep -qiE '"(sk-|ghp_|xoxb-|Bearer )'; then
      log_fail "Secrets: possible credential leak in settings export"
    else
      log_pass "Secrets: no credential leak in settings export"
    fi
  else
    log_pass "Secrets: no sensitive keys in settings export"
  fi
else
  log_skip "Secrets check (no auth token)"
fi

# ── Log Endpoint ─────────────────────────────────────────────────────────────

printf '\n%s\n' "$(bold '=== Logging ===')"

if [[ -n "$AUTH" ]]; then
  # GET log level (not SSE stream — just the level endpoint)
  body=$(api_get_body "/api/logs/level")
  if [[ -n "$body" ]]; then
    log_pass "Log level endpoint"
  else
    log_fail "Log level endpoint (empty response)"
  fi
else
  log_skip "Log level endpoint (no auth token)"
fi

# ── Summary ──────────────────────────────────────────────────────────────────

printf '\n%s\n' "$(bold '=== Results ===')"
printf '  Total: %d  |  ' "$TOTAL"
green "Passed: $PASS"; printf '  |  '
if [[ $FAIL -gt 0 ]]; then
  red "Failed: $FAIL"
else
  printf 'Failed: 0'
fi
printf '  |  '
if [[ $SKIP -gt 0 ]]; then
  yellow "Skipped: $SKIP"
else
  printf 'Skipped: 0'
fi
printf '\n\n'

if [[ $FAIL -gt 0 ]]; then
  printf '  %s\n\n' "$(red 'Some tests failed — see above for details.')"
  exit 1
else
  printf '  %s\n\n' "$(green 'All tests passed.')"
  exit 0
fi
