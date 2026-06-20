#!/usr/bin/env bash
# Stand up (or tear down) a local Multica/Lunartica server for exercising the
# multica-bridge. Brings up Postgres (pgvector) in a container, builds the Go
# server + migrate tool, applies migrations, and runs the server with the dev
# verification-code bypass enabled so multica-bridge-smoke-test.sh can self-seed.
#
# This is a TEST helper only — it deliberately enables the dev login bypass
# (MULTICA_DEV_VERIFICATION_CODE) and uses throwaway credentials. Never point it
# at anything but a local, disposable instance.
#
# Usage:
#   LUNARTICA_DIR=/path/to/Lunartica scripts/multica-local-test-server.sh up
#   scripts/multica-local-test-server.sh down
#
# Env:
#   LUNARTICA_DIR                  Path to the Lunartica (Multica fork) checkout (required for 'up').
#   MULTICA_DEV_VERIFICATION_CODE  Dev login code (default 424242).
#   PG_CONTAINER                   Container name (default multica-test-pg).
#   SERVER_PORT                    Server port (default 8080).
#
# Requires: podman or docker; go (uses GOTOOLCHAIN=auto to fetch the toolchain
# pinned in the repo's go.mod if the local go is older).
set -euo pipefail

DEVCODE="${MULTICA_DEV_VERIFICATION_CODE:-424242}"
PG_CONTAINER="${PG_CONTAINER:-multica-test-pg}"
SERVER_PORT="${SERVER_PORT:-8080}"
CMD="${1:-up}"

if command -v podman >/dev/null; then ENGINE=podman
elif command -v docker >/dev/null; then ENGINE=docker
else echo "need podman or docker"; exit 2; fi

down() {
  echo "==> stopping server on :$SERVER_PORT"
  if command -v lsof >/dev/null; then lsof -ti:"$SERVER_PORT" 2>/dev/null | xargs -r kill 2>/dev/null || true; fi
  echo "==> removing container $PG_CONTAINER"
  "$ENGINE" rm -f "$PG_CONTAINER" >/dev/null 2>&1 || true
  echo "done."
}

if [ "$CMD" = "down" ]; then down; exit 0; fi
if [ "$CMD" != "up" ]; then echo "usage: $0 [up|down]"; exit 2; fi

LUNARTICA_DIR="${LUNARTICA_DIR:-}"
[ -n "$LUNARTICA_DIR" ] || { echo "set LUNARTICA_DIR to the Lunartica checkout path"; exit 2; }
[ -d "$LUNARTICA_DIR/server" ] || { echo "no server/ under LUNARTICA_DIR=$LUNARTICA_DIR"; exit 2; }

echo "==> [1/4] Postgres (pgvector) via $ENGINE"
"$ENGINE" rm -f "$PG_CONTAINER" >/dev/null 2>&1 || true
"$ENGINE" run -d --name "$PG_CONTAINER" -p 127.0.0.1:5432:5432 \
  -e POSTGRES_DB=multica -e POSTGRES_USER=multica -e POSTGRES_PASSWORD=multica \
  docker.io/pgvector/pgvector:pg17 >/dev/null
echo "    waiting for readiness..."
for _ in $(seq 1 90); do "$ENGINE" exec "$PG_CONTAINER" pg_isready -U multica -d multica >/dev/null 2>&1 && break; sleep 2; done

cd "$LUNARTICA_DIR"
[ -f .env ] || cp .env.example .env
# Always set a fresh JWT secret for the throwaway instance.
if command -v openssl >/dev/null; then
  sed -i "s/^JWT_SECRET=.*/JWT_SECRET=$(openssl rand -hex 32)/" .env
fi

echo "==> [2/4] build server + migrate (GOTOOLCHAIN=auto)"
BIN="$(mktemp -d)"
( cd server && GOTOOLCHAIN=auto go build -o "$BIN/migrate" ./cmd/migrate && GOTOOLCHAIN=auto go build -o "$BIN/server" ./cmd/server )

echo "==> [3/4] migrate"
set -a; . ./.env; set +a
"$BIN/migrate" up

echo "==> [4/4] run server on :$SERVER_PORT (dev code: $DEVCODE)"
MULTICA_DEV_VERIFICATION_CODE="$DEVCODE" APP_ENV=development nohup "$BIN/server" >"$BIN/server.log" 2>&1 &
echo "    server pid $!   logs → $BIN/server.log"
echo "    stop with: $0 down"
echo ""
echo "Next:  scripts/multica-bridge-smoke-test.sh"
