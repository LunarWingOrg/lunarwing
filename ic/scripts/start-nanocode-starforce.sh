#!/usr/bin/env bash
set -euo pipefail

TENANT="starforce"
CONTAINER_NAME="lunarwing-nanocode-${TENANT}"
WSS_PORT=10007
WORKSPACE_DIR="/home/${TENANT}/lunarwing/nanocode-workspace"

if [[ $EUID -ne 0 ]]; then
  echo "error: must run as root" >&2
  exit 1
fi

mkdir -p "$WORKSPACE_DIR"
chown "${TENANT}:${TENANT}" "$WORKSPACE_DIR"
chmod 777 "$WORKSPACE_DIR"

if docker inspect "$CONTAINER_NAME" &>/dev/null; then
  echo "container $CONTAINER_NAME already exists, removing..."
  docker rm -f "$CONTAINER_NAME" >/dev/null
fi

docker run -d \
  --name "$CONTAINER_NAME" \
  -e LUNARWING_WORKER_ID="worker-nanocode-${TENANT}" \
  -e WS_PORT="$WSS_PORT" \
  -e HEALTH_PORT="0" \
  -e NANOCODE_MODE=websocket \
  -e WS_ROLE=server \
  -e WS_BIND_HOST=0.0.0.0 \
  -e WS_PATH=/ws/agent \
  -p "127.0.0.1:${WSS_PORT}:${WSS_PORT}" \
  -v "${WORKSPACE_DIR}:/workspace:z" \
  --restart unless-stopped \
  lunarwing-worker-nanocode:latest \
  --mode websocket

echo "nanocode worker started: $CONTAINER_NAME on WSS port $WSS_PORT"
