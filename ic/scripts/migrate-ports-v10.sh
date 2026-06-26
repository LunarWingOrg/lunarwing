#!/usr/bin/env bash
#
# Migrate the multi-tenant port registry from v9 to v10.
#
# v9 dedicated vision_service (extended_base+5) for the OCR/vision sidecar's
# main API port. v10 dedicates a SEPARATE health port so the host self-heal
# pipeline can probe /health independently of OCR traffic:
#   extended_ports.reserved_6 -> vision_health   (= extended_base + 6)
#
# The vision sidecar listens on two internal ports:
#   8088 (OCR_PORT)        — /ocr, /vision/analyze, /vision/metrics, etc.
#   8089 (OCR_HEALTH_PORT) — /health only
#
# Each tenant maps:
#   vision_service (host) -> 8088 (container)
#   vision_health  (host) -> 8089 (container)
#
# Falls back to extended_base+6 when the reserved slot is missing (e.g. a
# tenant whose block predates the reserved range, which would only happen
# for registries created before v6).
#
# Idempotent: a no-op if the registry is already at v10 (or newer).
# Safe: backs up first, validates port uniqueness, then swaps atomically.
#
# Usage:
#   sudo ./migrate-ports-v10.sh
#   PORTS_REGISTRY=/path/to/copy.json ./migrate-ports-v10.sh   # dry-run on a copy
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

if [[ "$current_version" -ge 10 ]]; then
  echo "already at v${current_version}, nothing to do"
  exit 0
fi

if [[ "$current_version" -lt 9 ]]; then
  echo "error: registry at v${current_version}; run migrate-ports-v9.sh first" >&2
  exit 1
fi

backup="${PORTS_REGISTRY}.bak.$(date -u +%Y%m%d%H%M%S)"
cp -p "$PORTS_REGISTRY" "$backup"
echo "backed up registry to $backup"

tmp="$(mktemp "$PORTS_REGISTRY.tmp.XXXXXX")"
jq '
  .version = 10
  | .tenants |= with_entries(
      .value |= (
        .extended_base as $eb
        | .extended_ports |= (
            if type == "object" then
              .vision_health = ((.vision_health) // (.reserved_6) // ($eb + 6))
              | del(.reserved_6)
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

echo "port registry migrated to v10 (vision_health dedicated at extended_base+6)"
echo "rollback if needed: cp $backup $PORTS_REGISTRY"
