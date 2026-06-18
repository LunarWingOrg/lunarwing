#!/usr/bin/env bash
#
# rehearse-testbot.sh — ⚠️ UNTESTED HELPER ⚠️ (generated, NOT yet validated — review
# before running). Spin up a throwaway "testbot" tenant with a seeded data marker so
# you can REHEARSE the machine-migration (export-tenant.sh -> import-tenant.sh) end to
# end before touching any real agent. See docs/ops/MT-MACHINE-MIGRATION.md.
#
# What it does: creates the tenant on THIS host via mt-admin (add-tenant -> build-tenant
# --with-wasm -> start-tenant), then seeds a `migration_rehearsal_marker` row in its DB.
# You then migrate it; on the new host the marker row should survive (proves DB restore
# + that pg_dump/pg_restore round-trips). NOTE: this proves DB-level survival only —
# OMEMO encrypted-chat continuity needs a real XMPP client to exercise, and decryptable-
# secrets continuity needs a real encrypted secret; this marker does not cover those.
#
# Usage (run as root):
#   sudo ic/scripts/rehearse-testbot.sh [--name testbot] [--cleanup] [--dry-run] [--yes]
#     --cleanup   tear down the throwaway tenant (remove-tenant --purge)
#     --dry-run   print the plan; make no changes
set -euo pipefail

NAME="testbot"
CLEANUP=false
DRY_RUN=false
AUTO_YES=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)    NAME="$2"; shift 2 ;;
    --cleanup) CLEANUP=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --yes|-y)  AUTO_YES=true; shift ;;
    *)         printf 'unknown arg: %s\n' "$1" >&2; exit 2 ;;
  esac
done

say()    { printf '%s\n' "$*"; }
die()    { printf 'error: %s\n' "$*" >&2; exit 1; }
banner() { printf '\n========== %s ==========\n' "$*"; }
note()   { printf '  · %s\n' "$*"; }
confirm() { $AUTO_YES && return 0; local a; read -r -p "$1 [y/N] " a; [[ "$a" == y || "$a" == Y ]]; }
run()    { if $DRY_RUN; then printf '  [dry-run] %s\n' "$*"; return 0; fi; printf '  + %s\n' "$*"; "$@"; }

[[ "$(id -u)" -eq 0 ]] || die "run as root (sudo) — mt-admin needs root"
NAME="$(printf '%s' "$NAME" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')"
[[ -n "$NAME" ]] || die "invalid --name"
[[ "$NAME" != testbot ]] && note "using tenant name '$NAME'"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MT="$SCRIPT_DIR/lunarwing-mt-admin.sh"
[[ -x "$MT" ]] || die "mt-admin not found/executable at $MT"
STAMP="$(date +%Y%m%d-%H%M%S)"
PG="lunarwing-pg-$NAME"

# Run psql inside the tenant's PG container. Best-effort: try the root container store
# first (rootful docker / v1.1.0), then fall back to the tenant's rootless store.
seed_sql() {  # <sql>
  local rt; rt="${LUNARWING_CONTAINER_RUNTIME:-$(command -v podman >/dev/null 2>&1 && echo podman || echo docker)}"
  if printf '%s' "$1" | "$rt" exec -i "$PG" psql -U lunarwing -d lunarwing -v ON_ERROR_STOP=1 >/dev/null 2>&1; then return 0; fi
  local uid home; uid="$(id -u "$NAME")"; home="$(getent passwd "$NAME" | cut -d: -f6)"
  printf '%s' "$1" | sudo -u "$NAME" env HOME="$home" XDG_RUNTIME_DIR="/run/user/$uid" \
    "$rt" exec -i "$PG" psql -U lunarwing -d lunarwing -v ON_ERROR_STOP=1
}

if $CLEANUP; then
  banner "Tear down throwaway tenant '$NAME'"
  confirm "Remove tenant '$NAME' (DESTRUCTIVE: remove-tenant --purge)?" || die "aborted"
  run "$MT" remove-tenant "$NAME" --purge
  say "removed '$NAME'."
  exit 0
fi

banner "Create throwaway tenant '$NAME' for migration rehearsal (UNTESTED helper)"
$DRY_RUN && say "*** DRY RUN — no changes will be made ***"
confirm "Create throwaway tenant '$NAME' on THIS host?" || die "aborted"

# add-tenant: pass --no-health only if this mt-admin supports it (v1.1.0 does not).
add_flags=()
grep -q 'no-health' "$MT" && add_flags+=(--no-health)
run "$MT" add-tenant "$NAME" "${add_flags[@]}"
run "$MT" build-tenant "$NAME" --with-wasm
run "$MT" start-tenant "$NAME"

banner "Seed a data marker"
MARKER="rehearsal-$STAMP"
SQL="CREATE TABLE IF NOT EXISTS migration_rehearsal_marker (id serial primary key, note text, created timestamptz default now()); INSERT INTO migration_rehearsal_marker (note) VALUES ('$MARKER');"
if $DRY_RUN; then
  note "[dry-run] would seed migration_rehearsal_marker note='$MARKER' into $PG"
else
  seed_sql "$SQL" || die "failed to seed marker into $PG (is the DB up? check the container/runtime)"
  say "seeded migration_rehearsal_marker note='$MARKER'"
fi

banner "Next: rehearse the migration"
say "1. Export (begins cutover — stops the testbot):"
say "     sudo ic/scripts/export-tenant.sh $NAME"
say "2. Copy the bundle to the new host, then import + start:"
say "     sudo ic/scripts/import-tenant.sh <bundle>.tar --start --old-stopped"
say "3. Verify the marker survived on the NEW host:"
say "     <runtime> exec $PG psql -U lunarwing -d lunarwing -tAc \\"
say "       \"SELECT note FROM migration_rehearsal_marker ORDER BY id DESC LIMIT 1\""
say "     (expect: $MARKER)"
say "4. Tear down when done:  sudo ic/scripts/rehearse-testbot.sh --name $NAME --cleanup"
say ""
say "Reminder: this marker proves DB round-trip only. For full confidence also send a"
say "real message + an OMEMO chat through the testbot before exporting, and confirm both"
say "the history and OMEMO decryption survive on the new host."
