#!/bin/bash
# LunarWing Infrastructure Health Check + Self-Healing Cron Wrapper
#
# Called by systemd timer, cron.hourly, or fcron to run the full
# health-check → self-heal pipeline. Detects its own location so
# it works regardless of where the infrastructure health-check
# directory is installed.
#
# Usage:
#   ./cron-wrapper.sh
#
# Environment:
#   LUNARWING_BASE_DIR    Base directory for LunarWing data (default: $HOME/.lunarwing)
#   LUNARWING_HEALTH_DIR  Override health-check script directory (default: auto-detect)

set -euo pipefail

# Set safe PATH
export PATH=/usr/local/bin:/usr/bin:/bin

# ── Detect script location ─────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Run health check ───────────────────────────────────────

HEALTH_CHECK="$SCRIPT_DIR/infrastructure-health-check.sh"

if [[ ! -x "$HEALTH_CHECK" ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: infrastructure-health-check.sh not found at $HEALTH_CHECK; skipping health check but proceeding to self-heal" >&2
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Running infrastructure health check..." >&2
    "$HEALTH_CHECK" || true  # Always continue to self-heal, even if health check fails
fi

# ── Run self-healing ────────────────────────────────────

SELF_HEAL="$SCRIPT_DIR/lunarwing-self-heal.sh"

if [[ ! -x "$SELF_HEAL" ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: self-heal script not found; skipping remediation" >&2
    exit 0
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Running self-healing watchdog..." >&2
"$SELF_HEAL" "$@" || true  # Self-heal failures are logged internally; don't abort cron

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Cron wrapper complete." >&2
exit 0