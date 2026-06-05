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

if [[ "$current_version" -ge 5 ]]; then
  echo "already at v${current_version}, nothing to do"
  exit 0
fi

tmp="$(mktemp "$PORTS_REGISTRY.tmp.XXXXXX")"
jq '
  .version = 5 |
  .tenants |= with_entries(
    .value.ports |= (
      if .reserved_3 then
        .weechat_adapter = .reserved_3 | del(.reserved_3)
      else
        . + { weechat_adapter: (.orchestrator + 3) }
      end
    )
  )
' "$PORTS_REGISTRY" >"$tmp"
chmod 0644 "$tmp"
mv "$tmp" "$PORTS_REGISTRY"

echo "port registry migrated from v${current_version} to v5"
