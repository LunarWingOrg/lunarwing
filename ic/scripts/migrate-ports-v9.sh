#!/usr/bin/env bash
#
# Migrate the multi-tenant port registry from v8 to v9.
#
# v8 left extended_ports.reserved_5..9 unnamed. v9 dedicates reserved_5 as the
# per-tenant LunarVision OCR/vision sidecar port (each tenant's sidecar
# container is bound 127.0.0.1:<vision_service> — the in-tree WASM tool
# `vision-analyze` reaches it via $VISION_SERVICE_URL):
#   extended_ports.reserved_5 -> vision_service   (= extended_base + 5)
#
# Falls back to extended_base+5 when the reserved slot is missing (e.g. a
# tenant whose block predates the reserved range, which would only happen for
# registries created before v6).
#
# Idempotent: a no-op if the registry is already at v9 (or newer).
# Safe: backs up first, validates port uniqueness, then swaps atomically.
#
# Usage:
#   sudo ./migrate-ports-v9.sh
#   PORTS_REGISTRY=/path/to/copy.json ./migrate-ports-v9.sh   # dry-run on a copy
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

if [[ "$current_version" -ge 9 ]]; then
  echo "already at v${current_version}, nothing to do"
  exit 0
fi

if [[ "$current_version" -lt 8 ]]; then
  echo "error: registry at v${current_version}; run migrate-ports-v8.sh first" >&2
  exit 1
fi

backup="${PORTS_REGISTRY}.bak.$(date -u +%Y%m%d%H%M%S)"
cp -p "$PORTS_REGISTRY" "$backup"
echo "backed up registry to $backup"

tmp="$(mktemp "$PORTS_REGISTRY.tmp.XXXXXX")"
jq '
  .version = 9
  | .tenants |= with_entries(
      .value |= (
        .extended_base as $eb
        | .extended_ports |= (
            if type == "object" then
              .vision_service = ((.vision_service) // (.reserved_5) // ($eb + 5))
              | del(.reserved_5)
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

echo "port registry migrated to v9 (vision_service dedicated at extended_base+5)"
echo "rollback if needed: cp $backup $PORTS_REGISTRY"
