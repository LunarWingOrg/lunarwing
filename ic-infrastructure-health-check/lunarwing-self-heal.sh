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
BACKOFF_SECONDS="${SELF_HEAL_BACKOFF_SECONDS:-5}"
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
        --report)       REPORT_FILE="$2"; shift 2 ;;
        --dry-run|-n)   DRY_RUN=true; shift ;;
        --max-retries)  MAX_RETRIES="$2"; shift 2 ;;
        --backoff)      BACKOFF_SECONDS="$2"; shift 2 ;;
        --help|-h)
            say "Usage: lunarwing-self-heal.sh [--report <path>] [--dry-run] [--max-retries N] [--backoff N]"
            exit 0
            ;;
        *) die "unknown arg: $1 (use --help)" ;;
    esac
done

# ── Init system detection ──────────────────────────────────────────────────

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

        log "RESTART: $svc (component=$comp, retries so far=$retries)"
        log_action "RESTART_BEGIN target=$svc component=$comp retries=$retries"

        if restart_service "$svc"; then
            # Wait for service to come back
            sleep "$BACKOFF_SECONDS"
            if check_service_active "$svc"; then
                log "SUCCESS: $svc is active after restart"
                log_action "RESTART_OK target=$svc"
                state="$(clear_service_state "$state" "$svc")"
            else
                retries=$((retries + 1))
                log "WARNING: $svc restart command succeeded but service not active (retries=$retries)"
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
    latest="$(find "$REPORT_DIR" -maxdepth 1 -name '*.json' ! -name '*-summary*' -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)"
    printf '%s' "$latest"
}

# ── Entry point ─────────────────────────────────────────────────────────────

main() {
    local report="$REPORT_FILE"

    ensure_state_dir

    if [[ -z "$report" ]]; then
        report="$(find_latest_report)"
    fi

    if [[ -z "$report" || ! -f "$report" ]]; then
        die "no health-check report found in $REPORT_DIR"
    fi

    log "=== Self-Healing Watchdog v$VERSION ==="
    log "report: $report"
    log "service manager: $SERVICE_MANAGER"
    log "max retries: $MAX_RETRIES | backoff: ${BACKOFF_SECONDS}s | dry-run: $DRY_RUN"

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
    done < <(jq -r '
        (.components[] | select(.component == "systemd" and .status != "healthy")) |
        (.metrics.units // []) | map(select(.status != "healthy")) | .[].name |
        "systemd:\(.)",
        (.components[] | select(.component == "openrc" and .status != "healthy")) |
        (.metrics.services // []) | map(select(.status != "healthy")) | .[].name |
        "openrc:\(.)",
        (.components[] | select(.component == "launchd" and .status != "healthy")) |
        (.metrics.agents // []) | map(select(.status != "healthy")) | .[].name |
        "launchd:\(.)"
    ' "$report" 2>/dev/null || true)

    if [[ ${#targets[@]} -eq 0 ]]; then
        log "all components healthy; no action needed"
        # Reset any stale state entries that are now healthy
        local stale
        stale="$(echo "$state" | jq -r 'keys[]')"
        for svc in $stale; do
            # Check if this service is now healthy
            if check_service_active "$svc" 2>/dev/null; then
                state="$(clear_service_state "$state" "$svc")"
                log "CLEARED stale state for $svc (now healthy)"
            fi
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
