#!/usr/bin/env bash
# LunarWing Self-Healing Infrastructure Watchdog
#
# Reads infrastructure health-check JSON reports and attempts auto-remediation
# by restarting unhealthy services. Applies a grace period before the first
# restart, exponential backoff with jitter (linear toggle available), a
# flapping guard, post-restart verification via the component health checks,
# multi-tenant remediation, state auto-prune, and escalation via notification.
#
# Usage:
#   lunarwing-self-heal.sh [--report <path>] [--dry-run] [--max-retries N]
#       [--backoff N] [--backoff-base N] [--backoff-max N]
#       [--backoff-strategy linear|exponential] [--grace-checks N]
#       [--prune-ttl SECONDS] [--verify-health true|false]
#
# All thresholds are also configurable via SELF_HEAL_* env vars (see below).
# Supports systemd (incl. per-tenant user units), OpenRC, and launchd.
# Designed to be called from cron-wrapper.sh after infrastructure-health-check.sh.

set -euo pipefail

VERSION="1.2.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Configuration ────────────────────────────────────────────────────────────

REPORT_DIR="${LUNARWING_BASE_DIR:-${IRONCLAW_BASE_DIR:-$HOME/.lunarwing}}/workspace/reports/health"
SELF_HEAL_STATE_DIR="${SELF_HEAL_STATE_DIR:-$REPORT_DIR/../self-heal}"
SELF_HEAL_LOG="${SELF_HEAL_LOG:-$SELF_HEAL_STATE_DIR/actions.log}"
MAX_RETRIES="${SELF_HEAL_MAX_RETRIES:-3}"

# Fixed in-run settle wait after a restart, before verifying. Kept short and
# un-jittered (a 0s settle would verify before the service has come up).
BACKOFF_SECONDS="${SELF_HEAL_BACKOFF_SECONDS:-5}"

# Exponential backoff + jitter (compute_backoff()) BETWEEN remediation attempts.
# This spaces retries ACROSS cron ticks via next_attempt_at — it is not an
# in-run sleep, so the run never blocks on a long backoff. "linear" returns
# BACKOFF_BASE unchanged (no jitter) as a backward-compatible kill switch.
BACKOFF_BASE="${SELF_HEAL_BACKOFF_BASE:-60}"
BACKOFF_MAX="${SELF_HEAL_BACKOFF_MAX:-3600}"
BACKOFF_STRATEGY="${SELF_HEAL_BACKOFF_STRATEGY:-exponential}"

# Grace period: consecutive unhealthy checks required before the first restart.
GRACE_CHECKS="${SELF_HEAL_GRACE_CHECKS:-2}"

# Flapping guard: too many restarts within the window → escalate, stop looping.
FLAP_MAX_RESTARTS="${SELF_HEAL_FLAP_MAX_RESTARTS:-5}"
FLAP_WINDOW_SECS="${SELF_HEAL_FLAP_WINDOW_SECS:-3600}"

# Restart history cap: trim restart_history[] to last N entries to prevent
# unbounded state growth. Must be ≥ FLAP_MAX_RESTARTS to preserve flap detection.
HISTORY_MAX="${SELF_HEAL_HISTORY_MAX:-20}"

# Escalation notifier timeout (seconds). Prevents a hung Gotify/notify endpoint
# from stalling the entire self-heal tick. Falls back to no timeout if GNU
# coreutils `timeout` is unavailable (macOS/launchd hosts).
ESCALATE_TIMEOUT="${SELF_HEAL_ESCALATE_TIMEOUT:-30}"

# Post-restart verification: re-run the component's health-*.sh and parse
# .status (deeper than is-active). Set false to use is-active only.
VERIFY_HEALTH="${SELF_HEAL_VERIFY_HEALTH:-true}"
HEALTH_CHECK_DIR="${SELF_HEAL_HEALTH_CHECK_DIR:-$SCRIPT_DIR}"

# Prune non-escalated state entries untouched for this long. 0 disables pruning.
STATE_PRUNE_TTL="${SELF_HEAL_STATE_PRUNE_TTL:-86400}"   # 24h

# Logical-component remediation. In multi-tenant deployments the logical
# components (gateway/xmpp/tensorzero/clickhouse) map to single-instance base
# service names (lunarwing, xmpp-bridge, ...) that DON'T exist — only per-tenant
# init units do. Set false to remediate ONLY the auto-discovered init sub-units
# and avoid phantom restarts/escalations of nonexistent base services.
REMEDY_LOGICAL="${SELF_HEAL_REMEDY_LOGICAL:-true}"

# Report staleness guard: refuse to act on a report older than this many seconds
# (0 = disabled). Prevents remediating on stale data if the scheduler stalls.
MAX_REPORT_AGE="${SELF_HEAL_MAX_REPORT_AGE:-0}"

# Multi-tenant registry (lunarwing-mt-admin.sh). Per-tenant systemd units are
# USER units, restarted via sudo -u <user> systemctl --user.
# Umbrel: /etc/ is non-persistent across app updates; prefer a data-volume path
# when available, falling back to /etc/ for bare-metal installs.
_default_tenants_file() {
    local candidate="${LUNARWING_BASE_DIR:-${IRONCLAW_BASE_DIR:-}}/tenants/ports.json"
    [[ -f "$candidate" ]] && { printf '%s' "$candidate"; return 0; }
    printf '%s' "/etc/lunarwing/ports.json"
}
TENANTS_FILE="${SELF_HEAL_TENANTS_FILE:-$(_default_tenants_file)}"

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
        --report)            REPORT_FILE="$2"; shift 2 ;;
        --dry-run|-n)        DRY_RUN=true; shift ;;
        --max-retries)       MAX_RETRIES="$2"; shift 2 ;;
        --backoff)           BACKOFF_SECONDS="$2"; shift 2 ;;
        --backoff-base)      BACKOFF_BASE="$2"; shift 2 ;;
        --backoff-max)       BACKOFF_MAX="$2"; shift 2 ;;
        --backoff-strategy)  BACKOFF_STRATEGY="$2"; shift 2 ;;
        --grace-checks)      GRACE_CHECKS="$2"; shift 2 ;;
        --prune-ttl)
            case "${2:-}" in
                0|false|no|off) STATE_PRUNE_TTL="0"; shift 2 ;;
                *) STATE_PRUNE_TTL="$2"; shift 2 ;;
            esac
            ;;
        --verify-health)
            case "${2:-}" in
                0|false|no|off) VERIFY_HEALTH="false"; shift 2 ;;
                *) VERIFY_HEALTH="true"; shift 2 ;;
            esac
            ;;
        --help|-h)
            say "Usage: lunarwing-self-heal.sh [--report <path>] [--dry-run] [--max-retries N] [--backoff N] [--backoff-base N] [--backoff-max N] [--backoff-strategy linear|exponential] [--grace-checks N] [--prune-ttl SECONDS] [--verify-health true|false]"
            exit 0
            ;;
        *) die "unknown arg: $1 (use --help)" ;;
    esac
done

# ── Init system detection ──────────────────────────────────────────────────

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

# ── Multi-tenant helpers ────────────────────────────────────────────────────
#
# Per-tenant units are named lunarwing-<tenant>, xmpp-bridge-<tenant>,
# ironclaw-proxy-<tenant>. On systemd they are USER units owned by the tenant
# OS user; on OpenRC they are system services. We only treat a unit as
# per-tenant when its tenant resolves to a real user in the registry, so base
# units (lunarwing, xmpp-bridge, lunarwing-watchdog, ...) fall through safely.

unit_tenant() {
    local u="${1%.service}"
    case "$u" in
        lunarwing-proxy-*) printf '%s' "${u#lunarwing-proxy-}" ;;
        ironclaw-proxy-*)  printf '%s' "${u#ironclaw-proxy-}" ;;
        xmpp-bridge-*)     printf '%s' "${u#xmpp-bridge-}" ;;
        lunarwing-*)       printf '%s' "${u#lunarwing-}" ;;
        *)                 printf '' ;;
    esac
}

tenant_user() {
    local tenant="$1"
    [[ -n "$tenant" && -f "$TENANTS_FILE" ]] || return 0
    jq -r --arg t "$tenant" '.tenants[$t].user // empty' "$TENANTS_FILE" 2>/dev/null || true
}

_resolve_systemd_tenant_user() {
    local svc="$1" tenant user
    tenant="$(unit_tenant "$svc")"
    [[ -n "$tenant" ]] || { printf ''; return 0; }
    user="$(tenant_user "$tenant")"
    printf '%s' "$user"
}

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

# Per-tenant systemd USER units: run as the tenant user against their bus.
_systemd_user_restart() {
    local user="$1" unit="$2" uid
    uid="$(id -u "$user" 2>/dev/null || printf '?')"
    if [[ "$DRY_RUN" == true ]]; then
        log "[DRY-RUN] would run: sudo -u $user env XDG_RUNTIME_DIR=/run/user/$uid systemctl --user restart $unit"
        return 0
    fi
    [[ "$uid" == '?' ]] && { log "WARNING: cannot resolve uid for tenant user $user"; return 1; }
    sudo -u "$user" env "XDG_RUNTIME_DIR=/run/user/$uid" systemctl --user restart "$unit"
}
_systemd_user_active() {
    local user="$1" unit="$2" uid
    uid="$(id -u "$user" 2>/dev/null || printf '?')"
    [[ "$uid" == '?' ]] && return 1
    sudo -u "$user" env "XDG_RUNTIME_DIR=/run/user/$uid" systemctl --user is-active --quiet "$unit"
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
    # Close the self-heal lock fd (200, opened in main()) for the restart and ALL
    # its children. rc-service/systemctl spawn a long-lived supervise-daemon that
    # would otherwise INHERIT fd 200 and hold the flock forever — wedging every
    # later self-heal run with "another self-heal instance is running". The
    # `200>&-` on the case compound closes it for the whole dispatch subtree.
    case "$SERVICE_MANAGER" in
        systemd)
            local user
            user="$(_resolve_systemd_tenant_user "$svc")"
            if [[ -n "$user" ]]; then
                _systemd_user_restart "$user" "$svc"
            else
                _systemd_restart "$svc"
            fi
            ;;
        openrc)  _openrc_restart "$svc" ;;
        launchd) _launchd_restart "$svc" ;;
        *)       log "WARNING: unknown service manager, cannot restart $svc"; return 1 ;;
    esac 200>&-
}

check_service_active() {
    local svc="$1"
    case "$SERVICE_MANAGER" in
        systemd)
            local user
            user="$(_resolve_systemd_tenant_user "$svc")"
            if [[ -n "$user" ]]; then
                _systemd_user_active "$user" "$svc"
            else
                _systemd_active "$svc"
            fi
            ;;
        openrc)  _openrc_active "$svc" ;;
        launchd) _launchd_active "$svc" ;;
        *)       return 1 ;;
    esac
}

# ── Component → service mapping ─────────────────────────────────────────────

declare -A SERVICE_MAP=(
    [gateway]="lunarwing"
    [xmpp]="xmpp-bridge"
    [tensorzero]="tensorzero-gateway"
    [clickhouse]="clickhouse-server"
)

# Component → health-check script, for post-restart verification.
declare -A COMPONENT_CHECK_MAP=(
    [gateway]="health-gateway.sh"
    [xmpp]="health-xmpp.sh"
    [tensorzero]="health-tensorzero.sh"
    [clickhouse]="health-clickhouse.sh"
)

# Components that represent features of another service, not their own service.
declare -A NO_REMEDY=(
    [omemo]=1
    [ratelimit]=1
    [models]=1
)

# ── Exponential backoff with jitter (kumogakure's compute_backoff) ───────────
#
# compute_backoff <attempt> -> integer seconds until the next attempt.
#   linear:      returns BACKOFF_BASE unchanged (no jitter, kill switch).
#   exponential: BACKOFF_BASE * 2^(attempt-1), capped at BACKOFF_MAX, then full
#                jitter: uniform random in [0, delay].
# Used to schedule next_attempt_at across runs (NOT as an in-run sleep), so a
# jittered 0 just means "retry on the next tick".

compute_backoff() {
    local attempt="${1:-1}"

    if [[ "$BACKOFF_STRATEGY" == "linear" ]]; then
        printf '%s' "${BACKOFF_BASE:-60}"
        return 0
    fi

    if ! [[ "$attempt" =~ ^[0-9]+$ ]] || [[ "$attempt" -le 0 ]]; then
        printf '0'; return 0
    fi
    # Hard cap: services escalated and idling for weeks would otherwise run a
    # huge exponentiation loop. Defensive only — practical attempts are <10.
    if [[ "$attempt" -gt 20 ]]; then
        printf '%s' "${max:-3600}"
        return 0
    fi
    local base="${BACKOFF_BASE:-60}"
    local max="${BACKOFF_MAX:-3600}"
    if ! [[ "$base" =~ ^[0-9]+$ ]] || ! [[ "$max" =~ ^[0-9]+$ ]]; then
        log "WARNING: invalid backoff config base=$base max=$max; falling back to 0"
        printf '0'; return 0
    fi

    # BASE * 2^(attempt-1), capped at MAX (cap inside the loop to avoid overflow).
    local delay="$base" i
    for ((i = 1; i < attempt; i++)); do
        delay=$((delay * 2))
        if [[ "$delay" -ge "$max" ]]; then delay="$max"; break; fi
    done
    if [[ "$delay" -gt "$max" ]]; then delay="$max"; fi

    if [[ "$delay" -le 0 ]]; then printf '0'; return 0; fi
    # $RANDOM is 15-bit (0-32767). Above that the distribution skews; use urandom.
    if [[ "$delay" -gt 32767 ]]; then
        local rand
        rand=$(od -An -tu2 -N2 /dev/urandom | tr -d ' ')
        printf '%s' "$(( rand % (delay + 1) ))"
    else
        printf '%s' "$(( RANDOM % (delay + 1) ))"
    fi   # full jitter [0, delay]
}

# ── State management ────────────────────────────────────────────────────────
#
# state.json maps service -> { retries, escalated, last_attempt, escalatedAt,
# next_attempt_at, consecutive_unhealthy, first_unhealthy_at, last_unhealthy_at,
# restart_history[] }. Helpers operate on a JSON string and echo a new one.

STATE_FILE="$SELF_HEAL_STATE_DIR/state.json"

ensure_state_dir() {
    mkdir -p "$SELF_HEAL_STATE_DIR"
    [[ -f "$STATE_FILE" ]] || echo '{}' > "$STATE_FILE"
}

load_state() {
    if [[ ! -f "$STATE_FILE" ]]; then
        echo '{}'; return 0
    fi
    local parsed
    if parsed="$(jq -r '.' "$STATE_FILE" 2>/dev/null)"; then
        printf '%s' "$parsed"
    else
        # State file is corrupt (truncated write, disk error, etc.). Preserve it
        # for forensics under a single-slot .corrupt name (won't accumulate), then
        # start fresh so escalated state can be rebuilt from the next tick.
        local ts; ts="$(date +%s)"
        mv "$STATE_FILE" "$STATE_FILE.corrupt.${ts}" 2>/dev/null || true
        log "WARNING: state.json is corrupt — renamed to state.json.corrupt.${ts} and starting fresh"
        echo '{}'
    fi
}

save_state() {
    local state="$1" tmp
    tmp="$(mktemp "$STATE_FILE.tmp.XXXXXX")"
    printf '%s\n' "$state" > "$tmp"
    mv "$tmp" "$STATE_FILE"
}

state_get_num() {
    local state="$1" svc="$2" field="$3" default="${4:-0}"
    echo "$state" | jq -r --arg s "$svc" --arg f "$field" --argjson d "$default" '.[$s][$f] // $d'
}
state_set_num() {
    local state="$1" svc="$2" field="$3" val="$4"
    echo "$state" | jq --arg s "$svc" --arg f "$field" --argjson v "$val" \
        '.[$s] = (.[$s] // {}) | .[$s][$f] = $v'
}
state_get_bool() {
    local state="$1" svc="$2" field="$3"
    echo "$state" | jq -r --arg s "$svc" --arg f "$field" '.[$s][$f] // false'
}

get_retry_count() { state_get_num "$1" "$2" retries 0; }

set_retry_count() {
    local state="$1" svc="$2" count="$3"
    echo "$state" | jq --arg svc "$svc" --argjson count "$count" \
        '.[$svc] = (.[$svc] // {}) | .[$svc].retries = $count | .[$svc].last_attempt = (now | floor) | .[$svc].escalated = (.[$svc].escalated // false)'
}

mark_escalated() {
    local state="$1" svc="$2"
    echo "$state" | jq --arg svc "$svc" \
        '.[$svc] = (.[$svc] // {}) | .[$svc].escalated = true | .[$svc].escalatedAt = (now | floor)'
}

clear_service_state() {
    local state="$1" svc="$2"
    echo "$state" | jq --arg svc "$svc" 'del(.[$svc])'
}

# Record an unhealthy observation: bump streak + first/last_unhealthy_at.
record_unhealthy() {
    local state="$1" svc="$2" now="$3"
    echo "$state" | jq --arg s "$svc" --argjson now "$now" '
        .[$s] = (.[$s] // {})
        | .[$s].consecutive_unhealthy = ((.[$s].consecutive_unhealthy // 0) + 1)
        | .[$s].first_unhealthy_at = (.[$s].first_unhealthy_at // $now)
        | .[$s].last_unhealthy_at = $now'
}

# Flapping window helpers.
flap_count() {
    local state="$1" svc="$2" since="$3"
    echo "$state" | jq -r --arg s "$svc" --argjson since "$since" \
        '[(.[$s].restart_history // [])[] | select(. >= $since)] | length'
}
state_push_restart() {
    local state="$1" svc="$2" epoch="$3" since="$4"
    echo "$state" | jq --arg s "$svc" --argjson e "$epoch" --argjson since "$since" --argjson max "$HISTORY_MAX" \
        '.[$s] = (.[$s] // {})
         | .[$s].restart_history = (
             [ ((.[$s].restart_history // [])[] | select(. >= $since)), $e ]
             | if length > $max then .[-$max:] else . end
         )'
}

# Drop entries untouched past TTL that are not escalated and not currently
# unhealthy. STATE_PRUNE_TTL=0 disables. Recency = max(last_attempt, last_unhealthy_at).
prune_state() {
    local state="$1" now="$2"; shift 2
    [[ "$STATE_PRUNE_TTL" == "0" ]] && { printf '%s' "$state"; return 0; }
    local seen_json
    if [[ $# -gt 0 ]]; then seen_json="$(printf '%s\n' "$@" | jq -R . | jq -s .)"; else seen_json='[]'; fi
    echo "$state" | jq --argjson now "$now" --argjson ttl "$STATE_PRUNE_TTL" --argjson seen "$seen_json" '
        with_entries(select(
            (.value.escalated == true)
            or (.key | IN($seen[]))
            or (([.value.last_attempt, .value.last_unhealthy_at] | map(. // 0) | max) >= ($now - $ttl))
        ))'
}

# ── Notification escalation ─────────────────────────────────────────────────

_send_notification() {
    local status="$1" report_path="$2"
    local notify_script="$SCRIPT_DIR/send-notification.sh"
    if [[ -x "$notify_script" ]]; then
        # CRITICAL: redirect the notifier's stdout to stderr. escalate_service runs
        # inside remediate_component, whose STDOUT is captured as the returned state
        # JSON (state="$(remediate_component ...)"). Any stdout here corrupts that
        # JSON, so the next prune_state jq aborts under `set -e` BEFORE save_state —
        # silently losing escalated:true. Also tolerate a non-zero notify (e.g.
        # Gotify non-200) so the escalated state still persists if the page fails.
        #
        # Guard with timeout so a hung Gotify endpoint can't stall the self-heal tick.
        if command -v timeout >/dev/null 2>&1; then
            timeout "${ESCALATE_TIMEOUT}" "$notify_script" "$status" "$report_path" >&2 || log "WARNING: escalation notification failed (page may not have been delivered)"
        else
            # Fallback for macOS/launchd hosts without GNU coreutils timeout.
            "$notify_script" "$status" "$report_path" >&2 || log "WARNING: escalation notification failed (page may not have been delivered)"
        fi
    else
        log "WARNING: send-notification.sh not found at $notify_script; cannot escalate"
    fi
}

# escalate_service <svc> <retries> [reason]   (retries passed explicitly — no $STATE)
escalate_service() {
    local svc="$1" retries="${2:-0}" reason="${3:-max_retries}"
    log "ESCALATING: $svc ($reason, retries=$retries)"
    log_action "ESCALATE target=$svc retries=$retries reason=$reason"
    if [[ "$DRY_RUN" == true ]]; then
        log "[DRY-RUN] would send escalation notification for $svc"
        return 0
    fi

    local esc_report
    esc_report="$SELF_HEAL_STATE_DIR/escalation-$(date +%Y%m%d%H%M%S)-$svc.json"
    jq -n --arg svc "$svc" --arg now "$(timestamp)" --arg reason "$reason" --argjson retries "$retries" \
        '{escalated: true, service: $svc, timestamp: $now, retries: $retries, reason: $reason, action: "manual_intervention_required"}' \
        > "$esc_report"

    _send_notification "critical" "$esc_report"
    rm -f "$esc_report"
}

# ── Post-restart verification ───────────────────────────────────────────────

# verify_restart <comp> <svc> -> 0 healthy, 1 still-unhealthy
verify_restart() {
    local comp="$1" svc="$2"
    if [[ "$VERIFY_HEALTH" == true ]]; then
        local check="${COMPONENT_CHECK_MAP[$comp]:-}"
        if [[ -n "$check" && -x "$HEALTH_CHECK_DIR/$check" ]]; then
            local out status
            out="$("$HEALTH_CHECK_DIR/$check" 2>/dev/null || true)"
            status="$(echo "$out" | jq -r '.status // "unknown"' 2>/dev/null || echo unknown)"
            case "$status" in
                healthy)            log "VERIFY: $comp health check healthy after restart"; return 0 ;;
                degraded|critical)  log "VERIFY: $comp still $status after restart"; return 1 ;;
                *)                  log "VERIFY: $comp check inconclusive ($status); falling back to is-active" ;;
            esac
        fi
    fi
    check_service_active "$svc"
}

# ── Main remediation logic ──────────────────────────────────────────────────

remediate_component() {
    local comp="$1" state="$2" services="$3"
    local svc now
    now="$(date +%s)"

    for svc in $services; do
        local retries escalated old_obs obs flap_since flaps next_at delay

        retries="$(get_retry_count "$state" "$svc")"
        escalated="$(state_get_bool "$state" "$svc" escalated)"

        # Record this unhealthy observation (grace period bookkeeping).
        old_obs="$(state_get_num "$state" "$svc" consecutive_unhealthy 0)"
        obs=$((old_obs + 1))
        state="$(record_unhealthy "$state" "$svc" "$now")"

        if [[ "$escalated" == true ]]; then
            log "SKIP: $svc already escalated (manual intervention pending)"
            continue
        fi

        # Flapping guard: too many restarts within the window → escalate.
        flap_since=$(( now - FLAP_WINDOW_SECS ))
        flaps="$(flap_count "$state" "$svc" "$flap_since")"
        if [[ "$flaps" -ge "$FLAP_MAX_RESTARTS" ]]; then
            log "FLAPPING: $svc restarted $flaps times in ${FLAP_WINDOW_SECS}s; escalating instead"
            state="$(mark_escalated "$state" "$svc")"
            escalate_service "$svc" "$retries" "flapping"
            continue
        fi

        # Max retries reached → escalate.
        if [[ "$retries" -ge "$MAX_RETRIES" ]]; then
            state="$(mark_escalated "$state" "$svc")"
            escalate_service "$svc" "$retries" "max_retries"
            continue
        fi

        # Grace period: require N consecutive unhealthy checks first.
        if [[ "$obs" -lt "$GRACE_CHECKS" ]]; then
            log "GRACE: $svc unhealthy $obs/$GRACE_CHECKS observation(s); deferring restart"
            log_action "GRACE target=$svc obs=$obs/$GRACE_CHECKS"
            continue
        fi

        # Backoff gate: wait until next_attempt_at before retrying.
        next_at="$(state_get_num "$state" "$svc" next_attempt_at 0)"
        if [[ "$now" -lt "$next_at" ]]; then
            log "BACKOFF: $svc waiting (next attempt at epoch $next_at, $((next_at - now))s)"
            log_action "BACKOFF target=$svc until=$next_at"
            continue
        fi

        log "RESTART: $svc (component=$comp, retries=$retries, obs=$obs, flaps=$flaps)"
        log_action "RESTART_BEGIN target=$svc component=$comp retries=$retries"
        state="$(state_push_restart "$state" "$svc" "$now" "$flap_since")"

        if restart_service "$svc"; then
            sleep "$BACKOFF_SECONDS"
            if verify_restart "$comp" "$svc"; then
                log "SUCCESS: $svc healthy after restart"
                log_action "RESTART_OK target=$svc"
                state="$(clear_service_state "$state" "$svc")"
            else
                retries=$((retries + 1))
                delay="$(compute_backoff "$retries")"
                state="$(set_retry_count "$state" "$svc" "$retries")"
                state="$(state_set_num "$state" "$svc" next_attempt_at $(( now + delay )))"
                log "WARNING: $svc still unhealthy after restart (retries=$retries, next try in ~${delay}s)"
                log_action "RESTART_PARTIAL target=$svc retries=$retries backoff=${delay}s strategy=$BACKOFF_STRATEGY"
            fi
        else
            retries=$((retries + 1))
            delay="$(compute_backoff "$retries")"
            state="$(set_retry_count "$state" "$svc" "$retries")"
            state="$(state_set_num "$state" "$svc" next_attempt_at $(( now + delay )))"
            log "FAILURE: restart command failed for $svc (retries=$retries, next try in ~${delay}s)"
            log_action "RESTART_FAIL target=$svc retries=$retries backoff=${delay}s strategy=$BACKOFF_STRATEGY"
        fi
    done

    printf '%s' "$state"
}

# ── Report discovery ────────────────────────────────────────────────────────

find_latest_report() {
    local latest
    # ISO-8601 report names sort chronologically; sort|tail avoids the empty-dir
    # `xargs ls -t` foot-gun (with no matches, xargs would ls the CWD).
    latest="$(find "$REPORT_DIR" -maxdepth 1 -name '*.json' ! -name '*-summary*' -type f 2>/dev/null | sort | tail -1)"
    printf '%s' "$latest"
}

# ── Entry point ─────────────────────────────────────────────────────────────

# ── Sentinel for test harness extraction ──────────────────────────────────
# If you move this block, update any `src_fn` harness that sources everything
# before the marker. The sentinel must appear immediately before main() entry.

# HARNESS_ENTRY_POINT

main() {
    local report="$REPORT_FILE"
    local now_epoch; now_epoch="$(date +%s)"

    ensure_state_dir

    local lockfile="$SELF_HEAL_STATE_DIR/self-heal.lock"
    if command -v flock >/dev/null 2>&1; then
        exec 200>"$lockfile"
        if ! flock -n 200; then
            log "WARNING: another self-heal instance is running; exiting"
            exit 0
        fi
    fi

    [[ -z "$report" ]] && report="$(find_latest_report)"
    [[ -z "$report" || ! -f "$report" ]] && die "no health-check report found in $REPORT_DIR"

    # Staleness guard: don't remediate on stale data (e.g. scheduler stalled).
    if [[ "$MAX_REPORT_AGE" -gt 0 ]] 2>/dev/null; then
        local mtime; mtime="$(stat -c %Y "$report" 2>/dev/null || stat -f %m "$report" 2>/dev/null || echo "$now_epoch")"
        local report_age=$(( now_epoch - mtime ))
        if [[ "$report_age" -gt "$MAX_REPORT_AGE" ]]; then
            log "WARNING: latest report is ${report_age}s old (> MAX_REPORT_AGE=${MAX_REPORT_AGE}s); refusing to act on stale data"
            exit 0
        fi
    fi

    log "=== Self-Healing Watchdog v$VERSION ==="
    log "report: $report"
    log "service manager: $SERVICE_MANAGER"
    log "config: max-retries=$MAX_RETRIES settle=${BACKOFF_SECONDS}s backoff=$BACKOFF_STRATEGY base=${BACKOFF_BASE}s max=${BACKOFF_MAX}s grace=$GRACE_CHECKS flap=$FLAP_MAX_RESTARTS/${FLAP_WINDOW_SECS}s prune-ttl=${STATE_PRUNE_TTL}s verify=$VERIFY_HEALTH dry-run=$DRY_RUN"

    jq . "$report" >/dev/null 2>&1 || die "report is not valid JSON: $report"

    local state
    state="$(load_state)"

    # Build target set (unhealthy) and healthy set (for report-as-truth reset).
    local -a targets=()
    local -A seen=()
    local -A healthy=()
    local comp services svc

    # 1) Standard logical components (skipped in MT mode — see SELF_HEAL_REMEDY_LOGICAL).
    if [[ "$REMEDY_LOGICAL" == "true" ]]; then
    while IFS=$'\t' read -r comp cstatus; do
        [[ -n "$comp" ]] || continue
        [[ "${NO_REMEDY[$comp]:-}" == "1" ]] && { [[ "$cstatus" != healthy ]] && log "SKIP: component '$comp' has no standalone service (feature/external)"; continue; }
        services="${SERVICE_MAP[$comp]:-}"
        [[ -n "$services" ]] || { [[ "$cstatus" != healthy ]] && log "WARNING: no service mapping for component '$comp'; skipping"; continue; }
        for svc in $services; do
            if [[ "$cstatus" == healthy ]]; then
                healthy[$svc]=1
            else
                [[ -n "${seen[$svc]:-}" ]] && continue
                seen[$svc]=1
                targets+=("$comp:$svc")
            fi
        done
    done < <(jq -r '.components[] | "\(.component)\t\(.status)"' "$report" 2>/dev/null || true)
    else
        log "MT mode: logical-component remediation disabled (SELF_HEAL_REMEDY_LOGICAL=false); only init sub-units will be remediated"
    fi

    # 2) Init-system sub-units (systemd/openrc/launchd). Healthy ones populate
    #    `healthy`; unhealthy ones become targets.
    local init_comp init_status init_name svc_norm
    while IFS=$'\t' read -r init_comp init_status init_name; do
        [[ -n "$init_name" ]] || continue
        svc_norm="$init_name"
        [[ "$SERVICE_MANAGER" == "openrc" ]] && svc_norm="${svc_norm%.service}"
        [[ "$SERVICE_MANAGER" == "systemd" && "$svc_norm" != *.* ]] && svc_norm="${svc_norm}.service"
        if [[ "$init_status" == healthy ]]; then
            healthy[$svc_norm]=1
        else
            [[ -n "${seen[$svc_norm]:-}" ]] && continue
            seen[$svc_norm]=1
            targets+=("$init_comp:$svc_norm")
        fi
    # NOTE: each init-system alternative MUST be fully parenthesized — jq's `|`
    # binds looser than `,`, so an unparenthesized trailing string gets piped
    # into the next alternative's `.metrics` and aborts the filter.
    done < <(jq -r '
        ( .components[] | select(.component == "systemd") | (.metrics.units // [])[]    | "systemd\t\(.status)\t\(.name)" ),
        ( .components[] | select(.component == "openrc")  | (.metrics.services // [])[] | "openrc\t\(.status)\t\(.name)" ),
        ( .components[] | select(.component == "launchd") | (.metrics.agents // [])[]   | "launchd\t\(.status)\t\(.name)" )
    ' "$report" 2>/dev/null || true)

    # Report-as-truth recovery: a service the report now calls healthy is cleared
    # without round-tripping through check_service_active (flaky right after a
    # restart). Services that simply aren't in this report are left for the TTL prune.
    local k
    while IFS= read -r k; do
        [[ -n "$k" ]] || continue
        if [[ -n "${healthy[$k]:-}" ]]; then
            state="$(clear_service_state "$state" "$k")"
            log "RECOVERED: cleared state for $k (report says healthy)"
        fi
    done < <(echo "$state" | jq -r 'keys[]' 2>/dev/null || true)

    if [[ ${#targets[@]} -eq 0 ]]; then
        state="$(prune_state "$state" "$now_epoch")"
        save_state "$state"
        log "=== Self-Healing complete (nothing to do) ==="
        exit 0
    fi

    log "identified ${#targets[@]} target(s) for remediation"

    local target
    for target in "${targets[@]}"; do
        IFS=: read -r comp svc <<< "$target"
        state="$(remediate_component "$comp" "$state" "$svc")"
    done

    state="$(prune_state "$state" "$now_epoch" "${!seen[@]}")"
    save_state "$state"

    local summary
    summary="$(echo "$state" | jq -r 'to_entries | map({service: .key, retries: (.value.retries // 0), escalated: (.value.escalated // false)})')"
    log "=== Self-Healing complete ==="
    log "state: $summary"
}

main "$@"
exit 0
