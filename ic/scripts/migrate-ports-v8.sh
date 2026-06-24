#!/usr/bin/env bash
#
# Migrate the multi-tenant port registry from v7 to v8.
#
# v7 left extended_ports.reserved_3..9 unnamed. v8 dedicates two of them as
# per-tenant worker health ports so each tenant's nanocode/pebble worker can
# publish a distinct host-side health endpoint (the host self-heal pipeline can
# then probe /health directly instead of relying on in-container `podman exec`):
#   extended_ports.reserved_3 -> nanocode_health  (= extended_base + 3)
#   extended_ports.reserved_4 -> pebble_health    (= extended_base + 4)
#
# Falls back to extended_base+3 / +4 when the reserved slots are missing
# (e.g. a tenant whose block predates the reserved range).
#
# Idempotent: a no-op if the registry is already at v8 (or newer).
# Safe: backs up first, validates port uniqueness, then swaps atomically.
#
# Usage:
#   sudo ./migrate-ports-v8.sh
#   PORTS_REGISTRY=/path/to/copy.json ./migrate-ports-v8.sh   # dry-run on a copy
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

if [[ "$current_version" -ge 8 ]]; then
  echo "already at v${current_version}, nothing to do"
  exit 0
fi

if [[ "$current_version" -lt 7 ]]; then
  echo "error: registry at v${current_version}; run migrate-ports-v7.sh first" >&2
  exit 1
fi

backup="${PORTS_REGISTRY}.bak.$(date -u +%Y%m%d%H%M%S)"
cp -p "$PORTS_REGISTRY" "$backup"
echo "backed up registry to $backup"

tmp="$(mktemp "$PORTS_REGISTRY.tmp.XXXXXX")"
jq '
  .version = 8
  | .tenants |= with_entries(
      .value |= (
        .extended_base as $eb
        | .extended_ports |= (
            if type == "object" then
              .nanocode_health = ((.nanocode_health) // (.reserved_3) // ($eb + 3))
              | .pebble_health = ((.pebble_health) // (.reserved_4) // ($eb + 4))
              | del(.reserved_3, .reserved_4)
            else . end
          )
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

echo "port registry migrated to v8 (nanocode_health + pebble_health dedicated)"
echo "rollback if needed: cp $backup $PORTS_REGISTRY"
