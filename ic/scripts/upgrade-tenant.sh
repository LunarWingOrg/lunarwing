#!/usr/bin/env bash

# Requires a little re-factoring and ensuring that upgrades from v1.1.0 to v1.1.5 are supported
# NOTE: A seperate upgrade harness to update an tenant in place must be created for v1.0.3 era instances to v1.1.0 era
# This NOTE is reflected in the internal feature tracking board
#
# upgrade-tenant.sh — generalized in-place upgrade of ONE multi-tenant tenant
# from a v1.1.0-era deployment to v1.1.4 ("Phoenix") on systemd.
#
# Supersedes the hardcoded upgrade-tenant-starforce.sh / upgrade-tenant-sunburst.sh
# (which were tenant-specific and predate the Podman rootless flip). See
# docs/proposals/MT-1.1.0-TO-1.1.4-UPGRADE.md for the full rationale.
#
# TWO MODES (Podman):
#   default (rootless adopt) — migrate the tenant to the new rootless + Quadlet
#       supervision model. Because v1.1.4 defaults MT_ROOTLESS=true and v1.1.0 ran
#       Postgres ROOTFUL (root store, no named volume), a naive start would boot an
#       EMPTY rootless DB. So this mode does a deliberate data migration:
#         backup (root store) -> stop old -> rebuild -> bring up empty rootless PG
#         -> restore -> start.
#   --keep-rootful — lowest disruption: pin LUNARWING_MT_ROOTLESS=false so the
#       existing rootful container is reused in place (no data migration).
#
# Flow (rootless adopt):
#   preflight GATE -> backup(DB+ports+env) & VERIFY -> stop(old) -> git update +
#   build-tenant + install-wasm -> add-tenant --no-health (rootless prereqs +
#   empty PG + render units, NO daemon) -> restore-tenant --yes -> start-tenant ->
#   weechat-orphan cleanup -> verify. Rollback steps printed at the end.
#
# SAFETY: never proceeds past a failed/again-unverified backup; never starts the
# daemon before the restore (so restore-tenant's "daemon stopped" gate holds);
# NEVER prunes the old root-store container (your ultimate rollback). --dry-run
# prints the plan without executing.
#
# Run as root:
#   sudo ic/scripts/upgrade-tenant.sh <tenant> [options]
#     --target <rev|tag>   git ref to upgrade the tenant clone to (default v1.1.4)
#     --keep-rootful       Runbook B: stay rootful, reuse existing PG (no migrate)
#     --with-nanocode      also (re)build the nanocode worker
#     --with-pebble        also (re)build the pebble worker
#     --skip-build         tenant clone is already at --target and built
#     --prune-old-root     (standalone) delete the orphaned v1.1.0 root-store PG
#                          container AFTER the tenant is migrated + verified
#     --dry-run            print the plan; make no changes
#     --yes | -y           skip confirmation prompts (gates still enforced)
#     --force              proceed even if preflight reports STOP (dangerous)
set -euo pipefail

TARGET_REF="v1.1.4"
KEEP_ROOTFUL=false
WITH_NANOCODE=false
WITH_PEBBLE=false
SKIP_BUILD=false
DRY_RUN=false
AUTO_YES=false
FORCE=false
PRUNE_OLD_ROOT=false
TENANT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)         TARGET_REF="$2"; shift 2 ;;
    --keep-rootful)   KEEP_ROOTFUL=true; shift ;;
    --with-nanocode)  WITH_NANOCODE=true; shift ;;
    --with-pebble)    WITH_PEBBLE=true; shift ;;
    --skip-build)     SKIP_BUILD=true; shift ;;
    --prune-old-root) PRUNE_OLD_ROOT=true; shift ;;
    --dry-run)        DRY_RUN=true; shift ;;
    --yes|-y)         AUTO_YES=true; shift ;;
    --force)          FORCE=true; shift ;;
    -*)               printf 'unknown arg: %s\n' "$1" >&2; exit 2 ;;
    *)                TENANT="$1"; shift ;;
  esac
done

say()    { printf '%s\n' "$*"; }
die()    { printf 'error: %s\n' "$*" >&2; exit 1; }
banner() { printf '\n========== %s ==========\n' "$*"; }
note()   { printf '  · %s\n' "$*"; }
confirm() { $AUTO_YES && return 0; local a; read -r -p "$1 [y/N] " a; [[ "$a" == y || "$a" == Y ]]; }

# run a command, or just print it under --dry-run
run() {
  if $DRY_RUN; then printf '  [dry-run] %s\n' "$*"; return 0; fi
  printf '  + %s\n' "$*"
  "$@"
}

[[ -n "$TENANT" ]] || die "usage: $0 <tenant> [--keep-rootful] [--target <ref>] [--dry-run] [--yes]"
[[ "$(id -u)" -eq 0 ]] || die "run as root (sudo) — mt-admin needs root"
command -v jq >/dev/null 2>&1 || die "jq required"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MT="$SCRIPT_DIR/lunarwing-mt-admin.sh"
PF="$SCRIPT_DIR/upgrade-preflight.sh"
PORTS_REGISTRY="${LUNARWING_PORTS_REGISTRY:-/etc/lunarwing/ports.json}"
BACKUP_DIR="${LUNARWING_MT_BACKUP_DIR:-/var/lib/lunarwing-backups}"

[[ -x "$MT" ]] || die "mt-admin not found/executable at $MT"
jq -e ".tenants[\"$TENANT\"]" "$PORTS_REGISTRY" >/dev/null 2>&1 || die "tenant '$TENANT' not in $PORTS_REGISTRY"

UID_T="$(id -u "$TENANT")" || die "OS user '$TENANT' not found"
HOME_T="$(getent passwd "$TENANT" | cut -d: -f6)"
LWROOT="$HOME_T/lunarwing"
ENVF="$LWROOT/env/lunarwing.env"
# Mirror mt-admin's detect_container_runtime precedence EXACTLY (docker-first when
# both are installed) so RUNTIME equals what mt-admin will actually drive; also
# validate the override the same way mt-admin does, instead of echoing it verbatim.
detect_runtime() {
  local o="${LUNARWING_CONTAINER_RUNTIME:-}"
  if [[ -n "$o" ]]; then
    case "${o,,}" in docker|podman) printf '%s' "${o,,}"; return 0 ;;
      *) die "unsupported LUNARWING_CONTAINER_RUNTIME='$o' (use docker or podman)" ;; esac
  fi
  command -v docker >/dev/null 2>&1 && { printf 'docker'; return 0; }
  command -v podman >/dev/null 2>&1 && { printf 'podman'; return 0; }
  die "neither docker nor podman found"
}
RUNTIME="$(detect_runtime)"
STAMP="$(date +%Y%m%d-%H%M%S)"

# In keep-rootful mode every mt-admin call must see MT_ROOTLESS=false. We also
# force it false for the pre-migration backup/stop so _ctr targets the ROOT store
# (where the v1.1.0 data lives) even in rootless-adopt mode.
mt_rootful() { LUNARWING_MT_ROOTLESS=false "$MT" "$@"; }
mt()         { if $KEEP_ROOTFUL; then LUNARWING_MT_ROOTLESS=false "$MT" "$@"; else "$MT" "$@"; fi; }

# tenant rootless podman (read-only verify in rootless-adopt mode)
tctr() { ( cd / && exec sudo -u "$TENANT" env HOME="$HOME_T" XDG_RUNTIME_DIR="/run/user/$UID_T" "$RUNTIME" "$@" ); }

# Count ACTUAL DATA ROWS in a tenant's rootless DB (not just schema). The daemon's
# migrations create public tables on first connect regardless of any restore, so a
# table-existence check would say "data present" for a schema-only DB. We count rows
# in the core conversation tables (present since V1__initial; unchanged v1.1.0..v1.1.4)
# instead — that is the signal that v1.1.0 data was actually loaded. `|| true` keeps
# it fail-safe under `set -e`/pipefail: an exec/psql failure yields empty -> 0 ->
# callers treat it as "no data" (refuse to prune / warn), never an abort.
rootless_data_rows() { tctr exec "lunarwing-pg-$1" psql -U lunarwing -tAc \
  "SELECT (SELECT count(*) FROM conversations) + (SELECT count(*) FROM conversation_messages)" \
  2>/dev/null | tr -cd '0-9' || true; }

# Re-apply an operator-customizable env line from the pre-upgrade backup. add-tenant
# preserves SECRETS but HARDCODES XMPP rooms/allowlist/OMEMO/plaintext-fallback + LLM
# endpoint to defaults on every write, which would silently wipe a tenant's
# MUC/OMEMO/LLM config. Values are passed via the environment and read with awk's
# ENVIRON (NOT `-v`, which C-escape-processes backslashes in the value). Preserves
# the live file's inode/owner/mode (truncate-in-place).
reapply_env_key() {  # <old_file> <live_file> <KEY>
  local old="$1" live="$2" key="$3" line tmp
  [[ -f "$old" && -f "$live" ]] || return 0
  line="$(grep -m1 "^${key}=" "$old" 2>/dev/null || true)"
  [[ -n "$line" ]] || return 0
  grep -qxF "$line" "$live" 2>/dev/null && return 0   # live already matches; nothing to do
  tmp="$(mktemp)"
  if grep -q "^${key}=" "$live"; then
    _rk_repl="$line" awk -v k="${key}=" 'index($0,k)==1{print ENVIRON["_rk_repl"];next}{print}' "$live" >"$tmp"
  else
    cp "$live" "$tmp"; printf '%s\n' "$line" >>"$tmp"
  fi
  cat "$tmp" >"$live"; rm -f "$tmp"
  note "re-applied $key from pre-upgrade config"
}

# ---- --prune-old-root: reclaim the orphaned v1.1.0 ROOT-store PG container ----
# Run this ONLY after the tenant has been migrated to rootless and verified. It
# refuses unless the rootless PG is up, pg_isready, AND non-empty (so it can never
# delete your only copy when the rootless DB is still the empty post-flip one).
# IRREVERSIBLE.
if $PRUNE_OLD_ROOT; then
  banner "Prune old root-store PG for '$TENANT'"
  [[ "$RUNTIME" == podman ]] || die "--prune-old-root only applies to Podman (rootful root store)"
  if $DRY_RUN; then
    note "[dry-run] would verify rootless lunarwing-pg-$TENANT is Running + pg_isready + non-empty, then: podman rm -f lunarwing-pg-$TENANT (root store)"
    exit 0
  fi

  # the migrated rootless PG must be healthy AND actually hold restored DATA first
  # (row count, not table count: migrations create the schema with zero data, so a
  # never-restored DB would otherwise pass and we'd delete the only copy).
  rootless_state="$(tctr inspect -f '{{.State.Running}}' "lunarwing-pg-$TENANT" 2>/dev/null || true)"
  [[ "$rootless_state" == true ]] || die "rootless PG for '$TENANT' is not running — refusing to prune (migrate + verify first)"
  tctr exec "lunarwing-pg-$TENANT" pg_isready -U lunarwing -q 2>/dev/null \
    || die "rootless PG for '$TENANT' is not accepting connections — refusing to prune"
  data_rows="$(rootless_data_rows "$TENANT")"
  [[ "${data_rows:-0}" -gt 0 ]] || die "rootless DB for '$TENANT' has 0 conversation rows (got '${data_rows:-0}') — it looks EMPTY/unrestored; refusing to delete the root-store copy. Restore your backup into the rootless DB first, then re-run."
  note "rootless PG is up, ready, and holds $data_rows conversation rows (restored data is live)"

  # the old root-store container must exist to prune
  if ! podman inspect "lunarwing-pg-$TENANT" >/dev/null 2>&1; then
    say "no root-store container lunarwing-pg-$TENANT found — nothing to prune."
    exit 0
  fi
  root_state="$(podman inspect -f '{{.State.Running}}' "lunarwing-pg-$TENANT" 2>/dev/null || true)"
  note "root-store container present (Running=$root_state) — holds the pre-upgrade v1.1.0 data"

  say ""
  say "This permanently deletes the v1.1.0 data still in the ROOT store. After this,"
  say "rollback to the pre-upgrade DB is only possible from your backup dump."
  confirm "Permanently remove the old root-store lunarwing-pg-$TENANT?" || die "aborted by user"
  run podman rm -f "lunarwing-pg-$TENANT"      # root store; v1.1.0 had no named volume (data in writable layer)
  say "old root-store PG container for '$TENANT' removed."
  exit 0
fi

MODE="rootless-adopt"; $KEEP_ROOTFUL && MODE="keep-rootful"
# This tool backs up the root-store DB (step 1) and restores into the fresh
# rootless DB (step 5), so the rootless flip is intended: acknowledge mt-admin's
# data-orphan guard (scoped to THIS tenant only) so step 4's add-tenant doesn't
# refuse. (Backup runs first and the script dies if it fails, so this can't bypass
# the guard without a backup.)
[[ "$KEEP_ROOTFUL" == false ]] && export LUNARWING_MT_ACK_ROOTLESS_FLIP="$TENANT"
banner "Upgrade tenant '$TENANT' -> $TARGET_REF  (mode: $MODE, runtime: $RUNTIME)"
$DRY_RUN && say "*** DRY RUN — no changes will be made ***"

# ---- 0. PREFLIGHT GATE -------------------------------------------------------
banner "0/8  Preflight (read-only gate)"
PF_RC=0
if [[ -x "$PF" ]]; then
  pf_args=("$TENANT" "--target=$TARGET_REF"); $KEEP_ROOTFUL && pf_args+=(--keep-rootful)
  "$PF" "${pf_args[@]}" || PF_RC=$?
else
  note "preflight script not found at $PF — skipping gate (NOT recommended)"
fi
if [[ "$PF_RC" -ne 0 ]]; then
  if $FORCE; then say "preflight reported STOP — proceeding due to --force"; else
    die "preflight gate failed (exit $PF_RC). Resolve the STOP items or re-run with --force."; fi
fi

if [[ "$RUNTIME" == docker && "$KEEP_ROOTFUL" == false ]]; then
  die "runtime is docker: there is no rootless flip. Re-run with --keep-rootful (no data migration needed)."
fi

confirm "Proceed with the upgrade of '$TENANT'? This stops the tenant." || die "aborted by user"

# ---- 1. BACKUP (DB from the OLD root store, + registry + env) ----------------
banner "1/8  Backup"
DUMP=""
if $DRY_RUN; then
  note "[dry-run] would run: LUNARWING_MT_ROOTLESS=false $MT backup-tenant $TENANT"
else
  mt_rootful backup-tenant "$TENANT"           # pg_dump -Fc from the root store
  DUMP="$(ls -t "$BACKUP_DIR/$TENANT"/*.dump 2>/dev/null | head -1 || true)"
  [[ -f "$DUMP" ]] || die "could not locate the backup dump under $BACKUP_DIR/$TENANT"
  [[ "$(head -c5 "$DUMP" 2>/dev/null)" == "PGDMP" ]] || die "backup is not a valid PGDMP archive: $DUMP"
  [[ "$(stat -c%s "$DUMP")" -gt 0 ]] || die "backup is empty: $DUMP"
  say "  verified DB backup: $DUMP ($(du -h "$DUMP" | cut -f1))"
fi
# registry + env snapshots (cheap insurance)
run cp -a "$PORTS_REGISTRY" "$BACKUP_DIR/ports.json.$STAMP"
run cp -a "$LWROOT/env" "$BACKUP_DIR/${TENANT}-env.$STAMP"
# Write-once pre-upgrade env snapshot — the source-of-truth for step-4 reapply. If a
# prior run was interrupted AFTER add-tenant reset the env (live env now holds
# defaults), re-deriving the source from the live env would bake those defaults in
# permanently. So snapshot once and never overwrite; reapply always reads from here.
PREUP_ENV_DIR="$BACKUP_DIR/${TENANT}-env.preupgrade"
if $DRY_RUN; then
  note "[dry-run] would snapshot $LWROOT/env -> $PREUP_ENV_DIR (write-once)"
elif [[ -d "$PREUP_ENV_DIR" ]]; then
  note "pre-upgrade env snapshot already exists ($PREUP_ENV_DIR) — keeping the ORIGINAL"
else
  cp -a "$LWROOT/env" "$PREUP_ENV_DIR"; note "snapshotted pre-upgrade env -> $PREUP_ENV_DIR"
fi
PRIOR_REV="$(sudo -u "$TENANT" git -C "$LWROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
note "prior clone rev recorded for rollback: $PRIOR_REV"

# ---- 2. STOP the OLD model (daemon + old PG); old container/volume preserved --
banner "2/8  Stop tenant (old model)"
run mt_rootful stop-tenant "$TENANT"

# ---- 3. UPDATE the tenant clone + REBUILD (mt-admin does NOT auto-update) -----
banner "3/8  Update clone + build"
if $SKIP_BUILD; then
  note "--skip-build: assuming $LWROOT is already at $TARGET_REF and built"
else
  if [[ -n "$(sudo -u "$TENANT" git -C "$LWROOT" status --porcelain 2>/dev/null || true)" ]]; then
    if $AUTO_YES; then run sudo -u "$TENANT" git -C "$LWROOT" stash push -u -m "pre-upgrade-$STAMP"
    else die "tenant clone $LWROOT has uncommitted changes; commit/stash them or re-run with --yes"; fi
  fi
  run sudo -u "$TENANT" git -C "$LWROOT" fetch --tags --prune
  run sudo -u "$TENANT" git -C "$LWROOT" checkout "$TARGET_REF"
  build_args=(build-tenant "$TENANT" --with-wasm)
  $WITH_NANOCODE && build_args+=(--with-nanocode)
  $WITH_PEBBLE  && build_args+=(--with-pebble)
  run mt "${build_args[@]}"
  run mt install-wasm "$TENANT"
fi

# ---- 4. PROVISION rootless + render units + bring up EMPTY PG (NO daemon) -----
banner "4/8  Provision + render (add-tenant --no-health, idempotent)"
# Preserve the existing XMPP JID so the idempotent env writer doesn't default it.
XMPP_JID="$(grep -m1 '^XMPP_JID=' "$ENVF" 2>/dev/null | cut -d= -f2- || true)"
add_args=(add-tenant "$TENANT" --no-health)
[[ -n "$XMPP_JID" ]] && add_args+=(--xmpp-jid "$XMPP_JID")
run mt "${add_args[@]}"      # rootless: ensure_rootless_prereqs + empty PG quadlet + render; daemon NOT started
                             # keep-rootful: reuses existing root PG; back-fills HTTP_HOST/secret

# add-tenant rewrote the env files and reset operator-customizable XMPP/LLM config
# to defaults. Re-apply those specific keys from the step-1 backup (both modes).
if ! $DRY_RUN; then
  OLD_ENV_DIR="$PREUP_ENV_DIR"          # the write-once original, not this run's timestamped copy
  BRIDGE_ENV="$LWROOT/env/xmpp-bridge.env"
  for k in XMPP_ALLOW_FROM XMPP_ALLOW_ROOMS XMPP_ENCRYPTED_ROOMS XMPP_DM_POLICY XMPP_ALLOW_PLAINTEXT_FALLBACK XMPP_OMEMO_DEVICE_ID LLM_BASE_URL LLM_API_KEY LLM_MODEL; do
    reapply_env_key "$OLD_ENV_DIR/lunarwing.env" "$ENVF" "$k"
  done
  for k in XMPP_ALLOW_FROM_JSON XMPP_ALLOW_ROOMS_JSON XMPP_ENCRYPTED_ROOMS_JSON XMPP_DEVICE_ID; do
    reapply_env_key "$OLD_ENV_DIR/xmpp-bridge.env" "$BRIDGE_ENV" "$k"
  done
  chown "$TENANT:$TENANT" "$ENVF" "$BRIDGE_ENV" 2>/dev/null || true
fi

if [[ "$KEEP_ROOTFUL" == false ]] && ! $DRY_RUN; then
  pg_state="$(tctr inspect -f '{{.State.Running}}' "lunarwing-pg-$TENANT" 2>/dev/null || true)"
  [[ "$pg_state" == true ]] || die "rootless PG container for '$TENANT' is not running after add-tenant (state='${pg_state:-none}'); investigate before restore"
  note "rootless PG container is up (empty) — ready for restore"
fi

# ---- 5. RESTORE the data (rootless-adopt only; PG up + daemon stopped) --------
if [[ "$KEEP_ROOTFUL" == false ]]; then
  banner "5/8  Restore data into rootless PG"
  if $DRY_RUN; then
    note "[dry-run] would run: $MT restore-tenant $TENANT <verified-dump> --yes"
  else
    confirm "Restore $DUMP into the rootless DB for '$TENANT'? (DROP + recreate)" || die "aborted before restore"
    "$MT" restore-tenant "$TENANT" "$DUMP" --yes
  fi
else
  banner "5/8  Restore — skipped (keep-rootful reuses the existing data in place)"
fi

# ---- 6. START the tenant (PG already up, then workers + daemon) --------------
banner "6/8  Start tenant"
run mt start-tenant "$TENANT"

# ---- 7. CLEAN UP the orphaned old WeeChat unit (rename left it) --------------
banner "7/8  Orphan cleanup"
OLD_WC="$HOME_T/.config/systemd/user/weechat-$TENANT.service"
if [[ -f "$OLD_WC" ]]; then
  run sudo -u "$TENANT" env XDG_RUNTIME_DIR="/run/user/$UID_T" systemctl --user disable --now "weechat-$TENANT.service"
  run rm -f "$OLD_WC"
  run sudo -u "$TENANT" env XDG_RUNTIME_DIR="/run/user/$UID_T" systemctl --user daemon-reload
  note "removed orphaned weechat-$TENANT.service (replaced by lunarwing-weechat-$TENANT.service)"
else
  note "no orphaned weechat-$TENANT.service found"
fi

# ---- 8. VERIFY ---------------------------------------------------------------
banner "8/8  Verify"
run mt status-tenant "$TENANT"
if [[ "$KEEP_ROOTFUL" == false ]] && ! $DRY_RUN; then
  vrows="$(rootless_data_rows "$TENANT")"   # row count, not table count (schema exists regardless of restore)
  if [[ "${vrows:-0}" -gt 0 ]]; then note "rootless DB holds $vrows conversation rows — restored data is present."
  else say "WARNING: rootless DB for '$TENANT' has 0 conversation rows — the restore may have failed (or this agent genuinely had none). Do NOT run --prune-old-root until you confirm; your backup + the old root container are intact." >&2; fi
fi
note "Now smoke-test: message round-trips, conversation history present, routines intact, channels load."
note "Run the infra health check once: ic-infrastructure-health-check/infrastructure-health-check.sh"

# ---- DONE + rollback notes ---------------------------------------------------
banner "Done — '$TENANT' upgraded to $TARGET_REF ($MODE)"
say ""
say "IMPORTANT:"
if [[ "$KEEP_ROOTFUL" == false ]]; then
say "  • The OLD root-store PG container (lunarwing-pg-$TENANT) still holds your"
say "    v1.1.0 data and is your rollback safety net. Do NOT remove it until the"
say "    tenant is fully verified. To reclaim space LATER (IRREVERSIBLE):"
say "        sudo podman rm -f lunarwing-pg-$TENANT      # root store"
fi
say "  • Self-heal was NOT enabled (used --no-health). Enable it fleet-wide only"
say "    after ALL tenants are migrated and verified (see the proposal, §7)."
say ""
say "ROLLBACK for '$TENANT':"
say "    sudo $MT stop-tenant $TENANT"
say "    sudo -u $TENANT git -C $LWROOT checkout $PRIOR_REV"
say "    sudo $MT build-tenant $TENANT --with-wasm"
if [[ "$KEEP_ROOTFUL" == false ]]; then
say "    # start the preserved old root container (still has original data):"
say "    sudo LUNARWING_MT_ROOTLESS=false $MT start-tenant $TENANT"
else
say "    sudo LUNARWING_MT_ROOTLESS=false $MT restart-tenant $TENANT"
fi
say "    # env backup: $BACKUP_DIR/${TENANT}-env.$STAMP   ports: $BACKUP_DIR/ports.json.$STAMP"
[[ -n "$DUMP" ]] && say "    # DB dump:  $DUMP"

