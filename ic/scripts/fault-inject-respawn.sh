#!/usr/bin/env bash
# fault-inject-respawn.sh — Verify podman container respawn latency via supervise-daemon
#
# Kills a supervised container and measures how long until it is running again.
# The babysitter pattern (lunarwing-ctr-babysit + supervise-daemon) should bring
# the container back within respawn_delay (default 2s). This script asserts the
# total recovery time is under the configured threshold.
#
# Usage:
#   fault-inject-respawn.sh --tenant <name> [--container-type pg|nanocode|pebble]
#   fault-inject-respawn.sh --container <container-name> [--user <os-user>]
#   fault-inject-respawn.sh --dry-run --tenant <name>
#
# Options:
#   --tenant <name>         Target tenant (derives container name + user)
#   --container-type <type> Container type: pg, nanocode, pebble (default: pg)
#   --container <name>      Explicit container name (bypasses tenant lookup)
#   --user <os-user>        OS user owning the rootless container (required with --container)
#   --threshold <secs>      Max acceptable respawn time in seconds (default: 4)
#   --poll-interval <ms>    Polling interval in milliseconds (default: 100)
#   --dry-run               Print what would be done without executing
#   --yes                   Skip the safety confirmation prompt
#   --verbose               Print extra diagnostic output
#
# Requirements:
#   - OpenRC host with supervise-daemon
#   - The target -sup babysitter unit must be running
#   - podman accessible for the target user
#   - Root or sudo (to inspect service state; podman kill runs as the container user)
#
# Exit: 0 = PASS, 1 = FAIL, 2 = precondition error

set -euo pipefail

readonly VERSION="1.0.0"
readonly SCRIPT_NAME="$(basename "$0")"

# ── Defaults ────────────────────────────────────────────────────────────────

TENANT=""
CONTAINER=""
CONTAINER_TYPE="pg"
USER=""
THRESHOLD="4"
POLL_INTERVAL_MS="100"
DRY_RUN=false
YES=false
VERBOSE=false

# ── Helpers ─────────────────────────────────────────────────────────────────

die()  { printf '\e[31mERROR:\e[0m %s\n' "$*" >&2; exit 2; }
warn() { printf '\e[33mWARN:\e[0m %s\n' "$*" >&2; }
info() { printf '\e[36mINFO:\e[0m %s\n' "$*"; }
verb() { [[ "$VERBOSE" == true ]] && printf '\e[90m  %s\e[0m\n' "$*"; }
pass() { printf '\n\e[32m✓ PASS:\e[0m %s\n' "$*"; exit 0; }
fail() { printf '\n\e[31m✗ FAIL:\e[0m %s\n' "$*"; exit 1; }

timestamp_ms() {
    if command -v gdate >/dev/null 2>&1; then
        gdate +%s%3N
    elif date --version >/dev/null 2>&1; then
        date +%s%3N
    else
        # macOS fallback: python3 for ms precision
        python3 -c 'import time; print(int(time.time()*1000))'
    fi
}

run_as_user() {
    local user="$1"; shift
    local uid
    uid="$(id -u "$user" 2>/dev/null)" || die "cannot resolve uid for user '$user'"
    sudo -n -u "$user" env "XDG_RUNTIME_DIR=/run/user/$uid" "HOME=$(eval echo "~$user")" "$@"
}

# ── Arg parsing ─────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tenant)         TENANT="$2"; shift 2 ;;
        --container-type) CONTAINER_TYPE="$2"; shift 2 ;;
        --container)      CONTAINER="$2"; shift 2 ;;
        --user)           USER="$2"; shift 2 ;;
        --threshold)      THRESHOLD="$2"; shift 2 ;;
        --poll-interval)  POLL_INTERVAL_MS="$2"; shift 2 ;;
        --dry-run|-n)     DRY_RUN=true; shift ;;
        --yes|-y)         YES=true; shift ;;
        --verbose|-v)     VERBOSE=true; shift ;;
        --help|-h)
            printf 'Usage: %s --tenant <name> [--container-type pg|nanocode|pebble] [options]\n' "$SCRIPT_NAME"
            printf '       %s --container <name> --user <os-user> [options]\n\n' "$SCRIPT_NAME"
            printf 'Fault-injection test: kills a supervised container and measures respawn latency.\n\n'
            printf 'Options:\n'
            printf '  --tenant <name>         Target tenant name\n'
            printf '  --container-type <type> Container type (pg, nanocode, pebble; default: pg)\n'
            printf '  --container <name>      Explicit container name\n'
            printf '  --user <os-user>        OS user for rootless podman\n'
            printf '  --threshold <secs>      Max acceptable respawn time (default: 4)\n'
            printf '  --poll-interval <ms>    Poll interval in ms (default: 100)\n'
            printf '  --dry-run               Show actions without executing\n'
            printf '  --yes                   Skip safety prompt\n'
            printf '  --verbose               Extra diagnostics\n'
            exit 0
            ;;
        *) die "unknown argument: $1 (use --help)" ;;
    esac
done

# ── Resolve target ──────────────────────────────────────────────────────────

if [[ -n "$TENANT" ]]; then
    case "$CONTAINER_TYPE" in
        pg)       CONTAINER="lunarwing-pg-${TENANT}" ;;
        nanocode) CONTAINER="lunarwing-nanocode-${TENANT}" ;;
        pebble)   CONTAINER="lunarwing-pebble-${TENANT}" ;;
        *) die "unknown container-type: $CONTAINER_TYPE (expected pg, nanocode, pebble)" ;;
    esac
    USER="${USER:-$TENANT}"
fi

[[ -n "$CONTAINER" ]] || die "must specify --tenant or --container"
[[ -n "$USER" ]]      || die "must specify --user (or use --tenant to derive it)"

SUP_UNIT="${CONTAINER}-sup"

info "Target container: $CONTAINER"
info "Target user:      $USER"
info "Babysitter unit:  $SUP_UNIT"
info "Threshold:        ${THRESHOLD}s"

# ── Safety prompt ───────────────────────────────────────────────────────────

if [[ "$DRY_RUN" == false && "$YES" == false ]]; then
    printf '\n\e[33mThis will kill container "%s" on this host.\e[0m\n' "$CONTAINER"
    printf 'The babysitter should respawn it within %ss.\n' "$THRESHOLD"
    printf 'Continue? [y/N] '
    read -r ans
    case "$ans" in
        [Yy]*) ;;
        *) info "Aborted."; exit 0 ;;
    esac
fi

# ── Dry-run output ──────────────────────────────────────────────────────────

if [[ "$DRY_RUN" == true ]]; then
    info "[DRY-RUN] Would execute the following:"
    printf '  1. Verify rc-service %s status == started\n' "$SUP_UNIT"
    printf '  2. Verify podman container "%s" is running (as user %s)\n' "$CONTAINER" "$USER"
    printf '  3. podman kill %s (as user %s)\n' "$CONTAINER" "$USER"
    printf '  4. Poll podman inspect every %sms until running again\n' "$POLL_INTERVAL_MS"
    printf '  5. Assert elapsed < %ss\n' "$THRESHOLD"
    exit 0
fi

# ── Precondition checks ────────────────────────────────────────────────────

command -v podman >/dev/null 2>&1 || die "podman not found"
id "$USER" >/dev/null 2>&1       || die "user '$USER' does not exist"

# Verify babysitter service is running
if command -v rc-service >/dev/null 2>&1; then
    if ! rc-service "$SUP_UNIT" status >/dev/null 2>&1; then
        die "babysitter unit '$SUP_UNIT' is not running (rc-service status failed)"
    fi
    verb "babysitter unit $SUP_UNIT is running"
else
    warn "rc-service not found; skipping babysitter unit check (non-OpenRC host?)"
fi

# Verify container is currently running
if ! run_as_user "$USER" podman inspect --format '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q "true"; then
    die "container '$CONTAINER' is not currently running (as user $USER)"
fi
verb "container $CONTAINER is running (precondition OK)"

# ── Execute fault injection ─────────────────────────────────────────────────

info "Killing container '$CONTAINER'..."
t_start="$(timestamp_ms)"

run_as_user "$USER" podman kill "$CONTAINER" >/dev/null 2>&1 \
    || die "podman kill failed"

verb "kill issued at t=$t_start ms"

# ── Poll for recovery ───────────────────────────────────────────────────────

threshold_ms=$(( ${THRESHOLD%.*} * 1000 ))
poll_s="$(awk "BEGIN{printf \"%.3f\", $POLL_INTERVAL_MS/1000}")"
deadline_ms=$(( t_start + threshold_ms + 1000 ))  # 1s extra buffer for poll loop

info "Polling for container restart (interval=${POLL_INTERVAL_MS}ms, deadline=${THRESHOLD}s)..."

recovered=false
while true; do
    t_now="$(timestamp_ms)"
    if (( t_now > deadline_ms )); then
        break
    fi

    if run_as_user "$USER" podman inspect --format '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q "true"; then
        recovered=true
        break
    fi

    sleep "$poll_s"
done

t_end="$(timestamp_ms)"
elapsed_ms=$(( t_end - t_start ))
elapsed_s="$(awk "BEGIN{printf \"%.2f\", $elapsed_ms/1000}")"

# ── Result ──────────────────────────────────────────────────────────────────

info "Elapsed: ${elapsed_s}s"

if [[ "$recovered" == true ]]; then
    if (( elapsed_ms <= threshold_ms )); then
        pass "Container '$CONTAINER' respawned in ${elapsed_s}s (threshold: ${THRESHOLD}s)"
    else
        fail "Container '$CONTAINER' respawned in ${elapsed_s}s — exceeds threshold of ${THRESHOLD}s"
    fi
else
    # Final diagnostic: check if container exists at all
    verb "Final container state:"
    run_as_user "$USER" podman inspect --format '{{.State.Status}}' "$CONTAINER" 2>&1 | while read -r line; do verb "  $line"; done || true
    verb "Babysitter unit status:"
    rc-service "$SUP_UNIT" status 2>&1 | while read -r line; do verb "  $line"; done || true

    fail "Container '$CONTAINER' did NOT respawn within ${THRESHOLD}s (babysitter may have failed)"
fi
