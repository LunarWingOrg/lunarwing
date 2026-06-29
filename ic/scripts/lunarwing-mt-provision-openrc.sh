#!/usr/bin/env bash
set -euo pipefail

# ── LunarWing Multi-Tenant Provisioning Orchestrator (OpenRC / Gentoo) ───────
#
# NOTE: This script is COMPLETELY UNTESTED. It was generated from the systemd
# variant and adapted for OpenRC. It has not been executed end-to-end on any
# OpenRC host. Verify each phase output before proceeding to the next.
#
# Same lifecycle as lunarwing-mt-provision-systemd.sh but tailored for OpenRC hosts
# (Gentoo, etc.). Key differences from the systemd variant:
#
#   - SERVICE_MANAGER=openrc (system-level units in /etc/init.d/, not user-level)
#   - No loginctl/linger — OpenRC uses system-level supervise-daemon with User=
#   - Watchdog installed via OpenRC path (hourly cron or fcron, not systemd timer)
#   - Worker containers get dedicated babysitter units (-sup) for crash recovery
#     since rootless podman has no daemon to honor --restart
#   - Logs go to /home/<tenant>/lunarwing/logs/ (not journalctl --user)
#   - elogind provides /run/user/<uid> instead of systemd-logind
#
# Prerequisites specific to OpenRC/Gentoo:
#   - sys-apps/openrc, app-admin/sudo, sys-process/fcron OR cronie/dcron
#   - newuidmap/newgidmap setuid (sys-apps/shadow with subid)
#   - net-vpn/pasta OR net-libs/slirp4netns (rootless port forwarding)
#   - modules: subuid/subgid populated, elogind running
#   - sudo (not passwordless — this script runs interactively)
#   - If using fcron: sys-process/fcron emerged and running
#
# Usage:
#   1. Edit the CONFIG section below
#   2. ./ic/scripts/lunarwing-mt-provision-openrc.sh           # all phases
#   3. ./ic/scripts/lunarwing-mt-provision-openrc.sh --phase 3  # run specific phase
#   4. ./ic/scripts/lunarwing-mt-provision-openrc.sh --phase 2-4 # range
#
# Phases:
#   1  Provision env + add tenants + start PG
#   2  Build binaries, workers, darkirc, vision, WASM
#   3  Post-build configuration (pebble, watchdog, health.env)
#   4  Start tenants
#   5  Verify

# ═══════════════════════════════════════════════════════════════════════════════
# CONFIG — edit these values before running
# ═══════════════════════════════════════════════════════════════════════════════

# Tenant names (comma-separated, will be lowercased)
TENANTS="ersa,pandia"

# Infrastructure (OpenRC defaults — do not change unless you know why)
SERVICE_MANAGER="openrc"            # MUST be openrc for this script
CONTAINER_RUNTIME="podman"          # podman | docker
ROOTLESS="true"                     # true for podman, false for docker

# Features
ENABLE_DARKIRC=true                 # DarkIRC daemon + adapter
ENABLE_SSH=true                     # SSH harness (key pair, agent, config.toml)
ENABLE_HEALTH=true                  # Host-global health/self-heal pipeline
BUILD_WASM=true                     # Build + install WASM tools and channels
BUILD_NANOCODE=true                 # Build nanocode worker Docker image
BUILD_PEBBLE=true                   # Build pebble worker Docker image
BUILD_DARKIRC=true                  # Build darkirc daemon binary
BUILD_VISION=true                   # Build vision/OCR sidecar Docker image
INSTALL_WATCHDOG=false             # Single-tenant watchdog; MT health pipeline already covers tenants

# OpenRC watchdog scheduler selection
#   auto     — prefer existing cronie/crond/dcron hourly; fall back to fcron
#   fcron    — force managed fcron entry
#   hourly   — force cron-hourly path
WATCHDOG_SCHEDULER="auto"

# LLM
TENSORZERO_URL="http://192.168.1.157:3000/openai/v1"

# Gotify (notifications)
GOTIFY_URL="https://gotify.darkc.sobe.world"
GOTIFY_TOKEN=""                     # REQUIRED if ENABLE_HEALTH=true — health pipeline escalation token

# Pebble worker (NanoGPT)
NANOGPT_API_KEY=""                  # REQUIRED if BUILD_PEBBLE=true — sk-nano-...

# XMPP
XMPP_DOMAIN="xmpp.sobe.world"       # JIDs become <tenant>@<domain>

# Build profile
BUILD_PROFILE="${LUNARWING_MT_PROFILE:-release}"  # release | debug

# ═══════════════════════════════════════════════════════════════════════════════
# END CONFIG — don't edit below unless you know what you're doing
# ═══════════════════════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
LUNARWING_ROOT="$(cd -- "${REPO_ROOT}/.." && pwd)"
MT_ADMIN="${SCRIPT_DIR}/lunarwing-mt-admin.sh"
ENV_FILE="${HOME}/.lunarwing-mt.env"
HEALTH_ENV="/etc/lunarwing/health.env"
LOG_DIR="/tmp"

# Colors
say()  { printf '\033[1;34m[provision]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  [OK]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  [WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m  [FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

# ── Phase selection ──────────────────────────────────────────────────────────

PHASE_START=1
PHASE_END=5

if [[ "${1:-}" == "--phase" ]]; then
  spec="$2"
  if [[ "$spec" == *-* ]]; then
    PHASE_START="${spec%-*}"
    PHASE_END="${spec#*-}"
  else
    PHASE_START="$spec"
    PHASE_END="$spec"
  fi
fi

in_phase_range() {
  local p="$1"
  (( p >= PHASE_START && p <= PHASE_END ))
}

# ── Validation ───────────────────────────────────────────────────────────────

validate_config() {
  [[ -n "$TENANTS" ]] || die "TENANTS must be set"
  [[ -n "$GOTIFY_URL" ]] || die "GOTIFY_URL must be set"
  [[ -f "$MT_ADMIN" ]] || die "mt-admin script not found at $MT_ADMIN"

  # Force OpenRC for this variant
  [[ "$SERVICE_MANAGER" == "openrc" ]] \
    || die "this script is for OpenRC only — use lunarwing-mt-provision.sh for systemd"

  if [[ "$ENABLE_HEALTH" == true && -z "$GOTIFY_TOKEN" ]]; then
    die "GOTIFY_TOKEN is required when ENABLE_HEALTH=true"
  fi
  if [[ "$BUILD_PEBBLE" == true && -z "$NANOGPT_API_KEY" ]]; then
    die "NANOGPT_API_KEY is required when BUILD_PEBBLE=true"
  fi

  # OpenRC-specific prerequisite checks
  command -v rc-service >/dev/null 2>&1 \
    || die "rc-service not found — this script requires OpenRC"

  if [[ "$ROOTLESS" == "true" ]]; then
    command -v newuidmap >/dev/null 2>&1 \
      || die "newuidmap not found (needed for rootless podman). Install sys-apps/shadow with subid support"
    command -v newgidmap >/dev/null 2>&1 \
      || die "newgidmap not found (needed for rootless podman)"
    [[ -s /etc/subuid ]] \
      || die "/etc/subuid is empty — rootless podman needs subordinate uid ranges"
    [[ -s /etc/subgid ]] \
      || die "/etc/subgid is empty — rootless podman needs subordinate gid ranges"
    command -v pasta >/dev/null 2>&1 || command -v slirp4netns >/dev/null 2>&1 \
      || die "neither pasta nor slirp4netns found — rootless podman needs a port-forwarder"
  fi

  local cr="${CONTAINER_RUNTIME,,}"
  case "$cr" in
    podman|docker) ;;
    *) die "CONTAINER_RUNTIME must be 'podman' or 'docker'" ;;
  esac
}

# ── Env file + sudo wrapper ──────────────────────────────────────────────────

write_env_file() {
  cat > "$ENV_FILE" <<EOF
export LUNARWING_SERVICE_MANAGER=${SERVICE_MANAGER}
export LUNARWING_CONTAINER_RUNTIME=${CONTAINER_RUNTIME}
export LUNARWING_MT_ROOTLESS=${ROOTLESS}
export LUNARWING_MT_PROFILE=${BUILD_PROFILE}
export LUNARWING_MT_GOTIFY_URL=${GOTIFY_URL}
export LUNARWING_MT_GOTIFY_TOKEN=${GOTIFY_TOKEN}
export LUNARWING_MT_TENSORZERO_URL=${TENSORZERO_URL}
EOF
  chmod 600 "$ENV_FILE"
  ok "wrote $ENV_FILE"
}

# Run mt-admin with all env vars preserved.
mt() {
  source "$ENV_FILE"
  sudo -E "$MT_ADMIN" "$@"
}

# Run a long mt-admin command inside tmux with a named log.
# Usage: mt_tmux <session-name> <args...>
mt_tmux() {
  local session="$1"; shift
  local log="${LOG_DIR}/${session}.log"
  source "$ENV_FILE"
  tmux kill-session -t "$session" 2>/dev/null || true
  tmux new-session -d -s "$session" \
    "sudo -E $MT_ADMIN $* 2>&1 | tee $log"
  say "started tmux session '$session' (log: $log)"
}

# Block until a tmux session ends (poll every 5s).
wait_tmux() {
  local session="$1"
  local log="${LOG_DIR}/${session}.log"
  say "waiting for '$session' to complete..."
  while tmux has-session -t "$session" 2>/dev/null; do
    sleep 5
  done
  local last
  last="$(tail -1 "$log" 2>/dev/null || true)"
  if [[ "$last" == *"build complete"* ]] || \
     [[ "$last" == *"image built"* ]] || \
     [[ "$last" == *"darkirc build complete"* ]] || \
     [[ "$last" == *"WASM install"* ]] || \
     [[ "$last" == *"vision sidecar image built"* ]]; then
    ok "'$session' completed successfully"
  else
    say "'$session' ended. Check $log for details."
    say "  last line: $last"
  fi
}

# ── Sanitize tenant name ─────────────────────────────────────────────────────

sanitize() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9-' '-' | sed 's/^-//;s/-$//'
}

# ── Phase 1: Provision env + add tenants ─────────────────────────────────────

phase_1() {
  say "══ Phase 1: Provision env + add tenants (OpenRC) ══"

  write_env_file

  local -a flags=()
  [[ "$ENABLE_DARKIRC" == true ]] && flags+=(--enable-darkirc)
  flags+=(--gotify-url "$GOTIFY_URL")
  flags+=(--llm-base-url "$TENSORZERO_URL")
  flags+=(--xmpp-domain "$XMPP_DOMAIN")
  [[ "$ENABLE_HEALTH" == false ]] && flags+=(--no-health)
  [[ "$ENABLE_SSH" == false ]] && flags+=(--no-ssh)

  say "adding tenants: $TENANTS"
  mt add-tenants "$TENANTS" "${flags[@]}"

  # Patch health.env GOTIFY_URL if the health pipeline was installed but the
  # URL wasn't picked up (happens when LUNARWING_MT_GOTIFY_URL isn't in the env
  # at add-tenant time).
  if [[ "$ENABLE_HEALTH" == true && -f "$HEALTH_ENV" ]]; then
    if ! grep -q "^GOTIFY_URL=${GOTIFY_URL}$" "$HEALTH_ENV"; then
      if grep -q "^GOTIFY_URL=" "$HEALTH_ENV"; then
        sudo sed -i "s#^GOTIFY_URL=.*#GOTIFY_URL=${GOTIFY_URL}#" "$HEALTH_ENV"
      else
        echo "GOTIFY_URL=${GOTIFY_URL}" | sudo tee -a "$HEALTH_ENV" >/dev/null
      fi
      ok "patched GOTIFY_URL in $HEALTH_ENV"
    else
      ok "GOTIFY_URL already correct in $HEALTH_ENV"
    fi
  fi

  ok "Phase 1 complete"
}

# ── Phase 2: Build everything ────────────────────────────────────────────────

phase_2() {
  say "══ Phase 2: Build binaries, workers, darkirc, vision, WASM ══"

  source "$ENV_FILE"

  local -a build_flags=()
  [[ "$BUILD_WASM" == true ]]     && build_flags+=(--with-wasm)
  [[ "$BUILD_NANOCODE" == true ]] && build_flags+=(--with-nanocode)
  [[ "$BUILD_PEBBLE" == true ]]   && build_flags+=(--with-pebble)

  if [[ ${#build_flags[@]} -gt 0 ]]; then
    mt_tmux mt-build build-all "${build_flags[@]}"
    wait_tmux mt-build
  else
    say "skipping build-all (no build flags enabled)"
  fi

  if [[ "$BUILD_DARKIRC" == true ]]; then
    local first_tenant; first_tenant="$(sanitize "${TENANTS%%,*}")"
    mt_tmux darkirc-build build-darkirc --tenant "$first_tenant"
    wait_tmux darkirc-build
  fi

  if [[ "$BUILD_VISION" == true ]]; then
    mt_tmux vision-build build-vision-sidecar
    wait_tmux vision-build
  fi

  if [[ "$BUILD_WASM" == true ]]; then
    say "installing WASM for all tenants..."
    mt install-wasm-all
    ok "WASM installed"
  fi

  ok "Phase 2 complete"
}

# ── Phase 3: Post-build configuration ────────────────────────────────────────

phase_3() {
  say "══ Phase 3: Post-build configuration ══"

  local IFS=','
  local -a tenants
  read -ra tenants <<< "$TENANTS"

  if [[ "$BUILD_PEBBLE" == true && -n "$NANOGPT_API_KEY" ]]; then
    for name in "${tenants[@]}"; do
      local sname; sname="$(sanitize "$name")"
      say "configuring pebble for $sname..."
      mt configure-pebble "$sname" --nanogpt-api-key "$NANOGPT_API_KEY"
      ok "pebble configured for $sname"
    done
  fi

  if [[ "$INSTALL_WATCHDOG" == true ]]; then
    say "installing watchdog (OpenRC)..."
    case "$WATCHDOG_SCHEDULER" in
      auto)
        sudo "$SCRIPT_DIR/install-lunarwing-watchdog.sh" \
          || warn "watchdog install returned non-zero (check output)"
        ;;
      fcron|hourly)
        sudo LUNARWING_WATCHDOG_SCHEDULER="$WATCHDOG_SCHEDULER" \
          "$SCRIPT_DIR/install-lunarwing-watchdog.sh" \
          || warn "watchdog install returned non-zero"
        ;;
    esac
    ok "watchdog installed (scheduler: $WATCHDOG_SCHEDULER)"
  fi

  ok "Phase 3 complete"
}

# ── Phase 4: Start tenants ───────────────────────────────────────────────────

phase_4() {
  say "══ Phase 4: Start tenants (OpenRC) ══"

  local IFS=','
  local -a tenants
  read -ra tenants <<< "$TENANTS"

  for name in "${tenants[@]}"; do
    local sname; sname="$(sanitize "$name")"
    say "starting $sname..."
    mt start-tenant "$sname" || warn "start-tenant $sname returned non-zero (check status)"
    # On OpenRC, start_tenant boots PG first, then proxy, bridge, daemon, and
    # workers — each via rc-service. Worker babysitter units (-sup) are
    # auto-registered by the start functions for rootless podman crash recovery.
  done

  ok "Phase 4 complete"
}

# ── Phase 5: Verify ──────────────────────────────────────────────────────────

phase_5() {
  say "══ Phase 5: Verify ══"

  local IFS=','
  local -a tenants
  read -ra tenants <<< "$TENANTS"

  say ""
  mt list-tenants
  say ""

  for name in "${tenants[@]}"; do
    local sname; sname="$(sanitize "$name")"
    say ""
    mt status "$sname"
  done

  say ""
  mt tokens
  ok "Phase 5 complete"
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
  validate_config

  say "LunarWing Multi-Tenant Provisioning (OpenRC/Gentoo)"
  say "  Tenants:       $TENANTS"
  say "  Service Mgr:   $SERVICE_MANAGER"
  say "  Runtime:       $CONTAINER_RUNTIME (rootless=$ROOTLESS)"
  say "  TensorZero:    $TENSORZERO_URL"
  say "  Gotify:        $GOTIFY_URL"
  say "  DarkIRC:       $ENABLE_DARKIRC"
  say "  SSH:           $ENABLE_SSH"
  say "  Health:        $ENABLE_HEALTH"
  say "  Build WASM:    $BUILD_WASM"
  say "  Nanocode:      $BUILD_NANOCODE"
  say "  Pebble:        $BUILD_PEBBLE"
  say "  DarkIRC build: $BUILD_DARKIRC"
  say "  Vision:        $BUILD_VISION"
  say "  Watchdog:      $INSTALL_WATCHDOG ($WATCHDOG_SCHEDULER)"
  say "  Phases:        $PHASE_START-$PHASE_END"
  say ""

  in_phase_range 1 && phase_1
  in_phase_range 2 && phase_2
  in_phase_range 3 && phase_3
  in_phase_range 4 && phase_4
  in_phase_range 5 && phase_5

  say ""
  ok "All requested phases complete."
  say ""
  say "Monitor builds:  tail -f /tmp/{mt-build,darkirc-build,vision-build}.log"
  say "View logs:       tail -f /home/<tenant>/lunarwing/logs/lunarwing.log"
  say "Service status:  sudo rc-service lunarwing-<tenant> status"
  say "Gateway:         http://127.0.0.1:<gateway-port>  (token from 'tokens' output above)"
}

main "$@"
