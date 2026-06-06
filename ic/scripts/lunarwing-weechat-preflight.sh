#!/usr/bin/env bash
#
# lunarwing-weechat-preflight.sh — read-only pre-flight for the WeeChat
# multi-tenant port fix.
#
# Verifies that each tenant's lunarwing.env agrees with its registry-allocated
# WeeChat ports BEFORE you install-wasm / patch-env / restart, so a bad env
# file is caught up front instead of after a restart. It is strictly read-only:
# it never writes, never restarts a service, and never prints secret values.
#
# Why this matters: `mt-admin patch-env` is idempotent and SKIPS any variable
# that is already present. So a *wrong* existing RELAY_URL / WS_ADAPTER_URL is
# NOT auto-corrected — patch-env leaves it as-is. Those cases are reported as
# FAIL here. A *missing* variable is only a WARN (patch-env will add it).
#
# Per tenant it checks:
#   RELAY_URL             port == registry `weechat`          (base+5)
#   WS_ADAPTER_URL        port == registry `weechat_adapter`  (base+9)
#   ADAPTER_PORT          == registry `weechat_adapter`  (Python adapter binds this)
#   WEECHAT_ADAPTER_PORT  == registry `weechat_adapter`
#   RELAY_PASSWORD        present (value never printed)
#   installed weechat.capabilities.json declares the `env` sources
#   (best-effort) adapter /api/health
#
# Usage:
#   sudo ic/scripts/lunarwing-weechat-preflight.sh [tenant]
#     (no args)  check every registered tenant
#     <tenant>   check just that tenant
#
# Exit status:
#   0  all consistent (warnings allowed — those are the expected backfill steps)
#   1  one or more FAILs (genuine drift — resolve before restarting)
#   2  setup error (missing jq / registry / bad args)
#
# Env overrides (mainly for testing):
#   LUNARWING_PORTS_REGISTRY   default /etc/lunarwing/ports.json
#   LUNARWING_TENANT_HOME_BASE default /home

set -euo pipefail

PORTS_REGISTRY="${LUNARWING_PORTS_REGISTRY:-/etc/lunarwing/ports.json}"
TENANT_HOME_BASE="${LUNARWING_TENANT_HOME_BASE:-/home}"

say() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 2; }

# Colors only when stdout is a terminal.
if [[ -t 1 ]]; then
  C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_FAIL=$'\033[31m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
else
  C_OK=""; C_WARN=""; C_FAIL=""; C_DIM=""; C_RST=""
fi

command -v jq >/dev/null 2>&1 || die "required command not found: jq"
[[ -f "$PORTS_REGISTRY" ]] || die "port registry not found: $PORTS_REGISTRY (run add-tenant first?)"

fail_total=0
warn_total=0
tenant_total=0

tenant_lw_root() { printf '%s/%s/lunarwing' "$TENANT_HOME_BASE" "$1"; }

# Extract the trailing :PORT from a URL (tolerates a trailing slash).
url_port() {
  local u="${1%/}"
  printf '%s' "${u##*:}"
}

# Read one KEY from an env file WITHOUT sourcing it (no code execution).
# Returns the last definition; strips a trailing CR and optional quotes.
env_get() {
  local file="$1" key="$2" line
  line="$(grep -E "^${key}=" "$file" 2>/dev/null | tail -n1 || true)"
  [[ -n "$line" ]] || { printf ''; return 0; }
  line="${line#*=}"
  line="${line%$'\r'}"
  line="${line%\"}"; line="${line#\"}"
  printf '%s' "$line"
}

mark() { # $1=OK|WARN|FAIL|INFO  $2=label  $3=detail
  local c=""
  case "$1" in
    OK)   c="$C_OK" ;;
    WARN) c="$C_WARN"; warn_total=$((warn_total + 1)) ;;
    FAIL) c="$C_FAIL"; fail_total=$((fail_total + 1)) ;;
    INFO) c="$C_DIM" ;;
  esac
  printf '    %s[%-4s]%s %-22s %s\n' "$c" "$1" "$C_RST" "$2" "$3"
}

check_tenant() {
  local name="$1"
  tenant_total=$((tenant_total + 1))

  local lw env_file caps_file
  lw="$(tenant_lw_root "$name")"
  env_file="$lw/env/lunarwing.env"
  caps_file="$lw/state/channels/weechat.capabilities.json"

  printf '%s== %s ==%s\n' "$C_DIM" "$name" "$C_RST"

  local rec_weechat rec_adapter
  rec_weechat="$(jq -r ".tenants[\"$name\"].ports.weechat // empty" "$PORTS_REGISTRY")"
  rec_adapter="$(jq -r ".tenants[\"$name\"].ports.weechat_adapter // empty" "$PORTS_REGISTRY")"

  if [[ -z "$rec_weechat" && -z "$rec_adapter" ]]; then
    mark INFO "registry" "no WeeChat ports allocated for this tenant — skipping"
    say ""
    return 0
  fi

  if [[ ! -e "$env_file" ]]; then
    mark FAIL "env file" "missing: $env_file"
    say ""
    return 0
  fi
  if [[ ! -r "$env_file" ]]; then
    mark WARN "env file" "not readable — run with sudo: $env_file"
    say ""
    return 0
  fi

  local relay_url ws_url adapter_port wc_adapter_port relay_pw
  relay_url="$(env_get "$env_file" RELAY_URL)"
  ws_url="$(env_get "$env_file" WS_ADAPTER_URL)"
  adapter_port="$(env_get "$env_file" ADAPTER_PORT)"
  wc_adapter_port="$(env_get "$env_file" WEECHAT_ADAPTER_PORT)"
  relay_pw="$(env_get "$env_file" RELAY_PASSWORD)"

  # RELAY_URL vs registry `weechat`.
  if [[ -n "$rec_weechat" ]]; then
    if [[ -z "$relay_url" ]]; then
      mark WARN "RELAY_URL" "missing — patch-env will add http://127.0.0.1:$rec_weechat"
    elif [[ "$(url_port "$relay_url")" == "$rec_weechat" ]]; then
      mark OK "RELAY_URL" "$relay_url"
    else
      mark FAIL "RELAY_URL" "$relay_url  (expected port $rec_weechat) — patch-env will NOT overwrite this"
    fi
  fi

  # WS_ADAPTER_URL + adapter ports vs registry `weechat_adapter`.
  if [[ -n "$rec_adapter" ]]; then
    if [[ -z "$ws_url" ]]; then
      mark WARN "WS_ADAPTER_URL" "missing — run 'patch-env $name' to add http://127.0.0.1:$rec_adapter"
    elif [[ "$(url_port "$ws_url")" == "$rec_adapter" ]]; then
      mark OK "WS_ADAPTER_URL" "$ws_url"
    else
      mark FAIL "WS_ADAPTER_URL" "$ws_url  (expected port $rec_adapter) — patch-env will NOT overwrite this"
    fi

    if [[ -n "$adapter_port" && "$adapter_port" != "$rec_adapter" ]]; then
      mark FAIL "ADAPTER_PORT" "$adapter_port  (expected $rec_adapter) — adapter binds the wrong port"
    fi
    if [[ -n "$wc_adapter_port" && "$wc_adapter_port" != "$rec_adapter" ]]; then
      mark FAIL "WEECHAT_ADAPTER_PORT" "$wc_adapter_port  (expected $rec_adapter)"
    fi
  fi

  # RELAY_PASSWORD presence only — never print the value.
  if [[ -n "$relay_pw" ]]; then
    mark OK "RELAY_PASSWORD" "set (${#relay_pw} chars) — WASM will authenticate to the adapter"
  else
    mark INFO "RELAY_PASSWORD" "empty/unset — adapter accepts unauthenticated local requests"
  fi

  # Installed capabilities: do they declare the `env` sources yet?
  if [[ -e "$caps_file" ]]; then
    if [[ -r "$caps_file" ]]; then
      local env_fields
      env_fields="$(jq -r '[.setup.required_fields[]? | select(.env)] | length' "$caps_file" 2>/dev/null || printf '0')"
      if [[ "$env_fields" =~ ^[0-9]+$ && "$env_fields" -ge 1 ]]; then
        mark OK "capabilities" "installed caps declare env sources ($env_fields)"
      else
        mark WARN "capabilities" "installed caps lack env sources — run 'install-wasm $name' before restart"
      fi
    else
      mark WARN "capabilities" "not readable — run with sudo: $caps_file"
    fi
  else
    mark INFO "capabilities" "weechat channel not installed for this tenant"
  fi

  # Best-effort adapter health (never fatal; adapter may be stopped pre-restart).
  if [[ -n "$rec_adapter" ]] && command -v curl >/dev/null 2>&1; then
    local health
    if health="$(curl -fsS --max-time 2 "http://127.0.0.1:$rec_adapter/api/health" 2>/dev/null)"; then
      mark OK "adapter health" "$health"
    else
      mark INFO "adapter health" "no response on :$rec_adapter (adapter may be stopped pre-restart)"
    fi
  fi

  say ""
}

main() {
  local names=()
  if [[ $# -gt 1 ]]; then
    die "usage: lunarwing-weechat-preflight.sh [tenant]"
  elif [[ $# -eq 1 ]]; then
    jq -e ".tenants[\"$1\"]" "$PORTS_REGISTRY" >/dev/null 2>&1 \
      || die "tenant '$1' not found in $PORTS_REGISTRY"
    names=("$1")
  else
    mapfile -t names < <(jq -r '.tenants | keys[]' "$PORTS_REGISTRY" 2>/dev/null)
  fi

  if [[ ${#names[@]} -eq 0 ]]; then
    say "no tenants registered in $PORTS_REGISTRY"
    return 0
  fi

  say "WeeChat multi-tenant pre-flight  (registry: $PORTS_REGISTRY)"
  say ""
  local n
  for n in "${names[@]}"; do
    check_tenant "$n"
  done

  say "----------------------------------------------------------------"
  if [[ "$fail_total" -gt 0 ]]; then
    printf '%sFAIL%s  %d failing check(s), %d warning(s), %d tenant(s)\n' \
      "$C_FAIL" "$C_RST" "$fail_total" "$warn_total" "$tenant_total"
    say "Resolve FAILs before restarting — a wrong *existing* env value is not auto-corrected by patch-env."
    return 1
  elif [[ "$warn_total" -gt 0 ]]; then
    printf '%sOK (with warnings)%s  %d warning(s), %d tenant(s)\n' \
      "$C_WARN" "$C_RST" "$warn_total" "$tenant_total"
    say "Warnings are the expected backfill steps: run 'install-wasm <name>' and/or 'patch-env <name>', then restart."
    return 0
  else
    printf '%sOK%s  all %d tenant(s) consistent — safe to install-wasm / patch-env / restart\n' \
      "$C_OK" "$C_RST" "$tenant_total"
    return 0
  fi
}

main "$@"
