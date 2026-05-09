#!/bin/bash
# entrypoint.sh — IronClaw Nanocode Worker startup script
# Supports three modes:
#   --mode websocket  (default) persistent worker with WebSocket agent communication
#   --mode cli                  one-shot nanocode run with a prompt
#   --mode acp                  ACP stdio bridge mode
set -euo pipefail

# ── helpers ────────────────────────────────────────────────────────────────────
log()  { printf '[%s] %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }
die()  { log "ERROR: $*" >&2; exit 1; }

# ── defaults ───────────────────────────────────────────────────────────────────
MODE="${NANOCODE_MODE:-websocket}"
HEALTH_PORT="${HEALTH_PORT:-8443}"
NANOCODE_SERVE_PORT="${NANOCODE_SERVE_PORT:-4096}"
NANOCODE_SERVE_HOST="${NANOCODE_SERVE_HOST:-127.0.0.1}"
WS_ROLE="${WS_ROLE:-server}"
WS_STATE_FILE="${WS_STATE_FILE:-/tmp/ironclaw_ws_state.json}"
FILE_UMASK="${FILE_UMASK:-0002}"
NANOCODE_ROOT="${NANOCODE_ROOT:-/app/nanocode/packages/opencode}"
WORKSPACE_ROOT="${WORKSPACE_ROOT:-/workspace}"

umask "$FILE_UMASK"

# ── parse CLI args (override env vars) ────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    --mode)      MODE="$2";             shift 2 ;;
    --port)      HEALTH_PORT="$2";      shift 2 ;;
    --serve-port) NANOCODE_SERVE_PORT="$2"; shift 2 ;;
    --)          shift; break ;;
    *)           break ;;
  esac
done

# ── config setup ──────────────────────────────────────────────────────────────
# Symlink project-level nanocode.json into the workspace if a config is mounted
if [ -f /app/config/nanocode.json ]; then
  mkdir -p "$WORKSPACE_ROOT/.nanocode"
  ln -sfn /app/config/nanocode.json "$WORKSPACE_ROOT/.nanocode/nanocode.json"
  log "Config linked: /app/config/nanocode.json → $WORKSPACE_ROOT/.nanocode/nanocode.json"
fi

# ── always start the health server in the background ──────────────────────────
log "Starting health server on port $HEALTH_PORT"
export WS_STATE_FILE
export CODEX_MODE="$MODE"
export CODEX_VERSION="nanocode-worker-1.0.0"
python3 /app/health_server.py --port "$HEALTH_PORT" &
HEALTH_PID=$!

sleep 1

cleanup() {
  log "Shutting down..."
  kill "$NANOCODE_PID" 2>/dev/null || true
  kill "$HEALTH_PID" 2>/dev/null || true
  wait "$NANOCODE_PID" 2>/dev/null || true
  wait "$HEALTH_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ── mode dispatch ──────────────────────────────────────────────────────────────
case "$MODE" in

  cli)
    log "Mode: CLI — running nanocode with args: $*"
    cd "$WORKSPACE_ROOT"
    exec bun run --cwd "$NANOCODE_ROOT" src/index.ts run "$@"
    ;;

  acp)
    log "Mode: ACP — launching nanocode ACP bridge"
    cd "$WORKSPACE_ROOT"
    exec bun run --cwd "$NANOCODE_ROOT" src/index.ts acp "$@"
    ;;

  websocket)
    log "Mode: WebSocket — starting nanocode headless server"

    # Start nanocode serve in background
    cd "$WORKSPACE_ROOT"
    bun run --cwd "$NANOCODE_ROOT" src/index.ts serve \
      --port "$NANOCODE_SERVE_PORT" \
      --hostname "$NANOCODE_SERVE_HOST" &
    NANOCODE_PID=$!

    # Wait for nanocode server to be ready
    log "Waiting for nanocode server on port $NANOCODE_SERVE_PORT..."
    RETRIES=0
    MAX_RETRIES=30
    until curl -sf "http://$NANOCODE_SERVE_HOST:$NANOCODE_SERVE_PORT/@nanogpt/health" >/dev/null 2>&1 || \
          curl -sf "http://$NANOCODE_SERVE_HOST:$NANOCODE_SERVE_PORT/" >/dev/null 2>&1; do
      RETRIES=$((RETRIES + 1))
      if [ $RETRIES -ge $MAX_RETRIES ]; then
        die "nanocode server failed to start after ${MAX_RETRIES}s"
      fi
      if ! kill -0 "$NANOCODE_PID" 2>/dev/null; then
        die "nanocode server process exited unexpectedly"
      fi
      sleep 1
    done
    log "nanocode server ready on http://$NANOCODE_SERVE_HOST:$NANOCODE_SERVE_PORT"

    # Launch the IronClaw WebSocket bridge
    log "Starting IronClaw bridge — role: $WS_ROLE"
    export NANOCODE_SERVE_PORT
    export NANOCODE_SERVE_HOST
    export WS_ROLE
    export WS_STATE_FILE
    export WORKSPACE_ROOT

    exec bun run /app/scripts/ironclaw_bridge.ts
    ;;

  *)
    die "Unknown mode '$MODE'. Use --mode websocket, --mode cli, or --mode acp"
    ;;

esac
