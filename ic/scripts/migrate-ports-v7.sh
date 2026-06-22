#!/usr/bin/env bash
#
# Migrate the multi-tenant port registry from v6.1 to v7.
#
# v6.1 assigned darkirc_adapter from extended_ports.reserved_0.
# v7 renames extended_ports.reserved_1 -> darkirc_irc and
#   extended_ports.reserved_2 -> darkirc_rpc for each tenant.
# Falls back to darkirc_adapter+1 / darkirc_adapter+2 when reserved slots
# are missing (e.g. fresh v6-created tenants that didn't run v6.1).
#
# Idempotent: a no-op if the registry is already at v7 (or newer).
# Safe: backs up first, validates port uniqueness, then swaps atomically.
#
# Usage:
#   sudo ./migrate-ports-v7.sh
#   PORTS_REGISTRY=/path/to/copy.json ./migrate-ports-v7.sh   # dry-run on a copy
#
set -euo pipefail

PORTS_REGISTRY="${PORTS_REGISTRY:-/etc/lunarwing/ports.json}"

# Root is only required when operating on the real system registry; a custom
# PORTS_REGISTRY (e.g. a backup copy for a dry run) can be migrated as any user.
if [[ "$PORTS_REGISTRY" == "/etc/lunarwing/ports.json" && $EUID -ne 0 ]]; then
  echo "error: must run as root" >&2
  exit 1
fi

if [[ ! -f "$PORTS_REGISTRY" ]]; then
  echo "error: $PORTS_REGISTRY not found" >&2
  exit 1
fi

command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 1; }

current_version="$(jq -r '.version // 0' "$PORTS_REGISTRY")"

if [[ "$current_version" -ge 7 ]]; then
  echo "already at v${current_version}, nothing to do"
  exit 0
fi

if [[ "$current_version" -lt 6 ]]; then
  echo "error: registry at v${current_version}; run migrate-ports-v6.sh and migrate-ports-v6.1.sh first" >&2
  exit 1
fi

backup="${PORTS_REGISTRY}.bak.$(date -u +%Y%m%d%H%M%S)"
cp -p "$PORTS_REGISTRY" "$backup"
echo "backed up registry to $backup"

tmp="$(mktemp "$PORTS_REGISTRY.tmp.XXXXXX")"
jq '
  .version = 7
  | .tenants |= with_entries(
      .value.extended_ports |= (
        if type == "object" then
          .darkirc_irc = ((.darkirc_irc) // (.reserved_1) // (.darkirc_adapter + 1))
          | .darkirc_rpc = ((.darkirc_rpc) // (.reserved_2) // (.darkirc_adapter + 2))
          | del(.reserved_1, .reserved_2)
        else . end
      )
    )
' "$PORTS_REGISTRY" >"$tmp"

collisions="$(jq -r '
  [ .tenants[]
    | ((.ports // {}) | to_entries[] | .value),
      ((.extended_ports // {}) | to_entries[] | .value)
  ]
  | group_by(.) | map(select(length > 1)) | length
' "$tmp")"

if [[ "$collisions" -ne 0 ]]; then
  echo "error: migration would create $collisions colliding port(s); aborting (registry unchanged)" >&2
  echo "       inspect the candidate output at: $tmp" >&2
  exit 1
fi

chmod 0644 "$tmp"
mv "$tmp" "$PORTS_REGISTRY"

echo "port registry migrated to v7 (darkirc_irc + darkirc_rpc added)"
echo "rollback if needed: cp $backup $PORTS_REGISTRY"
