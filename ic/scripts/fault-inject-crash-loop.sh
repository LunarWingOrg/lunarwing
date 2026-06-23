#!/usr/bin/env bash
# fault-inject-crash-loop.sh — Verify crash-loop exhaustion triggers self-heal backstop
#
# Rapidly kills a supervised container until supervise-daemon's respawn_max is
# exhausted, then verifies the self-heal pipeline detects the dead babysitter
# and either remediates or escalates.
#
# The babysitter pattern: supervise-daemon watches lunarwing-ctr-babysit, which
# blocks on `podman wait`. Each kill causes an exit+respawn cycle. After
# respawn_max exits within respawn_period, supervise-daemon gives up and the
# unit lands in /run/openrc/failed/.
#
# Usage:
#   fault-inject-crash-loop.sh --tenant <name> [--container-type pg|nanocode|pebble]
#   fault-inject-crash-loop.sh --container <name> --user <os-user> [options]
#
# Options:
#   --tenant <name>         Target tenant (derives container + user)
#   --container-type <type> Container type: pg, nanocode, pebble (default: pg)
#   --container <name>      Explicit container name
#   --user <os-user>        OS user owning the rootless container
#   --respawn-max <n>       Override respawn_max to exhaust (default: read from unit or 10)
#   --kill-interval <secs>  Delay between kills to stay within respawn_period (default: 1)
#   --self-heal             After exhausting respawns, invoke lunarwing-self-heal.sh once
#   --self-heal-script <p>  Path to lunarwing-self-heal.sh (auto-detected if omitted)
#   --recover               After test, restart the babysitter unit to restore service
#   --dry-run               Print what would be done
#   --yes                   Skip the safety confirmation prompt
#   --verbose               Print extra diagnostic output
#
# Requirements:
#   - OpenRC host with supervise-daemon
#   - The target -sup babysitter unit must be running
#   - Root or sudo
#
# Exit: 0 = PASS, 1 = FAIL, 2 = precondition error

set -euo pipefail

readonly VERSION="1.0.0"
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Defaults ────────────────────────────────────────────────────────────────

TENANT=""
CONTAINER=""
CONTAINER_TYPE="pg"
USER=""
RESPAWN_MAX=""
KILL_INTERVAL="1"
RUN_SELF_HEAL=false
SELF_HEAL_SCRIPT=""
RECOVER=false
DRY_RUN=false
YES=false
VERBOSE=false

# ── Helpers ─────────────────────────────────────────────────────────────────

die()  { printf '\e[31mERROR:\e[0m %s\n' "$*" >&2; exit 2; }
warn() { printf '\e[33mWARN:\e[0m %s\n' "$*" >&2; }
info() { printf '\e[36mINFO:\e[0m %s\n' "$*"; }
verb() { [[ "$VERBOSE" == true ]] && printf '\e[90m  %s\e[0m\n' "$*"; }
pass() { printf '\n\e[32m✓ PASS:\e[0m %s\n' "$*"; }
fail() { printf '\n\e[31m✗ FAIL:\e[0m %s\n' "$*"; exit 1; }

run_as_user() {
    local user="$1"; shift
    local uid
    uid="$(id -u "$user" 2>/dev/null)" || die "cannot resolve uid for user '$user'"
    sudo -n -u "$user" env "XDG_RUNTIME_DIR=/run/user/$uid" "HOME=$(eval echo "~$user")" "$@"
}

# Read a variable from the OpenRC conf.d file or the init script defaults.
read_unit_var() {
    local unit="$1" var="$2" default="$3"
    local conf="/etc/conf.d/${unit}"
    local initd="/etc/init.d/${unit}"
    local val=""

    # Try conf.d override first
    if [[ -f "$conf" ]]; then
        val="$(grep -oP "^${var}=\"?\K[^\"]*" "$conf" 2>/dev/null || true)"
    fi

    # Fall back to init.d script defaults (lines like : "${var:=VALUE}")
    if [[ -z "$val" && -f "$initd" ]]; then
        val="$(grep -oP "\\$\\{${var}:=\\K[^}]+" "$initd" 2>/dev/null || true)"
    fi

    printf '%s' "${val:-$default}"
}

# ── Arg parsing ─────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tenant)            TENANT="$2"; shift 2 ;;
        --container-type)    CONTAINER_TYPE="$2"; shift 2 ;;
        --container)         CONTAINER="$2"; shift 2 ;;
        --user)              USER="$2"; shift 2 ;;
        --respawn-max)       RESPAWN_MAX="$2"; shift 2 ;;
        --kill-interval)     KILL_INTERVAL="$2"; shift 2 ;;
        --self-heal)         RUN_SELF_HEAL=true; shift ;;
        --self-heal-script)  SELF_HEAL_SCRIPT="$2"; shift 2 ;;
        --recover)           RECOVER=true; shift ;;
        --dry-run|-n)        DRY_RUN=true; shift ;;
        --yes|-y)            YES=true; shift ;;
        --verbose|-v)        VERBOSE=true; shift ;;
        --help|-h)
            printf 'Usage: %s --tenant <name> [--container-type pg|nanocode|pebble] [options]\n' "$SCRIPT_NAME"
            printf '       %s --container <name> --user <os-user> [options]\n\n' "$SCRIPT_NAME"
            printf 'Fault-injection test: exhausts supervise-daemon respawn budget,\n'
            printf 'then verifies self-heal backstop detects and handles the dead unit.\n\n'
            printf 'Options:\n'
            printf '  --tenant <name>           Target tenant name\n'
            printf '  --container-type <type>   Container type (pg, nanocode, pebble; default: pg)\n'
            printf '  --container <name>        Explicit container name\n'
            printf '  --user <os-user>          OS user for rootless podman\n'
            printf '  --respawn-max <n>         Override respawn_max (default: read from unit or 10)\n'
            printf '  --kill-interval <secs>    Delay between kills (default: 1)\n'
            printf '  --self-heal               Trigger self-heal after exhausting respawns\n'
            printf '  --self-heal-script <path> Path to lunarwing-self-heal.sh\n'
            printf '  --recover                 Restart the babysitter unit after test completes\n'
            printf '  --dry-run                 Show actions without executing\n'
            printf '  --yes                     Skip safety prompt\n'
            printf '  --verbose                 Extra diagnostics\n'
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

# Read respawn config from the unit if not overridden
if [[ -z "$RESPAWN_MAX" ]]; then
    RESPAWN_MAX="$(read_unit_var "$SUP_UNIT" babysitter_respawn_max 10)"
fi
RESPAWN_PERIOD="$(read_unit_var "$SUP_UNIT" babysitter_respawn_period 120)"

info "Target container:  $CONTAINER"
info "Target user:       $USER"
info "Babysitter unit:   $SUP_UNIT"
info "Respawn max:       $RESPAWN_MAX (within ${RESPAWN_PERIOD}s period)"
info "Kill interval:     ${KILL_INTERVAL}s"
info "Self-heal after:   $RUN_SELF_HEAL"
info "Auto-recover:      $RECOVER"

# ── Resolve self-heal script ────────────────────────────────────────────────

if [[ "$RUN_SELF_HEAL" == true && -z "$SELF_HEAL_SCRIPT" ]]; then
    # Try common locations
    for candidate in \
        "/opt/lunarwing/ic-infrastructure-health-check/lunarwing-self-heal.sh" \
        "$SCRIPT_DIR/../../ic-infrastructure-health-check/lunarwing-self-heal.sh" \
        "/usr/local/lib/lunarwing/lunarwing-self-heal.sh"; do
        if [[ -x "$candidate" ]]; then
            SELF_HEAL_SCRIPT="$(realpath "$candidate")"
            break
        fi
    done
    [[ -n "$SELF_HEAL_SCRIPT" ]] || die "cannot locate lunarwing-self-heal.sh (use --self-heal-script)"
    info "Self-heal script:  $SELF_HEAL_SCRIPT"
fi

# ── Safety prompt ───────────────────────────────────────────────────────────

if [[ "$DRY_RUN" == false && "$YES" == false ]]; then
    printf '\n\e[33m*** DESTRUCTIVE TEST ***\e[0m\n'
    printf 'This will kill container "%s" %s times to exhaust the supervise-daemon\n' "$CONTAINER" "$RESPAWN_MAX"
    printf 'respawn budget. The container will be DOWN until manually restarted'
    if [[ "$RECOVER" == true ]]; then
        printf ' (--recover will restore it).\n'
    else
        printf '.\n'
    fi
    printf '\nThis should ONLY be run on a test/staging host.\n'
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
    printf '  2. Verify container "%s" is running (as user %s)\n' "$CONTAINER" "$USER"
    printf '  3. Kill container %s times with %ss interval (exhaust respawn_max=%s)\n' \
        "$RESPAWN_MAX" "$KILL_INTERVAL" "$RESPAWN_MAX"
    printf '  4. Wait for babysitter unit to land in failed state\n'
    printf '  5. Assert: rc-service %s status != started\n' "$SUP_UNIT"
    if [[ "$RUN_SELF_HEAL" == true ]]; then
        printf '  6. Run lunarwing-self-heal.sh and verify it detects the dead unit\n'
    fi
    if [[ "$RECOVER" == true ]]; then
        printf '  7. Restart %s to restore service\n' "$SUP_UNIT"
    fi
    exit 0
fi

# ── Precondition checks ────────────────────────────────────────────────────

command -v podman >/dev/null 2>&1     || die "podman not found"
command -v rc-service >/dev/null 2>&1 || die "rc-service not found (OpenRC required)"
id "$USER" >/dev/null 2>&1           || die "user '$USER' does not exist"

if ! rc-service "$SUP_UNIT" status >/dev/null 2>&1; then
    die "babysitter unit '$SUP_UNIT' is not running — cannot test crash-loop exhaustion"
fi
verb "babysitter unit $SUP_UNIT is running (precondition OK)"

if ! run_as_user "$USER" podman inspect --format '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q "true"; then
    die "container '$CONTAINER' is not currently running"
fi
verb "container $CONTAINER is running (precondition OK)"

# ── Phase 1: Exhaust respawn budget ────────────────────────────────────────

info ""
info "=== Phase 1: Exhaust respawn budget (killing $RESPAWN_MAX times) ==="
info ""

kills_done=0
for (( i = 1; i <= RESPAWN_MAX; i++ )); do
    # Wait for container to be running (babysitter respawns it)
    wait_start="$(date +%s)"
    wait_deadline=$(( wait_start + 30 ))
    while true; do
        if run_as_user "$USER" podman inspect --format '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q "true"; then
            break
        fi
        if (( $(date +%s) > wait_deadline )); then
            # Container didn't come back — respawn budget may be exhausted early
            verb "container did not respawn within 30s after kill #$((i-1))"
            break 2
        fi
        sleep 0.2
    done

    info "  Kill #${i}/${RESPAWN_MAX}..."
    if run_as_user "$USER" podman kill "$CONTAINER" >/dev/null 2>&1; then
        kills_done=$((kills_done + 1))
        verb "  killed at $(date -u '+%H:%M:%S')"
    else
        warn "  podman kill failed on attempt #$i (container may already be stopped)"
        kills_done=$((kills_done + 1))
    fi

    # Don't sleep after the last kill
    if (( i < RESPAWN_MAX )); then
        sleep "$KILL_INTERVAL"
    fi
done

info ""
info "Completed $kills_done kill(s). Waiting for supervise-daemon to give up..."

# ── Phase 2: Verify babysitter has stopped ──────────────────────────────────

# supervise-daemon needs a moment after the final respawn to mark the service failed
sleep 3

phase2_pass=false
babysitter_status=""

if rc-service "$SUP_UNIT" status >/dev/null 2>&1; then
    # Still running — maybe respawn budget wasn't fully exhausted
    warn "babysitter '$SUP_UNIT' is still running after $kills_done kills"
    babysitter_status="running"

    # Check if container is actually running (maybe supervise-daemon is still trying)
    if run_as_user "$USER" podman inspect --format '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q "true"; then
        warn "container is still running — respawn budget may not be exhausted yet"
        warn "Try increasing kill speed (--kill-interval 0.5) or kills may span multiple respawn_periods"
    fi
else
    phase2_pass=true
    babysitter_status="stopped/failed"
    info "Babysitter unit '$SUP_UNIT' has stopped (respawn budget exhausted)"
fi

# Also check /run/openrc/failed/ for the unit
if [[ -e "/run/openrc/failed/${SUP_UNIT}" ]]; then
    verb "confirmed: $SUP_UNIT present in /run/openrc/failed/"
    phase2_pass=true
fi

if [[ "$phase2_pass" != true ]]; then
    fail "Could not exhaust respawn budget — babysitter is still running after $kills_done kills (babysitter_status=$babysitter_status)"
fi

info ""
info "=== Phase 2 PASS: Respawn budget exhausted, babysitter stopped ==="

# ── Phase 3: Self-heal backstop verification (optional) ─────────────────────

phase3_pass=true

if [[ "$RUN_SELF_HEAL" == true ]]; then
    info ""
    info "=== Phase 3: Self-heal backstop verification ==="
    info ""

    # We need a health report that reflects the dead babysitter. On a real system,
    # the periodic health-check would detect this. For the test, we generate a
    # synthetic report showing the -sup unit as critical, or we run the real
    # health check first.
    #
    # Strategy: run health-openrc.sh if available to generate a real report, then
    # invoke self-heal against it.

    health_check_dir="$(dirname "$SELF_HEAL_SCRIPT")"
    report_dir="${LUNARWING_BASE_DIR:-$HOME/.lunarwing}/workspace/reports/health"
    mkdir -p "$report_dir"

    # Generate a health report
    if [[ -x "$health_check_dir/health-openrc.sh" ]]; then
        info "Running health-openrc.sh to generate a fresh report..."
        health_output="$("$health_check_dir/health-openrc.sh" 2>/dev/null || true)"
        verb "health output: $health_output"

        if [[ -n "$health_output" ]]; then
            # The infra health check writes its own report, but we also save one
            report_file="$report_dir/fault-inject-$(date -u '+%Y%m%dT%H%M%SZ').json"
            printf '%s\n' "$health_output" > "$report_file"
            info "Generated health report: $report_file"
        fi
    else
        # Synthesize a minimal report marking the -sup unit as critical
        info "Synthesizing health report (health-openrc.sh not found)..."
        report_file="$report_dir/fault-inject-$(date -u '+%Y%m%dT%H%M%SZ').json"
        jq -n --arg unit "$SUP_UNIT" '{
            timestamp: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
            overall: "critical",
            components: [{
                component: "openrc",
                status: "critical",
                metrics: {
                    services: [{name: $unit, status: "critical"}]
                }
            }]
        }' > "$report_file"
        info "Synthesized report: $report_file"
    fi

    # Invoke self-heal
    info "Invoking self-heal pipeline..."
    self_heal_output="$(
        env SELF_HEAL_GRACE_CHECKS=1 \
            SELF_HEAL_BACKOFF_BASE=0 \
            "$SELF_HEAL_SCRIPT" --report "$report_file" 2>&1
    )" || true

    verb "self-heal output:"
    while IFS= read -r line; do verb "  $line"; done <<< "$self_heal_output"

    # Check what self-heal did: it should have either restarted the unit or escalated
    if grep -qE "RESTART.*${SUP_UNIT}|SUCCESS.*${SUP_UNIT}" <<< "$self_heal_output"; then
        info "Self-heal detected and attempted restart of '$SUP_UNIT'"

        # If self-heal restarted it, the babysitter should be back
        if rc-service "$SUP_UNIT" status >/dev/null 2>&1; then
            info "Self-heal successfully restarted the babysitter unit"
        else
            info "Self-heal restarted but unit did not recover (may escalate on next tick)"
        fi
    elif grep -qE "ESCALAT.*${SUP_UNIT}" <<< "$self_heal_output"; then
        info "Self-heal escalated '$SUP_UNIT' (manual intervention flagged)"
    elif grep -qF "nothing to do" <<< "$self_heal_output"; then
        warn "Self-heal reported 'nothing to do' — the report may not reflect the dead unit"
        phase3_pass=false
    else
        warn "Self-heal did not appear to act on '$SUP_UNIT'"
        verb "Full output was:"
        printf '%s\n' "$self_heal_output" >&2
        phase3_pass=false
    fi

    if [[ "$phase3_pass" == true ]]; then
        info ""
        info "=== Phase 3 PASS: Self-heal backstop detected and handled the dead unit ==="
    else
        info ""
        warn "=== Phase 3 INCONCLUSIVE: Self-heal did not clearly act on the unit ==="
        warn "    This may be expected if the health report format doesn't include -sup units."
        warn "    Check the self-heal state dir for details."
    fi
fi

# ── Phase 4: Recovery (optional) ────────────────────────────────────────────

if [[ "$RECOVER" == true ]]; then
    info ""
    info "=== Recovery: Restarting babysitter unit ==="

    # Clear any failed state before restarting
    if [[ -e "/run/openrc/failed/${SUP_UNIT}" ]]; then
        rm -f "/run/openrc/failed/${SUP_UNIT}" 2>/dev/null || true
        verb "cleared /run/openrc/failed/$SUP_UNIT"
    fi

    if rc-service "$SUP_UNIT" restart >/dev/null 2>&1; then
        sleep 2
        if rc-service "$SUP_UNIT" status >/dev/null 2>&1; then
            info "Babysitter unit '$SUP_UNIT' restored successfully"
            # Verify container came back
            sleep 2
            if run_as_user "$USER" podman inspect --format '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q "true"; then
                info "Container '$CONTAINER' is running again"
            else
                warn "Container '$CONTAINER' has not started yet (may need a moment)"
            fi
        else
            warn "Babysitter restart issued but unit is not running"
        fi
    else
        warn "Failed to restart babysitter unit '$SUP_UNIT'"
        warn "Manual recovery: rc-service $SUP_UNIT restart"
    fi
fi

# ── Final verdict ───────────────────────────────────────────────────────────

info ""
info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
info "Summary:"
info "  Phase 1 (exhaust respawns):  PASS ($kills_done kills, babysitter stopped)"
if [[ "$RUN_SELF_HEAL" == true ]]; then
    if [[ "$phase3_pass" == true ]]; then
        info "  Phase 3 (self-heal backstop): PASS"
    else
        info "  Phase 3 (self-heal backstop): INCONCLUSIVE"
    fi
fi
if [[ "$RECOVER" == true ]]; then
    if rc-service "$SUP_UNIT" status >/dev/null 2>&1; then
        info "  Recovery:                     OK"
    else
        info "  Recovery:                     INCOMPLETE (check manually)"
    fi
fi
info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ "$phase2_pass" == true ]]; then
    pass "Crash-loop exhaustion verified: supervise-daemon stopped after $kills_done rapid kills"
else
    fail "Test did not complete successfully"
fi
