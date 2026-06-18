#!/usr/bin/env bash
#
# import-tenant.sh — recreate a tenant on a FRESH LunarWing host from a bundle made
# by export-tenant.sh (see docs/ops/MT-MACHINE-MIGRATION.md). MACHINE MIGRATION.
#
# Runs on the NEW (target) host with a v1.1.4-class mt-admin. Init-system agnostic:
# all init/runtime-specific work is delegated to lunarwing-mt-admin.sh, which
# auto-detects systemd vs OpenRC and rootless-podman vs rootful-docker. So this same
# script imports onto either init system.
#
# Flow (the tenant is STAGED but NOT started by default, so YOU control the cutover —
# the new daemon uses the SAME XMPP JID as the old one, and two logins on one JID
# conflict):
#   add-tenant --no-health (fresh: clone, ports, throwaway secrets, empty PG, units;
#     NO daemon) -> build-tenant + workers -> INJECT carried secrets/config (incl.
#     SECRETS_MASTER_KEY — without it the restored DB's encrypted secrets are dead)
#     -> restore-tenant (DB) -> restore state dir (OMEMO/workspace) -> install-wasm
#     (overlay fresh v1.1.4 artifacts) -> [--start] start-tenant + verify.
#
# Usage (run as root on the new host):
#   sudo ic/scripts/import-tenant.sh <bundle.tar> [--name <tenant>] [--start]
#        [--with-nanocode] [--with-pebble] [--dry-run] [--yes] [--force]
#     --name <t>       override the tenant name from the bundle's meta
#     --start          start the tenant immediately (cutover now) instead of staging
#     --force          proceed even if the tenant already exists in the registry
set -euo pipefail

BUNDLE=""
NAME_OVERRIDE=""
DO_START=false
WITH_NANOCODE=false
WITH_PEBBLE=false
DRY_RUN=false
AUTO_YES=false
FORCE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)          NAME_OVERRIDE="$2"; shift 2 ;;
    --start)         DO_START=true; shift ;;
    --with-nanocode) WITH_NANOCODE=true; shift ;;
    --with-pebble)   WITH_PEBBLE=true; shift ;;
    --dry-run)       DRY_RUN=true; shift ;;
    --yes|-y)        AUTO_YES=true; shift ;;
    --force)         FORCE=true; shift ;;
    -*)              printf 'unknown arg: %s\n' "$1" >&2; exit 2 ;;
    *)               BUNDLE="$1"; shift ;;
  esac
done

say()    { printf '%s\n' "$*"; }
die()    { printf 'error: %s\n' "$*" >&2; exit 1; }
banner() { printf '\n========== %s ==========\n' "$*"; }
note()   { printf '  · %s\n' "$*"; }
confirm() { $AUTO_YES && return 0; local a; read -r -p "$1 [y/N] " a; [[ "$a" == y || "$a" == Y ]]; }
run()    { if $DRY_RUN; then printf '  [dry-run] %s\n' "$*"; return 0; fi; printf '  + %s\n' "$*"; "$@"; }

# Inject KEY=value lines from a manifest into a live env file, backslash-safe (awk
# ENVIRON, NOT -v). Preserves the live file's inode/owner/mode.
inject_keys() {  # <manifest> <live_env>
  local man="$1" live="$2" line key tmp
  [[ -f "$man" && -f "$live" ]] || return 0
  while IFS= read -r line; do
    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"
    grep -qxF "$line" "$live" 2>/dev/null && continue
    tmp="$(mktemp)"
    if grep -q "^${key}=" "$live"; then
      _ik_repl="$line" awk -v k="${key}=" 'index($0,k)==1{print ENVIRON["_ik_repl"];next}{print}' "$live" >"$tmp"
    else
      cp "$live" "$tmp"; printf '%s\n' "$line" >>"$tmp"
    fi
    cat "$tmp" >"$live"; rm -f "$tmp"
    note "injected $key"
  done < "$man"
}

[[ -n "$BUNDLE" ]] || die "usage: $0 <bundle.tar> [--name <tenant>] [--start] [--dry-run]"
[[ -f "$BUNDLE" ]] || die "bundle not found: $BUNDLE"
[[ "$(id -u)" -eq 0 ]] || die "run as root (sudo) — mt-admin needs root"
command -v jq  >/dev/null 2>&1 || die "jq required"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MT="$SCRIPT_DIR/lunarwing-mt-admin.sh"
PORTS_REGISTRY="${LUNARWING_PORTS_REGISTRY:-/etc/lunarwing/ports.json}"
[[ -x "$MT" ]] || die "mt-admin not found/executable at $MT"
grep -qE '^\s*restore-tenant\)' "$MT" || die "mt-admin at $MT predates restore-tenant (need a v1.1.4-class host)"

# ---- unpack bundle -----------------------------------------------------------
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
chmod 0700 "$WORK"
tar xf "$BUNDLE" -C "$WORK" || die "failed to unpack bundle $BUNDLE"
[[ -f "$WORK/meta.txt" ]] || die "bundle missing meta.txt — not an export-tenant.sh bundle?"

meta() { sed -n "s/^$1=//p" "$WORK/meta.txt" | head -1; }
TENANT="${NAME_OVERRIDE:-$(meta tenant)}"
[[ -n "$TENANT" ]] || die "could not determine tenant name (pass --name)"
SRC_VER="$(meta source_version)"; DB_BACKEND="$(meta db_backend)"; DB_BACKEND="${DB_BACKEND:-postgres}"

banner "Import tenant '$TENANT' (from source $SRC_VER, db $DB_BACKEND)"
$DRY_RUN && say "*** DRY RUN — no changes will be made ***"

# preconditions
grep -q '^SECRETS_MASTER_KEY=' "$WORK/manifest-lunarwing.env" 2>/dev/null \
  || die "bundle has no SECRETS_MASTER_KEY — the restored DB's encrypted secrets would be unrecoverable; abort"
if jq -e ".tenants[\"$TENANT\"]" "$PORTS_REGISTRY" >/dev/null 2>&1; then
  $FORCE || die "tenant '$TENANT' already exists in $PORTS_REGISTRY — refusing (use --force only if you mean to re-import over it)"
  say "WARNING: tenant '$TENANT' already exists — proceeding due to --force"
fi
if [[ "$DB_BACKEND" == "postgres" && ! -f "$WORK/db.dump" ]]; then die "bundle missing db.dump for a postgres tenant"; fi

XMPP_JID="$(sed -n 's/^XMPP_JID=//p' "$WORK/manifest-lunarwing.env" | head -1)"

confirm "Stage tenant '$TENANT' on THIS host from the bundle?" || die "aborted by user"

# ---- 1. provision fresh (no daemon, no health) -------------------------------
banner "1/6  Provision (add-tenant --no-health)"
add_args=(add-tenant "$TENANT" --no-health)
[[ -n "$XMPP_JID" ]] && add_args+=(--xmpp-jid "$XMPP_JID")
run "$MT" "${add_args[@]}"     # clones repo, allocates ports, mints THROWAWAY secrets,
                               # brings up an EMPTY rootless PG + renders units; daemon NOT started

HOME_T="$(getent passwd "$TENANT" | cut -d: -f6 2>/dev/null || echo "/home/$TENANT")"
LWROOT="$HOME_T/lunarwing"
ENVF="$LWROOT/env/lunarwing.env"
BRIDGE_ENVF="$LWROOT/env/xmpp-bridge.env"

# ---- 2. build the daemon + workers -------------------------------------------
banner "2/6  Build"
build_args=(build-tenant "$TENANT" --with-wasm)
$WITH_NANOCODE && build_args+=(--with-nanocode)
$WITH_PEBBLE  && build_args+=(--with-pebble)
run "$MT" "${build_args[@]}"

# ---- 3. inject carried secrets + config (CRITICAL: SECRETS_MASTER_KEY) -------
banner "3/6  Inject carried secrets + config"
if $DRY_RUN; then
  note "[dry-run] would inject manifest-lunarwing.env -> $ENVF and manifest-bridge.env -> $BRIDGE_ENVF (incl. SECRETS_MASTER_KEY, XMPP_PASSWORD, tokens, XMPP/LLM config)"
else
  inject_keys "$WORK/manifest-lunarwing.env" "$ENVF"
  [[ -f "$WORK/manifest-bridge.env" ]] && inject_keys "$WORK/manifest-bridge.env" "$BRIDGE_ENVF"
  chown "$TENANT:$TENANT" "$ENVF" "$BRIDGE_ENVF" 2>/dev/null || true
  grep -qxF "$(grep '^SECRETS_MASTER_KEY=' "$WORK/manifest-lunarwing.env")" "$ENVF" \
    || die "SECRETS_MASTER_KEY did not land in $ENVF after injection — abort before restore"
  note "SECRETS_MASTER_KEY confirmed in place"
fi

# ---- 4. restore the database (PG up from step 1, daemon not started) ---------
banner "4/6  Restore database"
if [[ "$DB_BACKEND" == "postgres" ]]; then
  if $DRY_RUN; then note "[dry-run] would: $MT restore-tenant $TENANT <bundle db.dump> --yes"
  else "$MT" restore-tenant "$TENANT" "$WORK/db.dump" --yes; fi
else
  note "non-postgres backend: DB travels in the state tar (restored next step); no pg_restore"
fi

# ---- 5. restore on-disk state (OMEMO/workspace), then overlay fresh WASM ------
banner "5/6  Restore state + install WASM"
if [[ -f "$WORK/state.tar.gz" ]]; then
  if $DRY_RUN; then note "[dry-run] would: tar xzf state.tar.gz into $LWROOT (restores state/xmpp OMEMO + workspace), chown to $TENANT"
  else
    tar xzf "$WORK/state.tar.gz" -C "$LWROOT"
    chown -R "$TENANT:$TENANT" "$LWROOT/state"
    note "restored state dir$( [[ -d "$LWROOT/state/xmpp" ]] && echo ' (incl. OMEMO store)' )"
  fi
else
  note "bundle has no state.tar.gz — OMEMO/workspace will start fresh"
fi
run "$MT" install-wasm "$TENANT"   # overlay current v1.1.4 .wasm artifacts on the restored state

# ---- 6. cutover ---------------------------------------------------------------
banner "6/6  Cutover"
if $DO_START; then
  say "Starting '$TENANT' now (--start)."
  say "⚠  Ensure the OLD host's '$TENANT' is STOPPED first — both use XMPP JID '${XMPP_JID:-?}'"
  say "   and two simultaneous logins on one JID conflict."
  confirm "Old host's '$TENANT' is stopped — start it here now?" || { say "Staged but not started. Start later: sudo $MT start-tenant $TENANT"; exit 0; }
  run "$MT" start-tenant "$TENANT"
  if ! $DRY_RUN; then
    run "$MT" status-tenant "$TENANT"
    note "Smoke-test: a message round-trips, history present, routines + channels load, OMEMO decrypts."
  fi
else
  say "Tenant '$TENANT' is STAGED (DB + secrets + state restored, units rendered) but NOT started."
  say ""
  say "To cut over:"
  say "  1. Stop '$TENANT' on the OLD host (same XMPP JID '${XMPP_JID:-?}' — avoid a double login)."
  say "  2. sudo $MT start-tenant $TENANT"
  say "  3. Verify, then enable self-heal fleet-wide once all agents are migrated:"
  say "     sudo ic/scripts/enable-health-fleet.sh --gotify-url <url> --gotify-token-file <path>"
fi
say ""
say "Rollback: the OLD host is untouched — just keep running '$TENANT' there."
