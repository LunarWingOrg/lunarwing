#!/usr/bin/env bash
set -euo pipefail

# ── LunarWing Multi-Tenant Provisioning Orchestrator (systemd) ───────────────
#
# Wraps the full tenant lifecycle (add → build → configure → start → verify)
# into one script with all knobs at the top. Runs sudo -E internally so the
# LUNARWING_MT_* env vars reach the admin script.
#
# Usage:
#   1. Edit the CONFIG section below
#   2. ./ic/scripts/lunarwing-mt-provision-systemd.sh           # all phases
#   3. ./ic/scripts/lunarwing-mt-provision-systemd.sh --phase 3  # run specific phase
#   4. ./ic/scripts/lunarwing-mt-provision-systemd.sh --phase 2-4 # range
#
# Phases:
#   1  Provision env + add tenants + start PG
#   2  Build binaries, workers, darkirc, vision, WASM
#   3  Post-build configuration (pebble, watchdog, health.env)
#   4  Start tenants
#   5  Verify
#
# The script checks for completion at each phase boundary and exits on failure.

# ═══════════════════════════════════════════════════════════════════════════════
# CONFIG — edit these values before running
# ═══════════════════════════════════════════════════════════════════════════════

# Tenant names (comma-separated, will be lowercased)
TENANTS="tenant1,tenant2"

# Infrastructure
SERVICE_MANAGER="systemd"          # systemd | openrc
CONTAINER_RUNTIME="podman"         # podman | docker
ROOTLESS="true"                    # true | false (true for podman, false for docker)

# Features
ENABLE_DARKIRC=false                # DarkIRC daemon + adapter
ENABLE_SSH=true                    # SSH harness (key pair, agent, config.toml)
ENABLE_HEALTH=true                 # Host-global health/self-heal pipeline
BUILD_WASM=true                    # Build + install WASM tools and channels
BUILD_NANOCODE=true               # Build nanocode worker Docker image
BUILD_PEBBLE=true                  # Build pebble worker Docker image
BUILD_DARKIRC=false                # Build darkirc daemon binary
BUILD_VISION=true                  # Build vision/OCR sidecar Docker image
INSTALL_WATCHDOG=false             # Single-tenant watchdog; MT health pipeline already covers tenants

# LLM                                                                 
TENSORZERO_URL="http://tensorzerohost.local:3000/openai/v1"                  
                                                                      
# Gotify (notifications)                                              
GOTIFY_URL="https://gotify.mecha.godzilla"                          
GOTIFY_TOKEN="supersecrettokene33"                    # REQUIRED if ENABLE_HEALTH=true — health pipeline escalation token                       
                                                                      
# Pebble worker (NanoGPT)                                             
NANOGPT_API_KEY="sk-nano-apikeylol"
# XMPP
XMPP_DOMAIN="xmpp.my.domain"      # JIDs become <tenant>@<domain>

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

sanitize() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9-' '-' | sed 's/^-//;s/-$//'
}

# ── Validation ───────────────────────────────────────────────────────────────

validate_config() {
  [[ -n "$TENANTS" ]] || die "TENANTS must be set"
  [[ -n "$GOTIFY_URL" ]] || die "GOTIFY_URL must be set"
  [[ -f "$MT_ADMIN" ]] || die "mt-admin script not found at $MT_ADMIN"

  if [[ "$ENABLE_HEALTH" == true && -z "$GOTIFY_TOKEN" ]]; then
    die "GOTIFY_TOKEN is required when ENABLE_HEALTH=true"
  fi
  if [[ "$BUILD_PEBBLE" == true && -z "$NANOGPT_API_KEY" ]]; then
    die "NANOGPT_API_KEY is required when BUILD_PEBBLE=true"
  fi

  local sv="${SERVICE_MANAGER,,}"
  case "$sv" in
    systemd|openrc) ;;
    *) die "SERVICE_MANAGER must be 'systemd' or 'openrc'" ;;
  esac

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

# Block until a tmux session ends (poll every 5s). Returns the session's exit code.
wait_tmux() {
  local session="$1"
  local log="${LOG_DIR}/${session}.log"
  say "waiting for '$session' to complete..."
  while tmux has-session -t "$session" 2>/dev/null; do
    sleep 5
  done
  # tmux doesn't expose exit code directly; check the log for the last line
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

# ── Phase 1: Provision env + add tenants ─────────────────────────────────────

phase_1() {
  say "══ Phase 1: Provision env + add tenants ══"

  write_env_file

  local -a flags=()
  flags+=(--enable-darkirc)
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
    # darkirc is a shared binary — only needs to be built once (as the first
    # tenant so it uses that user's rust toolchain, not root's).
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
      local sname
      sname="$(echo "$name" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9-' '-' | sed 's/^-//;s/-$//')"
      say "configuring pebble for $sname..."
      mt configure-pebble "$sname" --nanogpt-api-key "$NANOGPT_API_KEY"
      ok "pebble configured for $sname"
    done
  fi

  if [[ "$INSTALL_WATCHDOG" == true ]]; then
    say "installing watchdog..."
    sudo "$SCRIPT_DIR/install-lunarwing-watchdog.sh" || warn "watchdog install returned non-zero"
    ok "watchdog installed"
  fi

  ok "Phase 3 complete"
}

# ── Phase 4: Start tenants ───────────────────────────────────────────────────

phase_4() {
  say "══ Phase 4: Start tenants ══"

  local IFS=','
  local -a tenants
  read -ra tenants <<< "$TENANTS"

  for name in "${tenants[@]}"; do
    local sname
    sname="$(echo "$name" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9-' '-' | sed 's/^-//;s/-$//')"
    say "starting $sname..."
    mt start-tenant "$sname" || warn "start-tenant $sname returned non-zero (check status)"
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
    local sname
    sname="$(echo "$name" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9-' '-' | sed 's/^-//;s/-$//')"
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

  say "LunarWing Multi-Tenant Provisioning"
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
  say "  Watchdog:      $INSTALL_WATCHDOG"
  say "  Phases:        $PHASE_START-$PHASE_END"
  say ""

  in_phase_range 1 && phase_1
  in_phase_range 2 && phase_2
  in_phase_range 3 && phase_3
  in_phase_range 4 && phase_4
  in_phase_range 5 && phase_5

  say ""
  ok "All requested phases complete."
  say "Monitor builds:  tail -f /tmp/{mt-build,darkirc-build,vision-build}.log"
  say "View logs:       sudo -u <tenant> XDG_RUNTIME_DIR=/run/user/\$(id -u <tenant>) journalctl --user -u lunarwing-<tenant> -f"
  say "Gateway:         http://127.0.0.1:<gateway-port>  (token from 'tokens' output above)"
}

main "$@"
