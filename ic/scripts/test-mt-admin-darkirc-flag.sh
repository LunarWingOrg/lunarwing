#!/usr/bin/env bash
# Regression test for H2: `--enable-darkirc` must be flippable on an existing
# tenant. ports_allocate()'s resume path reconciles the registry flag so the
# env/unit writers (which gate on tenant_darkirc_enabled, a registry read) stay
# consistent with add_tenant()'s in-memory flag.
#
# Sources lunarwing-mt-admin.sh's functions into an isolated temp registry and
# exercises ports_allocate / ports_enable_darkirc WITHOUT touching /etc/lunarwing
# or any real tenant. Does NOT require root.
#
# Exits: 0 PASS / 1 FAIL / 2 precondition error.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MT_ADMIN="$SCRIPT_DIR/lunarwing-mt-admin.sh"

[[ -f "$MT_ADMIN" ]] || { echo "error: $MT_ADMIN not found" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "error: jq required" >&2; exit 2; }

# Source the admin script — functions only; `main` is guarded by the
# BASH_SOURCE[0] == $0 check at the bottom of the file, so sourcing is safe.
# shellcheck source=lunarwing-mt-admin.sh
source "$MT_ADMIN"

# Redirect the isolated registry AWAY from /etc/lunarwing/ports.json.
PORTS_REGISTRY="$(mktemp -t mt-darkirc-flag.XXXXXX.json)"
trap 'rm -f "$PORTS_REGISTRY"' EXIT

# Seed an empty v7 registry (what ports_registry_init would write) so this test
# never calls ports_registry_init (which mkdir's /etc/lunarwing).
cat >"$PORTS_REGISTRY" <<'ENDJSON'
{
  "version": 7,
  "range": { "start": 10000, "end": 19999 },
  "block_size": 10,
  "extended_range": { "start": 20000 },
  "extended_block_size": 10,
  "tenants": {}
}
ENDJSON

PASS=0
FAIL=0

assert_eq() {
  local desc="$1" got="$2" want="$3"
  if [[ "$got" == "$want" ]]; then
    echo "  ok   - $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL - $desc (got: '$got', want: '$want')"
    FAIL=$((FAIL + 1))
  fi
}

darkirc_flag() {
  # NOTE: jq's `//` treats `false` like `null`, so `false // "x"` == "x". Use an
  # explicit null-check to distinguish false from a genuinely missing key.
  jq -r ".tenants[\"$1\"].enable_darkirc | if . == null then \"<missing>\" else tostring end" "$PORTS_REGISTRY"
}

echo "== H2: --enable-darkirc flag flip on existing tenant =="

# 1. Fresh tenant, darkirc disabled.
base1="$(ports_allocate alpha false 2>/dev/null)"
assert_eq "fresh tenant base_port (alpha)"        "$base1"               "10000"
assert_eq "alpha enable_darkirc initially false"  "$(darkirc_flag alpha)" "false"

# 2. Resume the SAME tenant WITH darkirc — must reuse base AND flip the flag (H2).
base1b="$(ports_allocate alpha true 2>/dev/null)"
assert_eq "resume reuses base_port (alpha)"       "$base1b"               "10000"
assert_eq "alpha enable_darkirc flips to true"    "$(darkirc_flag alpha)" "true"

# 3. Resume WITHOUT the flag must NOT silently downgrade an enabled tenant
#    (reconciliation is one-directional; disabling is a manual teardown).
base1c="$(ports_allocate alpha false 2>/dev/null)"
assert_eq "resume w/o flag keeps base_port (alpha)" "$base1c"               "10000"
assert_eq "alpha stays enabled (no silent downgrade)" "$(darkirc_flag alpha)" "true"

# 4. A second fresh tenant with darkirc enabled from the start.
base2="$(ports_allocate beta true 2>/dev/null)"
assert_eq "second tenant base_port (beta)"        "$base2"               "10010"
assert_eq "beta enable_darkirc true on create"    "$(darkirc_flag beta)" "true"

# 5. ports_enable_darkirc is idempotent on an already-enabled tenant (no rewrite).
before_mtime="$(stat -c %Y "$PORTS_REGISTRY" 2>/dev/null || stat -f %m "$PORTS_REGISTRY")"
ports_enable_darkirc beta 2>/dev/null || true
after_mtime="$(stat -c %Y "$PORTS_REGISTRY" 2>/dev/null || stat -f %m "$PORTS_REGISTRY")"
assert_eq "idempotent: registry not rewritten"     "$after_mtime"          "$before_mtime"
assert_eq "beta still enabled after idempotent call" "$(darkirc_flag beta)" "true"

echo ""
if [[ "$FAIL" -eq 0 ]]; then
  echo "RESULT: PASS ($PASS assertions)"
  exit 0
else
  echo "RESULT: FAIL ($PASS passed, $FAIL failed)"
  exit 1
fi
