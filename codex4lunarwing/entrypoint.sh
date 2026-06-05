#!/bin/bash
# entrypoint.sh — LunarWing Codex Worker startup script
# Supports two modes:
#   --mode websocket  (default) persistent worker with WebSocket agent communication
#   --mode cli                  one-shot codex run with a prompt
set -euo pipefail

# ── helpers ────────────────────────────────────────────────────────────────────
log()  { printf '[%s] %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }
die()  { log "ERROR: $*" >&2; exit 1; }

# ── defaults ───────────────────────────────────────────────────────────────────
MODE="${CODEX_MODE:-websocket}"
HEALTH_PORT="${HEALTH_PORT:-8443}"
WS_ROLE="${WS_ROLE:-server}"
WS_STATE_FILE="${WS_STATE_FILE:-/tmp/lunarwing_ws_state.json}"
FILE_UMASK="${FILE_UMASK:-0002}"
WORKSPACE_ROOT="${WORKSPACE_ROOT:-/workspace}"

umask "$FILE_UMASK"

# ── git / SSH credential setup ────────────────────────────────────────────────
if [ -n "${GIT_AUTHOR_NAME:-}" ] && ! git config --global user.name >/dev/null 2>&1; then
  git config --global user.name "$GIT_AUTHOR_NAME"
  log "Git user.name set to: $GIT_AUTHOR_NAME"
fi
if [ -n "${GIT_AUTHOR_EMAIL:-}" ] && ! git config --global user.email >/dev/null 2>&1; then
  git config --global user.email "$GIT_AUTHOR_EMAIL"
  log "Git user.email set to: $GIT_AUTHOR_EMAIL"
fi

if [ -n "${GITHUB_TOKEN:-}" ]; then
  git config --global credential.https://github.com.helper \
    '!f() { echo "protocol=https"; echo "host=github.com"; echo "username=x-access-token"; echo "password=${GITHUB_TOKEN}"; }; f'
  log "GitHub HTTPS credential helper configured"
elif [ -n "${GH_TOKEN:-}" ]; then
  git config --global credential.https://github.com.helper \
    '!f() { echo "protocol=https"; echo "host=github.com"; echo "username=x-access-token"; echo "password=${GH_TOKEN}"; }; f'
  log "GitHub HTTPS credential helper configured (via GH_TOKEN)"
fi

# Copy host SSH keys if mounted
if [ -d /home/codex/.host-ssh ] && [ "$(ls -A /home/codex/.host-ssh 2>/dev/null)" ]; then
  mkdir -p /home/codex/.ssh
  cp -a /home/codex/.host-ssh/* /home/codex/.ssh/ 2>/dev/null || true
  chmod 700 /home/codex/.ssh 2>/dev/null || true
  chmod 600 /home/codex/.ssh/id_* 2>/dev/null || true
  chmod 644 /home/codex/.ssh/*.pub 2>/dev/null || true
  chmod 644 /home/codex/.ssh/known_hosts 2>/dev/null || true
  log "SSH keys copied from host mount"
  if [ ! -f /home/codex/.ssh/config ]; then
    printf 'Host *\n  StrictHostKeyChecking accept-new\n  UserKnownHostsFile /home/codex/.ssh/known_hosts\n' \
      > /home/codex/.ssh/config
    chmod 600 /home/codex/.ssh/config
  fi
fi

# Copy host .gitconfig if mounted
if [ -f /home/codex/.host-gitconfig ] && [ -s /home/codex/.host-gitconfig ]; then
  cp /home/codex/.host-gitconfig /home/codex/.gitconfig 2>/dev/null || true
  log "Host .gitconfig copied into container"
fi

# ── parse CLI args (override env vars) ────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    --mode)      MODE="$2";        shift 2 ;;
    --port)      HEALTH_PORT="$2"; shift 2 ;;
    --)          shift; break ;;
    *)           break ;;
  esac
done

# ── config setup ──────────────────────────────────────────────────────────────
# Symlink codex config if mounted
if [ -f /app/config/codex.toml ]; then
  mkdir -p /home/codex/.codex
  ln -sfn /app/config/codex.toml /home/codex/.codex/config.toml
  log "Config linked: /app/config/codex.toml → /home/codex/.codex/config.toml"
fi

# ── always start the health server in the background ──────────────────────────
log "Starting health server on port $HEALTH_PORT"
export WS_STATE_FILE
export CODEX_MODE="$MODE"
export CODEX_VERSION="codex-worker-1.0.0"
python3 /app/health_server.py --port "$HEALTH_PORT" &
HEALTH_PID=$!

sleep 1

cleanup() {
  log "Shutting down..."
  kill "$HEALTH_PID" 2>/dev/null || true
  wait "$HEALTH_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ── mode dispatch ──────────────────────────────────────────────────────────────
case "$MODE" in

  cli)
    log "Mode: CLI — running codex with args: $*"
    cd "$WORKSPACE_ROOT"
    exec codex --approval-mode full-auto --quiet "$@"
    ;;

  websocket)
    log "Mode: WebSocket — starting codex bridge"
    cd "$WORKSPACE_ROOT"

    # Launch the LunarWing WebSocket bridge
    log "Starting LunarWing bridge — role: $WS_ROLE"
    export WS_ROLE
    export WS_STATE_FILE
    export WORKSPACE_ROOT

    exec bun run /app/scripts/lunarwing_bridge.ts
    ;;

  *)
    die "Unknown mode '$MODE'. Use --mode websocket or --mode cli"
    ;;

esac
