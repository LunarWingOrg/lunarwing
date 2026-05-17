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

if [[ "$current_version" -ge 3 ]]; then
  echo "already at v${current_version}, nothing to do"
  exit 0
fi

tmp="$(mktemp "$PORTS_REGISTRY.tmp.XXXXXX")"
jq '
  .version = 3 |
  .tenants |= with_entries(
    .value.ports |= (
      if .reserved_1 then
        .nanocode_wss = .reserved_1 | del(.reserved_1)
      else
        . + { nanocode_wss: (.orchestrator + 1) }
      end
    )
  )
' "$PORTS_REGISTRY" >"$tmp"
chmod 0644 "$tmp"
mv "$tmp" "$PORTS_REGISTRY"

echo "port registry migrated from v${current_version} to v3"
