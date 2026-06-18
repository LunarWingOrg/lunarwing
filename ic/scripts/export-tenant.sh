#!/usr/bin/env bash
#
# export-tenant.sh — package one multi-tenant tenant into a portable bundle for
# MACHINE MIGRATION to a fresh LunarWing host (see docs/ops/MT-MACHINE-MIGRATION.md).
#
# Runs on the OLD (source) host. It is self-contained: it does NOT require a
# v1.1.4-class mt-admin (the source may still be on v1.1.0), only the container
# runtime + jq + tar. Init-system agnostic (it touches no systemd/OpenRC units).
#
# The bundle contains everything `import-tenant.sh` needs to recreate the tenant
# identically on the new host:
#   meta.txt                 tenant name, source version/runtime, timestamp, db backend
#   db.dump                  pg_dump -Fc of the tenant DB (postgres backend)
#   manifest-lunarwing.env   carry-over secret+config keys from lunarwing.env (0600)
#   manifest-bridge.env      carry-over keys from xmpp-bridge.env (0600)
#   state.tar.gz             the tenant's on-disk state dir (OMEMO store, workspace,
#                            WASM storage) — minus sockets
#
# CRITICAL: the bundle contains SECRETS (SECRETS_MASTER_KEY — the AES-256-GCM vault
# key without which the DB's encrypted secret rows are unrecoverable — plus XMPP
# password and tokens). The bundle is written 0600, root-owned. Treat it like a key.
#
# Usage (run as root on the source host):
#   sudo ic/scripts/export-tenant.sh <tenant> [--out-dir DIR] [--dry-run]
#     --out-dir DIR   where to write the bundle (default /var/lib/lunarwing-migrate)
#     --dry-run       show what would happen; make no changes
set -euo pipefail

OUT_DIR="${LUNARWING_MIGRATE_DIR:-/var/lib/lunarwing-migrate}"
DRY_RUN=false
TENANT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -*)        printf 'unknown arg: %s\n' "$1" >&2; exit 2 ;;
    *)         TENANT="$1"; shift ;;
  esac
done

say()    { printf '%s\n' "$*"; }
die()    { printf 'error: %s\n' "$*" >&2; exit 1; }
banner() { printf '\n========== %s ==========\n' "$*"; }
note()   { printf '  · %s\n' "$*"; }
run()    { if $DRY_RUN; then printf '  [dry-run] %s\n' "$*"; return 0; fi; printf '  + %s\n' "$*"; "$@"; }

[[ -n "$TENANT" ]] || die "usage: $0 <tenant> [--out-dir DIR] [--dry-run]"
[[ "$(id -u)" -eq 0 ]] || die "run as root (sudo): reads the tenant's home/state and execs its DB container"
command -v jq  >/dev/null 2>&1 || die "jq required"
command -v tar >/dev/null 2>&1 || die "tar required"

id "$TENANT" >/dev/null 2>&1 || die "OS user '$TENANT' not found"
HOME_T="$(getent passwd "$TENANT" | cut -d: -f6)"
LWROOT="$HOME_T/lunarwing"
ENVF="$LWROOT/env/lunarwing.env"
BRIDGE_ENVF="$LWROOT/env/xmpp-bridge.env"
STATE_DIR="$LWROOT/state"
[[ -f "$ENVF" ]] || die "tenant env not found: $ENVF (is '$TENANT' a LunarWing tenant on this host?)"

RUNTIME="${LUNARWING_CONTAINER_RUNTIME:-$(command -v podman >/dev/null 2>&1 && echo podman || echo docker)}"
PG="lunarwing-pg-$TENANT"
STAMP="$(date +%Y%m%d-%H%M%S)"

# Source version (best-effort, for the meta record only).
SRC_VER="$(sudo -u "$TENANT" git -C "$LWROOT" describe --tags --always 2>/dev/null || echo unknown)"
DB_BACKEND="$(sed -n 's/^DATABASE_BACKEND=//p' "$ENVF" | head -1)"; DB_BACKEND="${DB_BACKEND:-postgres}"

banner "Export tenant '$TENANT' (source $SRC_VER, runtime $RUNTIME, db $DB_BACKEND)"
$DRY_RUN && say "*** DRY RUN — no changes will be made ***"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
chmod 0700 "$WORK"

# ---- 1. database -------------------------------------------------------------
banner "1/4  Database"
if [[ "$DB_BACKEND" == "postgres" ]]; then
  if $DRY_RUN; then
    note "[dry-run] would: $RUNTIME exec $PG pg_dump -U lunarwing -Fc lunarwing > db.dump (then verify PGDMP)"
  else
    "$RUNTIME" inspect -f '{{.State.Running}}' "$PG" 2>/dev/null | grep -q true \
      || die "DB container $PG is not running — start it so pg_dump can run, then re-export"
    ( umask 077; "$RUNTIME" exec "$PG" pg_dump -U lunarwing -Fc lunarwing > "$WORK/db.dump" ) \
      || die "pg_dump failed for '$TENANT'"
    [[ "$(head -c5 "$WORK/db.dump")" == "PGDMP" ]] || die "pg_dump output is not a valid PGDMP archive"
    [[ "$(stat -c%s "$WORK/db.dump")" -gt 0 ]] || die "pg_dump produced an empty file"
    say "  db.dump: $(du -h "$WORK/db.dump" | cut -f1) (verified PGDMP)"
  fi
else
  note "DATABASE_BACKEND=$DB_BACKEND (not postgres) — the DB file travels inside state.tar.gz; no pg_dump taken"
fi

# ---- 2. carry-over env keys (secrets + operator config) ----------------------
banner "2/4  Secrets + config manifest"
# These are NOT regenerable on the new host: SECRETS_MASTER_KEY decrypts the DB's
# secret rows; XMPP creds/tokens keep the same identity; the XMPP_* config is
# operator-chosen. Ports/paths/URLs that are host-specific are intentionally OMITTED
# (the new host's add-tenant regenerates them).
LW_KEYS=(SECRETS_MASTER_KEY XMPP_JID XMPP_PASSWORD XMPP_BRIDGE_TOKEN GATEWAY_AUTH_TOKEN
         HTTP_WEBHOOK_SECRET RELAY_PASSWORD LLM_BASE_URL LLM_API_KEY LLM_MODEL
         XMPP_DM_POLICY XMPP_ALLOW_FROM XMPP_ALLOW_ROOMS XMPP_ENCRYPTED_ROOMS
         XMPP_ALLOW_PLAINTEXT_FALLBACK XMPP_OMEMO_DEVICE_ID)
BRIDGE_KEYS=(XMPP_PASSWORD XMPP_BRIDGE_TOKEN XMPP_DM_POLICY XMPP_ALLOW_FROM_JSON
             XMPP_ALLOW_ROOMS_JSON XMPP_ENCRYPTED_ROOMS_JSON XMPP_DEVICE_ID
             XMPP_ALLOW_PLAINTEXT_FALLBACK)

extract_keys() {  # <src_env> <dest_manifest> <key...>
  local src="$1" dest="$2"; shift 2
  [[ -f "$src" ]] || { note "source env missing, skipping: $src"; return 0; }
  ( umask 077; : > "$dest" )
  local k line
  for k in "$@"; do
    line="$(grep -m1 "^${k}=" "$src" 2>/dev/null || true)"
    [[ -n "$line" ]] && printf '%s\n' "$line" >> "$dest"
  done
}

if $DRY_RUN; then
  note "[dry-run] would extract ${#LW_KEYS[@]} keys from lunarwing.env and ${#BRIDGE_KEYS[@]} from xmpp-bridge.env (incl. SECRETS_MASTER_KEY)"
else
  extract_keys "$ENVF"        "$WORK/manifest-lunarwing.env" "${LW_KEYS[@]}"
  extract_keys "$BRIDGE_ENVF" "$WORK/manifest-bridge.env"    "${BRIDGE_KEYS[@]}"
  grep -q '^SECRETS_MASTER_KEY=' "$WORK/manifest-lunarwing.env" \
    || die "SECRETS_MASTER_KEY not found in $ENVF — refusing to export a bundle that can't decrypt the DB. Locate the key first."
  say "  manifest-lunarwing.env: $(grep -c '=' "$WORK/manifest-lunarwing.env") keys (incl. SECRETS_MASTER_KEY)"
  say "  manifest-bridge.env:    $( [[ -f "$WORK/manifest-bridge.env" ]] && grep -c '=' "$WORK/manifest-bridge.env" || echo 0) keys"
fi

# ---- 3. on-disk state (OMEMO store, workspace, WASM storage) ------------------
banner "3/4  State directory"
if [[ -d "$STATE_DIR" ]]; then
  if $DRY_RUN; then
    note "[dry-run] would: tar czf state.tar.gz -C $LWROOT state --exclude='*.sock'"
    [[ -d "$STATE_DIR/xmpp" ]] && note "  includes OMEMO store state/xmpp" || note "  (no state/xmpp OMEMO store present)"
  else
    tar czf "$WORK/state.tar.gz" -C "$LWROOT" --exclude='*.sock' state
    say "  state.tar.gz: $(du -h "$WORK/state.tar.gz" | cut -f1)$( [[ -d "$STATE_DIR/xmpp" ]] && echo ' (incl. OMEMO store)' )"
  fi
else
  note "no state dir at $STATE_DIR — nothing to bundle (OMEMO/workspace will start fresh on import)"
fi

# ---- 4. seal the bundle ------------------------------------------------------
banner "4/4  Seal bundle"
BUNDLE="$OUT_DIR/${TENANT}-migrate-${STAMP}.tar"
if $DRY_RUN; then
  note "[dry-run] would write meta.txt and tar the workdir -> $BUNDLE (0600)"
  say ""; say "DRY RUN complete — no bundle written."
  exit 0
fi
mkdir -p "$OUT_DIR"; chmod 0700 "$OUT_DIR"
{
  printf 'tenant=%s\n' "$TENANT"
  printf 'source_version=%s\n' "$SRC_VER"
  printf 'source_runtime=%s\n' "$RUNTIME"
  printf 'db_backend=%s\n' "$DB_BACKEND"
  printf 'created=%s\n' "$STAMP"
} > "$WORK/meta.txt"
( umask 077; tar cf "$BUNDLE" -C "$WORK" . )
chmod 0600 "$BUNDLE"

banner "Done — bundle written"
say "  $BUNDLE ($(du -h "$BUNDLE" | cut -f1))"
say ""
say "SECURITY: this bundle contains SECRETS_MASTER_KEY, the XMPP password, and tokens."
say "  Transfer it over a secure channel (scp/rsync over ssh), keep mode 0600, and"
say "  delete it from both hosts once the import is verified."
say ""
say "Next: copy it to the new host and run:  sudo ic/scripts/import-tenant.sh $(basename "$BUNDLE")"
