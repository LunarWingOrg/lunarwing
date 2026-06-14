#!/usr/bin/env bash
#
# Migrate the multi-tenant port registry from schema v5 to v6.
#
# v5 packed each tenant into a single 10-port block (offsets 0-9), and all ten
# offsets are now assigned to services -- there is no free slot left for a new
# service type. v6 fixes this *without moving any existing port*: every tenant
# keeps its existing base_port and .ports block untouched, and gains a parallel
# block mirrored into a second range (20000-29999) that holds fresh reserved_N
# slots for future services.
#
#   extended_base = base_port - range.start + extended_range.start   (= base_port + 10000)
#   extended_ports = { reserved_0: extended_base+0, ... reserved_9: extended_base+9 }
#
# Because base_ports are unique and spaced >= block_size apart, the mirrored
# extended blocks never overlap each other or the original range. Future service
# additions rename extended_ports.reserved_N -> <service>, exactly like the
# v2->v5 migrations did with the original reserved slots.
#
# Idempotent: a no-op if the registry is already at v6 (or newer).
# Safe: backs up first, validates for port collisions, and only swaps the
# registry in atomically if validation passes.
#
# Usage:
#   sudo ./migrate-ports-v6.sh
#   PORTS_REGISTRY=/path/to/copy.json ./migrate-ports-v6.sh   # dry-run on a copy
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

if [[ "$current_version" -ge 6 ]]; then
  echo "already at v${current_version}, nothing to do"
  exit 0
fi

# Back up before a structural change.
backup="${PORTS_REGISTRY}.bak.$(date -u +%Y%m%d%H%M%S)"
cp -p "$PORTS_REGISTRY" "$backup"
echo "backed up registry to $backup"

tmp="$(mktemp "$PORTS_REGISTRY.tmp.XXXXXX")"
jq '
  .version = 6
  | .extended_range = { "start": 20000, "end": 29999 }
  | .extended_block_size = (.block_size // 10)
  | ( .range.start // 10000 ) as $rstart
  | ( .extended_range.start ) as $estart
  | ( .extended_block_size ) as $bs
  | .tenants |= with_entries(
      .value |= (
        if .base_port then
          ( .base_port - $rstart + $estart ) as $eb
          | .extended_base = $eb
          | .extended_ports = (
              reduce range(0; $bs) as $i ({}; . + { ("reserved_\($i)"): ($eb + $i) })
            )
        else . end
      )
    )
' "$PORTS_REGISTRY" >"$tmp"

# Validate: every port across all tenants (original .ports + .extended_ports)
# must be unique. Abort without touching the live registry on any collision.
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

echo "port registry migrated from v${current_version} to v6 (extended range 20000-29999 added)"
echo "rollback if needed: cp $backup $PORTS_REGISTRY"
