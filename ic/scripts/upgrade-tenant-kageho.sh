#!/usr/bin/env bash
#
# upgrade-tenant-kageho.sh — in-place version upgrade of the EXISTING live tenant
# "kageho" from v1.0.8/v1.0.9 to v1.1.1, on THIS host (Docker, rootful).
#
# Why this is its own script (not upgrade-tenant.sh): the generic upgrade-tenant.sh
# is a v1.1.0->v1.1.4 (Phoenix) tool built around the Podman rootful->rootless flip
# and its step 4 re-runs `add-tenant`, which REWRITES the tenant env and resets
# XMPP/LLM config to defaults. That is wrong for a 1.0.x->1.1.1 jump. v1.1.1:
#   * adds exactly ONE DB migration, V21__fix_null_agent_id_unique_constraint.sql,
#     applied automatically by refinery on first boot (self-dedups, then swaps the
#     memory_documents unique constraint to UNIQUE NULLS NOT DISTINCT);
#   * has NO podman/rootless concept (that is v1.1.4) -> kageho stays on her
#     existing rootful Docker Postgres container, reused in place;
#   * is the env-sourced WeeChat MT port fix rollout -> needs install-wasm +
#     patch-env so the daemon sources RELAY_URL/WS_ADAPTER_URL from env.
#
# This script DEFAULTS TO A READ-ONLY DRY-RUN: it runs every gate (PG>=15, the
# unique_path_per_user constraint still exists by name, pending-migration check,
# duplicate-row check, clean working tree, weechat pre-flight) and prints the plan.
# It changes NOTHING until you pass --apply.
#
# Flow (--apply):
#   gates -> backup(DB + env + ports + caps) -> stop -> fetch+checkout TARGET ->
#   build-tenant --with-wasm -> install-wasm -> patch-env -> weechat pre-flight GATE
#   -> start (refinery applies V21 on boot) -> remove stale weechat unit -> verify.
# Rollback steps are printed at the end.
#
# Run as root:
#   sudo ic/scripts/upgrade-tenant-kageho.sh                # DRY-RUN (read-only)
#   sudo ic/scripts/upgrade-tenant-kageho.sh --apply        # perform the upgrade
#     --target <tag>   git ref to upgrade to (default v1.1.1)
#     --yes | -y       skip confirmation prompts (gates still abort on failure)
set -euo pipefail

TENANT="kageho"
TARGET="v1.1.1"
APPLY=false
AUTO_YES=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)     APPLY=true; shift ;;
    --target)    TARGET="$2"; shift 2 ;;
    --target=*)  TARGET="${1#*=}"; shift ;;
    --yes|-y)    AUTO_YES=true; shift ;;
    *) printf 'unknown arg: %s\n' "$1" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MT="$SCRIPT_DIR/lunarwing-mt-admin.sh"
PF="$SCRIPT_DIR/lunarwing-weechat-preflight.sh"
REGISTRY="${LUNARWING_PORTS_REGISTRY:-/etc/lunarwing/ports.json}"
HOME_DIR="/home/$TENANT/lunarwing"
ENV_FILE="$HOME_DIR/env/lunarwing.env"
CAPS_FILE="$HOME_DIR/state/channels/weechat.capabilities.json"
CONFIG_FILE="$HOME_DIR/state/config.toml"
PG_CONTAINER="lunarwing-pg-$TENANT"
PG_USER="lunarwing"
PG_DB="lunarwing"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$HOME_DIR/backups/${TARGET}-upgrade-$STAMP"
MT_BACKUP_ROOT="${LUNARWING_MT_BACKUP_DIR:-/var/lib/lunarwing-backups}"
TENANT_BACKUP_DIR="$MT_BACKUP_ROOT/$TENANT"
NEWEST_DUMP=""

# Defensive: under Docker mt-admin stays rootful anyway, but pin it so a
# v1.1.4-class mt-admin can never flip kageho toward a rootless store.
export LUNARWING_MT_ROOTLESS=false

say()    { printf '%s\n' "$*"; }
warn()   { printf 'WARN: %s\n' "$*" >&2; }
die()    { printf 'error: %s\n' "$*" >&2; exit 1; }
banner() { printf '\n========== %s ==========\n' "$*"; }
confirm(){ $AUTO_YES && return 0; local a; read -r -p "$1 [y/N] " a; [[ "$a" == y || "$a" == Y ]]; }
# psql gate helper: tuples-only, unaligned, read-only. Prints the scalar result.
dpsql()  { docker exec "$PG_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -tAc "$1"; }

# ---- host / tool prerequisites -------------------------------------------------
[[ "$(id -u)" -eq 0 ]] || die "run as root (sudo) — mt-admin needs root"
[[ -x "$MT" ]] || die "mt-admin not found/executable at $MT"
[[ -x "$PF" ]] || die "weechat pre-flight not found/executable at $PF"
command -v jq >/dev/null 2>&1 || die "jq required"
command -v docker >/dev/null 2>&1 || die "docker required (this tenant runs on Docker)"
[[ -f "$REGISTRY" ]] || die "ports registry not found: $REGISTRY"
jq -e ".tenants[\"$TENANT\"]" "$REGISTRY" >/dev/null 2>&1 || die "tenant '$TENANT' not in $REGISTRY"
[[ -d "$HOME_DIR/.git" ]] || die "tenant clone not found at $HOME_DIR"

wc_port="$(jq -r ".tenants[\"$TENANT\"].ports.weechat // empty" "$REGISTRY")"
adapter_port="$(jq -r ".tenants[\"$TENANT\"].ports.weechat_adapter // empty" "$REGISTRY")"

banner "kageho upgrade -> $TARGET   (mode: $([ "$APPLY" = true ] && echo APPLY || echo DRY-RUN))"
say "tenant clone : $HOME_DIR"
say "pg container : $PG_CONTAINER (Docker, rootful)"
say "weechat ports: relay=$wc_port  adapter=$adapter_port"

# ================================================================================
# GATES (read-only — run in BOTH dry-run and apply; any failure aborts)
# ================================================================================
banner "GATE 0  container runtime is Docker (podman is unsupported before 1.1.4)"
if ! docker inspect "$PG_CONTAINER" >/dev/null 2>&1; then
  if command -v podman >/dev/null 2>&1 && podman inspect "$PG_CONTAINER" >/dev/null 2>&1; then
    die "kageho's Postgres is a PODMAN container. Podman is not supported until 1.1.4; a v1.1.1 target must stay on Docker. Aborting."
  fi
  die "Postgres container '$PG_CONTAINER' not found under docker. Is the tenant running?"
fi
running="$(docker inspect -f '{{.State.Running}}' "$PG_CONTAINER" 2>/dev/null || echo false)"
[[ "$running" == "true" ]] || die "container '$PG_CONTAINER' is not running — start the tenant before upgrading (backup needs PG up)"
say "  ok: docker container '$PG_CONTAINER' is up"

banner "GATE 1  PostgreSQL >= 15  (V21 uses UNIQUE NULLS NOT DISTINCT)"
svn="$(dpsql 'SHOW server_version_num;' | tr -d '[:space:]')"
[[ "$svn" =~ ^[0-9]+$ ]] || die "could not read server_version_num (got: '$svn')"
if (( svn < 150000 )); then die "PostgreSQL server_version_num=$svn (<15) — V21 will fail. Bump the PG image first."; fi
say "  ok: server_version_num=$svn (>=150000)"

banner "GATE 2  constraint 'unique_path_per_user' exists by name  (V21 DROP has no IF EXISTS)"
ccount="$(dpsql "SELECT count(*) FROM pg_constraint WHERE conrelid='memory_documents'::regclass AND conname='unique_path_per_user';" | tr -d '[:space:]')"
if [[ "$ccount" != "1" ]]; then
  die "constraint 'unique_path_per_user' not found (count=$ccount). The 2026-06-01 cleanup may have renamed/dropped it. Re-create it under that name (UNIQUE (user_id, agent_id, path)) before upgrading, or V21 aborts startup."
fi
say "  ok: unique_path_per_user present"

banner "GATE 3  pending-migration check  (expect current applied version = 20)"
maxv="$(dpsql 'SELECT COALESCE(max(version),0) FROM refinery_schema_history;' | tr -d '[:space:]')"
case "$maxv" in
  20) say "  ok: at V20 — V21 is pending and will apply on first v1.1.1 boot" ;;
  21|2[2-9]|[3-9][0-9]) warn "schema already at V$maxv (>=21) — V21 looks already applied; the binary upgrade can still proceed but verify this is expected"; confirm "  continue anyway?" || die "aborted at GATE 3" ;;
  *) warn "unexpected current migration version: V$maxv (expected 20)"; confirm "  continue anyway?" || die "aborted at GATE 3" ;;
esac

banner "GATE 4  duplicate memory_documents check  (V21 silently deletes all but the oldest per group)"
dupgroups="$(dpsql "SELECT count(*) FROM (SELECT 1 FROM memory_documents GROUP BY user_id, COALESCE(agent_id::text,''), path HAVING count(*)>1) x;" | tr -d '[:space:]')"
if [[ "$dupgroups" == "0" ]]; then
  say "  ok: no duplicate groups (expected — cleaned 2026-06-01); V21 Step 1 is a no-op"
else
  warn "$dupgroups duplicate group(s) found — V21 will KEEP the oldest row per (user_id, COALESCE(agent_id,''), path) and DELETE the rest (cascading to memory_chunks/document_versions)."
  say "  inspect the rows V21 would delete:"
  say "    docker exec $PG_CONTAINER psql -U $PG_USER -d $PG_DB -c \"SELECT id,user_id,agent_id,path,created_at FROM memory_documents WHERE id NOT IN (SELECT DISTINCT ON (user_id,COALESCE(agent_id::text,''),path) id FROM memory_documents ORDER BY user_id,COALESCE(agent_id::text,''),path,created_at ASC) ORDER BY user_id,path,created_at;\""
  say "  The pre-upgrade DB backup makes this recoverable. Review before --apply."
  confirm "  proceed knowing V21 will delete the duplicate losers?" || die "aborted at GATE 4 (no changes made)"
fi

banner "GATE 5  tenant working tree is clean  (git checkout $TARGET must not clobber hand-edits)"
dirty="$(sudo -u "$TENANT" git -c safe.directory="$HOME_DIR" -C "$HOME_DIR" status --short --untracked-files=no 2>/dev/null || true)"
if [[ -n "$dirty" ]]; then
  say "  MODIFIED TRACKED files in $HOME_DIR:"
  printf '%s\n' "$dirty" | sed 's/^/    /'
  die "checkout $TARGET would conflict with hand-edited tracked files. Review (sudo -u $TENANT git -C $HOME_DIR diff), reconcile/stash, then re-run."
fi
cur_rev="$(sudo -u "$TENANT" git -c safe.directory="$HOME_DIR" -C "$HOME_DIR" describe --tags --always 2>/dev/null || echo '?')"
say "  ok: clean working tree (current: $cur_rev)"

banner "GATE 6  WeeChat pre-flight (read-only)"
"$PF" "$TENANT" || warn "weechat pre-flight returned non-zero (a value disagrees with the registry) — review above before --apply"

banner "GATE 7  onboarding flag present (kageho anti-bootstrap fix)"
if [[ -f "$CONFIG_FILE" ]] && grep -q 'profile_onboarding_completed *= *true' "$CONFIG_FILE"; then
  say "  ok: profile_onboarding_completed = true in $CONFIG_FILE"
else
  warn "profile_onboarding_completed=true not confirmed in $CONFIG_FILE — re-verify after upgrade so bootstrap mode does not re-trigger"
fi

# ================================================================================
if ! $APPLY; then
  banner "DRY-RUN complete — all gates evaluated, NOTHING changed"
  say "If the gates above are green, perform the upgrade with:"
  say "    sudo $SCRIPT_DIR/$(basename "$0") --apply"
  exit 0
fi

# ================================================================================
# APPLY (mutations begin here)
# ================================================================================
confirm "All gates passed. Upgrade kageho $cur_rev -> $TARGET now?" || { say "aborted (no changes made)."; exit 0; }

banner "1/9  backup  (DB dump + env + ports + installed caps)"
mkdir -p "$BACKUP_DIR"
"$MT" backup-tenant "$TENANT" || die "backup-tenant failed — refusing to proceed without a DB backup"
"$MT" list-backups "$TENANT" || true
# Verify the dump is real before trusting it (size + PGDMP custom-format magic),
# not just backup-tenant's exit code — this is the rollback net for V21.
NEWEST_DUMP="$(ls -1t "$TENANT_BACKUP_DIR"/*.dump 2>/dev/null | head -1 || true)"
[[ -n "$NEWEST_DUMP" && -f "$NEWEST_DUMP" ]] || die "no .dump found in $TENANT_BACKUP_DIR after backup-tenant — aborting before any change"
dump_size="$(stat -c%s "$NEWEST_DUMP" 2>/dev/null || echo 0)"
(( dump_size > 1024 )) || die "DB dump suspiciously small (${dump_size}B): $NEWEST_DUMP — aborting"
[[ "$(head -c5 "$NEWEST_DUMP" 2>/dev/null)" == "PGDMP" ]] || die "DB dump missing PGDMP magic header: $NEWEST_DUMP — aborting"
say "  verified DB dump: $NEWEST_DUMP (${dump_size}B, PGDMP ok)"
[[ -f "$ENV_FILE" ]]  && cp -a "$ENV_FILE"  "$BACKUP_DIR/lunarwing.env.bak"            && say "  saved env"
[[ -f "$REGISTRY" ]]  && cp -a "$REGISTRY"  "$BACKUP_DIR/ports.json.bak"               && say "  saved ports.json"
[[ -f "$CAPS_FILE" ]] && cp -a "$CAPS_FILE" "$BACKUP_DIR/weechat.capabilities.json.bak" && say "  saved installed caps"
chown -R "$TENANT:$TENANT" "$HOME_DIR/backups" 2>/dev/null || true
say "  side backup dir: $BACKUP_DIR"

banner "2/9  stop-tenant"
"$MT" stop-tenant "$TENANT"

banner "3/9  fetch tags + checkout $TARGET (as $TENANT)"
sudo -u "$TENANT" git -c safe.directory="$HOME_DIR" -C "$HOME_DIR" fetch --tags --prune origin \
  || die "git fetch failed — could not retrieve tags from origin"
sudo -u "$TENANT" git -c safe.directory="$HOME_DIR" -C "$HOME_DIR" checkout "$TARGET" \
  || die "git checkout $TARGET failed"
[[ -f "$HOME_DIR/ic/migrations/V21__fix_null_agent_id_unique_constraint.sql" ]] \
  || die "V21 migration missing from checkout — wrong ref? Aborting before build."
say "  now at: $(sudo -u "$TENANT" git -c safe.directory="$HOME_DIR" -C "$HOME_DIR" describe --tags --always)"

banner "4/9  build-tenant --with-wasm  (binary + bridge + refreshed capabilities.json)"
"$MT" build-tenant "$TENANT" --with-wasm

banner "5/9  install-wasm  (installs caps with the new env-source fields)"
"$MT" install-wasm "$TENANT"

banner "6/9  patch-env  (additive: adds RELAY_URL/WS_ADAPTER_URL/etc; never overwrites)"
"$MT" patch-env "$TENANT"

banner "7/9  WeeChat pre-flight GATE — must pass before restart"
"$PF" "$TENANT" || die "weechat pre-flight FAILED — NOT starting. A value disagrees with the registry. Investigate (or restore from $BACKUP_DIR), then re-run."

confirm "Pre-flight clean. Start kageho on $TARGET now? (refinery applies V21 on boot)" \
  || { say "Stopped before start — code is at $TARGET but daemon is DOWN. Start later: $MT start-tenant $TENANT"; exit 0; }

banner "8/9  start-tenant  (V21 applies automatically on first connect)"
"$MT" start-tenant "$TENANT"

banner "9/9  remove stale pre-v1.1.0 weechat unit orphan (if present)"
uid="$(id -u "$TENANT" 2>/dev/null || echo '')"
OLD_UNIT="/home/$TENANT/.config/systemd/user/weechat-$TENANT.service"
if [[ -n "$uid" && -f "$OLD_UNIT" ]]; then
  sudo -u "$TENANT" env XDG_RUNTIME_DIR="/run/user/$uid" systemctl --user disable --now "weechat-$TENANT.service" 2>/dev/null || true
  rm -f "$OLD_UNIT"
  sudo -u "$TENANT" env XDG_RUNTIME_DIR="/run/user/$uid" systemctl --user daemon-reload 2>/dev/null || true
  say "  removed $OLD_UNIT (replaced by lunarwing-weechat-$TENANT.service)"
else
  say "  no stale weechat-$TENANT.service unit found (ok)"
fi

# ================================================================================
banner "VERIFY"
"$MT" status "$TENANT" || true
say ""
say "migration history (expect top = 21):"
dpsql "SELECT version, name FROM refinery_schema_history ORDER BY version DESC LIMIT 3;" || true
say ""
say "constraint def (expect UNIQUE NULLS NOT DISTINCT):"
dpsql "SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname='unique_path_per_user';" || true
say ""
say "onboarding flag:"
grep -i 'profile_onboarding_completed' "$CONFIG_FILE" 2>/dev/null || say "  (config.toml not found at $CONFIG_FILE — check manually)"
say ""
if [[ -n "$adapter_port" ]]; then
  say "weechat adapter health (:$adapter_port):"
  curl -fsS --max-time 3 "http://127.0.0.1:$adapter_port/api/health" 2>/dev/null && say "" || say "  (no response on :$adapter_port — check after channels settle)"
fi

# ================================================================================
banner "ROLLBACK (only if needed)"
cat <<EOF
  v1.1.1 stayed rootful and reused the same Docker PG container, so the only DB
  change to undo is V21 (constraint swap + any duplicate-row deletions).

  1) stop:     sudo $MT stop-tenant $TENANT
  2) revert:   sudo -u $TENANT git -c safe.directory=$HOME_DIR -C $HOME_DIR checkout $cur_rev
  3) DB (only if V21 deletions removed needed rows):
       docker start $PG_CONTAINER
       docker exec -i $PG_CONTAINER pg_restore -U $PG_USER -d $PG_DB --clean --if-exists \\
         < "$NEWEST_DUMP"
  4) env/caps (only if they diverged):
       cp -a $BACKUP_DIR/lunarwing.env.bak $ENV_FILE
       cp -a $BACKUP_DIR/weechat.capabilities.json.bak $CAPS_FILE
  5) rebuild + start:
       sudo $MT build-tenant $TENANT --with-wasm
       sudo $MT start-tenant $TENANT

  NOTE: never delete/recreate $PG_CONTAINER — kageho's live data is in its
  writable layer (no named volume at v1.1.1). V21 is idempotent via
  refinery_schema_history, so a binary-only rollback to $cur_rev leaves the DB
  at V21 harmlessly (old code simply ignores it).
EOF

banner "DONE — kageho upgraded to $TARGET"
