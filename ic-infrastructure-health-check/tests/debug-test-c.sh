#!/usr/bin/env bash
# Debug script: reproduces Test C (invalid JSON response) with full variable dump.
# Shows all variable values right before the jq output call.
#
# Run:  bash tests/debug-test-c.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$SCRIPT_DIR/../health-lunarvision.sh"

TMPD=$(mktemp -d "${TMPDIR:-/tmp}/lv-debug.XXXXXX")
trap 'rm -rf "$TMPD"' EXIT

mkdir -p "$TMPD/bin"

cat > "$TMPD/bin/curl" <<'MOCKCURL'
#!/usr/bin/env bash
url=""
has_write_off=false
for arg in "$@"; do
    case "$arg" in
        http://*|https://*) url="$arg" ;;
        *%{http_code}*) has_write_off=true ;;
    esac
done
case "$url" in
    */health) body="${MOCK_HEALTH_BODY:-}"; code="${MOCK_HEALTH_CODE:-200}" ;;
    */vision/metrics) body="${MOCK_METRICS_BODY:-}"; code="${MOCK_METRICS_CODE:-200}" ;;
    *) body=""; code="404" ;;
esac
printf '%s' "$body"
$has_write_off && printf '\n%s' "$code"
MOCKCURL
chmod +x "$TMPD/bin/curl"

echo "════════════════════════════════════════════════════════════"
echo "TEST C: Invalid JSON response"
echo "════════════════════════════════════════════════════════════"
echo ""

# Patch the check script on the fly: inject variable dump before jq output
PATCHED="$TMPD/health-lunarvision-debug.sh"
sed '/^jq -n \\$/i\
echo "DEBUG: latency_ms=[$latency_ms]" >&2\
echo "DEBUG: uptime_secs=[$uptime_secs]" >&2\
echo "DEBUG: total_requests=[$total_requests]" >&2\
echo "DEBUG: ocr_requests=[$ocr_requests]" >&2\
echo "DEBUG: vision_requests=[$vision_requests]" >&2\
echo "DEBUG: cache_hits=[$cache_hits]" >&2\
echo "DEBUG: cache_misses=[$cache_misses]" >&2\
echo "DEBUG: rate_limited=[$rate_limited]" >&2\
echo "DEBUG: cache_hit_rate=[$cache_hit_rate]" >&2\
echo "DEBUG: avg_latency_ms=[$avg_latency_ms]" >&2\
echo "DEBUG: svc_status=[$svc_status]" >&2\
echo "DEBUG: tesseract_version=[$tesseract_version]" >&2\
echo "DEBUG: vl_available=[$vl_available]" >&2\
echo "DEBUG: capabilities=[$capabilities]" >&2\
echo "DEBUG: issues_json=[$issues_json]" >&2\
' "$CHECK" > "$PATCHED"

echo "--- STDOUT + STDERR (with variable dump) ---"

MOCK_HEALTH_BODY='this is not json' MOCK_HEALTH_CODE=200 \
PATH="$TMPD/bin:$PATH" bash "$PATCHED"

ec=$?
echo ""
echo "--- EXIT CODE: $ec ---"
