#!/bin/bash
# entrypoint.sh — LunarWing OpenCode Worker startup script
set -euo pipefail

log()  { printf '[%s] %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }
die()  { log "ERROR: $*" >&2; exit 1; }

MODE="${OPENCODE_MODE:-websocket}"
HEALTH_PORT="${HEALTH_PORT:-8443}"
OPENCODE_SERVE_PORT="${OPENCODE_SERVE_PORT:-4096}"
OPENCODE_SERVE_HOST="${OPENCODE_SERVE_HOST:-127.0.0.1}"
WS_ROLE="${WS_ROLE:-server}"
WS_STATE_FILE="${WS_STATE_FILE:-/tmp/lunarwing_ws_state.json}"
FILE_UMASK="${FILE_UMASK:-0002}"
OPENCODE_ROOT="${OPENCODE_ROOT:-/app/opencode/packages/opencode}"
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

# Copy host SSH keys into writable ~/.ssh if mounted (read-only mount needs copy)
if [ -d /home/opencode/.host-ssh ] && [ "$(ls -A /home/opencode/.host-ssh 2>/dev/null)" ]; then
  mkdir -p /home/opencode/.ssh
  cp -a /home/opencode/.host-ssh/* /home/opencode/.ssh/ 2>/dev/null || true
  chmod 700 /home/opencode/.ssh 2>/dev/null || true
  chmod 600 /home/opencode/.ssh/id_* 2>/dev/null || true
  chmod 644 /home/opencode/.ssh/*.pub 2>/dev/null || true
  chmod 644 /home/opencode/.ssh/known_hosts 2>/dev/null || true
  log "SSH keys copied from host mount"
  if [ ! -f /home/opencode/.ssh/config ]; then
    printf 'Host *\n  StrictHostKeyChecking accept-new\n  UserKnownHostsFile /home/opencode/.ssh/known_hosts\n' \
      > /home/opencode/.ssh/config
    chmod 600 /home/opencode/.ssh/config
  fi
fi

# Copy host .gitconfig if mounted
if [ -f /home/opencode/.host-gitconfig ] && [ -s /home/opencode/.host-gitconfig ]; then
  cp /home/opencode/.host-gitconfig /home/opencode/.gitconfig 2>/dev/null || true
  log "Host .gitconfig copied into container"
fi

# ── parse CLI args ─────────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    --mode)       MODE="$2";              shift 2 ;;
    --port)       HEALTH_PORT="$2";       shift 2 ;;
    --serve-port) OPENCODE_SERVE_PORT="$2"; shift 2 ;;
    --)           shift; break ;;
    *)            break ;;
  esac
done

# ── config setup ──────────────────────────────────────────────────────────────
if [ -f /app/config/opencode.json ]; then
  mkdir -p "$WORKSPACE_ROOT/.opencode"
  if [ -n "${OPENCODE_MODEL:-}" ] || [ -n "${OPENCODE_BASE_URL:-}" ]; then
    python3 - "$WORKSPACE_ROOT/.opencode/opencode.json" <<'PY'
import json, os, sys
with open("/app/config/opencode.json") as f:
    cfg = json.load(f)
model = os.environ.get("OPENCODE_MODEL", "").strip()
base = os.environ.get("OPENCODE_BASE_URL", "").strip()
if model:
    # opencode resolves a model reference as "<provider>/<model-id>", splitting on
    # the first "/" (packages/core/src/model.ts:parse). A bare function name like
    # "tensorzero::function_name::FrontierCODE" has no slash, so opencode treats the
    # whole string as the provider and the model id as empty, producing a malformed
    # request ("tensorzero::function_name::FrontierCODE/") that the backend rejects.
    # Accept the bare function name and build the provider/model reference against
    # the first provider in the config (the TensorZero provider). Also register the
    # model in that provider's models map so opencode can resolve it.
    if "/" not in model:
        providers = cfg.get("provider", {})
        if providers:
            provider_id = next(iter(providers))
            cfg["model"] = f"{provider_id}/{model}"
            providers[provider_id].setdefault("models", {})[model] = {"name": model}
        else:
            cfg["model"] = model
    else:
        cfg["model"] = model
if base:
    for prov in cfg.get("provider", {}).values():
        prov.setdefault("options", {})["baseURL"] = base
with open(sys.argv[1], "w") as f:
    json.dump(cfg, f, indent=2)
PY
    log "Config generated with overrides (model=${OPENCODE_MODEL:-<default>}, baseURL=${OPENCODE_BASE_URL:-<default>})"
  else
    ln -sfn /app/config/opencode.json "$WORKSPACE_ROOT/.opencode/opencode.json"
    log "Config linked: /app/config/opencode.json → $WORKSPACE_ROOT/.opencode/opencode.json"
  fi
fi

# ── optional Paseo MCP integration ────────────────────────────────────────────
if [ -n "${PASEO_URL:-}" ] && [ -n "${PASEO_TOKEN:-}" ] && [ -f "$WORKSPACE_ROOT/.opencode/opencode.json" ]; then
  python3 - "$WORKSPACE_ROOT/.opencode/opencode.json" <<'PY'
import json, os, sys
path = sys.argv[1]
with open(path) as f:
    cfg = json.load(f)
mcp = cfg.setdefault("mcp", {})
mcp["paseo"] = {
    "type": "remote",
    "url": os.environ["PASEO_URL"].rstrip("/") + "/mcp/agents",
    "enabled": True,
    "oauth": False,
    "headers": {"Authorization": "Bearer " + os.environ["PASEO_TOKEN"]},
}
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
PY
  log "Paseo MCP entry injected into opencode config"
fi

# ── always start the health server in the background ──────────────────────────
log "Starting health server on port $HEALTH_PORT"
export WS_STATE_FILE
export CODEX_MODE="$MODE"
export CODEX_VERSION="opencode-worker-1.0.0"
python3 /app/health_server.py --port "$HEALTH_PORT" &
HEALTH_PID=$!

sleep 1

cleanup() {
  log "Shutting down..."
  kill "$OPENCODE_PID" 2>/dev/null || true
  kill "$HEALTH_PID" 2>/dev/null || true
  wait "$OPENCODE_PID" 2>/dev/null || true
  wait "$HEALTH_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ── mode dispatch ──────────────────────────────────────────────────────────────
case "$MODE" in

  cli)
    log "Mode: CLI — running opencode with args: $*"
    cd "$WORKSPACE_ROOT"
    exec bun run --cwd "$OPENCODE_ROOT" src/index.ts run "$@"
    ;;

  acp)
    log "Mode: ACP — launching opencode ACP bridge"
    cd "$WORKSPACE_ROOT"
    exec bun run --cwd "$OPENCODE_ROOT" src/index.ts acp "$@"
    ;;

  websocket)
    log "Mode: WebSocket — starting opencode headless server"

    cd "$WORKSPACE_ROOT"
    bun run --cwd "$OPENCODE_ROOT" src/index.ts serve \
      --port "$OPENCODE_SERVE_PORT" \
      --hostname "$OPENCODE_SERVE_HOST" &
    OPENCODE_PID=$!

    log "Waiting for opencode server on port $OPENCODE_SERVE_PORT..."
    RETRIES=0
    MAX_RETRIES=30
    # Ready = the server speaks HTTP on this port. Use `curl -s` (NOT `-sf`):
    # opencode `serve` returns 404 on bare `/` (it only serves the built SPA
    # there, which this image does not build), so `-sf`/`--fail` would loop until
    # timeout even though the API is healthy. Any HTTP response (incl. 404) means
    # ready; only a refused/no-connection keeps the loop waiting.
    until curl -s --max-time 2 -o /dev/null "http://$OPENCODE_SERVE_HOST:$OPENCODE_SERVE_PORT/" 2>/dev/null; do
      RETRIES=$((RETRIES + 1))
      if [ $RETRIES -ge $MAX_RETRIES ]; then
        die "opencode server failed to start after ${MAX_RETRIES}s"
      fi
      if ! kill -0 "$OPENCODE_PID" 2>/dev/null; then
        die "opencode server process exited unexpectedly"
      fi
      sleep 1
    done
    log "opencode server ready on http://$OPENCODE_SERVE_HOST:$OPENCODE_SERVE_PORT"

    log "Starting LunarWing bridge — role: $WS_ROLE"
    export OPENCODE_SERVE_PORT
    export OPENCODE_SERVE_HOST
    export WS_ROLE
    export WS_STATE_FILE
    export WORKSPACE_ROOT

    exec bun run /app/scripts/lunarwing_bridge.ts
    ;;

  *)
    die "Unknown mode '$MODE'. Use --mode websocket, --mode cli, or --mode acp"
    ;;

esac
