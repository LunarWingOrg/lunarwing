#!/usr/bin/env bash
set -euo pipefail

# ── Port Registry v10 → v11 Migration ─────────────────────────────────────────
#
# Renames extended_ports.reserved_7 → opencode_wss and
# extended_ports.reserved_8 → opencode_health for every tenant in the registry.
# If reserved_7/reserved_8 are absent, assigns from extended_base + 7 / + 8.
#
# Usage:
#   ./migrate-ports-v10-to-v11.sh [PORTS_JSON_PATH] [--dry-run]
#
# Defaults to /etc/lunarwing/ports.json.

PORTS_REGISTRY="${1:-/etc/lunarwing/ports.json}"
DRY_RUN=false

# Parse flags
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    -*) ;; # ignore unknown flags
    *) PORTS_REGISTRY="$arg" ;;
  esac
done

if [[ ! -f "$PORTS_REGISTRY" ]]; then
  echo "error: ports registry not found at $PORTS_REGISTRY" >&2
  exit 1
fi

command -v jq >/dev/null 2>&1 || {
  echo "error: jq is required" >&2
  exit 1
}

current_version="$(jq -r '.version // 0' "$PORTS_REGISTRY")"

if [[ "$current_version" -ge 11 ]]; then
  echo "port registry is already v${current_version} — nothing to migrate"
  exit 0
fi

if [[ "$current_version" -lt 10 ]]; then
  echo "error: registry at v${current_version}; run migrate-ports-v10.sh first" >&2
  exit 1
fi

echo "current registry version: v${current_version}"
echo "migrating → v11 (add opencode_wss + opencode_health)"

# ── Dry-run: show what would change ────────────────────────────────────────────
if [[ "$DRY_RUN" == "true" ]]; then
  echo ""
  echo "[dry-run] changes that would be applied:"
  jq -r '.tenants | to_entries[] |
    .key as $name |
    .value.extended_base as $eb |
    "  \($name): opencode_wss=\($eb + 7), opencode_health=\($eb + 8)"
  ' "$PORTS_REGISTRY" 2>/dev/null || echo "  (no tenants to display)"
  echo ""
  echo "[dry-run] no changes written."
  exit 0
fi

# ── Backup ─────────────────────────────────────────────────────────────────────
backup="${PORTS_REGISTRY}.bak.$(date -u +%Y%m%d%H%M%S)"
cp -p "$PORTS_REGISTRY" "$backup"
echo "backed up registry to $backup"

# ── Migrate ────────────────────────────────────────────────────────────────────
tmp="$(mktemp "${PORTS_REGISTRY}.tmp.XXXXXX")"

jq '
  .version = 11
  | .tenants |= with_entries(
      .value |= (
        if (.extended_ports | type == "object") then
          .extended_base as $eb
          | .extended_ports |= (
              .opencode_wss = ((.opencode_wss) // (.reserved_7) // ($eb + 7))
              | .opencode_health = ((.opencode_health) // (.reserved_8) // ($eb + 8))
              | del(.reserved_7, .reserved_8)
            )
        else . end
      )
    )
' "$PORTS_REGISTRY" >"$tmp"

# Validate port uniqueness before committing — abort without touching the
# live registry if the migration would create any colliding ports.
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

# ── Summary ────────────────────────────────────────────────────────────────────
echo ""
echo "migration complete. summary:"
jq -r '.tenants | to_entries[] |
  "  \(.key): opencode_wss=\(.value.extended_ports.opencode_wss), opencode_health=\(.value.extended_ports.opencode_health)"
' "$PORTS_REGISTRY" 2>/dev/null || echo "  (no tenants)"

new_version="$(jq -r '.version' "$PORTS_REGISTRY")"
echo ""
echo "registry version is now v${new_version}"
echo "rollback if needed: cp $backup $PORTS_REGISTRY"
