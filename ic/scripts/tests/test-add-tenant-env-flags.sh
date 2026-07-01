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

echo ""
if [[ "$failures" -eq 0 ]]; then
  echo "ALL TESTS PASSED"
  exit 0
else
  echo "$failures TEST(S) FAILED"
  exit 1
fi
