#!/usr/bin/env bash
# Standalone test harness for the add-tenant env-flag feature.
# Sources lunarwing-mt-admin.sh (the script's BASH_SOURCE guard skips main()
# when sourced, so no dispatch / require_root runs) and invokes the pure
# helpers + env-writer functions against fixtures.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADMIN_SCRIPT="$SCRIPT_DIR/../lunarwing-mt-admin.sh"

# shellcheck source=../lunarwing-mt-admin.sh
source "$ADMIN_SCRIPT"

failures=0
assert_eq() {  # <label> <actual> <expected>
  if [[ "$2" == "$3" ]]; then
    echo "  PASS: $1"
  else
    echo "  FAIL: $1"
    echo "        expected: [$3]"
    echo "        actual:   [$2]"
    failures=$((failures + 1))
  fi
}

echo "=== build_xmpp_allow_from tests ==="

# Owner JID only (no extras)
out="$(build_xmpp_allow_from "ruffles@xmpp.localhost" "")"
assert_eq "owner-only (csv)" "$out" "ruffles@xmpp.localhost"

# Owner + one extra
out="$(build_xmpp_allow_from "ruffles@xmpp.localhost" "admin@xmpp.org")"
assert_eq "owner+one (csv)" "$out" "ruffles@xmpp.localhost,admin@xmpp.org"

# Owner + multiple extras (comma-separated input)
out="$(build_xmpp_allow_from "ruffles@xmpp.localhost" "admin@xmpp.org,bob@xmpp.org")"
assert_eq "owner+two (csv)" "$out" "ruffles@xmpp.localhost,admin@xmpp.org,bob@xmpp.org"

# Dedupe: extra equals owner
out="$(build_xmpp_allow_from "ruffles@xmpp.localhost" "ruffles@xmpp.localhost")"
assert_eq "dedupe-owner" "$out" "ruffles@xmpp.localhost"

# Dedupe: duplicate extra
out="$(build_xmpp_allow_from "ruffles@xmpp.localhost" "admin@xmpp.org,admin@xmpp.org")"
assert_eq "dedupe-extra" "$out" "ruffles@xmpp.localhost,admin@xmpp.org"

# Whitespace trimmed around extras
out="$(build_xmpp_allow_from "ruffles@xmpp.localhost" " admin@xmpp.org , bob@xmpp.org ")"
assert_eq "trim-whitespace" "$out" "ruffles@xmpp.localhost,admin@xmpp.org,bob@xmpp.org"

echo "=== build_xmpp_allow_from_json tests ==="

out="$(build_xmpp_allow_from_json "ruffles@xmpp.localhost" "")"
assert_eq "json owner-only" "$out" '["ruffles@xmpp.localhost"]'

out="$(build_xmpp_allow_from_json "ruffles@xmpp.localhost" "admin@xmpp.org,bob@xmpp.org")"
assert_eq "json owner+two" "$out" '["ruffles@xmpp.localhost","admin@xmpp.org","bob@xmpp.org"]'

out="$(build_xmpp_allow_from_json "ruffles@xmpp.localhost" "ruffles@xmpp.localhost,admin@xmpp.org")"
assert_eq "json dedupe" "$out" '["ruffles@xmpp.localhost","admin@xmpp.org"]'

echo "=== write_tenant_lunarwing_env fixture tests ==="

# Fixture: stub the helpers the env writer depends on so it can run without
# root, a real tenant, or podman. We capture into a temp dir.
MT_FIXTURE="$(mktemp -d)"
trap 'rm -rf "$MT_FIXTURE"' EXIT

# Stub tenant_* path helpers to point at the fixture dir.
tenant_env_dir()    { echo "$MT_FIXTURE/env"; }
tenant_state_dir()  { echo "$MT_FIXTURE/state"; }
tenant_run_dir()    { echo "$MT_FIXTURE/run"; }
mkdir -p "$MT_FIXTURE/env" "$MT_FIXTURE/state" "$MT_FIXTURE/run"

# Stub ports_get to return deterministic ports.
ports_get() {  # <name> <service>
  case "$2" in
    gateway)         echo 10000 ;;
    http)            echo 10001 ;;
    bridge)          echo 10002 ;;
    postgres)        echo 10003 ;;
    proxy)           echo 10004 ;;
    weechat)         echo 10005 ;;
    orchestrator)    echo 10006 ;;
    nanocode_wss)    echo 10007 ;;
    pebble_wss)      echo 10008 ;;
    weechat_adapter) echo 10009 ;;
    *)               echo 0 ;;
  esac
}

# Stub tenant_pg_password, tenant_darkirc_enabled, generate_token, say, chown.
tenant_pg_password()      { echo "pgpass-fixture"; }
tenant_darkirc_enabled()  { return 1; }   # darkirc disabled in fixture
generate_token()          { echo "token-fixture-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"; }
say()                     { :; }          # silence
chown()                   { :; }          # no-op (running as non-root in tests)

run_writer() {  # <args...> — invokes write_tenant_lunarwing_env, prints the file
  rm -f "$MT_FIXTURE/env/lunarwing.env"
  write_tenant_lunarwing_env "$@"
}

envval() {  # <key> — extract value from the last-written fixture env
  grep -m1 "^$1=" "$MT_FIXTURE/env/lunarwing.env" | cut -d= -f2-
}

# Case 1: defaults (no flags) on first write
out="$(run_writer fixture-tenant)"
assert_eq "default LLM_MODEL" "$(envval LLM_MODEL)" "tensorzero::function_name::lunarwing"
assert_eq "default GATEWAY_HOST" "$(envval GATEWAY_HOST)" "127.0.0.1"
assert_eq "default XMPP_ALLOW_FROM" "$(envval XMPP_ALLOW_FROM)" "fixture-tenant@xmpp.localhost"

# Case 2: all three flags on first write
out="$(run_writer fixture-tenant \
  "fixture-tenant@xmpp.localhost" "" "http://tz:3030" "" "" "" "" \
  "glm-5-air" "0.0.0.0" "admin@xmpp.org,bob@xmpp.org")"
assert_eq "flag LLM_MODEL" "$(envval LLM_MODEL)" "glm-5-air"
assert_eq "flag GATEWAY_HOST" "$(envval GATEWAY_HOST)" "0.0.0.0"
assert_eq "flag XMPP_ALLOW_FROM" "$(envval XMPP_ALLOW_FROM)" "fixture-tenant@xmpp.localhost,admin@xmpp.org,bob@xmpp.org"

# Case 3: idempotent re-run WITHOUT flags preserves operator-set values.
#   (run_writer deletes the file each call, so simulate a re-run by writing
#   once with flags, then a second time without — but keep the file between.)
rm -f "$MT_FIXTURE/env/lunarwing.env"
write_tenant_lunarwing_env fixture-tenant \
  "fixture-tenant@xmpp.localhost" "" "http://tz:3030" "" "" "" "" \
  "glm-5-air" "0.0.0.0" "admin@xmpp.org"
# Now re-run WITHOUT the new flags (pass empty for slots 9-11) — file exists.
write_tenant_lunarwing_env fixture-tenant \
  "fixture-tenant@xmpp.localhost" "" "http://tz:3030" "" "" "" "" \
  "" "" ""
assert_eq "rerun preserves LLM_MODEL" "$(envval LLM_MODEL)" "glm-5-air"
assert_eq "rerun preserves GATEWAY_HOST" "$(envval GATEWAY_HOST)" "0.0.0.0"
assert_eq "rerun preserves XMPP_ALLOW_FROM" "$(envval XMPP_ALLOW_FROM)" "fixture-tenant@xmpp.localhost,admin@xmpp.org"

echo "=== write_tenant_bridge_env fixture tests ==="

# The bridge writer reads XMPP_BRIDGE_TOKEN / XMPP_PASSWORD from the daemon env.
# Ensure a daemon env exists with those keys for the fixture tenant.
cat > "$MT_FIXTURE/env/lunarwing.env" <<E
XMPP_BRIDGE_TOKEN=bridge-tok-fixture
XMPP_PASSWORD=xmpp-pass-fixture
E

run_bridge_writer() {  # <xmpp_allow_from_extras>
  rm -f "$MT_FIXTURE/env/xmpp-bridge.env"
  write_tenant_bridge_env fixture-tenant \
    "fixture-tenant@xmpp.localhost" "" "$1"
  cat "$MT_FIXTURE/env/xmpp-bridge.env"
}

bridgeval() {  # <key>
  grep -m1 "^$1=" "$MT_FIXTURE/env/xmpp-bridge.env" | cut -d= -f2-
}

# Case 1: no extras → owner JID only
out="$(run_bridge_writer "")"
assert_eq "bridge json owner-only" "$(bridgeval XMPP_ALLOW_FROM_JSON)" '["fixture-tenant@xmpp.localhost"]'

# Case 2: extras → owner + extras
out="$(run_bridge_writer "admin@xmpp.org,bob@xmpp.org")"
assert_eq "bridge json owner+two" "$(bridgeval XMPP_ALLOW_FROM_JSON)" '["fixture-tenant@xmpp.localhost","admin@xmpp.org","bob@xmpp.org"]'

echo "=== CLI dispatch parsing smoke check ==="

# Verify the dispatch block recognizes the new flags by invoking the script
# directly with a deliberately-bad tenant name AFTER the flags; if the flags
# parsed, the script reaches require_root (not "unknown flag"). As non-root,
# require_root exits with a permission message; we assert it does NOT mention
# "unknown flag".
err="$(bash "$ADMIN_SCRIPT" add-tenant \
  --llm-model glm-5-air \
  --gateway-host 0.0.0.0 \
  --xmpp-allow-from admin@xmpp.org \
  2>&1 || true)"
if echo "$err" | grep -q 'unknown flag'; then
  echo "  FAIL: a new flag was rejected as unknown"
  echo "        $err"
  failures=$((failures + 1))
else
  echo "  PASS: all three new flags parsed without 'unknown flag' error"
fi

echo ""
if [[ "$failures" -eq 0 ]]; then
  echo "ALL TESTS PASSED"
  exit 0
else
  echo "$failures TEST(S) FAILED"
  exit 1
fi
