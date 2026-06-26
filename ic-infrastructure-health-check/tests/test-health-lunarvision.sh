#!/usr/bin/env bash
# Tests for health-lunarvision.sh
#
# Mocks curl to simulate various LunarVision sidecar responses.
# No real sidecar needed — all HTTP responses are faked.
#
# Run:  bash tests/test-health-lunarvision.sh   (exit 0 = pass, 1 = fail)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$SCRIPT_DIR/../health-lunarvision.sh"
[[ -x "$CHECK" ]] || { echo "FATAL: $CHECK not found/executable"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 1; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/lv-health-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

fail=0; pass=0
ok()  { printf 'PASS: %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL: %s\n      %s\n' "$1" "$2"; fail=$((fail + 1)); }
assert_eq()       { [[ "$1" == "$2" ]] && ok "$3" || bad "$3" "got [$1] want [$2]"; }
assert_contains() { grep -qF -- "$2" <<<"$1" && ok "$3" || bad "$3" "expected: $2"; }
assert_absent()   { grep -qF -- "$2" <<<"$1" && bad "$3" "unexpected: $2" || ok "$3"; }

# ── Mock curl ────────────────────────────────────────────────────────────────
# Creates a fake curl script in a temp bin dir that returns canned responses.
# The mock reads MOCK_HEALTH_BODY, MOCK_HEALTH_CODE, MOCK_METRICS_BODY,
# MOCK_METRICS_CODE from the environment.

MOCK_BIN="$ROOT/bin"
mkdir -p "$MOCK_BIN"

cat > "$MOCK_BIN/curl" <<'MOCKCURL'
#!/usr/bin/env bash
# Minimal curl mock for health-lunarvision.sh tests.
# Parses the URL from args to decide which response to return.
# Supports -w "\n%{http_code}" output format.

url=""
has_write_out=false
for arg in "$@"; do
    case "$arg" in
        http://*|https://*) url="$arg" ;;
        *%{http_code}*) has_write_out=true ;;
    esac
done

# Simulate connection failure
if [[ "${MOCK_CURL_FAIL:-}" == "true" ]]; then
    exit 7  # CURLE_COULDNT_CONNECT
fi

# Simulate slow response
if [[ -n "${MOCK_CURL_SLEEP:-}" ]]; then
    sleep "$MOCK_CURL_SLEEP"
fi

case "$url" in
    */health)
        body="${MOCK_HEALTH_BODY:-}"
        code="${MOCK_HEALTH_CODE:-200}"
        ;;
    */vision/metrics)
        body="${MOCK_METRICS_BODY:-}"
        code="${MOCK_METRICS_CODE:-200}"
        ;;
    *)
        body=""
        code="404"
        ;;
esac

printf '%s' "$body"
if $has_write_out; then
    printf '\n%s' "$code"
fi
MOCKCURL
chmod +x "$MOCK_BIN/curl"

# Run check with mocked curl — prepend mock bin to PATH
run_check() {
    PATH="$MOCK_BIN:$PATH" bash "$CHECK" 2>/dev/null
}

# ── Helpers ──────────────────────────────────────────────────────────────────

# Standard healthy /health response
HEALTH_OK='{"status":"ok","tesseract_version":"5.3.4","uptime_secs":18342}'
HEALTH_OK_WITH_VL='{"status":"ok","tesseract_version":"5.3.4","uptime_secs":18342,"vl_available":true}'
HEALTH_OK_VL_DOWN='{"status":"ok","tesseract_version":"5.3.4","uptime_secs":18342,"vl_available":false}'
HEALTH_BAD_STATUS='{"status":"error","tesseract_version":"5.3.4","uptime_secs":100}'
HEALTH_NO_TESS='{"status":"ok","uptime_secs":500}'

# Standard /vision/metrics response
METRICS_OK='{"total_requests":1500,"ocr_requests":1200,"vision_requests":300,"cache_hits":800,"cache_misses":400,"rate_limited":5,"cache_hit_rate":0.67,"avg_latency_ms":45}'

# ═════════════════════════════════════════════════════════════════════════════
# TEST A: Service unreachable → critical, exit 2
# ═════════════════════════════════════════════════════════════════════════════

out_A=$(MOCK_CURL_FAIL=true \
    HEALTH_LUNARVISION_URL="http://127.0.0.1:8088" \
    run_check)
ec_A=$?

assert_eq "$ec_A" "2" "A1: unreachable → exit 2"
assert_eq "$(jq -r '.status' <<<"$out_A")" "critical" "A2: unreachable → status critical"
assert_contains "$(jq -r '.issues[0]' <<<"$out_A")" "unreachable" "A3: issue mentions unreachable"

# ═════════════════════════════════════════════════════════════════════════════
# TEST B: Non-200 HTTP response → critical, exit 2
# ═════════════════════════════════════════════════════════════════════════════

out_B=$(MOCK_HEALTH_BODY='{"error":"forbidden"}' MOCK_HEALTH_CODE=403 \
    HEALTH_LUNARVISION_URL="http://127.0.0.1:8088" \
    run_check)
ec_B=$?

assert_eq "$ec_B" "2" "B1: HTTP 403 → exit 2"
assert_eq "$(jq -r '.status' <<<"$out_B")" "critical" "B2: HTTP 403 → status critical"
assert_contains "$(jq -r '.issues[0]' <<<"$out_B")" "403" "B3: issue mentions HTTP code"

# ═════════════════════════════════════════════════════════════════════════════
# TEST C: Invalid JSON response → critical, exit 2
# ═════════════════════════════════════════════════════════════════════════════

out_C=$(MOCK_HEALTH_BODY='this is not json' MOCK_HEALTH_CODE=200 \
    HEALTH_LUNARVISION_URL="http://127.0.0.1:8088" \
    run_check)
ec_C=$?

assert_eq "$ec_C" "2" "C1: invalid JSON → exit 2"
assert_eq "$(jq -r '.status' <<<"$out_C")" "critical" "C2: invalid JSON → status critical"
assert_contains "$(jq -r '.issues[0]' <<<"$out_C")" "invalid JSON" "C3: issue mentions invalid JSON"

# ═════════════════════════════════════════════════════════════════════════════
# TEST D: Healthy service → healthy, exit 0
# ═════════════════════════════════════════════════════════════════════════════

out_D=$(MOCK_HEALTH_BODY="$HEALTH_OK" MOCK_HEALTH_CODE=200 \
    MOCK_METRICS_BODY="$METRICS_OK" MOCK_METRICS_CODE=200 \
    HEALTH_LUNARVISION_URL="http://127.0.0.1:8088" \
    HEALTH_LUNARVISION_FETCH_METRICS=true \
    run_check)
ec_D=$?

assert_eq "$ec_D" "0" "D1: healthy service → exit 0"
assert_eq "$(jq -r '.status' <<<"$out_D")" "healthy" "D2: healthy → status healthy"
assert_eq "$(jq -r '.component' <<<"$out_D")" "lunarvision" "D3: component is lunarvision"
assert_eq "$(jq -r '.metrics.service_status' <<<"$out_D")" "ok" "D4: service_status is ok"
assert_eq "$(jq -r '.metrics.tesseract_version' <<<"$out_D")" "5.3.4" "D5: tesseract version parsed"
assert_eq "$(jq -r '.metrics.uptime_secs' <<<"$out_D")" "18342" "D6: uptime parsed"
assert_eq "$(jq -r '.issues' <<<"$out_D")" "[]" "D7: no issues"

# ═════════════════════════════════════════════════════════════════════════════
# TEST E: Metrics integration
# ═════════════════════════════════════════════════════════════════════════════

assert_eq "$(jq -r '.metrics.total_requests' <<<"$out_D")" "1500" "E1: total_requests from metrics"
assert_eq "$(jq -r '.metrics.ocr_requests' <<<"$out_D")" "1200" "E2: ocr_requests from metrics"
assert_eq "$(jq -r '.metrics.vision_requests' <<<"$out_D")" "300" "E3: vision_requests from metrics"
assert_eq "$(jq -r '.metrics.cache.hits' <<<"$out_D")" "800" "E4: cache hits"
assert_eq "$(jq -r '.metrics.cache.misses' <<<"$out_D")" "400" "E5: cache misses"
assert_eq "$(jq -r '.metrics.cache.hit_rate' <<<"$out_D")" "0.67" "E6: cache hit rate"
assert_eq "$(jq -r '.metrics.rate_limited' <<<"$out_D")" "5" "E7: rate_limited from metrics"
assert_eq "$(jq -r '.metrics.avg_latency_ms' <<<"$out_D")" "45" "E8: avg_latency from metrics"

# ═════════════════════════════════════════════════════════════════════════════
# TEST F: Metrics fetch disabled → zeroed metrics, still healthy
# ═════════════════════════════════════════════════════════════════════════════

out_F=$(MOCK_HEALTH_BODY="$HEALTH_OK" MOCK_HEALTH_CODE=200 \
    HEALTH_LUNARVISION_URL="http://127.0.0.1:8088" \
    HEALTH_LUNARVISION_FETCH_METRICS=false \
    run_check)
ec_F=$?

assert_eq "$ec_F" "0" "F1: healthy without metrics → exit 0"
assert_eq "$(jq -r '.metrics.total_requests' <<<"$out_F")" "0" "F2: metrics zeroed when fetch disabled"

# ═════════════════════════════════════════════════════════════════════════════
# TEST G: Service reports non-ok status → critical
# ═════════════════════════════════════════════════════════════════════════════

out_G=$(MOCK_HEALTH_BODY="$HEALTH_BAD_STATUS" MOCK_HEALTH_CODE=200 \
    HEALTH_LUNARVISION_URL="http://127.0.0.1:8088" \
    HEALTH_LUNARVISION_FETCH_METRICS=false \
    run_check)
ec_G=$?

assert_eq "$ec_G" "2" "G1: status=error → exit 2"
assert_eq "$(jq -r '.status' <<<"$out_G")" "critical" "G2: status=error → critical"
assert_contains "$(jq -r '.issues[0]' <<<"$out_G")" "error" "G3: issue mentions reported status"

# ═════════════════════════════════════════════════════════════════════════════
# TEST H: Tesseract version missing → degraded
# ═════════════════════════════════════════════════════════════════════════════

out_H=$(MOCK_HEALTH_BODY="$HEALTH_NO_TESS" MOCK_HEALTH_CODE=200 \
    HEALTH_LUNARVISION_URL="http://127.0.0.1:8088" \
    HEALTH_LUNARVISION_FETCH_METRICS=false \
    run_check)
ec_H=$?

assert_eq "$ec_H" "1" "H1: no tesseract → exit 1"
assert_eq "$(jq -r '.status' <<<"$out_H")" "degraded" "H2: no tesseract → degraded"
assert_contains "$(jq -r '.issues[0]' <<<"$out_H")" "Tesseract" "H3: issue mentions Tesseract"

# ═════════════════════════════════════════════════════════════════════════════
# TEST I: VL required, VL unavailable → degraded
# ═════════════════════════════════════════════════════════════════════════════

out_I=$(MOCK_HEALTH_BODY="$HEALTH_OK_VL_DOWN" MOCK_HEALTH_CODE=200 \
    HEALTH_LUNARVISION_URL="http://127.0.0.1:8088" \
    HEALTH_LUNARVISION_FETCH_METRICS=false \
    HEALTH_LUNARVISION_REQUIRE_VL=true \
    run_check)
ec_I=$?

assert_eq "$ec_I" "1" "I1: VL required + unavailable → exit 1"
assert_eq "$(jq -r '.status' <<<"$out_I")" "degraded" "I2: VL required + unavailable → degraded"
assert_contains "$(jq -r '.issues[0]' <<<"$out_I")" "VL backend" "I3: issue mentions VL backend"

# ═════════════════════════════════════════════════════════════════════════════
# TEST J: VL required, VL unknown (sidecar doesn't report it) → degraded
# ═════════════════════════════════════════════════════════════════════════════

out_J=$(MOCK_HEALTH_BODY="$HEALTH_OK" MOCK_HEALTH_CODE=200 \
    HEALTH_LUNARVISION_URL="http://127.0.0.1:8088" \
    HEALTH_LUNARVISION_FETCH_METRICS=false \
    HEALTH_LUNARVISION_REQUIRE_VL=true \
    run_check)
ec_J=$?

assert_eq "$ec_J" "1" "J1: VL required + unknown → exit 1"
assert_eq "$(jq -r '.status' <<<"$out_J")" "degraded" "J2: VL required + unknown → degraded"
assert_contains "$(jq -r '.issues[0]' <<<"$out_J")" "unknown" "J3: issue mentions unknown availability"

# ═════════════════════════════════════════════════════════════════════════════
# TEST K: VL required, VL available → healthy
# ═════════════════════════════════════════════════════════════════════════════

out_K=$(MOCK_HEALTH_BODY="$HEALTH_OK_WITH_VL" MOCK_HEALTH_CODE=200 \
    HEALTH_LUNARVISION_URL="http://127.0.0.1:8088" \
    HEALTH_LUNARVISION_FETCH_METRICS=false \
    HEALTH_LUNARVISION_REQUIRE_VL=true \
    run_check)
ec_K=$?

assert_eq "$ec_K" "0" "K1: VL required + available → exit 0"
assert_eq "$(jq -r '.status' <<<"$out_K")" "healthy" "K2: VL required + available → healthy"

# ═════════════════════════════════════════════════════════════════════════════
# TEST L: VL not required, VL down → still healthy
# ═════════════════════════════════════════════════════════════════════════════

out_L=$(MOCK_HEALTH_BODY="$HEALTH_OK_VL_DOWN" MOCK_HEALTH_CODE=200 \
    HEALTH_LUNARVISION_URL="http://127.0.0.1:8088" \
    HEALTH_LUNARVISION_FETCH_METRICS=false \
    HEALTH_LUNARVISION_REQUIRE_VL=false \
    run_check)
ec_L=$?

assert_eq "$ec_L" "0" "L1: VL not required + down → exit 0"
assert_eq "$(jq -r '.status' <<<"$out_L")" "healthy" "L2: VL not required + down → healthy"

# ═════════════════════════════════════════════════════════════════════════════
# TEST M: Disabled → healthy/disabled, exit 0
# ═════════════════════════════════════════════════════════════════════════════

out_M=$(HEALTH_LUNARVISION_ENABLED=false run_check)
ec_M=$?

assert_eq "$ec_M" "0" "M1: disabled → exit 0"
assert_eq "$(jq -r '.status' <<<"$out_M")" "healthy" "M2: disabled → status healthy"
assert_eq "$(jq -r '.metrics.enabled' <<<"$out_M")" "false" "M3: disabled → enabled=false"

# ═════════════════════════════════════════════════════════════════════════════
# TEST N: Capabilities field — ocr only vs ocr+vl
# ═════════════════════════════════════════════════════════════════════════════

out_N1=$(MOCK_HEALTH_BODY="$HEALTH_OK" MOCK_HEALTH_CODE=200 \
    HEALTH_LUNARVISION_URL="http://127.0.0.1:8088" \
    HEALTH_LUNARVISION_FETCH_METRICS=false \
    run_check)
assert_eq "$(jq -r '.metrics.capabilities' <<<"$out_N1")" "ocr" "N1: no VL info → capabilities=ocr"

out_N2=$(MOCK_HEALTH_BODY="$HEALTH_OK_WITH_VL" MOCK_HEALTH_CODE=200 \
    MOCK_METRICS_BODY="$METRICS_OK" MOCK_METRICS_CODE=200 \
    HEALTH_LUNARVISION_URL="http://127.0.0.1:8088" \
    HEALTH_LUNARVISION_FETCH_METRICS=true \
    run_check)
assert_eq "$(jq -r '.metrics.capabilities' <<<"$out_N2")" "ocr,vl" "N2: VL available → capabilities=ocr,vl"

# Capabilities via vision_requests > 0 (even without vl_available field)
out_N3=$(MOCK_HEALTH_BODY="$HEALTH_OK" MOCK_HEALTH_CODE=200 \
    MOCK_METRICS_BODY="$METRICS_OK" MOCK_METRICS_CODE=200 \
    HEALTH_LUNARVISION_URL="http://127.0.0.1:8088" \
    HEALTH_LUNARVISION_FETCH_METRICS=true \
    run_check)
assert_eq "$(jq -r '.metrics.capabilities' <<<"$out_N3")" "ocr,vl" "N3: vision_requests>0 infers vl capability"

# ═════════════════════════════════════════════════════════════════════════════
# TEST O: Output structure — all required fields present
# ═════════════════════════════════════════════════════════════════════════════

required_fields=("component" "status" "timestamp" "metrics" "issues")
for field in "${required_fields[@]}"; do
    val=$(jq -r ".$field // \"MISSING\"" <<<"$out_D")
    [[ "$val" != "MISSING" && "$val" != "null" ]] && ok "O: top-level field '$field' present" \
        || bad "O: top-level field '$field' present" "field missing or null"
done

metric_fields=("enabled" "url" "latency_ms" "service_status" "tesseract_version"
               "uptime_secs" "vl_available" "capabilities" "total_requests"
               "ocr_requests" "vision_requests" "cache" "rate_limited" "avg_latency_ms")
for field in "${metric_fields[@]}"; do
    val=$(jq -r ".metrics.$field // \"MISSING\"" <<<"$out_D")
    [[ "$val" != "MISSING" && "$val" != "null" ]] && ok "O: metrics.$field present" \
        || bad "O: metrics.$field present" "field missing or null"
done

# ═════════════════════════════════════════════════════════════════════════════
# TEST P: Timestamp format (ISO 8601)
# ═════════════════════════════════════════════════════════════════════════════

ts=$(jq -r '.timestamp' <<<"$out_D")
[[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
    && ok "P1: timestamp is ISO 8601 UTC" \
    || bad "P1: timestamp is ISO 8601 UTC" "got: $ts"

# ═════════════════════════════════════════════════════════════════════════════
# Summary
# ═════════════════════════════════════════════════════════════════════════════

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
