#!/bin/bash
# Health Check: LunarVision Sidecar (OCR + Vision-Language)
# Checks: service reachability, /health endpoint, optional /vision/metrics
# Output: JSON to stdout
# Exit codes: 0=healthy, 1=degraded, 2=critical
#
# Env vars:
#   HEALTH_LUNARVISION_ENABLED       (default: true)   — false disables
#   HEALTH_LUNARVISION_URL           (default: http://127.0.0.1:8088)
#   HEALTH_LUNARVISION_TIMEOUT       (default: 5)      — curl timeout in seconds
#   HEALTH_LUNARVISION_FETCH_METRICS (default: true)   — also probe /vision/metrics
#   HEALTH_LUNARVISION_REQUIRE_VL    (default: false)  — degrade if VL backend not confirmed
#   HEALTH_LUNARVISION_LATENCY_DEGRADED_MS  (default: 2000)
#   HEALTH_LUNARVISION_LATENCY_CRITICAL_MS (default: 5000)

set -uo pipefail

# ── Config ──────────────────────────────────────────────────────────────────

LUNARVISION_URL="${HEALTH_LUNARVISION_URL:-http://127.0.0.1:8088}"
TIMEOUT_SECS="${HEALTH_LUNARVISION_TIMEOUT:-5}"
FETCH_METRICS="${HEALTH_LUNARVISION_FETCH_METRICS:-true}"
REQUIRE_VL="${HEALTH_LUNARVISION_REQUIRE_VL:-false}"
LATENCY_DEGRADED_MS="${HEALTH_LUNARVISION_LATENCY_DEGRADED_MS:-2000}"
LATENCY_CRITICAL_MS="${HEALTH_LUNARVISION_LATENCY_CRITICAL_MS:-5000}"

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# ── Disable shortcut ─────────────────────────────────────────────────────────

if [ "${HEALTH_LUNARVISION_ENABLED:-true}" != "true" ]; then
    printf '{"component":"lunarvision","status":"healthy","timestamp":"%s","metrics":{"enabled":false}}\n' \
        "$TIMESTAMP"
    exit 0
fi

# ── State ────────────────────────────────────────────────────────────────────

status="healthy"
exit_code=0
issues=()
latency_ms=0

# Fields extracted from /health
svc_status=""
tesseract_version=""
uptime_secs=0
vl_available="unknown"   # forward-compat: sidecar may add this field later

# Fields extracted from /vision/metrics (optional)
total_requests=0
ocr_requests=0
vision_requests=0
cache_hits=0
cache_misses=0
rate_limited=0
cache_hit_rate=0.0
avg_latency_ms=0

# ── Probe /health ────────────────────────────────────────────────────────────

health_raw=""
http_code="000"

start_ns=$(date +%s%N)

curl_exit=0
health_raw=$(curl -s --connect-timeout "$TIMEOUT_SECS" --max-time "$TIMEOUT_SECS" \
    -w "\n%{http_code}" \
    "${LUNARVISION_URL}/health" 2>/dev/null) || curl_exit=$?

end_ns=$(date +%s%N)
latency_ms=$(( (end_ns - start_ns) / 1000000 ))

# Split body and HTTP status code (last line)
http_code=$(printf '%s' "$health_raw" | tail -1)
health_body=$(printf '%s' "$health_raw" | sed '$d')

# ── Classify ─────────────────────────────────────────────────────────────────

if [ "$http_code" = "000" ] || [ "$curl_exit" -ne 0 ]; then
    # Connection refused / timeout / DNS failure / curl error
    status="critical"
    exit_code=2
    issues+=("Service unreachable at ${LUNARVISION_URL}/health")
elif [ "$http_code" != "200" ]; then
    status="critical"
    exit_code=2
    issues+=("Health endpoint returned HTTP ${http_code}")
elif ! printf '%s' "$health_body" | jq . >/dev/null 2>&1; then
    status="critical"
    exit_code=2
    issues+=("Health endpoint returned invalid JSON")
else
    # Parse health response
    svc_status=$(printf '%s' "$health_body" | jq -r '.status // "unknown"')
    tesseract_version=$(printf '%s' "$health_body" | jq -r '.tesseract_version // "unknown"')
    uptime_secs=$(printf '%s' "$health_body" | jq -r '.uptime_secs // 0')
    # Forward-compatible: sidecar may report vl_available in future
    vl_available=$(printf '%s' "$health_body" | jq -r '.vl_available // "unknown"')

    if [ "$svc_status" != "ok" ]; then
        status="critical"
        exit_code=2
        issues+=("Service reports status='${svc_status}', expected 'ok'")
    fi

    if [ "$tesseract_version" = "unknown" ] || [ -z "$tesseract_version" ]; then
        if [ "$status" = "healthy" ]; then
            status="degraded"
            exit_code=1
        fi
        issues+=("Tesseract version unavailable — OCR engine may not be installed")
    fi
fi

# ── Latency check ────────────────────────────────────────────────────────────

if [ "$latency_ms" -gt "$LATENCY_CRITICAL_MS" ] 2>/dev/null; then
    if [ "$status" = "healthy" ]; then
        status="degraded"
        exit_code=1
    fi
    issues+=("Health endpoint latency critical: ${latency_ms}ms")
elif [ "$latency_ms" -gt "$LATENCY_DEGRADED_MS" ] 2>/dev/null; then
    if [ "$status" = "healthy" ]; then
        status="degraded"
        exit_code=1
    fi
    issues+=("Health endpoint latency elevated: ${latency_ms}ms")
fi

# ── Optional: probe /vision/metrics ──────────────────────────────────────────

if [ "$FETCH_METRICS" = "true" ] && [ "$http_code" = "200" ]; then
    metrics_raw=$(curl -s --connect-timeout "$TIMEOUT_SECS" --max-time "$TIMEOUT_SECS" \
        "${LUNARVISION_URL}/vision/metrics" 2>/dev/null) || true

    if printf '%s' "$metrics_raw" | jq . >/dev/null 2>&1; then
        total_requests=$(printf '%s' "$metrics_raw" | jq -r '.total_requests // 0')
        ocr_requests=$(printf '%s' "$metrics_raw" | jq -r '.ocr_requests // 0')
        vision_requests=$(printf '%s' "$metrics_raw" | jq -r '.vision_requests // 0')
        cache_hits=$(printf '%s' "$metrics_raw" | jq -r '.cache_hits // 0')
        cache_misses=$(printf '%s' "$metrics_raw" | jq -r '.cache_misses // 0')
        rate_limited=$(printf '%s' "$metrics_raw" | jq -r '.rate_limited // 0')
        cache_hit_rate=$(printf '%s' "$metrics_raw" | jq -r '.cache_hit_rate // 0.0')
        avg_latency_ms=$(printf '%s' "$metrics_raw" | jq -r '.avg_latency_ms // 0')
    fi
fi

# ── VL requirement check ─────────────────────────────────────────────────────

if [ "$REQUIRE_VL" = "true" ]; then
    if [ "$vl_available" = "false" ]; then
        if [ "$status" = "healthy" ]; then
            status="degraded"
            exit_code=1
        fi
        issues+=("VL backend required but unavailable")
    elif [ "$vl_available" = "unknown" ]; then
        # Sidecar doesn't expose VL status yet — flag as degraded with clear reason
        if [ "$status" = "healthy" ]; then
            status="degraded"
            exit_code=1
        fi
        issues+=("VL backend required but availability unknown (sidecar health endpoint doesn't report vl_available)")
    fi
fi

# ── Build issues array ───────────────────────────────────────────────────────

issues_json="[]"
if [ ${#issues[@]} -gt 0 ]; then
    issues_json=$(printf '%s\n' "${issues[@]}" | jq -R . | jq -s .)
fi

# ── Guard: ensure all numeric vars are valid numbers ─────────────────────────

[[ -z "$latency_ms" || ! "$latency_ms" =~ ^[0-9]+$ ]] && latency_ms=0
[[ -z "$uptime_secs" || ! "$uptime_secs" =~ ^[0-9]+$ ]] && uptime_secs=0
[[ -z "$total_requests" || ! "$total_requests" =~ ^[0-9]+$ ]] && total_requests=0
[[ -z "$ocr_requests" || ! "$ocr_requests" =~ ^[0-9]+$ ]] && ocr_requests=0
[[ -z "$vision_requests" || ! "$vision_requests" =~ ^[0-9]+$ ]] && vision_requests=0
[[ -z "$cache_hits" || ! "$cache_hits" =~ ^[0-9]+$ ]] && cache_hits=0
[[ -z "$cache_misses" || ! "$cache_misses" =~ ^[0-9]+$ ]] && cache_misses=0
[[ -z "$rate_limited" || ! "$rate_limited" =~ ^[0-9]+$ ]] && rate_limited=0
[[ -z "$avg_latency_ms" || ! "$avg_latency_ms" =~ ^[0-9]+$ ]] && avg_latency_ms=0
[[ -z "$cache_hit_rate" || ! "$cache_hit_rate" =~ ^[0-9.]+$ ]] && cache_hit_rate=0.0

# ── Guard: ensure all numeric vars are valid numbers ─────────────────────────

[[ -z "$latency_ms" || ! "$latency_ms" =~ ^[0-9]+$ ]] && latency_ms=0
[[ -z "$uptime_secs" || ! "$uptime_secs" =~ ^[0-9]+$ ]] && uptime_secs=0
[[ -z "$total_requests" || ! "$total_requests" =~ ^[0-9]+$ ]] && total_requests=0
[[ -z "$ocr_requests" || ! "$ocr_requests" =~ ^[0-9]+$ ]] && ocr_requests=0
[[ -z "$vision_requests" || ! "$vision_requests" =~ ^[0-9]+$ ]] && vision_requests=0
[[ -z "$cache_hits" || ! "$cache_hits" =~ ^[0-9]+$ ]] && cache_hits=0
[[ -z "$cache_misses" || ! "$cache_misses" =~ ^[0-9]+$ ]] && cache_misses=0
[[ -z "$rate_limited" || ! "$rate_limited" =~ ^[0-9]+$ ]] && rate_limited=0
[[ -z "$avg_latency_ms" || ! "$avg_latency_ms" =~ ^[0-9]+$ ]] && avg_latency_ms=0
[[ -z "$cache_hit_rate" || ! "$cache_hit_rate" =~ ^[0-9.]+$ ]] && cache_hit_rate=0.0

# ── Output ───────────────────────────────────────────────────────────────────

# Capabilities summary (short, for top-level visibility)
capabilities="ocr"
if [ "$vl_available" = "true" ] || [ "$vision_requests" -gt 0 ] 2>/dev/null; then
    capabilities="ocr,vl"
fi

jq -n \
    --arg component "lunarvision" \
    --arg status "$status" \
    --arg timestamp "$TIMESTAMP" \
    --arg latency "$latency_ms" \
    --arg url "${LUNARVISION_URL}/health" \
    --arg svc_status "$svc_status" \
    --arg tesseract_version "$tesseract_version" \
    --arg uptime_secs "$uptime_secs" \
    --arg vl_available "$vl_available" \
    --arg capabilities "$capabilities" \
    --arg total_requests "$total_requests" \
    --arg ocr_requests "$ocr_requests" \
    --arg vision_requests "$vision_requests" \
    --arg cache_hits "$cache_hits" \
    --arg cache_misses "$cache_misses" \
    --arg rate_limited "$rate_limited" \
    --arg cache_hit_rate "$cache_hit_rate" \
    --arg avg_latency_ms "$avg_latency_ms" \
    --argjson issues "$issues_json" \
    '{
        component: $component,
        status: $status,
        timestamp: $timestamp,
        metrics: {
            enabled: true,
            url: $url,
            latency_ms: ($latency | tonumber),
            service_status: $svc_status,
            tesseract_version: $tesseract_version,
            uptime_secs: ($uptime_secs | tonumber),
            vl_available: $vl_available,
            capabilities: $capabilities,
            total_requests: ($total_requests | tonumber),
            ocr_requests: ($ocr_requests | tonumber),
            vision_requests: ($vision_requests | tonumber),
            cache: {
                hits: ($cache_hits | tonumber),
                misses: ($cache_misses | tonumber),
                hit_rate: ($cache_hit_rate | tonumber)
            },
            rate_limited: ($rate_limited | tonumber),
            avg_latency_ms: ($avg_latency_ms | tonumber)
        },
        issues: $issues
    }'

exit $exit_code
