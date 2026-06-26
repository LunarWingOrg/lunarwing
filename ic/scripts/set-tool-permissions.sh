#!/usr/bin/env bash
#
# set-tool-permissions.sh — grant "always_allow" tool permissions for a
# LunarWing tenant by upserting rows into the agent `settings` table.
#
# Postgres runs in the tenant's rootless Podman container (lunarwing-pg-<tenant>),
# so we hop into the tenant user with sudo + the correct XDG_RUNTIME_DIR before
# calling `podman exec ... psql`.
#
set -euo pipefail

# ---- defaults (override via environment) ------------------------------------
PG_USER="${PG_USER:-lunarwing}"
PG_DB="${PG_DB:-lunarwing}"
SETTINGS_USER_ID="${SETTINGS_USER_ID:-default}"

# Tools to flip to always_allow. Override: PERMISSIONS="read_file shell" ./script ...
read -r -a PERMISSIONS <<< "${PERMISSIONS:-read_file write_file list_dir apply_patch shell}"

# ---- arg parsing -------------------------------------------------------------
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: set-tool-permissions.sh [--dry-run] <tenant>
       TENANT=<tenant> set-tool-permissions.sh

Grants "always_allow" tool permissions for a LunarWing tenant by upserting
rows into the agent settings table inside lunarwing-pg-<tenant>.

Options:
  -n, --dry-run   Print the SQL that would run, then exit.
  -h, --help      Show this help.

Environment overrides:
  PG_USER          Postgres role            (default: lunarwing)
  PG_DB            Postgres database        (default: lunarwing)
  SETTINGS_USER_ID settings.user_id to set  (default: default)
  CONTAINER        Container name           (default: lunarwing-pg-<tenant>)
  PERMISSIONS      Space-separated tools    (default: read_file write_file
                   list_dir apply_patch shell)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--dry-run) DRY_RUN=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    --)           shift; break ;;
    -*)           echo "Unknown option: $1" >&2; exit 64 ;;
    *)            break ;;
  esac
done

TENANT="${1:-${TENANT:-}}"

if [[ -z "$TENANT" ]]; then
  echo "Usage: $0 [--dry-run] <tenant>   (or set TENANT=<tenant>)" >&2
  exit 64
fi

CONTAINER="${CONTAINER:-lunarwing-pg-${TENANT}}"

# ---- build SQL ---------------------------------------------------------------
nl=$'\n'
values=""
for perm in "${PERMISSIONS[@]}"; do
  row="  ('${SETTINGS_USER_ID}', 'tool_permissions.${perm}', '\"always_allow\"'::jsonb, now())"
  values+="${values:+,$nl}${row}"
done

sql=$(cat <<SQL
INSERT INTO settings (user_id, key, value, updated_at) VALUES
${values}
ON CONFLICT (user_id, key) DO UPDATE
  SET value = EXCLUDED.value, updated_at = now()
RETURNING user_id, key, value, updated_at;
SQL
)

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "# DRY RUN — SQL for container '${CONTAINER}':"
  printf '%s\n' "$sql"
  exit 0
fi

# ---- validate runtime --------------------------------------------------------
if ! TENANT_UID="$(id -u "$TENANT" 2>/dev/null)"; then
  echo "Error: system user '$TENANT' does not exist." >&2
  exit 1
fi

RUNTIME_DIR="/run/user/${TENANT_UID}"
if [[ ! -d "$RUNTIME_DIR" ]]; then
  echo "Error: ${RUNTIME_DIR} not found — is the tenant session active?" >&2
  echo "Hint: sudo loginctl enable-linger ${TENANT}" >&2
  exit 1
fi

run_podman() {
  sudo -u "$TENANT" XDG_RUNTIME_DIR="$RUNTIME_DIR" podman "$@"
}

if ! run_podman container exists "$CONTAINER"; then
  echo "Error: container '$CONTAINER' not found for tenant '$TENANT'." >&2
  exit 1
fi

# ---- execute -----------------------------------------------------------------
echo "Applying ${#PERMISSIONS[@]} tool permission(s) to '${CONTAINER}' (user_id='${SETTINGS_USER_ID}')..."

run_podman exec "$CONTAINER" \
  psql -v ON_ERROR_STOP=1 -U "$PG_USER" -d "$PG_DB" -c "$sql"
