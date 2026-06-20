#!/usr/bin/env bash
# Smoke-test the LunarWing multica-bridge against a running Multica/Lunartica
# server by replaying the bridge tool's EXACT daemon-protocol HTTP calls, plus
# the workspace-scoping contract that the bridge depends on.
#
# Two modes:
#   1. Self-seed (local dev, default): when MULTICA_PAT is unset, log in via the
#      dev verification-code bypass and create a throwaway workspace + PAT. The
#      server must be started with MULTICA_DEV_VERIFICATION_CODE set and
#      APP_ENV != production (see multica-local-test-server.sh).
#   2. Bring-your-own creds: set MULTICA_PAT and MULTICA_WS to test against an
#      existing server/workspace without creating anything.
#
# Env:
#   MULTICA_URL       Base URL (default http://localhost:8080)
#   MULTICA_PAT       Personal access token (mul_...). If set, skips seeding.
#   MULTICA_WS        Workspace UUID (required when MULTICA_PAT is set).
#   MULTICA_DEV_CODE  Dev verification code for self-seed (default 424242).
#   MULTICA_EMAIL     Email for self-seed (default bridge-test-<ts>@example.com).
#
# Requires: curl, jq. Exit code = number of failed checks.
set -u

BASE="${MULTICA_URL:-http://localhost:8080}"
PAT="${MULTICA_PAT:-}"
WSID="${MULTICA_WS:-}"
DEVCODE="${MULTICA_DEV_CODE:-424242}"
TS="$(date +%s)"
EMAIL="${MULTICA_EMAIL:-bridge-test-$TS@example.com}"

command -v curl >/dev/null || { echo "curl required"; exit 2; }
command -v jq   >/dev/null || { echo "jq required"; exit 2; }

TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
pass=0; fail=0
chk() { if [ "$1" = "$2" ]; then echo "  ✓ $3 (HTTP $1)"; pass=$((pass+1)); else echo "  ✗ $3 (got HTTP $1, want $2)"; fail=$((fail+1)); fi; }
hc()  { curl -s -o "$TMP" -w '%{http_code}' "$@"; }   # echoes status; body lands in $TMP

echo "== target: $BASE =="
for _ in $(seq 1 60); do curl -sf "$BASE/health" >/dev/null 2>&1 && break; sleep 1; done

if [ -z "$PAT" ]; then
  echo "== self-seed via dev verification code =="
  code=$(hc -X POST "$BASE/auth/send-code" -H 'Content-Type: application/json' -d "{\"email\":\"$EMAIL\"}"); chk "$code" 200 "send-code"
  JWT=$(curl -s -X POST "$BASE/auth/verify-code" -H 'Content-Type: application/json' -d "{\"email\":\"$EMAIL\",\"code\":\"$DEVCODE\"}" | jq -r '.token // empty')
  [ -n "$JWT" ] || { echo "  FATAL: no JWT (is MULTICA_DEV_VERIFICATION_CODE set on the server?)"; exit 1; }
  WS=$(curl -s -X POST "$BASE/api/workspaces" -H "Authorization: Bearer $JWT" -H 'Content-Type: application/json' -d "{\"name\":\"Bridge Test $TS\",\"slug\":\"bridge-test-$TS\"}")
  WSID=$(echo "$WS" | jq -r '.id // empty')
  [ -n "$WSID" ] || { echo "  FATAL: no workspace id: $WS"; exit 1; }
  PAT=$(curl -s -X POST "$BASE/api/tokens" -H "Authorization: Bearer $JWT" -H 'Content-Type: application/json' -d '{"name":"bridge-smoke-test"}' | jq -r '.token // empty')
  [ -n "$PAT" ] || { echo "  FATAL: no PAT"; exit 1; }
  echo "  workspace=$WSID  pat=${PAT:0:8}..."
else
  [ -n "$WSID" ] || { echo "FATAL: set MULTICA_WS (workspace UUID) when providing MULTICA_PAT"; exit 2; }
  echo "== using provided PAT + workspace $WSID =="
fi

echo "== daemon-protocol calls (DaemonAuth — no workspace header needed) =="
code=$(hc -X POST "$BASE/api/daemon/register" -H "Authorization: Bearer $PAT" -H 'Content-Type: application/json' \
  -d "{\"workspace_id\":\"$WSID\",\"daemon_id\":\"lunarwing-smoke-test\",\"runtimes\":[{\"name\":\"LunarWing\",\"type\":\"lunarwing\",\"version\":\"0.1.0\",\"status\":\"online\"}]}")
chk "$code" 200 "register"
# register returns an object: {"runtimes":[{"id":...}], ...} — id is at runtimes[0].id
RUNTIME_ID=$(jq -r '(.runtimes[0].id // (if type=="array" then .[0].id else .id end)) // empty' "$TMP" 2>/dev/null)
echo "  runtime_id=$RUNTIME_ID"
[ -n "$RUNTIME_ID" ] || { echo "  FATAL: no runtime_id in register response"; exit 1; }

code=$(hc -X POST "$BASE/api/daemon/heartbeat" -H "Authorization: Bearer $PAT" -H 'Content-Type: application/json' -d "{\"runtime_id\":\"$RUNTIME_ID\"}"); chk "$code" 200 "heartbeat"
code=$(hc -X POST "$BASE/api/daemon/runtimes/$RUNTIME_ID/tasks/claim" -H "Authorization: Bearer $PAT" -H 'Content-Type: application/json' -d '{}'); chk "$code" 200 "claim_task"
code=$(hc -X POST "$BASE/api/daemon/runtimes/$RUNTIME_ID/recover-orphans" -H "Authorization: Bearer $PAT" -H 'Content-Type: application/json' -d '{}'); chk "$code" 200 "recover_orphans"

echo "== workspace-scoped calls (RequireWorkspaceMember — need workspace_id) =="
code=$(hc "$BASE/api/issues" -H "Authorization: Bearer $PAT");                    chk "$code" 400 "issues WITHOUT workspace_id → 400 (why the bridge must scope)"
code=$(hc "$BASE/api/issues?workspace_id=$WSID" -H "Authorization: Bearer $PAT"); chk "$code" 200 "issues?workspace_id= → 200"
code=$(hc "$BASE/api/skills?workspace_id=$WSID" -H "Authorization: Bearer $PAT"); chk "$code" 200 "skills?workspace_id= → 200"

echo ""
echo "== $pass passed, $fail failed =="
exit "$fail"
