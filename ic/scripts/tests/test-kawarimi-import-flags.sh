#!/usr/bin/env bash
# Regression coverage for Kawarimi import/export orchestration flags.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
IC_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
IMPORT_SRC="$IC_DIR/scripts/import-tenant.sh"
EXPORT_SRC="$IC_DIR/scripts/export-tenant.sh"

failures=0

fail() {
  printf '  FAIL: %s\n' "$1"
  failures=$((failures + 1))
}

pass() {
  printf '  PASS: %s\n' "$1"
}

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    pass "$label"
  else
    fail "$label"
    printf '        missing: %s\n' "$needle"
  fi
}

assert_file_contains() {
  local label="$1" file="$2" needle="$3"
  if grep -qF -- "$needle" "$file"; then
    pass "$label"
  else
    fail "$label"
    printf '        %s missing: %s\n' "$file" "$needle"
  fi
}

make_bundle() {
  local work="$1"
  mkdir -p "$work/bundle-src"
  cat >"$work/bundle-src/meta.txt" <<'META'
tenant=kawarimi
source_version=test
db_backend=postgres
META
  printf 'not-a-real-pgdump-for-dry-run\n' >"$work/bundle-src/db.dump"
  cat >"$work/bundle-src/manifest-lunarwing.env" <<'ENV'
SECRETS_MASTER_KEY=test-master-key
XMPP_JID=kawarimi@example.test
GATEWAY_HOST=0.0.0.0
ENV
  cat >"$work/bundle-src/manifest-bridge.env" <<'ENV'
XMPP_JID=kawarimi@example.test
ENV
  cat >"$work/bundle-src/manifest-vision.env" <<'ENV'
VL_URL=http://vision.example.test:8080
VL_MODEL=qwen3-vl
LUNARWING_AUTH_TOKEN=vision-token
ENV
  tar cf "$work/kawarimi.tar" -C "$work/bundle-src" .
}

make_test_scripts() {
  local work="$1"
  mkdir -p "$work/scripts" "$work/bin" "$work/home/kawarimi/lunarwing/env"
  cp "$IMPORT_SRC" "$work/scripts/import-tenant.sh"

  cat >"$work/scripts/lunarwing-mt-admin.sh" <<'MT'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${KAWARIMI_TEST_WORK:?}/mt-admin.log"
case "${1:-}" in
  owner-scopes)
    if [[ -f "$KAWARIMI_TEST_WORK/scope-migrated" ]]; then
      printf 'kawarimi\t12\n'
    else
      printf 'default\t12\n'
    fi
    ;;
  migrate-owner-scope)
    touch "$KAWARIMI_TEST_WORK/scope-migrated"
    exit 0
    ;;
  restore-tenant) exit 0 ;;
  *) exit 0 ;;
esac
MT
  chmod +x "$work/scripts/lunarwing-mt-admin.sh"

  cat >"$work/scripts/lunarwing-weechat-preflight.sh" <<'PREFLIGHT'
#!/usr/bin/env bash
printf 'preflight %s\n' "${1:-}" >> "${KAWARIMI_TEST_WORK:?}/preflight.log"
PREFLIGHT
  chmod +x "$work/scripts/import-tenant.sh" "$work/scripts/lunarwing-weechat-preflight.sh"

  cat >"$work/bin/id" <<'ID'
#!/usr/bin/env bash
if [[ "${1:-}" == "-u" ]]; then
  printf '0\n'
else
  exec /usr/bin/id "$@"
fi
ID
  chmod +x "$work/bin/id"

  cat >"$work/bin/getent" <<GETENT
#!/usr/bin/env bash
if [[ "\${1:-}" == "passwd" && "\${2:-}" == "kawarimi" ]]; then
  printf 'kawarimi:x:1000:1000::%s/home/kawarimi:/bin/bash\n' "$work"
else
  exit 2
fi
GETENT
  chmod +x "$work/bin/getent"
}

echo "=== import-tenant dry-run flag passthrough ==="
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
make_bundle "$tmp"
make_test_scripts "$tmp"
printf '{"tenants":{}}\n' >"$tmp/ports.json"

output="$(
  PATH="$tmp/bin:$PATH" \
  LUNARWING_PORTS_REGISTRY="$tmp/ports.json" \
  KAWARIMI_TEST_WORK="$tmp" \
  bash "$tmp/scripts/import-tenant.sh" "$tmp/kawarimi.tar" \
    --dry-run --yes --start --old-stopped \
    --docker-group \
    --tensorzero-url http://tensorzero.example.test/openai/v1 \
    --with-vision \
    2>&1
)" || {
  status=$?
  printf '%s\n' "$output"
  fail "import dry-run exited successfully"
  exit "$status"
}

assert_contains "passes --docker-group to add-tenant" "$output" "--docker-group"
assert_contains "passes --tensorzero-url to add-tenant" "$output" "--tensorzero-url http://tensorzero.example.test/openai/v1"
assert_contains "builds vision sidecar when requested" "$output" "build-vision-sidecar"
assert_contains "injects vision manifest" "$output" "manifest-vision.env ->"
assert_contains "runs WeeChat preflight before start" "$output" "lunarwing-weechat-preflight.sh kawarimi"

echo "=== import-tenant explicit owner-scope dry-run ==="
explicit_output="$(
  PATH="$tmp/bin:$PATH" \
  LUNARWING_PORTS_REGISTRY="$tmp/ports.json" \
  KAWARIMI_TEST_WORK="$tmp" \
  bash "$tmp/scripts/import-tenant.sh" "$tmp/kawarimi.tar" \
    --dry-run --yes --owner-scope legacy-scope \
    2>&1
)" || {
  status=$?
  printf '%s\n' "$explicit_output"
  fail "explicit owner-scope dry-run exited successfully"
  exit "$status"
}
assert_contains "plans explicit owner-scope rekey" "$explicit_output" "migrate-owner-scope kawarimi --from legacy-scope"

echo "=== import-tenant auto owner-scope migration ==="
rm -f "$tmp/mt-admin.log" "$tmp/scope-migrated"
cat >"$tmp/home/kawarimi/lunarwing/env/lunarwing.env" <<'ENV'
SECRETS_MASTER_KEY=throwaway-master-key
ENV
cat >"$tmp/home/kawarimi/lunarwing/env/xmpp-bridge.env" <<'ENV'
XMPP_JID=throwaway@example.test
ENV
cat >"$tmp/home/kawarimi/lunarwing/env/vision.env" <<'ENV'
VL_MODEL=throwaway
ENV
auto_output="$(
  PATH="$tmp/bin:$PATH" \
  LUNARWING_PORTS_REGISTRY="$tmp/ports.json" \
  KAWARIMI_TEST_WORK="$tmp" \
  bash "$tmp/scripts/import-tenant.sh" "$tmp/kawarimi.tar" --yes \
    2>&1
)" || {
  status=$?
  printf '%s\n' "$auto_output"
  fail "auto owner-scope import exited successfully"
  exit "$status"
}
assert_file_contains "auto-migrates default owner scope" "$tmp/mt-admin.log" "migrate-owner-scope kawarimi --from default"

echo "=== export-tenant vision manifest coverage ==="
assert_file_contains "export writes a vision manifest" "$EXPORT_SRC" "manifest-vision.env"
assert_file_contains "export carries VL_URL" "$EXPORT_SRC" "VL_URL"
assert_file_contains "export carries VL_MODEL" "$EXPORT_SRC" "VL_MODEL"
assert_file_contains "export carries vision auth token" "$EXPORT_SRC" "LUNARWING_AUTH_TOKEN"

echo ""
if [[ "$failures" -eq 0 ]]; then
  echo "ALL TESTS PASSED"
  exit 0
else
  echo "$failures TEST(S) FAILED"
  exit 1
fi
