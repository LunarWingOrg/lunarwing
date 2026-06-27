#!/usr/bin/env bash
#
# WARNING: THIS IS A DEV TOOL SCRIPT. NORMAL USERS HAVE NO REASON TO EVER RUN THIS SCRIPT
# set-sandbox-config.sh — configure agent sandbox settings for a LunarWing
# tenant by upserting rows into the agent `settings` table.
#
# Postgres runs in the tenant's rootless Podman container (lunarwing-pg-<tenant>),
# so we hop into the tenant user with sudo + the correct XDG_RUNTIME_DIR before
# calling `podman exec ... psql`. The SQL is built as literal text in bash;
# string values are SQL-escaped and JSON-encoded server-side via to_jsonb().
#
set -euo pipefail

# ---- defaults (override via environment) ------------------------------------
PG_USER="${PG_USER:-lunarwing}"
PG_DB="${PG_DB:-lunarwing}"
SETTINGS_USER_ID="${SETTINGS_USER_ID:-default}"

SANDBOX_ENABLED="${SANDBOX_ENABLED:-true}"
SANDBOX_POLICY="${SANDBOX_POLICY:-workspace_write}"
SANDBOX_TIMEOUT_SECS="${SANDBOX_TIMEOUT_SECS:-300}"
SANDBOX_IMAGE="${SANDBOX_IMAGE:-lunarwing-worker:latest}"

# ---- arg parsing -------------------------------------------------------------
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: set-sandbox-config.sh [--dry-run] <tenant>
       TENANT=<tenant> set-sandbox-config.sh

Configures agent sandbox settings for a LunarWing tenant by upserting rows
into the agent settings table inside lunarwing-pg-<tenant>.

Options:
  -n, --dry-run   Print the bindings + SQL that would run, then exit.
  -h, --help      Show this help.

Environment overrides:
  PG_USER               Postgres role          (default: lunarwing)
  PG_DB                 Postgres database      (default: lunarwing)
  SETTINGS_USER_ID      settings.user_id       (default: default)
  CONTAINER             Container name         (default: lunarwing-pg-<tenant>)
  SANDBOX_ENABLED       true | false           (default: true)
  SANDBOX_POLICY        policy string          (default: workspace_write)
  SANDBOX_TIMEOUT_SECS  integer seconds        (default: 300)
  SANDBOX_IMAGE         worker image ref       (default: lunarwing-worker:latest)
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

# ---- validate values ---------------------------------------------------------
case "$SANDBOX_ENABLED" in
  true|false) ;;
  *) echo "Error: SANDBOX_ENABLED must be 'true' or 'false' (got '$SANDBOX_ENABLED')." >&2; exit 64 ;;
esac

if ! [[ "$SANDBOX_TIMEOUT_SECS" =~ ^[0-9]+$ ]]; then
  echo "Error: SANDBOX_TIMEOUT_SECS must be a non-negative integer (got '$SANDBOX_TIMEOUT_SECS')." >&2
  exit 64
fi

# ---- build SQL ---------------------------------------------------------------
# psql -c does NOT perform :'var' interpolation (it ships the string to the
# server as-is), so we build literal SQL. ENABLED/TIMEOUT are validated above
# and embedded as jsonb scalars; the string values are SQL-escaped (single
# quotes doubled) and JSON-encoded server-side via to_jsonb(), so colons and
# dots in image refs are handled safely.
sql_lit() { local s=${1//\'/\'\'}; printf "'%s'" "$s"; }

uid_lit=$(sql_lit "$SETTINGS_USER_ID")
policy_lit=$(sql_lit "$SANDBOX_POLICY")
image_lit=$(sql_lit "$SANDBOX_IMAGE")

sql=$(cat <<SQL
INSERT INTO settings (user_id, key, value) VALUES
  (${uid_lit}, 'sandbox.enabled',      '${SANDBOX_ENABLED}'::jsonb),
  (${uid_lit}, 'sandbox.policy',       to_jsonb(${policy_lit}::text)),
  (${uid_lit}, 'sandbox.timeout_secs', '${SANDBOX_TIMEOUT_SECS}'::jsonb),
  (${uid_lit}, 'sandbox.image',        to_jsonb(${image_lit}::text))
ON CONFLICT (user_id, key) DO UPDATE
  SET value = EXCLUDED.value
RETURNING user_id, key, value;
SQL
)

psql_args=(
  -v ON_ERROR_STOP=1
  -U "$PG_USER"
  -d "$PG_DB"
  -c "$sql"
)

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "# DRY RUN — SQL for container '${CONTAINER}' (psql -U ${PG_USER} -d ${PG_DB}):"
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
echo "Configuring sandbox for '${CONTAINER}' (user_id='${SETTINGS_USER_ID}'): enabled=${SANDBOX_ENABLED}, policy=${SANDBOX_POLICY}, timeout=${SANDBOX_TIMEOUT_SECS}s, image=${SANDBOX_IMAGE}"

run_podman exec "$CONTAINER" psql "${psql_args[@]}"
