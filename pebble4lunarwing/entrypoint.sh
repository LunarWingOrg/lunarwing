#!/usr/bin/env bash
set -euo pipefail

PEBBLE_MODE="${PEBBLE_MODE:-websocket}"

case "$PEBBLE_MODE" in
  websocket)
    echo "[entrypoint] starting pebble4lunarwing bridge (WebSocket mode)"
    exec pebble4lunarwing
    ;;
  cli)
    echo "[entrypoint] running pebble in CLI mode"
    exec pebble --permission-mode "${PEBBLE_PERMISSION_MODE:-danger-full-access}" \
                --model "${PEBBLE_MODEL:-openai/gpt-5.2}" \
                --output-format "${PEBBLE_OUTPUT_FORMAT:-text}" \
                "$@"
    ;;
  *)
    echo "[entrypoint] unknown PEBBLE_MODE: $PEBBLE_MODE (expected websocket or cli)" >&2
    exit 1
    ;;
esac
