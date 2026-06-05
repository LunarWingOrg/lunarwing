#!/usr/bin/env bash
set -euo pipefail

PORTS_REGISTRY="/etc/lunarwing/ports.json"

if [[ $EUID -ne 0 ]]; then
  echo "error: must run as root" >&2
  exit 1
fi

if [[ ! -f "$PORTS_REGISTRY" ]]; then
  echo "error: $PORTS_REGISTRY not found" >&2
  exit 1
fi

current_version="$(jq -r '.version // 0' "$PORTS_REGISTRY")"

if [[ "$current_version" -ge 4 ]]; then
  echo "already at v${current_version}, nothing to do"
  exit 0
fi

tmp="$(mktemp "$PORTS_REGISTRY.tmp.XXXXXX")"
jq '
  .version = 4 |
  .tenants |= with_entries(
    .value.ports |= (
      if .reserved_2 then
        .pebble_wss = .reserved_2 | del(.reserved_2)
      else
        . + { pebble_wss: (.orchestrator + 2) }
      end
    )
  )
' "$PORTS_REGISTRY" >"$tmp"
chmod 0644 "$tmp"
mv "$tmp" "$PORTS_REGISTRY"

echo "port registry migrated from v${current_version} to v4"
