#!/usr/bin/env bash
#
# upgrade-tenant-version.sh — generalized in-place VERSION upgrade of ONE existing
# multi-tenant tenant (Docker, rootful) to a target release tag (default v1.1.2).
#
# Generalizes the one-off upgrade-tenant-kageho.sh. It is NOT the v1.1.0->v1.1.4
# rootless-migration tool (ic/scripts/upgrade-tenant.sh) — this stays rootful and
# is for 1.0.x/1.1.x -> 1.1.x version bumps on the SAME Docker host, where the only
# schema delta is additive reflex tables (V19/V20) and the self-healing dedup V21.
#
# Lessons baked in from the kageho 1.0.x->1.1.2 upgrade (2026-06-18):
#   * RENDER UNITS before start. The in-place path (build/patch-env/start) does NOT
#     render systemd units, and pre-1.1.0 tenants have the OLD weechat unit name
#     (weechat-<t> vs lunarwing-weechat-<t>), so `start-tenant` aborts on
#     "Unit lunarwing-weechat-<t>.service does not exist" and never starts the
#     daemon. `render-units` creates the renamed units first.
#   * START THE WEECHAT ADAPTER LAST + kick it. On a cold all-at-once start the
#     adapter races weechat's relay readiness, gets a 401, and a 401 is not a crash
#     so Restart=on-failure won't recover it. We restart the adapter after weechat
#     settles and verify ws_connected.
#   * RELAY_PASSWORD lives only in the env (patch-env never manages it). If the
#     adapter can't auth to weechat (401), the env RELAY_PASSWORD must match
#     weechat's relay.network.password — surfaced at the end if ws_connected=false.
#
# DEFAULTS TO READ-ONLY DRY-RUN. Changes nothing until --apply.
#
# Run as root:
#   sudo ic/scripts/upgrade-tenant-version.sh <tenant>                 # DRY-RUN
#   sudo ic/scripts/upgrade-tenant-version.sh <tenant> --apply
#     --target <tag>   git ref to upgrade to (default v1.1.2)
#     --yes | -y       skip confirmation prompts (gates still abort on failure)
set -euo pipefail

TARGET="v1.1.2"
APPLY=false
AUTO_YES=false
TENANT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)     APPLY=true; shift ;;
    --target)    TARGET="$2"; shift 2 ;;
    --target=*)  TARGET="${1#*=}"; shift ;;
    --yes|-y)    AUTO_YES=true; shift ;;
    -*)          printf 'unknown arg: %s\n' "$1" >&2; exit 2 ;;
    *)           [[ -z "$TENANT" ]] || { printf 'unexpected arg: %s\n' "$1" >&2; exit 2; }; TENANT="$1"; shift ;;
  esac
done
[[ -n "$TENANT" ]] || { printf 'usage: %s <tenant> [--apply] [--target <tag>] [--yes]\n' "$(basename "$0")" >&2; exit 2; }

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

# Defensive: Docker stays rootful regardless, but pin it so a v1.1.4-class mt-admin
# can never flip the tenant toward a rootless store.
export LUNARWING_MT_ROOTLESS=false

say()    { printf '%s\n' "$*"; }
warn()   { printf 'WARN: %s\n' "$*" >&2; }
die()    { printf 'error: %s\n' "$*" >&2; exit 1; }
banner() { printf '\n========== %s ==========\n' "$*"; }
confirm(){ $AUTO_YES && return 0; local a; read -r -p "$1 [y/N] " a; [[ "$a" == y || "$a" == Y ]]; }
dpsql()  { docker exec "$PG_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -tAc "$1"; }
as_user(){ sudo -u "$TENANT" XDG_RUNTIME_DIR="/run/user/$(id -u "$TENANT")" "$@"; }

# ---- prerequisites -------------------------------------------------------------
[[ "$(id -u)" -eq 0 ]] || die "run as root (sudo)"
[[ -x "$MT" ]] || die "mt-admin not found/executable at $MT"
[[ -x "$PF" ]] || warn "weechat pre-flight not found at $PF (weechat checks will be skipped)"
command -v jq >/dev/null 2>&1 || die "jq required"
command -v docker >/dev/null 2>&1 || die "docker required (this tool is for Docker, rootful tenants)"
[[ -f "$REGISTRY" ]] || die "ports registry not found: $REGISTRY"
jq -e ".tenants[\"$TENANT\"]" "$REGISTRY" >/dev/null 2>&1 || die "tenant '$TENANT' not in $REGISTRY"
[[ -d "$HOME_DIR/.git" ]] || die "tenant clone not found at $HOME_DIR"

banner "$TENANT upgrade -> $TARGET   (mode: $([ "$APPLY" = true ] && echo APPLY || echo DRY-RUN))"
say "tenant clone : $HOME_DIR"
say "pg container : $PG_CONTAINER (Docker, rootful)"

# ================================================================================
# GATES (read-only; run in BOTH modes; any failure aborts)
# ================================================================================
banner "GATE 0  container runtime is Docker (podman is unsupported before 1.1.4)"
if ! docker inspect "$PG_CONTAINER" >/dev/null 2>&1; then
  if command -v podman >/dev/null 2>&1 && podman inspect "$PG_CONTAINER" >/dev/null 2>&1; then
    die "'$PG_CONTAINER' is a PODMAN container — unsupported for a <1.1.4 target. Aborting."
  fi
  die "Postgres container '$PG_CONTAINER' not found under docker. Is the tenant running?"
fi
[[ "$(docker inspect -f '{{.State.Running}}' "$PG_CONTAINER" 2>/dev/null)" == "true" ]] \
  || die "'$PG_CONTAINER' is not running — start the tenant before upgrading (backup needs PG up)"
say "  ok: docker container '$PG_CONTAINER' is up"

banner "GATE 1  PostgreSQL >= 15  (V21 uses UNIQUE NULLS NOT DISTINCT)"
svn="$(dpsql 'SHOW server_version_num;' | tr -d '[:space:]')"
[[ "$svn" =~ ^[0-9]+$ ]] || die "could not read server_version_num (got: '$svn')"
(( svn >= 150000 )) || die "PostgreSQL server_version_num=$svn (<15) — V21 will fail. Bump the PG image first."
say "  ok: server_version_num=$svn"

banner "GATE 2/3/4  migration state"
maxv="$(dpsql 'SELECT COALESCE(max(version),0) FROM refinery_schema_history;' | tr -d '[:space:]')"
[[ "$maxv" =~ ^[0-9]+$ ]] || die "could not read current migration version (got: '$maxv')"
say "  current applied migration: V$maxv"
if (( maxv < 21 )); then
  say "  V21 (null-agent_id dedup + UNIQUE NULLS NOT DISTINCT) is PENDING — enforcing constraint + dup checks"
  ccount="$(dpsql "SELECT count(*) FROM pg_constraint WHERE conrelid='memory_documents'::regclass AND conname='unique_path_per_user';" | tr -d '[:space:]')"
  [[ "$ccount" == "1" ]] || die "constraint 'unique_path_per_user' not found (count=$ccount). V21's DROP CONSTRAINT has no IF EXISTS — re-create it (UNIQUE (user_id, agent_id, path)) before upgrading."
  say "  ok: unique_path_per_user present"
  dupgroups="$(dpsql "SELECT count(*) FROM (SELECT 1 FROM memory_documents GROUP BY user_id, COALESCE(agent_id::text,''), path HAVING count(*)>1) x;" | tr -d '[:space:]')"
  if [[ "$dupgroups" == "0" ]]; then
    say "  ok: no duplicate memory_documents groups (V21 Step 1 is a no-op)"
  else
    warn "$dupgroups duplicate group(s) — V21 will KEEP the oldest per (user_id,COALESCE(agent_id,''),path) and DELETE the rest (cascades to memory_chunks/document_versions). Recoverable from the pre-upgrade backup."
    confirm "  proceed knowing V21 deletes the duplicate losers?" || die "aborted at GATE 4 (no changes made)"
  fi
else
  say "  V21 already applied (V$maxv >= 21) — no dedup/constraint risk this upgrade"
fi

banner "GATE 5  tenant working tree is clean  (git checkout $TARGET must not clobber hand-edits)"
dirty="$(sudo -u "$TENANT" git -c safe.directory="$HOME_DIR" -C "$HOME_DIR" status --short --untracked-files=no 2>/dev/null || true)"
if [[ -n "$dirty" ]]; then
  printf '%s\n' "$dirty" | sed 's/^/    /'
  die "checkout $TARGET would conflict with hand-edited tracked files. Reconcile/stash, then re-run."
fi
cur_rev="$(sudo -u "$TENANT" git -c safe.directory="$HOME_DIR" -C "$HOME_DIR" describe --tags --always 2>/dev/null || echo '?')"
say "  ok: clean working tree (current: $cur_rev)"

if [[ -x "$PF" ]]; then
  banner "GATE 6  WeeChat pre-flight (read-only)"
  "$PF" "$TENANT" || warn "weechat pre-flight returned non-zero — review above before --apply"
fi

banner "GATE 7  onboarding flag (anti-bootstrap)"
if [[ -f "$CONFIG_FILE" ]] && grep -q 'profile_onboarding_completed *= *true' "$CONFIG_FILE"; then
  say "  ok: profile_onboarding_completed = true"
else
  warn "profile_onboarding_completed=true not confirmed in $CONFIG_FILE — re-verify after upgrade"
fi

# ================================================================================
if ! $APPLY; then
  banner "DRY-RUN complete — gates evaluated, NOTHING changed"
  say "If green, run:  sudo $SCRIPT_DIR/$(basename "$0") $TENANT --apply --target $TARGET"
  exit 0
fi

# ================================================================================
# APPLY
# ================================================================================
confirm "All gates passed. Upgrade $TENANT $cur_rev -> $TARGET now?" || { say "aborted (no changes made)."; exit 0; }

banner "1/10  backup (DB dump + env + ports + caps)"
mkdir -p "$BACKUP_DIR"
"$MT" backup-tenant "$TENANT" || die "backup-tenant failed — refusing to proceed without a DB backup"
"$MT" list-backups "$TENANT" || true
NEWEST_DUMP="$(ls -1t "$TENANT_BACKUP_DIR"/*.dump 2>/dev/null | head -1 || true)"
[[ -n "$NEWEST_DUMP" && -f "$NEWEST_DUMP" ]] || die "no .dump in $TENANT_BACKUP_DIR after backup-tenant — aborting"
dump_size="$(stat -c%s "$NEWEST_DUMP" 2>/dev/null || echo 0)"
(( dump_size > 1024 )) || die "DB dump suspiciously small (${dump_size}B): $NEWEST_DUMP"
[[ "$(head -c5 "$NEWEST_DUMP" 2>/dev/null)" == "PGDMP" ]] || die "DB dump missing PGDMP magic: $NEWEST_DUMP"
say "  verified DB dump: $NEWEST_DUMP (${dump_size}B, PGDMP ok)"
[[ -f "$ENV_FILE" ]]  && cp -a "$ENV_FILE"  "$BACKUP_DIR/lunarwing.env.bak"            && say "  saved env"
[[ -f "$REGISTRY" ]]  && cp -a "$REGISTRY"  "$BACKUP_DIR/ports.json.bak"               && say "  saved ports.json"
[[ -f "$CAPS_FILE" ]] && cp -a "$CAPS_FILE" "$BACKUP_DIR/weechat.capabilities.json.bak" && say "  saved installed caps"
chown -R "$TENANT:$TENANT" "$HOME_DIR/backups" 2>/dev/null || true

banner "2/10  stop-tenant"
"$MT" stop-tenant "$TENANT"

banner "3/10  fetch tags + checkout $TARGET (as $TENANT)"
sudo -u "$TENANT" git -c safe.directory="$HOME_DIR" -C "$HOME_DIR" fetch --tags --prune origin || die "git fetch failed"
sudo -u "$TENANT" git -c safe.directory="$HOME_DIR" -C "$HOME_DIR" checkout "$TARGET" || die "git checkout $TARGET failed"
[[ -d "$HOME_DIR/ic/migrations" ]] || die "ic/migrations missing from checkout — wrong ref? Aborting before build."
say "  now at: $(sudo -u "$TENANT" git -c safe.directory="$HOME_DIR" -C "$HOME_DIR" describe --tags --always)"

banner "4/10  build-tenant --with-wasm"
"$MT" build-tenant "$TENANT" --with-wasm

banner "5/10  install-wasm"
"$MT" install-wasm "$TENANT"

banner "6/10  render-units  (CRITICAL: creates renamed lunarwing-weechat-<t> + adapter units; pre-1.1.0 tenants lack them)"
"$MT" render-units "$TENANT"

banner "7/10  patch-env  (additive: adds missing port vars; never overwrites RELAY_PASSWORD etc.)"
"$MT" patch-env "$TENANT"

banner "8/10  start-tenant  (daemon applies pending migrations on boot)"
"$MT" start-tenant "$TENANT"

banner "9/10  remove stale pre-1.1.0 weechat unit orphan (if present)"
OLD_UNIT="/home/$TENANT/.config/systemd/user/weechat-$TENANT.service"
if [[ -f "$OLD_UNIT" ]]; then
  as_user systemctl --user disable --now "weechat-$TENANT.service" 2>/dev/null || true
  rm -f "$OLD_UNIT"
  as_user systemctl --user daemon-reload 2>/dev/null || true
  say "  removed $OLD_UNIT (replaced by lunarwing-weechat-$TENANT.service)"
else
  say "  no stale weechat-$TENANT.service unit (ok)"
fi

banner "10/10  weechat adapter: kick LAST (avoid the relay-readiness race) + verify ws_connected"
adapter_url="$(grep -E '^WS_ADAPTER_URL=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"' || true)"
if [[ -n "$adapter_url" ]]; then
  say "  letting weechat settle, then restarting the adapter (so it doesn't race the relay)"
  sleep 8
  as_user systemctl --user restart "lunarwing-weechat-adapter-$TENANT.service" 2>/dev/null || warn "could not restart adapter unit"
  ws=""
  for _ in $(seq 1 15); do
    ws="$(curl -s --max-time 4 "${adapter_url%/}/api/health" 2>/dev/null | grep -o '"ws_connected":[a-z]*' | cut -d: -f2 || true)"
    [[ "$ws" == "true" ]] && break
    sleep 2
  done
  if [[ "$ws" == "true" ]]; then
    say "  ok: adapter ws_connected=true (weechat relay leg up)"
  else
    warn "adapter ws_connected != true at ${adapter_url}/api/health."
    say  "    Most common cause: a 401 — the env RELAY_PASSWORD does not match weechat's relay.network.password."
    say  "    Check:  curl -s ${adapter_url%/}/api/health   (look at ws_error)"
    say  "    Fix:    set RELAY_PASSWORD in $ENV_FILE to weechat's relay password (grep it from"
    say  "            /home/$TENANT/.config/weechat/relay.conf), then:"
    say  "            sudo -u $TENANT XDG_RUNTIME_DIR=/run/user/\$(id -u $TENANT) systemctl --user restart lunarwing-weechat-adapter-$TENANT.service"
    say  "    Or go passwordless on loopback: /set relay.network.password \"\" + /save in the weechat tmux, then restart the adapter."
  fi
else
  warn "WS_ADAPTER_URL not found in env — skipping adapter health check; verify weechat manually"
fi

# ================================================================================
banner "VERIFY"
"$MT" status "$TENANT" || true
say ""
say "migration history (expect top covers V21):"
dpsql "SELECT version, name FROM refinery_schema_history ORDER BY version DESC LIMIT 4;" || true
say ""
say "constraint def (expect UNIQUE NULLS NOT DISTINCT):"
dpsql "SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname='unique_path_per_user';" || true
say ""
grep -i 'profile_onboarding_completed' "$CONFIG_FILE" 2>/dev/null || say "(config.toml not found at $CONFIG_FILE — check manually)"

banner "ROLLBACK (only if needed)"
cat <<EOF
  Rootful + same Docker PG container reused, so the only DB change to undo is V21
  (and additive V19/V20 tables, harmless to leave).
    1) sudo $MT stop-tenant $TENANT
    2) sudo -u $TENANT git -c safe.directory=$HOME_DIR -C $HOME_DIR checkout $cur_rev
    3) DB (only if V21 deletions removed needed rows):
         docker start $PG_CONTAINER
         docker exec -i $PG_CONTAINER pg_restore -U $PG_USER -d $PG_DB --clean --if-exists < "$NEWEST_DUMP"
    4) env/caps (only if diverged): cp -a $BACKUP_DIR/lunarwing.env.bak $ENV_FILE ; cp -a $BACKUP_DIR/weechat.capabilities.json.bak $CAPS_FILE
    5) sudo $MT build-tenant $TENANT --with-wasm && sudo $MT render-units $TENANT && sudo $MT start-tenant $TENANT
  NEVER delete/recreate $PG_CONTAINER — data is in its writable layer (no named volume pre-1.1.4).
EOF

banner "DONE — $TENANT upgraded to $TARGET"
