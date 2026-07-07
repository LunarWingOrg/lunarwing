#!/usr/bin/env bash
#
# export-tenant.sh — package one multi-tenant tenant into a portable bundle for
# MACHINE MIGRATION to a fresh LunarWing host (see docs/ops/MT-MACHINE-MIGRATION.md).
#
# Runs on the OLD (source) host. Self-contained: it does NOT need a v1.1.4-class
# mt-admin (the source may be v1.1.0). It only needs the container runtime, jq, tar.
#
# IMPORTANT — this is the START OF CUTOVER, not a read-only snapshot. To capture a
# CONSISTENT and FINAL picture (so nothing is written after the snapshot and the
# OMEMO double-ratchet store isn't torn mid-write), it STOPS the tenant's daemon +
# xmpp-bridge first (PostgreSQL stays up only for pg_dump). Plan a maintenance window.
#
# Bundle (a single 0600 tar):
#   meta.txt                 tenant, source version/runtime, pg role/db, timestamp
#   db.dump                  pg_dump -Fc of the tenant DB
#   manifest-lunarwing.env   carry-over keys for lunarwing.env (0600) — see CARRY below
#   manifest-bridge.env      carry-over keys for xmpp-bridge.env (0600)
#   manifest-vision.env      optional carry-over keys for vision.env (0600)
#   state.tar.gz             state dir (OMEMO store + workspace + tool storage),
#                            EXCLUDING sockets, host-specific config.toml, and *.wasm
#
# CARRY policy: only values that MUST match the source are carried — SECRETS_MASTER_KEY
# (the AES-256-GCM vault key, without which the DB's encrypted secret rows are
# unrecoverable), the XMPP identity (JID + password), and operator config (XMPP
# rooms/allowlist/OMEMO + LLM model/key). Intra-host tokens (gateway/bridge/webhook/
# relay) are intentionally NOT carried — the new host mints fresh, self-consistent
# ones (gateway UI / external webhook senders re-auth after cutover). Host-specific
# LLM_BASE_URL and OPENCODE_BASE_URL local proxies are carried ONLY when they
# point at non-local custom endpoints. Vision sidecar ports are regenerated, but
# a custom VL_URL/VL_MODEL and sidecar auth token are carried when vision.env exists.
#
# SECURITY: the bundle contains SECRETS_MASTER_KEY + the XMPP password. It is 0600,
# root-owned, in a 0700 dir. Transfer over ssh; delete from both hosts after verify.
#
# Usage (run as root on the source host):
#   sudo ic/scripts/export-tenant.sh <tenant> [--out-dir DIR] [--no-quiesce] [--dry-run]
#     --out-dir DIR   where to write the bundle (default /var/lib/lunarwing-migrate)
#     --no-quiesce    do NOT stop the daemon/bridge (you stopped them already);
#                     the script still verifies the daemon is not running
#     --dry-run       show what would happen; make no changes
set -euo pipefail

OUT_DIR="${LUNARWING_MIGRATE_DIR:-/var/lib/lunarwing-migrate}"
NO_QUIESCE=false
DRY_RUN=false
TENANT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out-dir)    OUT_DIR="$2"; shift 2 ;;
    --no-quiesce) NO_QUIESCE=true; shift ;;
    --dry-run)    DRY_RUN=true; shift ;;
    -*)           printf 'unknown arg: %s\n' "$1" >&2; exit 2 ;;
    *)            TENANT="$1"; shift ;;
  esac
done

say()    { printf '%s\n' "$*"; }
die()    { printf 'error: %s\n' "$*" >&2; exit 1; }
banner() { printf '\n========== %s ==========\n' "$*"; }
note()   { printf '  · %s\n' "$*"; }
run()    { if $DRY_RUN; then printf '  [dry-run] %s\n' "$*"; return 0; fi; printf '  + %s\n' "$*"; "$@"; }

[[ -n "$TENANT" ]] || die "usage: $0 <tenant> [--out-dir DIR] [--no-quiesce] [--dry-run]"
[[ "$(id -u)" -eq 0 ]] || die "run as root (sudo): stops the tenant services, reads its home/state, execs its DB container"
command -v jq  >/dev/null 2>&1 || die "jq required"
command -v tar >/dev/null 2>&1 || die "tar required"

id "$TENANT" >/dev/null 2>&1 || die "OS user '$TENANT' not found"
UID_T="$(id -u "$TENANT")"
HOME_T="$(getent passwd "$TENANT" | cut -d: -f6)"
LWROOT="$HOME_T/lunarwing"
ENVF="$LWROOT/env/lunarwing.env"
BRIDGE_ENVF="$LWROOT/env/xmpp-bridge.env"
VISION_ENVF="$LWROOT/env/vision.env"
STATE_DIR="$LWROOT/state"
[[ -f "$ENVF" ]] || die "tenant env not found: $ENVF (is '$TENANT' a LunarWing tenant on this host?)"

DB_BACKEND="$(sed -n 's/^DATABASE_BACKEND=//p' "$ENVF" | head -1)"; DB_BACKEND="${DB_BACKEND:-postgres}"
[[ "$DB_BACKEND" == "postgres" ]] || die "DATABASE_BACKEND=$DB_BACKEND: machine migration supports postgres only (libSQL would need a manual DB-file copy + a libSQL target). Aborting rather than risk a silent empty import."

# Parse role + db from DATABASE_URL (handles a pre-rename source named ironclaw).
# In-process parameter expansion — the password never reaches argv/logs.
DBURL="$(sed -n 's/^DATABASE_URL=//p' "$ENVF" | head -1)"
PG_ROLE="lunarwing"; PG_DB="lunarwing"
if [[ "$DBURL" == postgres://* ]]; then
  _u="${DBURL#postgres://}"; PG_ROLE="${_u%%:*}"; PG_ROLE="${PG_ROLE:-lunarwing}"
  _d="${DBURL##*/}"; _d="${_d%%\?*}"; PG_DB="${_d:-lunarwing}"
fi

# Find which runtime actually owns the container (don't assume podman-first).
PG="lunarwing-pg-$TENANT"
pick_runtime() {
  if [[ -n "${LUNARWING_CONTAINER_RUNTIME:-}" ]]; then echo "$LUNARWING_CONTAINER_RUNTIME"; return 0; fi
  local rt
  for rt in podman docker; do
    command -v "$rt" >/dev/null 2>&1 || continue
    "$rt" inspect "$PG" >/dev/null 2>&1 && { echo "$rt"; return 0; }
  done
  return 1
}
RUNTIME="$(pick_runtime || true)"
[[ -n "$RUNTIME" ]] || die "could not find container '$PG' in podman or docker — is the tenant's PostgreSQL container present on this host? (set LUNARWING_CONTAINER_RUNTIME to force)"

SRC_VER="$(sudo -u "$TENANT" git -C "$LWROOT" describe --tags --always 2>/dev/null || echo unknown)"
STAMP="$(date +%Y%m%d-%H%M%S)"

banner "Export tenant '$TENANT' (source $SRC_VER, runtime $RUNTIME, db $PG_DB/$PG_ROLE) — CUTOVER"
$DRY_RUN && say "*** DRY RUN — no changes will be made ***"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
chmod 0700 "$WORK"

# ---- 1. quiesce the writers (consistent + final snapshot) --------------------
banner "1/5  Quiesce daemon + bridge"
daemon_running() {
  if command -v systemctl >/dev/null 2>&1 \
     && sudo -u "$TENANT" XDG_RUNTIME_DIR="/run/user/$UID_T" systemctl --user is-active --quiet "lunarwing-$TENANT.service" 2>/dev/null; then return 0; fi
  if command -v rc-service >/dev/null 2>&1 && rc-service "lunarwing-$TENANT" status >/dev/null 2>&1; then return 0; fi
  return 1
}
if $NO_QUIESCE; then
  if ! $DRY_RUN && daemon_running; then die "--no-quiesce given but the '$TENANT' daemon is still running — stop it (and the bridge) first for a consistent snapshot"; fi
  note "--no-quiesce: assuming daemon + bridge are already stopped"
else
  if command -v systemctl >/dev/null 2>&1 \
     && sudo -u "$TENANT" XDG_RUNTIME_DIR="/run/user/$UID_T" systemctl --user list-unit-files "lunarwing-$TENANT.service" >/dev/null 2>&1; then
    run sudo -u "$TENANT" env XDG_RUNTIME_DIR="/run/user/$UID_T" systemctl --user stop "lunarwing-$TENANT.service" "xmpp-bridge-$TENANT.service"
  elif command -v rc-service >/dev/null 2>&1; then
    run rc-service "lunarwing-$TENANT" stop
    run rc-service "xmpp-bridge-$TENANT" stop
  else
    die "could not detect the init system to stop the writers; stop the '$TENANT' daemon + xmpp-bridge manually and re-run with --no-quiesce"
  fi
  note "daemon + bridge stopped (PostgreSQL left running for the dump)"
fi

# ---- 2. database (PG container must still be up) -----------------------------
banner "2/5  Database (pg_dump -Fc)"
if $DRY_RUN; then
  note "[dry-run] would: $RUNTIME exec $PG pg_dump -U $PG_ROLE -Fc $PG_DB > db.dump (then verify PGDMP)"
else
  "$RUNTIME" inspect -f '{{.State.Running}}' "$PG" 2>/dev/null | grep -q true \
    || die "DB container $PG is not running — start just the PG container so pg_dump can run, then re-export"
  ( umask 077; "$RUNTIME" exec "$PG" pg_dump -U "$PG_ROLE" -Fc "$PG_DB" > "$WORK/db.dump" ) \
    || die "pg_dump failed (role=$PG_ROLE db=$PG_DB) — check the names parsed from DATABASE_URL"
  [[ "$(head -c5 "$WORK/db.dump")" == "PGDMP" ]] || die "pg_dump output is not a valid PGDMP archive"
  [[ "$(stat -c%s "$WORK/db.dump")" -gt 0 ]] || die "pg_dump produced an empty file"
  say "  db.dump: $(du -h "$WORK/db.dump" | cut -f1) (verified PGDMP)"
fi

# ---- 3. carry-over manifests (secrets + operator config) ---------------------
banner "3/5  Secrets + config manifest"
LW_KEYS=(SECRETS_MASTER_KEY XMPP_JID XMPP_PASSWORD XMPP_DM_POLICY XMPP_ALLOW_FROM
         XMPP_ALLOW_ROOMS XMPP_ENCRYPTED_ROOMS XMPP_ALLOW_PLAINTEXT_FALLBACK
         XMPP_OMEMO_DEVICE_ID LLM_API_KEY LLM_MODEL OPENCODE_MODEL GOTIFY_URL
         GATEWAY_HOST HTTP_HOST)   # bind ADDRESS is operator config (carried); the
                                   # PORTS are host-specific and regenerated by add-tenant.
                                   # local proxy URLs are handled specially below.
BRIDGE_KEYS=(XMPP_JID XMPP_PASSWORD XMPP_DM_POLICY XMPP_ALLOW_FROM_JSON
             XMPP_ALLOW_ROOMS_JSON XMPP_ENCRYPTED_ROOMS_JSON XMPP_DEVICE_ID
             XMPP_ALLOW_PLAINTEXT_FALLBACK)
VISION_KEYS=(VL_URL VL_MODEL LUNARWING_AUTH_TOKEN)

# Append KEY=line from <src> to <dest> if present (CR-stripped). The `if` form (not
# `&& printf`) keeps a missing last key from making the function return non-zero
# under set -e.
copy_key() {  # <src> <dest> <key>
  local line; line="$(grep -m1 "^${3}=" "$1" 2>/dev/null || true)"
  if [[ -n "$line" ]]; then printf '%s\n' "${line%$'\r'}" >> "$2"; fi
}

if $DRY_RUN; then
  note "[dry-run] would extract ${#LW_KEYS[@]}+ keys from lunarwing.env (incl. SECRETS_MASTER_KEY) and ${#BRIDGE_KEYS[@]} from xmpp-bridge.env; intra-host tokens are NOT carried"
  if [[ -f "$VISION_ENVF" ]]; then
    note "[dry-run] would extract ${#VISION_KEYS[@]} keys from vision.env (VL_URL, VL_MODEL, LUNARWING_AUTH_TOKEN)"
  else
    note "[dry-run] no vision.env at $VISION_ENVF — no vision manifest would be written"
  fi
else
  ( umask 077; : > "$WORK/manifest-lunarwing.env"; : > "$WORK/manifest-bridge.env" )
  for k in "${LW_KEYS[@]}"; do copy_key "$ENVF" "$WORK/manifest-lunarwing.env" "$k"; done
  # LLM_BASE_URL: carry ONLY a non-local custom endpoint; a local proxy URL is
  # host-specific (its port differs on the new host, which sets its own).
  llm_url="$(sed -n 's/^LLM_BASE_URL=//p' "$ENVF" | head -1)"; llm_url="${llm_url%$'\r'}"
  if [[ -n "$llm_url" && "$llm_url" != http://127.0.0.1:* && "$llm_url" != http://localhost:* ]]; then
    printf 'LLM_BASE_URL=%s\n' "$llm_url" >> "$WORK/manifest-lunarwing.env"
    note "carrying custom LLM_BASE_URL"
  else
    note "LLM_BASE_URL is the local proxy ($llm_url) — NOT carried (new host sets its own)"
  fi
  opencode_url="$(sed -n 's/^OPENCODE_BASE_URL=//p' "$ENVF" | head -1)"; opencode_url="${opencode_url%$'\r'}"
  if [[ -n "$opencode_url" && "$opencode_url" != http://127.0.0.1:* && "$opencode_url" != http://localhost:* ]]; then
    printf 'OPENCODE_BASE_URL=%s\n' "$opencode_url" >> "$WORK/manifest-lunarwing.env"
    note "carrying custom OPENCODE_BASE_URL"
  elif [[ -n "$opencode_url" ]]; then
    note "OPENCODE_BASE_URL is local ($opencode_url) — NOT carried (new host sets its own)"
  fi
  for k in "${BRIDGE_KEYS[@]}"; do copy_key "$BRIDGE_ENVF" "$WORK/manifest-bridge.env" "$k"; done
  if [[ -f "$VISION_ENVF" ]]; then
    ( umask 077; : > "$WORK/manifest-vision.env" )
    for k in "${VISION_KEYS[@]}"; do copy_key "$VISION_ENVF" "$WORK/manifest-vision.env" "$k"; done
    if [[ -s "$WORK/manifest-vision.env" ]]; then
      say "  manifest-vision.env:    $(grep -c '=' "$WORK/manifest-vision.env" 2>/dev/null || echo 0) keys"
    else
      rm -f "$WORK/manifest-vision.env"
      note "vision.env had no carried keys — no vision manifest written"
    fi
  else
    note "no vision.env at $VISION_ENVF — vision sidecar config not carried"
  fi
  grep -q '^SECRETS_MASTER_KEY=' "$WORK/manifest-lunarwing.env" \
    || die "SECRETS_MASTER_KEY not found in $ENVF — refusing to export a bundle that can't decrypt the DB. Locate the key first."
  say "  manifest-lunarwing.env: $(grep -c '=' "$WORK/manifest-lunarwing.env") keys (incl. SECRETS_MASTER_KEY)"
  say "  manifest-bridge.env:    $(grep -c '=' "$WORK/manifest-bridge.env" 2>/dev/null || echo 0) keys"
fi

# ---- 4. on-disk state (OMEMO store + workspace) ------------------------------
banner "4/5  State directory"
if [[ -d "$STATE_DIR" ]]; then
  if $DRY_RUN; then
    note "[dry-run] would: tar czf state.tar.gz -C $LWROOT state (excluding *.sock, state/config.toml, *.wasm)"
    if [[ -d "$STATE_DIR/xmpp" ]]; then
      note "  includes OMEMO store state/xmpp"
    else
      note "  (no OMEMO store present yet)"
    fi
  else
    # Exclude: sockets; the host-specific config.toml (the new host's add-tenant
    # writes the correct external-worker ports); and *.wasm (rebuilt by install-wasm
    # — carrying stale v1.1.0 artifacts would linger past the never-cleaning overlay).
    tar czf "$WORK/state.tar.gz" -C "$LWROOT" \
      --exclude='*.sock' --exclude='state/config.toml' \
      --exclude='state/tools/*.wasm' --exclude='state/channels/*.wasm' state
    say "  state.tar.gz: $(du -h "$WORK/state.tar.gz" | cut -f1)$( [[ -d "$STATE_DIR/xmpp" ]] && echo ' (incl. OMEMO store)' )"
  fi
else
  note "no state dir at $STATE_DIR — nothing to bundle (OMEMO/workspace start fresh on import)"
fi

# ---- 5. seal the bundle ------------------------------------------------------
banner "5/5  Seal bundle"
BUNDLE="$OUT_DIR/${TENANT}-migrate-${STAMP}.tar"
if $DRY_RUN; then
  note "[dry-run] would write meta.txt and seal -> $BUNDLE (0600)"
  say ""; say "DRY RUN complete — no bundle written, services NOT stopped."
  exit 0
fi
mkdir -p "$OUT_DIR"; chmod 0700 "$OUT_DIR"
{
  printf 'tenant=%s\n' "$TENANT"
  printf 'source_version=%s\n' "$SRC_VER"
  printf 'source_runtime=%s\n' "$RUNTIME"
  printf 'pg_role=%s\n' "$PG_ROLE"
  printf 'pg_db=%s\n' "$PG_DB"
  printf 'db_backend=%s\n' "$DB_BACKEND"
  printf 'created=%s\n' "$STAMP"
} > "$WORK/meta.txt"
( umask 077; tar cf "$BUNDLE" -C "$WORK" . )
chmod 0600 "$BUNDLE"

banner "Done — bundle written (tenant is STOPPED — cutover in progress)"
say "  $BUNDLE ($(du -h "$BUNDLE" | cut -f1))"
say ""
say "The '$TENANT' daemon + bridge are now STOPPED on this host (PG still up for the"
say "dump; you may stop it too). The bundle contains SECRETS_MASTER_KEY + the XMPP"
say "password — transfer it over ssh (0600), and delete it from both hosts after verify."
say ""
say "Next, on the NEW host:  sudo ic/scripts/import-tenant.sh $(basename "$BUNDLE") --start"
say "Rollback: this host is intact — restart '$TENANT' here to abort the migration."
