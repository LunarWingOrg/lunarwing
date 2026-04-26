#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

export ALLOW_PRIVATE_IPS="${ALLOW_PRIVATE_IPS:-1}"
export PGSSLMODE="${PGSSLMODE:-disable}"
export HTTP_PORT="${HTTP_PORT:-9098}"
export HTTP_WEBHOOK_SECRET="${HTTP_WEBHOOK_SECRET:-testtoken}"
export AGENT_NAME="${AGENT_NAME:-lunarwing}"

if [[ -n "${LUNARWING_BASE_DIR:-}" && -z "${IRONCLAW_BASE_DIR:-}" ]]; then
  export IRONCLAW_BASE_DIR="$LUNARWING_BASE_DIR"
fi

sleep "${RUN_START_DELAY_SECS:-2}"

if [[ "$#" -gt 0 ]]; then
  exec ./target/release/ironclaw "$@"
fi

exec ./target/release/ironclaw run
