#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run with sudo: sudo scripts/install-lunarwing-watchdog.sh" >&2
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
WATCHDOG_LOG="/var/log/lunarwing-watchdog.log"
SYSTEMD_UNIT_DIR="/etc/systemd/system"
OPENRC_CONFD="/etc/conf.d/lunarwing-watchdog"
OPENRC_WRAPPER="/usr/local/sbin/lunarwing-watchdog-openrc"
SYSTEMD_WRAPPER="/usr/local/sbin/lunarwing-watchdog"
FCRON_MARKER_BEGIN="# BEGIN lunarwing-watchdog managed block"
FCRON_MARKER_END="# END lunarwing-watchdog managed block"
LEGACY_FCRON_MARKER_BEGIN="# BEGIN ironclaw-watchdog managed block"
LEGACY_FCRON_MARKER_END="# END ironclaw-watchdog managed block"

say() {
  printf '%s\n' "$*"
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

binary_exists() {
  command -v "$1" >/dev/null 2>&1
}

detect_service_manager() {
  local override="${LUNARWING_SERVICE_MANAGER:-${IRONCLAW_SERVICE_MANAGER:-}}"
  if [[ -n "$override" ]]; then
    case "${override,,}" in
      systemd|systemd-user)
        printf 'systemd'
        return 0
        ;;
      openrc)
        printf 'openrc'
        return 0
        ;;
      *)
        die "unsupported service manager override '$override'; use systemd or openrc"
        ;;
    esac
  fi

  if [[ -e /run/openrc/softlevel ]]; then
    printf 'openrc'
    return 0
  fi
  if [[ -e /run/systemd/system ]]; then
    printf 'systemd'
    return 0
  fi
  if binary_exists rc-service && binary_exists rc-update && ! binary_exists systemctl; then
    printf 'openrc'
    return 0
  fi
  if binary_exists systemctl; then
    printf 'systemd'
    return 0
  fi
  if binary_exists rc-service && binary_exists rc-update; then
    printf 'openrc'
    return 0
  fi

  die "could not detect a supported service manager; set LUNARWING_SERVICE_MANAGER=systemd or openrc"
}

ensure_log_file() {
  touch "$WATCHDOG_LOG"
  chown root:root "$WATCHDOG_LOG"
  chmod 0644 "$WATCHDOG_LOG"
}

cleanup_legacy_names() {
  if binary_exists systemctl; then
    systemctl disable --now ironclaw-watchdog.timer >/dev/null 2>&1 || true
    systemctl disable --now ironclaw-watchdog.service >/dev/null 2>&1 || true
  fi

  rm -f \
    "${SYSTEMD_UNIT_DIR}/ironclaw-watchdog.service" \
    "${SYSTEMD_UNIT_DIR}/ironclaw-watchdog.timer" \
    /usr/local/sbin/ironclaw-watchdog \
    /usr/local/sbin/ironclaw-watchdog-openrc \
    /etc/cron.hourly/ironclaw-watchdog \
    /etc/periodic/hourly/ironclaw-watchdog

  cleanup_openrc_fcron_entry
}

cleanup_systemd_watchdog() {
  if binary_exists systemctl; then
    systemctl disable --now lunarwing-watchdog.timer >/dev/null 2>&1 || true
    systemctl disable --now lunarwing-watchdog.service >/dev/null 2>&1 || true
  fi
  rm -f \
    "${SYSTEMD_UNIT_DIR}/lunarwing-watchdog.service" \
    "${SYSTEMD_UNIT_DIR}/lunarwing-watchdog.timer" \
    "${SYSTEMD_WRAPPER}"
}

cleanup_openrc_hourly_watchdog() {
  rm -f \
    /etc/cron.hourly/lunarwing-watchdog \
    /etc/periodic/hourly/lunarwing-watchdog
}

cleanup_openrc_watchdog() {
  cleanup_openrc_hourly_watchdog
  rm -f "${OPENRC_WRAPPER}"
}

strip_managed_block() {
  local start_marker="$1"
  local end_marker="$2"
  awk -v start="$start_marker" -v end="$end_marker" '
    $0 == start { skip = 1; next }
    $0 == end { skip = 0; next }
    !skip { print }
  '
}

read_fcron_root_tab() {
  if ! binary_exists fcrontab; then
    return 1
  fi

  fcrontab -l root 2>/dev/null || true
}

cleanup_openrc_fcron_entry() {
  local current cleaned tmp

  binary_exists fcrontab || return 0

  current="$(read_fcron_root_tab)"
  cleaned="$(
    printf '%s\n' "$current" \
      | strip_managed_block "$FCRON_MARKER_BEGIN" "$FCRON_MARKER_END" \
      | strip_managed_block "$LEGACY_FCRON_MARKER_BEGIN" "$LEGACY_FCRON_MARKER_END"
  )"

  if [[ "$cleaned" == "$current" ]]; then
    return 0
  fi

  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' RETURN
  if [[ -n "$cleaned" ]]; then
    printf '%s\n' "$cleaned" >"$tmp"
  else
    : >"$tmp"
  fi
  fcrontab "$tmp" root
  rm -f "$tmp"
  trap - RETURN
}

install_openrc_fcron_entry() {
  local current cleaned tmp

  binary_exists fcrontab || die "fcron mode requires the fcrontab command"

  current="$(read_fcron_root_tab)"
  cleaned="$(
    printf '%s\n' "$current" \
      | strip_managed_block "$FCRON_MARKER_BEGIN" "$FCRON_MARKER_END" \
      | strip_managed_block "$LEGACY_FCRON_MARKER_BEGIN" "$LEGACY_FCRON_MARKER_END"
  )"

  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' RETURN
  if [[ -n "$cleaned" ]]; then
    printf '%s\n' "$cleaned" >"$tmp"
    printf '\n' >>"$tmp"
  else
    : >"$tmp"
  fi

  {
    printf '%s\n' "$FCRON_MARKER_BEGIN"
    printf '%%hourly %s\n' "$OPENRC_WRAPPER"
    printf '%s\n' "$FCRON_MARKER_END"
  } >>"$tmp"

  fcrontab "$tmp" root
  rm -f "$tmp"
  trap - RETURN
}

openrc_scheduler_dir() {
  if [[ -n "${LUNARWING_WATCHDOG_CRON_DIR:-}" ]]; then
    printf '%s' "$LUNARWING_WATCHDOG_CRON_DIR"
    return 0
  fi
  if [[ -d /etc/cron.hourly ]]; then
    printf '%s' "/etc/cron.hourly"
    return 0
  fi
  if [[ -d /etc/periodic/hourly ]]; then
    printf '%s' "/etc/periodic/hourly"
    return 0
  fi

  die "OpenRC watchdog install needs /etc/cron.hourly or /etc/periodic/hourly; set LUNARWING_WATCHDOG_CRON_DIR to override"
}

openrc_has_fcron() {
  binary_exists fcrontab || [[ -x /etc/init.d/fcron ]]
}

openrc_fcron_service_exists() {
  [[ -x /etc/init.d/fcron ]]
}

openrc_scheduler_service() {
  local service
  for service in cronie crond dcron; do
    if [[ -x "/etc/init.d/${service}" ]]; then
      printf '%s' "$service"
      return 0
    fi
  done
  return 1
}

detect_openrc_scheduler_mode() {
  local override="${LUNARWING_WATCHDOG_SCHEDULER:-auto}"
  override="${override,,}"

  case "$override" in
    ""|auto)
      if openrc_scheduler_service >/dev/null 2>&1; then
        printf '%s' "hourly"
        return 0
      fi
      if openrc_has_fcron; then
        printf '%s' "fcron"
        return 0
      fi
      printf '%s' "hourly"
      return 0
      ;;
    hourly|cron-hourly|periodic-hourly)
      printf '%s' "hourly"
      return 0
      ;;
    fcron)
      openrc_has_fcron || die "LUNARWING_WATCHDOG_SCHEDULER=fcron requires fcron/fcrontab to be installed"
      printf '%s' "fcron"
      return 0
      ;;
    *)
      die "unsupported OpenRC watchdog scheduler '$override'; use auto, hourly, or fcron"
      ;;
  esac
}

install_openrc_confd() {
  if [[ -f "$OPENRC_CONFD" ]]; then
    chmod 0644 "$OPENRC_CONFD"
    say "Preserved existing OpenRC watchdog config: $OPENRC_CONFD"
    return 0
  fi

  install -o root -g root -m 0644 \
    "${REPO_ROOT}/systemd/lunarwing-watchdog.confd" \
    "$OPENRC_CONFD"
  say "Installed OpenRC watchdog config: $OPENRC_CONFD"
}

install_systemd_watchdog() {
  cleanup_systemd_watchdog
  cleanup_openrc_watchdog
  cleanup_openrc_fcron_entry

  install -o root -g root -m 0755 \
    "${REPO_ROOT}/scripts/lunarwing-watchdog.sh" \
    "$SYSTEMD_WRAPPER"

  install -o root -g root -m 0644 \
    "${REPO_ROOT}/systemd/lunarwing-watchdog.service" \
    "${SYSTEMD_UNIT_DIR}/lunarwing-watchdog.service"

  install -o root -g root -m 0644 \
    "${REPO_ROOT}/systemd/lunarwing-watchdog.timer" \
    "${SYSTEMD_UNIT_DIR}/lunarwing-watchdog.timer"

  ensure_log_file

  systemctl daemon-reload
  systemctl enable --now lunarwing-watchdog.timer
  systemctl start lunarwing-watchdog.service

  say "Installed systemd watchdog timer."
  systemctl status lunarwing-watchdog.timer --no-pager
}

install_openrc_watchdog() {
  local schedule_mode scheduler_dir scheduler_hook scheduler_service
  schedule_mode="$(detect_openrc_scheduler_mode)"

  cleanup_systemd_watchdog
  cleanup_openrc_watchdog
  cleanup_openrc_fcron_entry

  install -o root -g root -m 0755 \
    "${REPO_ROOT}/scripts/lunarwing-watchdog-openrc.sh" \
    "$OPENRC_WRAPPER"

  install_openrc_confd

  ensure_log_file

  if [[ "$schedule_mode" == "fcron" ]]; then
    install_openrc_fcron_entry

    if openrc_fcron_service_exists; then
      rc-update add fcron default >/dev/null 2>&1 || true
      rc-service fcron start >/dev/null 2>&1 || true
      say "Installed OpenRC watchdog fcron entry for root."
      say "Scheduler service: fcron"
    else
      say "Installed OpenRC watchdog fcron entry for root."
      say "No OpenRC fcron init script detected automatically. Start fcron manually."
    fi

    say "Schedule mode: fcron"
    say "Auto mode only selects fcron when no cronie/crond/dcron hourly scheduler is already present."
  else
    scheduler_dir="$(openrc_scheduler_dir)"
    scheduler_hook="${scheduler_dir}/lunarwing-watchdog"

    install -o root -g root -m 0755 \
      "${REPO_ROOT}/systemd/lunarwing-watchdog.cron.hourly" \
      "$scheduler_hook"

    if scheduler_service="$(openrc_scheduler_service)"; then
      rc-update add "$scheduler_service" default >/dev/null 2>&1 || true
      rc-service "$scheduler_service" start >/dev/null 2>&1 || true
      say "Installed OpenRC watchdog scheduler hook: $scheduler_hook"
      say "Scheduler service: $scheduler_service"
    else
      say "Installed OpenRC watchdog scheduler hook: $scheduler_hook"
      say "No known hourly scheduler service detected automatically. Start your cron daemon manually."
    fi

    if [[ "$scheduler_dir" == "/etc/cron.hourly" ]]; then
      say "Schedule mode: cron.hourly"
    elif [[ "$scheduler_dir" == "/etc/periodic/hourly" ]]; then
      say "Schedule mode: periodic/hourly"
    else
      say "Schedule mode: custom ($scheduler_dir)"
    fi
    say "Auto mode prefers this path when an existing cronie/crond/dcron setup is present."
    say "Note: unlike the systemd timer, plain cron-style schedules do not replay missed runs after downtime."
    return 0
  fi

  say "Unlike the plain cron-hourly path, fcron can provide better catch-up behavior depending on your fcron policy."
}

cleanup_legacy_names

case "$(detect_service_manager)" in
  systemd)
    install_systemd_watchdog
    ;;
  openrc)
    install_openrc_watchdog
    ;;
  *)
    die "unsupported service manager"
    ;;
esac
