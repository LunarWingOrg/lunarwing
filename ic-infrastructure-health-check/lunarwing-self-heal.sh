#!/usr/bin/env bash
# LunarWing Self-Healing Infrastructure Watchdog
#
# Reads infrastructure health-check JSON reports and attempts auto-remediation
# by restarting unhealthy services. Tracks retry counts, applies backoff,
# and escalates to notification after max retries.
#
# Usage:
#   lunarwing-self-heal.sh [--report <path>] [--dry-run] [--max-retries N] [--backoff N]
#
# Supports systemd, OpenRC, and launchd init systems.
# Designed to be called from cron-wrapper.sh after infrastructure-health-check.sh.

set -euo pipefail

VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Configuration ────────────────────────────────────────────────────────────

REPORT_DIR="${LUNARWING_BASE_DIR:-${IRONCLAW_BASE_DIR:-$HOME/.lunarwing}}/workspace/reports/health"
SELF_HEAL_STATE_DIR="${SELF_HEAL_STATE_DIR:-$REPORT_DIR/../self-heal}"
SELF_HEAL_LOG="${SELF_HEAL_LOG:-$SELF_HEAL_STATE_DIR/actions.log}"
MAX_RETRIES="${SELF_HEAL_MAX_RETRIES:-3}"
# Linear backoff (legacy). Kept as a fallback for callers that still set
# SELF_HEAL_BACKOFF_SECONDS / --backoff. When BACKOFF_BASE is at its default,
# the legacy value (if set) wins; otherwise exponential backoff with jitter
# is used. See compute_backoff().
BACKOFF_SECONDS="${SELF_HEAL_BACKOFF_SECONDS:-}"
BACKOFF_BASE="${SELF_HEAL_BACKOFF_BASE:-5}"
BACKOFF_MAX="${SELF_HEAL_BACKOFF_MAX:-300}"
# Backoff strategy. "linear" preserves the historical fixed-delay behavior
# (one number, no jitter). "exponential" uses compute_backoff(): each
# attempt's wait is BASE * 2^(attempt-1), capped at MAX, with full jitter
# (uniform random in [0, capped]). Default exponential.
BACKOFF_STRATEGY="${SELF_HEAL_BACKOFF_STRATEGY:-exponential}"
# Number of consecutive unhealthy checks before first restart (flapping guard).
# Default 2: a service must fail two health checks in a row before remediation.
GRACE_CHECKS="${SELF_HEAL_GRACE_CHECKS:-2}"
DRY_RUN=false
REPORT_FILE=""

# ── Logging ──────────────────────────────────────────────────────────────────

timestamp() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

log_action() {
    local line="$(timestamp) $*"
    mkdir -p "$(dirname "$SELF_HEAL_LOG")"
    printf '%s\n' "$line" >> "$SELF_HEAL_LOG"
    printf '%s\n' "$line" >&2
}

log() {
    printf '%s %s\n' "$(timestamp)" "$*" >&2
}

say() { printf '%s\n' "$*"; }
die() { log "FATAL: $*"; exit 1; }

# ── Arg parsing ────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --report)        REPORT_FILE="$2"; shift 2 ;;
        --dry-run|-n)    DRY_RUN=true; shift ;;
        --max-retries)   MAX_RETRIES="$2"; shift 2 ;;
        --backoff)       BACKOFF_SECONDS="$2"; shift 2 ;;
        --backoff-base)  BACKOFF_BASE="$2"; shift 2 ;;
        --backoff-max)   BACKOFF_MAX="$2"; shift 2 ;;
        --backoff-strategy) BACKOFF_STRATEGY="$2"; shift 2 ;;
        --grace-checks)  GRACE_CHECKS="$2"; shift 2 ;;
        --verify-health)
            case "${2:-}" in
                0|false|no|off) VERIFY_HEALTH="false"; shift 2 ;;
                *) VERIFY_HEALTH="true"; shift 2 ;;  # explicit enable or missing arg
            esac
            ;;
        --help|-h)
            say "Usage: lunarwing-self-heal.sh [--report <path>] [--dry-run] [--max-retries N] [--backoff N] [--backoff-base N] [--backoff-max N] [--backoff-strategy linear|exponential] [--grace-checks N] [--verify-health true|false]"
            exit 0
            ;;
        *) die "unknown arg: $1 (use --help)" ;;
    esac
done

# ── Init system detection ──────────────────────────────────────────────────

# Legacy promotion: if SELF_HEAL_BACKOFF_SECONDS or --backoff was used,
# honour it as a fixed linear delay for full backward compatibility.
# New callers should use --backoff-base / --backoff-max / --backoff-strategy.
if [[ -n "$BACKOFF_SECONDS" ]]; then
    BACKOFF_BASE="$BACKOFF_SECONDS"
    BACKOFF_STRATEGY="linear"
fi

# Same logic as health-check and watchdog installers
detect_service_manager() {
    local override="${LUNARWING_SERVICE_MANAGER:-${IRONCLAW_SERVICE_MANAGER:-}}"
    if [[ -n "$override" ]]; then
        printf '%s' "$override"
        return 0
    fi

    [[ "$(uname -s)" == "Darwin" ]] && { printf 'launchd'; return 0; }
    [[ -e /run/openrc/softlevel ]] && { printf 'openrc'; return 0; }
    [[ -e /run/systemd/system ]]   && { printf 'systemd'; return 0; }

    command -v rc-service >/dev/null 2>&1 && ! command -v systemctl >/dev/null 2>&1 && { printf 'openrc'; return 0; }
    command -v systemctl >/dev/null 2>&1 && { printf 'systemd'; return 0; }
    command -v rc-service >/dev/null 2>&1 && { printf 'openrc'; return 0; }

    printf 'unknown'
}

SERVICE_MANAGER="$(detect_service_manager)"
log "detected service manager: $SERVICE_MANAGER"

# ── Service restart helpers ──────────────────────────────────────────────────

_systemd_active() { systemctl is-active --quiet "$1"; }
_systemd_restart() {
    local svc="$1"
    if [[ "$DRY_RUN" == true ]]; then
        log "[DRY-RUN] would run: systemctl restart $svc"
        return 0
    fi
    systemctl restart "$svc"
}

_openrc_active() { rc-service "$1" status >/dev/null 2>&1; }
_openrc_restart() {
    local svc="$1"
    if [[ "$DRY_RUN" == true ]]; then
        log "[DRY-RUN] would run: rc-service $svc restart"
        return 0
    fi
    rc-service "$svc" restart
}

_launchd_active() {
    local label="$1"
    launchctl list 2>/dev/null | grep -q "$label"
}
_launchd_restart() {
    local label="$1"
    if [[ "$DRY_RUN" == true ]]; then
        log "[DRY-RUN] would run: launchctl stop/start $label"
        return 0
    fi
    launchctl stop "$label" 2>/dev/null || true
    sleep 1
    launchctl start "$label"
}

restart_service() {
    local svc="$1"
    case "$SERVICE_MANAGER" in
        systemd) _systemd_restart "$svc" ;;
        openrc)  _openrc_restart "$svc" ;;
        launchd) _launchd_restart "$svc" ;;
        *)       log "WARNING: unknown service manager, cannot restart $svc"; return 1 ;;
    esac
}

check_service_active() {
    local svc="$1"
    case "$SERVICE_MANAGER" in
        systemd) _systemd_active "$svc" ;;
        openrc)  _openrc_active "$svc" ;;
        launchd) _launchd_active "$svc" ;;
        *)       return 1 ;;
    esac
}

# ── Post-restart health verification ────────────────────
# verify_service_healthy <svc>
#   Returns 0 if the service appears healthy. Stops at the init-system check
#   when VERIFY_HEALTH is false or no SERVICE_VERIFY_MAP entry exists.
#   Otherwise runs a second-stage functional probe after the init check passes.
#   Strategies:
#     "http://..." -- curl with 5s timeout, expects HTTP 200
#     "tcp://..."  -- bash /dev/tcp, expects connection success
verify_service_healthy() {
    local svc="$1"

    # Gate 1: init-system says it's active.
    # When running in a container/CI without an init system, the check tools
    # (systemctl, rc-service, launchctl) are absent — skip this gate so the
    # second-stage probe can still run in tests.
    if command -v systemctl >/dev/null 2>&1 || command -v rc-service >/dev/null 2>&1 || command -v launchctl >/dev/null 2>&1; then
        if ! check_service_active "$svc"; then
            return 1
        fi
    fi

    # Gate 2: second-stage probe (only if enabled)
    if [[ "$VERIFY_HEALTH" == "false" ]] || [[ "$VERIFY_HEALTH" == "0" ]]; then
        return 0
    fi

    local strategy="${SERVICE_VERIFY_MAP[$svc]:-}"
    if [[ -z "$strategy" ]]; then
        return 0  # no verify map entry → init_only is sufficient
    fi

    case "$strategy" in
        http://*)
            local http_code
            http_code="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 "$strategy" 2>/dev/null || true)"
            if [[ "$http_code" == "200" ]] || [[ "$http_code" == "204" ]]; then
                return 0
            fi
            log "VERIFY: $svc HTTP $strategy returned $http_code (expected 200)"
            return 1
            ;;
        tcp://*)
            local host_port="${strategy#tcp://}"
            local host="${host_port%:*}"
            local port="${host_port##*:}"
            if timeout 3 bash -c "echo >/dev/tcp/$host/$port" 2>/dev/null; then
                return 0
            fi
            log "VERIFY: $svc TCP $strategy connection failed"
            return 1
            ;;
        *)
            return 0  # unknown strategy — treated as init_only
            ;;
    esac
}

# ── Component → service mapping ─────────────────────────────────────────────
#
# Maps logical health-check component names to service/unit names.
# Keys are health-check "component" values.
# Values are space-separated service names (init-system-agnostic; .service not needed).
# For systemd, .service is auto-appended. For OpenRC/launchd, bare names are used.

declare -A SERVICE_MAP=(
    [gateway]="lunarwing"
    [xmpp]="xmpp-bridge"
    [tensorzero]="tensorzero-gateway"
    [clickhouse]="clickhouse-server"
)

# Components that represent features of another service, not their own service
# (e.g., OMEMO is a feature of xmpp-bridge; models is an external API)
# These are skipped for auto-remediation.
declare -A NO_REMEDY=(
    [omemo]=1
    [ratelimit]=1
    [models]=1
)

# ── Post-restart verification map ────────────────────
# Maps service names to verification strategies. After rest_mode=restart and the
# init-system says the service is active, an optional second-stage probe confirms
# the service actually responds. Strategies:
#   "init_only" — the default; stops at check_service_active()
#   "http://HOST:PORT/PATH" — curl the URL, expect HTTP 200
#   "tcp://HOST:PORT" — connect via bash /dev/tcp, expect success
# All verification is gated on SELF_HEAL_VERIFY_HEALTH (default true).
declare -A SERVICE_VERIFY_MAP=(
    [lunarwing]="http://127.0.0.1:8080/api/health"
    [xmpp-bridge]="http://127.0.0.1:5280"
    [tensorzero-gateway]="http://127.0.0.1:8081/health"
    # clickhouse-server has no HTTP endpoint; init_only is the correct default
)

# Whether post-restart verification is enabled. Set to "0" or "false" to
# disable the second-stage probe (init-system check only).
VERIFY_HEALTH="${SELF_HEAL_VERIFY_HEALTH:-true}"

# ── State management ────────────────────────────────────────────────────────

STATE_FILE="$SELF_HEAL_STATE_DIR/state.json"

ensure_state_dir() {
    mkdir -p "$SELF_HEAL_STATE_DIR"
    if [[ ! -f "$STATE_FILE" ]]; then
        echo '{}' > "$STATE_FILE"
    fi
}

load_state() { jq -r '.' "$STATE_FILE" 2>/dev/null || echo '{}'; }

save_state() {
    local state="$1"
    local tmp
    tmp="$(mktemp "$STATE_FILE.tmp.XXXXXX")"
    printf '%s\n' "$state" > "$tmp"
    mv "$tmp" "$STATE_FILE"
}

get_retry_count() {
    local state="$1" svc="$2"
    echo "$state" | jq -r ".\"$svc\".retries // 0"
}

set_retry_count() {
    local state="$1" svc="$2" count="$3"
    echo "$state" | jq --arg svc "$svc" --argjson count "$count" \
        '.[$svc] = (.[$svc] // {}) | .[$svc].retries = $count | .[$svc].last_attempt = now | .[$svc].escalated = (.[$svc].escalated // false)'
}

mark_escalated() {
    local state="$1" svc="$2"
    echo "$state" | jq --arg svc "$svc" \
        '.[$svc] = (.[$svc] // {}) | .[$svc].escalated = true | .[$svc].escalatedAt = now'
}

clear_service_state() {
    local state="$1" svc="$2"
    echo "$state" | jq --arg svc "$svc" 'del(.[$svc])'
}

# ── Grace-period (flapping-guard) helpers ───────────────────────────────────
#
# `consecutive_unhealthy` counts how many consecutive runs have seen this
# service unhealthy. We only proceed to restart after the counter reaches
# `$GRACE_CHECKS`. A single healthy observation resets it to 0 (and clears the
# service's state entry entirely via `clear_service_state`).
#
# `first_unhealthy_at` records when the streak began — useful for debugging
# flapping services and for downstream tooling to report "down since X".

get_unhealthy_count() {
    local state="$1" svc="$2"
    echo "$state" | jq -r ".\"$svc\".consecutive_unhealthy // 0"
}

increment_unhealthy_count() {
    local state="$1" svc="$2"
    echo "$state" | jq --arg svc "$svc" '
        .[$svc] = (.[$svc] // {})
        | .[$svc].consecutive_unhealthy = ((.[$svc].consecutive_unhealthy // 0) + 1)
        | .[$svc].first_unhealthy_at = (.[$svc].first_unhealthy_at // now)
        | .[$svc].last_unhealthy_at = now
    '
}

# ── Notification escalation ─────────────────

# ── Exponential backoff with jitter ─────────────────
#
# compute_backoff <attempt-number>
#   attempt-number: 1-based restart attempt within the current remediation
#   cycle (1 = first restart, 2 = second restart after first failed, etc.).
#
# Linear mode (--backoff used, or SELF_HEAL_BACKOFF_STRATEGY=linear):
#   returns $BACKOFF_BASE as-is. No jitter. Preserves historical behaviour.
#
# Exponential mode (default):
#   delay = BASE * 2^(attempt-1), capped at MAX, then full jitter:
#   actual = $RANDOM % (delay + 1), so result is in [0, delay].
#   With the defaults (BASE=5s, MAX=300s) the scale is:
#     attempt 1: 0–5s
#     attempt 2: 0–10s
#     attempt 3: 0–20s
#   Output: integer seconds to stdout.
#   Edge cases: attempt <= 0 → 0. BASE or MAX not numeric → 0 (logged).

compute_backoff() {
    local attempt="${1:-1}"

    if [[ "$BACKOFF_STRATEGY" == "linear" ]]; then
        printf '%s' "${BACKOFF_BASE:-5}"
        return 0
    fi

    # Validate inputs
    if ! [[ "$attempt" =~ ^[0-9]+$ ]] || [[ "$attempt" -le 0 ]]; then
        printf '0'
        return 0
    fi
    local base="${BACKOFF_BASE:-5}"
    local max="${BACKOFF_MAX:-300}"
    if ! [[ "$base" =~ ^[0-9]+$ ]] || ! [[ "$max" =~ ^[0-9]+$ ]]; then
        log "WARNING: invalid backoff config base=$base max=$max; falling back to 0"
        printf '0'
        return 0
    fi

    # BASE * 2^(attempt-1), capped at MAX
    local delay="$base"
    local i
    for ((i = 1; i < attempt; i++)); do
        delay=$((delay * 2))
    done
    if [[ "$delay" -gt "$max" ]]; then
        delay="$max"
    fi

    # Full jitter: uniform random [0, delay]
    if [[ "$delay" -le 0 ]]; then
        printf '0'
        return 0
    fi
    printf '%s' "$(( RANDOM % (delay + 1) ))"
}

# ── Notification escalation ─────────────────────────────────────────────────

_send_notification() {
    local status="$1" report_path="$2"
    local notify_script="$SCRIPT_DIR/send-notification.sh"
    if [[ -x "$notify_script" ]]; then
        "$notify_script" "$status" "$report_path"
    else
        log "WARNING: send-notification.sh not found at $notify_script; cannot escalate"
    fi
}

escalate_service() {
    local svc="$1"
    local report_path="${2:-}"
    log "ESCALATING: $svc has failed $MAX_RETRIES consecutive restart attempts"
    log_action "ESCALATE target=$svc retries=$MAX_RETRIES"
    if [[ "$DRY_RUN" == true ]]; then
        log "[DRY-RUN] would send escalation notification for $svc"
        return 0
    fi

    # Build a terse escalation report
    local esc_report
    esc_report="$SELF_HEAL_STATE_DIR/escalation-$(date +%Y%m%d%H%M%S)-$svc.json"
    jq -n \
        --arg svc "$svc" \
        --arg now "$(timestamp)" \
        --argjson retries "$(get_retry_count "$STATE" "$svc")" \
        '{escalated: true, service: $svc, timestamp: $now, retries: $retries, action: "manual_intervention_required"}' \
        > "$esc_report"

    _send_notification "critical" "$esc_report"
    rm -f "$esc_report"
}

# ── Main remediation logic ──────────────────────────────────────────────────

remediate_component() {
    local comp="$1" state="$2" services="$3"
    local svc result=0

    for svc in $services; do
        local retries
        retries="$(get_retry_count "$state" "$svc")"

        if [[ $retries -ge $MAX_RETRIES ]]; then
            local escalated
            escalated="$(echo "$state" | jq -r ".\"$svc\".escalated // false")"
            if [[ "$escalated" == "false" ]]; then
                state="$(mark_escalated "$state" "$svc")"
                escalate_service "$svc"
            else
                log "SKIP: $svc already escalated (retries=$retries >= max=$MAX_RETRIES)"
            fi
            continue
        fi

        # Grace-period (flapping-guard): only restart once this service has
        # been observed unhealthy for $GRACE_CHECKS consecutive checks. The
        # first observation just bumps the counter and exits quietly, so
        # transient flakes no longer cause an immediate restart. The
        # counter is cleared by the "all healthy" branch in main() when
        # the service comes back, or by set_retry_count/clear_service_state
        # once a restart is actually attempted.
        local unhealthy_count
        unhealthy_count="$(get_unhealthy_count "$state" "$svc")"
        state="$(increment_unhealthy_count "$state" "$svc")"
        if [[ $unhealthy_count -lt $((GRACE_CHECKS - 1)) ]]; then
            log "GRACE: $svc unhealthy streak=$((unhealthy_count + 1))/$GRACE_CHECKS — observing, not restarting yet"
            log_action "GRACE_HOLD target=$svc streak=$((unhealthy_count + 1)) threshold=$GRACE_CHECKS"
            continue
        fi

        log "RESTART: $svc (component=$comp, retries so far=$retries, unhealthy streak=$((unhealthy_count + 1)))"
        log_action "RESTART_BEGIN target=$svc component=$comp retries=$retries"

        if restart_service "$svc"; then
            # Wait for service to come back, using exponential backoff + jitter
            local attempt=$((retries + 1))
            local wait_s
            wait_s="$(compute_backoff "$attempt")"
            log "BACKOFF: waiting ${wait_s}s for $svc (attempt $attempt, base=$BACKOFF_BASE, max=$BACKOFF_MAX, strategy=$BACKOFF_STRATEGY)"
            sleep "$wait_s"
            if verify_service_healthy "$svc"; then
                log "SUCCESS: $svc is active after restart"
                log_action "RESTART_OK target=$svc"
                state="$(clear_service_state "$state" "$svc")"
            else
                retries=$((retries + 1))
                log "WARNING: $svc restart command succeeded but service not healthy (retries=$retries)"
                log_action "RESTART_PARTIAL target=$svc retries=$retries"
                state="$(set_retry_count "$state" "$svc" "$retries")"
            fi
        else
            retries=$((retries + 1))
            log "FAILURE: restart command failed for $svc (retries=$retries)"
            log_action "RESTART_FAIL target=$svc retries=$retries"
            state="$(set_retry_count "$state" "$svc" "$retries")"
        fi
    done

    printf '%s' "$state"
}

# ── Report discovery ────────────────────────────────────────────────────────

find_latest_report() {
    local latest
    # Portable version — works on GNU and BSD/macOS find
    latest="$(find "$REPORT_DIR" -maxdepth 1 -name '*.json' ! -name '*-summary*' -type f 2>/dev/null | xargs ls -t 2>/dev/null | head -1)"
    printf '%s' "$latest"
}

# ── Entry point ─────────────────────────────────────────────────────────────

main() {
    local report="$REPORT_FILE"

    ensure_state_dir

    # Acquire lock to prevent concurrent self-heal runs
    local lockfile="$SELF_HEAL_STATE_DIR/self-heal.lock"
    if command -v flock >/dev/null 2>&1; then
        exec 200>"$lockfile"
        if ! flock -n 200; then
            log "WARNING: another self-heal instance is running; exiting"
            exit 0
        fi
    fi

    if [[ -z "$report" ]]; then
        report="$(find_latest_report)"
    fi

    if [[ -z "$report" || ! -f "$report" ]]; then
        die "no health-check report found in $REPORT_DIR"
    fi

    log "=== Self-Healing Watchdog v$VERSION ==="
    log "report: $report"
    log "service manager: $SERVICE_MANAGER"
    log "config: max-retries=$MAX_RETRIES backoff=strategy=$BACKOFF_STRATEGY base=${BACKOFF_BASE}s max=${BACKOFF_MAX}s grace-checks=$GRACE_CHECKS verify-health=$VERIFY_HEALTH dry-run=$DRY_RUN"

    if ! jq . "$report" >/dev/null 2>&1; then
        die "report is not valid JSON: $report"
    fi

    local state
    state="$(load_state)"

    # Build a set of target services from all unhealthy components
    local -a targets=()
    local -A seen=()

    # 1) Handle standard logical components
    local comp services svc
    while IFS= read -r comp; do
        [[ -n "$comp" ]] || continue

        # Skip if component has no remedy
        if [[ "${NO_REMEDY[$comp]:-}" == "1" ]]; then
            log "SKIP: component '$comp' has no standalone service (feature/external)"
            continue
        fi

        services="${SERVICE_MAP[$comp]:-}"
        if [[ -z "$services" ]]; then
            log "WARNING: no service mapping for component '$comp'; skipping"
            continue
        fi

        for svc in $services; do
            [[ -n "${seen[$svc]:-}" ]] && continue
            seen[$svc]=1
            targets+=("$comp:$svc")
        done
    done < <(jq -r '.components[] | select(.status != "healthy") | .component' "$report" 2>/dev/null || true)

    # 2) Handle init-system-specific components (systemd/openrc/launchd)
    # These components contain metrics.units or metrics.services listing sub-units
    local init_comp init_svc_line
    while IFS=: read -r init_comp init_svc_line; do
        [[ -n "$init_comp" ]] || continue

        # Extract individual unit/service names from the sub-metrics
        while IFS= read -r svc; do
            [[ -n "$svc" ]] || continue
            [[ -n "${seen[$svc]:-}" ]] && continue
            seen[$svc]=1

            # systemd units already include .service; strip it for OpenRC
            if [[ "$SERVICE_MANAGER" == "openrc" ]]; then
                svc="${svc%.service}"
            fi

            # Validate: systemd doesn't want bare names without .service
            if [[ "$SERVICE_MANAGER" == "systemd" && "$svc" != *.* ]]; then
                svc="${svc}.service"
            fi

            targets+=("$init_comp:$svc")
        done < <(echo "$init_svc_line")
    # NOTE: each init-system alternative MUST be fully parenthesized. jq's `|`
    # binds looser than `,`, so without the wrapping parens the trailing
    # "systemd:\(.name)" string of one alternative is piped into the next
    # alternative's `.metrics` index, which aborts the whole filter with
    # "Cannot index string with string" and silently yields zero targets.
    done < <(jq -r '
        ( .components[] | select(.component == "systemd" and .status != "healthy")
          | (.metrics.units // [])[]    | select(.status != "healthy") | "systemd:\(.name)" ),
        ( .components[] | select(.component == "openrc"  and .status != "healthy")
          | (.metrics.services // [])[] | select(.status != "healthy") | "openrc:\(.name)" ),
        ( .components[] | select(.component == "launchd" and .status != "healthy")
          | (.metrics.agents // [])[]   | select(.status != "healthy") | "launchd:\(.name)" )
    ' "$report" 2>/dev/null || true)

    if [[ ${#targets[@]} -eq 0 ]]; then
        log "all components healthy; no action needed"
        # Reset any stale state entries — the report itself is the source of
        # truth for "all healthy", so we don't round-trip through
        # check_service_active (which can be flaky in the seconds after a
        # restart and would cause the grace-period counter to stick). This
        # also makes the grace period self-healing: a transient flake that
        # resolves before the streak hits $GRACE_CHECKS leaves no residue.
        local stale
        stale="$(echo "$state" | jq -r 'keys[]')"
        for svc in $stale; do
            state="$(clear_service_state "$state" "$svc")"
            log "CLEARED stale state for $svc (report says all healthy)"
        done
        save_state "$state"
        log "=== Self-Healing complete (nothing to do) ==="
        exit 0
    fi

    log "identified ${#targets[@]} target(s) for remediation"

    # Process each unique target
    for target in "${targets[@]}"; do
        IFS=: read -r comp svc <<< "$target"
        state="$(remediate_component "$comp" "$state" "$svc")"
    done

    save_state "$state"

    # Generate summary
    local summary
    summary="$(echo "$state" | jq -r 'to_entries | map({service: .key, retries: .value.retries, escalated: .value.escalated})')"
    log "=== Self-Healing complete ==="
    log "state: $summary"
}

main "$@"
exit 0
