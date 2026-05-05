#!/usr/bin/env bash
set -euo pipefail

WATCHDOG_CONFD="${LUNARWING_WATCHDOG_CONFD:-${HOME}/Library/Application Support/lunarwing/watchdog.conf}"

if [[ -r "$WATCHDOG_CONFD" ]]; then
  # shellcheck disable=SC1090
  . "$WATCHDOG_CONFD"
fi

LABEL="${lunarwing_watchdog_label:-${LUNARWING_WATCHDOG_LABEL:-com.lunarwing.daemon}}"
LOG_FILE="${lunarwing_watchdog_log:-${LUNARWING_WATCHDOG_LOG:-${HOME}/Library/Logs/lunarwing-watchdog.log}}"
LOCK_DIR="${lunarwing_watchdog_lock:-${LUNARWING_WATCHDOG_LOCK:-/tmp/lunarwing-watchdog.lock}}"
POST_RESTART_SLEEP_SECONDS="${lunarwing_watchdog_post_restart_sleep_seconds:-${LUNARWING_WATCHDOG_POST_RESTART_SLEEP_SECONDS:-5}}"

timestamp() {
  date '+%Y-%m-%dT%H:%M:%S%z'
}

prepare_log_file() {
  local log_dir
  log_dir="$(dirname -- "$LOG_FILE")"

  if [[ -d "$log_dir" && -w "$log_dir" ]]; then
    touch "$LOG_FILE" 2>/dev/null || LOG_FILE=""
  else
    LOG_FILE=""
  fi
}

log() {
  local line
  line="$(timestamp) $*"

  if [[ -n "$LOG_FILE" ]]; then
    printf '%s\n' "$line" | tee -a "$LOG_FILE"
  else
    printf '%s\n' "$line"
  fi
}

state_summary() {
  local output pid exit_status
  output="$(launchctl list "$LABEL" 2>&1)" || true

  if [[ -n "$output" ]]; then
    pid="$(printf '%s' "$output" | awk 'NR==2{print $1}')"
    exit_status="$(printf '%s' "$output" | awk 'NR==2{print $2}')"
    printf 'pid=%s exit=%s label=%s' "${pid:--}" "${exit_status:--}" "$LABEL"
  else
    printf 'not_loaded label=%s' "$LABEL"
  fi
}

acquire_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s' "$$" >"${LOCK_DIR}/pid"
    trap 'rm -rf "$LOCK_DIR"' EXIT
    return 0
  fi

  local stale_pid
  if [[ -f "${LOCK_DIR}/pid" ]]; then
    stale_pid="$(cat "${LOCK_DIR}/pid" 2>/dev/null || true)"
    if [[ -n "$stale_pid" ]] && ! kill -0 "$stale_pid" 2>/dev/null; then
      rm -rf "$LOCK_DIR"
      if mkdir "$LOCK_DIR" 2>/dev/null; then
        printf '%s' "$$" >"${LOCK_DIR}/pid"
        trap 'rm -rf "$LOCK_DIR"' EXIT
        return 0
      fi
    fi
  fi

  return 1
}

agent_is_running() {
  local output pid
  output="$(launchctl list "$LABEL" 2>/dev/null)" || return 1

  pid="$(printf '%s' "$output" | awk 'NR==2{print $1}')"
  [[ "$pid" != "-" && -n "$pid" ]]
}

prepare_log_file

if ! acquire_lock; then
  log "another watchdog run is already active; exiting"
  exit 0
fi

if agent_is_running; then
  log "$LABEL active; no action"
  exit 0
fi

before_state="$(state_summary || true)"
log "$LABEL not active; attempting restart; before_state=\"$before_state\""

restarted=false

if command -v launchctl >/dev/null 2>&1; then
  uid="$(id -u)"

  # Try modern kickstart first (macOS 10.10+)
  if launchctl kickstart -k "gui/${uid}/${LABEL}" 2>/dev/null; then
    restarted=true
  else
    # Fallback: if agent is loaded, stop and let KeepAlive restart it
    if launchctl list "$LABEL" >/dev/null 2>&1; then
      launchctl stop "$LABEL" 2>/dev/null || true
      restarted=true
    else
      # Agent not loaded — try to load it
      local_plist="${HOME}/Library/LaunchAgents/${LABEL}.plist"
      if [[ -f "$local_plist" ]]; then
        if launchctl load -w "$local_plist" 2>/dev/null; then
          restarted=true
        fi
      fi
    fi
  fi
fi

if [[ "$restarted" != "true" ]]; then
  after_state="$(state_summary || true)"
  log "$LABEL restart failed; after_state=\"$after_state\""
  exit 1
fi

sleep "$POST_RESTART_SLEEP_SECONDS"

if agent_is_running; then
  after_state="$(state_summary || true)"
  log "$LABEL restart succeeded; after_state=\"$after_state\""
  exit 0
fi

after_state="$(state_summary || true)"
log "$LABEL restart attempted but agent is still not active; after_state=\"$after_state\""
exit 1
