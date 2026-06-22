#!/usr/bin/env bash
#
# Migrate the multi-tenant port registry from v6 to v6.1.
#
# v6 populated the extended port range with reserved_0..reserved_9.
# v6.1 renames extended_ports.reserved_0 -> darkirc_adapter for each tenant.
#
# Idempotent: a no-op if every tenant already has darkirc_adapter.
# Safe: backs up first, validates port uniqueness, then swaps atomically.
#
# Usage:
#   sudo ./migrate-ports-v6.1.sh
#   PORTS_REGISTRY=/path/to/copy.json ./migrate-ports-v6.1.sh   # dry-run on a copy
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

if [[ "$current_version" -lt 6 ]]; then
  echo "error: registry at v${current_version}; run migrate-ports-v6.sh first" >&2
  exit 1
fi

if jq -e '.tenants | to_entries[] | select(.value.extended_ports | has("darkirc_adapter") | not)' "$PORTS_REGISTRY" >/dev/null 2>&1; then
  :
else
  echo "already at v6.1 (all tenants have darkirc_adapter), nothing to do"
  exit 0
fi

backup="${PORTS_REGISTRY}.bak.$(date -u +%Y%m%d%H%M%S)"
cp -p "$PORTS_REGISTRY" "$backup"
echo "backed up registry to $backup"

tmp="$(mktemp "$PORTS_REGISTRY.tmp.XXXXXX")"
jq '
  .tenants |= with_entries(
    .value |= (
      if (.extended_ports | type == "object") and (.extended_ports | has("darkirc_adapter") | not) then
        .extended_ports.darkirc_adapter = .extended_ports.reserved_0
        | if (.extended_ports.reserved_0) then .extended_ports |= del(.reserved_0) else . end
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

echo "port registry migrated to v6.1 (darkirc_adapter added)"
echo "rollback if needed: cp $backup $PORTS_REGISTRY"
