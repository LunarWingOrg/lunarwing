#!/bin/bash
# Health Check: Model API Health
# Checks: provider availability (OpenRouter, OpenAI, Anthropic, local models)
# Output: JSON to stdout
# Exit codes: 0=healthy, 1=degraded, 2=critical

set -uo pipefail

# Thresholds
LATENCY_DEGRADED_MS=3000
LATENCY_CRITICAL_MS=10000

# Initialize
overall_status="healthy"
overall_exit_code=0

# Check a single provider, output JSON object to stdout, return exit code
check_provider() {
    local provider=$1
    local endpoint=$2
    local api_key_env=$3
    
    local status="healthy"
    local latency_ms=0
    local last_error=""
    local exit_code=0
    
    local start=$(date +%s%N)
    
    case $provider in
        "openrouter")
            if [ -n "${!api_key_env:-}" ]; then
                response=$(curl -s --connect-timeout 5 --max-time 15 -w "%{http_code}" \
                    -H "Authorization: Bearer ${!api_key_env}" \
                    -H "Content-Type: application/json" \
                    "$endpoint/health" 2>/dev/null) || true
                
                if [[ "$response" == *"200"* ]] && [[ "$response" == *"ok"* ]]; then
                    status="healthy"
                else
                    status="critical"
                    last_error="HTTP error or unhealthy response"
                    exit_code=2
                fi
            else
                status="unknown"
                last_error="API key not set"
                exit_code=1
            fi
            ;;
        "openai")
            if [ -n "${!api_key_env:-}" ]; then
                response=$(curl -s --connect-timeout 5 --max-time 15 -w "%{http_code}" \
                    -H "Authorization: Bearer ${!api_key_env}" \
                    "$endpoint/models" 2>/dev/null) || true
                
                if [[ "$response" == *"200"* ]]; then
                    status="healthy"
                else
                    status="critical"
                    last_error="HTTP error"
                    exit_code=2
                fi
            else
                status="unknown"
                last_error="API key not set"
                exit_code=1
            fi
            ;;
        "anthropic")
            if [ -n "${!api_key_env:-}" ]; then
                response=$(curl -s --connect-timeout 5 --max-time 15 -w "%{http_code}" \
                    -H "x-api-key: ${!api_key_env}" \
                    -H "anthropic-version: 2023-06-01" \
                    "$endpoint" 2>/dev/null) || true
                
                if [[ "$response" == *"200"* ]]; then
                    status="healthy"
                else
                    status="critical"
                    last_error="HTTP error"
                    exit_code=2
                fi
            else
                status="unknown"
                last_error="API key not set"
                exit_code=1
            fi
            ;;
        "local")
            response=$(curl -s --connect-timeout 5 --max-time 15 -w "%{http_code}" \
                "$endpoint" 2>/dev/null) || true
            
            if [[ "$response" == *"200"* ]]; then
                status="healthy"
            else
                status="critical"
                last_error="Local model endpoint unreachable"
                exit_code=2
            fi
            ;;
    esac
    
    local end=$(date +%s%N)
    latency_ms=$(( (end - start) / 1000000 ))
    
    # Check latency thresholds
    if [ $latency_ms -gt $LATENCY_CRITICAL_MS ]; then
        status="critical"
        last_error="Latency critical: ${latency_ms}ms"
        exit_code=2
    elif [ $latency_ms -gt $LATENCY_DEGRADED_MS ]; then
        if [ "$status" = "healthy" ]; then
            status="degraded"
            last_error="Latency elevated: ${latency_ms}ms"
            exit_code=1
        fi
    fi
    
    # Output provider result as a single JSON line (easy to parse later)
    printf '%s\n' "{\"name\":\"$provider\",\"status\":\"$status\",\"latency_ms\":$latency_ms,\"last_error\":\"$last_error\",\"exit_code\":$exit_code}"
    
    return $exit_code
}

# Check all providers — collect JSON and track worst exit code
provider_results=()
for provider_spec in \
    "openrouter|https://openrouter.ai/api/v1|OPENROUTER_API_KEY" \
    "openai|https://api.openai.com/v1|OPENAI_API_KEY" \
    "anthropic|https://api.anthropic.com/v1|ANTHROPIC_API_KEY" \
    "local|http://localhost:8000/v1|"
do
    IFS='|' read -r pname pendpoint pkey <<< "$provider_spec"
    result=$(check_provider "$pname" "$pendpoint" "$pkey") || true
    rc=${PIPESTATUS[0]:-0}
    
    # Extract exit_code from the JSON result
    prov_exit=$(echo "$result" | jq -r '.exit_code // 0' 2>/dev/null || echo 0)
    
    if [ "$prov_exit" -gt "$overall_exit_code" ] 2>/dev/null; then
        overall_exit_code=$prov_exit
        if [ "$prov_exit" -eq 2 ]; then
            overall_status="critical"
        elif [ "$prov_exit" -eq 1 ] && [ "$overall_status" != "critical" ]; then
            overall_status="degraded"
        fi
    fi
    
    provider_results+=("$result")
done

# Build providers array JSON using jq
providers_json=$(printf '%s\n' "${provider_results[@]}" | jq -s '[.[] | del(.exit_code)]')

# Output final JSON
jq -n \
    --arg status "$overall_status" \
    --arg timestamp "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    --argjson providers "$providers_json" \
    '{
        component: "models",
        status: $status,
        timestamp: $timestamp,
        providers: $providers
    }'

exit $overall_exit_code
