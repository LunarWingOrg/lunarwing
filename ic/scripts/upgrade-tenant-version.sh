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
# SOURCE DETECTION: The script auto-detects the tenant's source version via
# `git describe --tags` and branches into a legacy path (v1.0.3–v1.0.8) or
# modern path (>= v1.0.9). Legacy sources require an explicit --target.
#
# Supports source >= v1.0.3.
#
# Run as root:
#   sudo ic/scripts/upgrade-tenant-version.sh <tenant>                 # DRY-RUN
#   sudo ic/scripts/upgrade-tenant-version.sh <tenant> --apply
#     --target <tag>                    git ref to upgrade to (default v1.1.2 for modern sources;
#                                       REQUIRED for legacy sources v1.0.3–v1.0.8)
#     --source-version-override <tag>   force source version detection (escape hatch)
#     --force                           proceed even if source version is unsupported
#     --yes | -y                        skip confirmation prompts (gates still abort on failure)
set -euo pipefail

TARGET="v1.1.2"
TARGET_EXPLICIT=false
APPLY=false
AUTO_YES=false
FORCE=false
SOURCE_VERSION_OVERRIDE=""
SOURCE_AGE=""
SOURCE_MAJOR=0
SOURCE_MINOR=0
SOURCE_PATCH=0
TENANT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)     APPLY=true; shift ;;
    --target)    TARGET="$2"; TARGET_EXPLICIT=true; shift 2 ;;
    --target=*)  TARGET="${1#*=}"; TARGET_EXPLICIT=true; shift ;;
    --source-version-override) SOURCE_VERSION_OVERRIDE="$2"; shift 2 ;;
    --source-version-override=*) SOURCE_VERSION_OVERRIDE="${1#*=}"; shift ;;
    --force)     FORCE=true; shift ;;
    --yes|-y)    AUTO_YES=true; shift ;;
    -*)          printf 'unknown arg: %s\n' "$1" >&2; exit 2 ;;
    *)           [[ -z "$TENANT" ]] || { printf 'unexpected arg: %s\n' "$1" >&2; exit 2; }; TENANT="$1"; shift ;;
  esac
done
[[ -n "$TENANT" ]] || { printf 'usage: %s <tenant> [--apply] [--target <tag>] [--source-version-override <tag>] [--force] [--yes]\n' "$(basename "$0")" >&2; exit 2; }

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

# Failure-rollback trap (MF-5): once an --apply run has taken its verified backup and
# begun mutating, any abort (a `die` or a set -e failure) prints recovery guidance
# instead of leaving the operator with a silently half-applied, stopped tenant.
APPLY_STARTED=false
on_apply_exit() {
  local rc=$?
  trap - EXIT
  if $APPLY_STARTED && (( rc != 0 )); then
    banner "UPGRADE FAILED (exit $rc) — RECOVERY STEPS"
    say "  The run aborted after mutation began; the tenant may be stopped or partially upgraded."
    say "    backup dump : ${NEWEST_DUMP:-<none captured>}"
    say "    pre-upgrade  : ${cur_rev:-<unknown>}"
    say "    1) sudo $MT stop-tenant $TENANT"
    say "    2) sudo -u $TENANT git -c safe.directory=$HOME_DIR -C $HOME_DIR checkout ${cur_rev:-<rev>}"
    say "    3) docker start $PG_CONTAINER && docker exec -i $PG_CONTAINER pg_restore -U $PG_USER -d $PG_DB --clean --if-exists < \"${NEWEST_DUMP:-<dump>}\""
    say "    4) sudo $MT build-tenant $TENANT --with-wasm && sudo $MT render-units $TENANT && sudo $MT start-tenant $TENANT"
    say "  NEVER delete/recreate $PG_CONTAINER — data is in its writable layer (no named volume pre-1.1.4)."
  fi
  exit $rc
}

# ---- prerequisites -------------------------------------------------------------
[[ "$(id -u)" -eq 0 ]] || die "run as root (sudo)"
[[ -x "$MT" ]] || die "mt-admin not found/executable at $MT"
[[ -x "$PF" ]] || warn "weechat pre-flight not found at $PF (weechat checks will be skipped)"
command -v jq >/dev/null 2>&1 || die "jq required"
command -v docker >/dev/null 2>&1 || die "docker required (this tool is for Docker, rootful tenants)"
[[ -f "$REGISTRY" ]] || die "ports registry not found: $REGISTRY"
jq -e ".tenants[\"$TENANT\"]" "$REGISTRY" >/dev/null 2>&1 || die "tenant '$TENANT' not in $REGISTRY"
[[ -d "$HOME_DIR/.git" ]] || die "tenant clone not found at $HOME_DIR"

# ---- source version detection --------------------------------------------------
# Parses git describe --tags to determine if the tenant is a modern (>= v1.0.9)
# or legacy (v1.0.3–v1.0.8) source. Sets SOURCE_MAJOR/MINOR/PATCH and SOURCE_AGE.
detect_source_version() {
  local raw
  if [[ -n "$SOURCE_VERSION_OVERRIDE" ]]; then
    raw="$SOURCE_VERSION_OVERRIDE"
    say "  source version override: $raw"
  else
    raw="$(sudo -u "$TENANT" git -c safe.directory="$HOME_DIR" -C "$HOME_DIR" describe --tags --always 2>/dev/null || echo '?')"
  fi
  SOURCE_MAJOR=0; SOURCE_MINOR=0; SOURCE_PATCH=0
  local parsed
  parsed="$(printf '%s' "$raw" | sed -E 's/^v//; s/-[0-9]+-g[0-9a-f]+$//')"
  if [[ "$parsed" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    SOURCE_MAJOR="${BASH_REMATCH[1]}"
    SOURCE_MINOR="${BASH_REMATCH[2]}"
    SOURCE_PATCH="${BASH_REMATCH[3]}"
  else
    if $FORCE; then
      warn "could not parse version from '$raw' — proceeding due to --force (treating as legacy)"
      SOURCE_AGE="legacy"
      return
    fi
    die "could not parse source version from git describe '$raw'. Use --source-version-override <tag> or --force."
  fi
  local source_dec=$(( SOURCE_MAJOR * 10000 + SOURCE_MINOR * 100 + SOURCE_PATCH ))
  local min_legacy=$(( 1 * 10000 + 0 * 100 + 3 ))
  local min_modern=$(( 1 * 10000 + 0 * 100 + 9 ))
  if (( source_dec >= min_modern )); then
    SOURCE_AGE="modern"
  elif (( source_dec >= min_legacy )); then
    SOURCE_AGE="legacy"
  else
    SOURCE_AGE="unsupported"
    if ! $FORCE; then
      die "source version v${SOURCE_MAJOR}.${SOURCE_MINOR}.${SOURCE_PATCH} is older than v1.0.3 (unsupported). Use --force to override."
    fi
    warn "source version v${SOURCE_MAJOR}.${SOURCE_MINOR}.${SOURCE_PATCH} is unsupported — proceeding due to --force"
  fi
  say "  source: v${SOURCE_MAJOR}.${SOURCE_MINOR}.${SOURCE_PATCH} (age: $SOURCE_AGE)"
}

detect_source_version

# Legacy sources require an explicit --target (no silent default)
if [[ "$SOURCE_AGE" == "legacy" && "$TARGET_EXPLICIT" == false ]]; then
  die "legacy source (v1.0.3–v1.0.8) requires an explicit --target (e.g., --target v1.1.3). Refusing to use default v1.1.2 silently."
fi
# Legacy sources must target a literal vX.Y.Z release tag — no branch / SHA / suffixed ref
# (e.g. a branch named v1.1.0-rootless): a moving ref could pull post-v1.1.4 rootless code
# onto a rootful tenant. And the target cannot exceed v1.1.3 (that's upgrade-tenant.sh).
if [[ "$SOURCE_AGE" == "legacy" ]]; then
  [[ "$TARGET" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] \
    || die "legacy source requires an explicit vX.Y.Z release tag as --target (got '$TARGET'). Branch / SHA / suffixed targets are unsafe (moving ref; could pull post-v1.1.4 rootless code onto a rootful tenant)."
  target_major="${BASH_REMATCH[1]}"; target_minor="${BASH_REMATCH[2]}"; target_patch="${BASH_REMATCH[3]}"
  target_dec=$(( target_major * 10000 + target_minor * 100 + target_patch ))
  max_legacy_target=$(( 1 * 10000 + 1 * 100 + 3 ))
  if (( target_dec > max_legacy_target )); then
    die "legacy source cannot target $TARGET (> v1.1.3). For v1.1.4+ targets (rootless flip), use ic/scripts/upgrade-tenant.sh instead."
  fi
fi

banner "$TENANT upgrade -> $TARGET   (mode: $([ "$APPLY" = true ] && echo APPLY || echo DRY-RUN), source: v${SOURCE_MAJOR}.${SOURCE_MINOR}.${SOURCE_PATCH} ($SOURCE_AGE))"
say "tenant clone : $HOME_DIR"
say "pg container : $PG_CONTAINER (Docker, rootful)"

# ---- shared helper: validate a DB dump file --------------------------
validate_dump() {
  local dump="$1" label="${2:-dump}"
  [[ -f "$dump" ]] || die "$label not found: $dump"
  local sz; sz="$(stat -c%s "$dump" 2>/dev/null || echo 0)"
  (( sz > 1024 )) || die "$label suspiciously small (${sz}B): $dump"
  [[ "$(head -c5 "$dump" 2>/dev/null)" == "PGDMP" ]] || die "$label missing PGDMP magic: $dump"
  say "  verified $label: $dump ($(du -h "$dump" | cut -f1), PGDMP ok)"
}

# ---- shared helper: kick weechat adapter last ------------------------
kick_weechat_adapter() {
  local adapter_url
  adapter_url="$(grep -E '^WS_ADAPTER_URL=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"' || true)"
  if [[ -n "$adapter_url" ]]; then
    say "  letting weechat settle, then restarting the adapter (so it doesn't race the relay)"
    sleep 8
    as_user systemctl --user restart "lunarwing-weechat-adapter-$TENANT.service" 2>/dev/null || warn "could not restart adapter unit"
    local ws=""
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
}

# ---- shared gate: Docker runtime + PG up -----------------------------
gate_docker_and_pg() {
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
  local svn; svn="$(dpsql 'SHOW server_version_num;' | tr -d '[:space:]')"
  [[ "$svn" =~ ^[0-9]+$ ]] || die "could not read server_version_num (got: '$svn')"
  (( svn >= 150000 )) || die "PostgreSQL server_version_num=$svn (<15) — V21 will fail. Bump the PG image first."
  say "  ok: server_version_num=$svn"
}

# ---- shared gate: clean working tree ----------------------------------
gate_clean_tree() {
  banner "GATE 5  tenant working tree is clean  (git checkout $TARGET must not clobber hand-edits)"
  # MF-7: build-tenant regenerates Cargo.lock files; those are build artifacts (the checkout
  # would replace them anyway), NOT hand-edits. Report + restore any modified *Cargo.lock so
  # they don't trip the hand-edit guard, but STILL hard-fail on any OTHER dirty tracked file.
  local dirty_locks; dirty_locks="$(sudo -u "$TENANT" git -c safe.directory="$HOME_DIR" -C "$HOME_DIR" status --short --untracked-files=no -- '*Cargo.lock' 2>/dev/null || true)"
  if [[ -n "$dirty_locks" ]]; then
    say "  restoring build-regenerated Cargo.lock (build artifact; the checkout replaces it):"
    printf '%s\n' "$dirty_locks" | sed 's/^/    /'
    sudo -u "$TENANT" git -c safe.directory="$HOME_DIR" -C "$HOME_DIR" checkout -- '*Cargo.lock' 2>/dev/null || true
  fi
  local dirty; dirty="$(sudo -u "$TENANT" git -c safe.directory="$HOME_DIR" -C "$HOME_DIR" status --short --untracked-files=no 2>/dev/null || true)"
  if [[ -n "$dirty" ]]; then
    printf '%s\n' "$dirty" | sed 's/^/    /'
    die "checkout $TARGET would conflict with hand-edited tracked files (non-Cargo.lock). Reconcile/stash, then re-run."
  fi
  cur_rev="$(sudo -u "$TENANT" git -c safe.directory="$HOME_DIR" -C "$HOME_DIR" describe --tags --always 2>/dev/null || echo '?')"
  say "  ok: clean working tree (current: $cur_rev)"
}

# ---- shared gate: weechat + onboarding --------------------------------
gate_weechat_and_onboarding() {
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
}

# ---- shared gate: V21 dedup + constraint (MF-1/MF-2) ------------------
# memory_documents and its unique_path_per_user constraint both exist since
# V1__initial.sql, so this is valid for EVERY source (legacy or modern) at maxv<21 —
# legacy is NOT special-cased. V21 KEEPs the oldest row per (user_id,COALESCE(agent_id,''),
# path) and DELETEs the rest (cascades to memory_chunks/document_versions), and its
# DROP CONSTRAINT has no IF EXISTS — so verify the constraint is present and require an
# explicit confirm before any dedup deletion. Shared so the two paths can never drift.
gate_migration_state() {
  banner "GATE 2/3/4  migration state (V21 dedup + constraint)"
  local maxv; maxv="$(dpsql 'SELECT COALESCE(max(version),0) FROM refinery_schema_history;' | tr -d '[:space:]')"
  [[ "$maxv" =~ ^[0-9]+$ ]] || die "could not read current migration version (got: '$maxv')"
  say "  current applied migration: V$maxv"
  if (( maxv < 21 )); then
    say "  V21 (null-agent_id dedup + UNIQUE NULLS NOT DISTINCT) is PENDING — enforcing constraint + dup checks"
    local ccount; ccount="$(dpsql "SELECT count(*) FROM pg_constraint WHERE conrelid='memory_documents'::regclass AND conname='unique_path_per_user';" | tr -d '[:space:]')"
    [[ "$ccount" == "1" ]] || die "constraint 'unique_path_per_user' not found (count=$ccount). V21's DROP CONSTRAINT has no IF EXISTS — re-create it (UNIQUE (user_id, agent_id, path)) before upgrading."
    say "  ok: unique_path_per_user present"
    local dupgroups; dupgroups="$(dpsql "SELECT count(*) FROM (SELECT 1 FROM memory_documents GROUP BY user_id, COALESCE(agent_id::text,''), path HAVING count(*)>1) x;" | tr -d '[:space:]')"
    if [[ "$dupgroups" == "0" ]]; then
      say "  ok: no duplicate memory_documents groups (V21 Step 1 is a no-op)"
    else
      warn "$dupgroups duplicate group(s) — V21 will KEEP the oldest per (user_id,COALESCE(agent_id,''),path) and DELETE the rest (cascades to memory_chunks/document_versions). Recoverable from the pre-upgrade backup."
      confirm "  proceed knowing V21 deletes the duplicate losers?" || die "aborted at GATE 4 (no changes made)"
    fi
  else
    say "  V21 already applied (V$maxv >= 21) — no dedup/constraint risk this upgrade"
  fi
}

# ---- shared apply: backup (DB dump via mt-admin + env/ports/caps) -----
# Uses the repo-checkout mt-admin ($MT), which HAS backup-tenant (no inline pg_dump).
# The DB dump lands root-owned in $TENANT_BACKUP_DIR; only the env/ports/caps copies live
# under $BACKUP_DIR, which is locked to 0700 (MF-4).
backup_tenant() {
  banner "1/10  backup (DB dump via mt-admin + env + ports + caps)"
  mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR" 2>/dev/null || true
  "$MT" backup-tenant "$TENANT" || die "backup-tenant failed — refusing to proceed without a DB backup"
  "$MT" list-backups "$TENANT" || true
  NEWEST_DUMP="$(find "$TENANT_BACKUP_DIR" -maxdepth 1 -type f -name '*.dump' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2- || true)"
  validate_dump "$NEWEST_DUMP" "DB dump"
  [[ -f "$ENV_FILE" ]]  && cp -a "$ENV_FILE"  "$BACKUP_DIR/lunarwing.env.bak"            && say "  saved env"
  [[ -f "$REGISTRY" ]]  && cp -a "$REGISTRY"  "$BACKUP_DIR/ports.json.bak"               && say "  saved ports.json"
  [[ -f "$CAPS_FILE" ]] && cp -a "$CAPS_FILE" "$BACKUP_DIR/weechat.capabilities.json.bak" && say "  saved installed caps"
  chown -R "$TENANT:$TENANT" "$BACKUP_DIR" 2>/dev/null || true
}

# ---- shared apply: steps 2-5, 7-10 (stop, checkout, build, install, patch, start, cleanup, adapter) ----
apply_core_steps() {
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

  banner "6/10  render-units"
  if "$MT" render-units "$TENANT" 2>/dev/null; then
    say "  ok: render-units completed via mt-admin"
  else
    say "  render-units not available in mt-admin — attempting via modern mt-admin from repo checkout"
    # shellcheck disable=SC1091
    ( source "$SCRIPT_DIR/lunarwing-mt-admin.sh" --source-only 2>/dev/null && render_tenant_systemd_units "$TENANT" ) \
      || die "render-units failed. Ensure the modern lunarwing-mt-admin.sh is available in the repo checkout."
    say "  ok: render-units completed via sourced modern mt-admin"
  fi

  banner "7/10  patch-env"
  "$MT" patch-env "$TENANT"

  banner "8/10  start-tenant"
  "$MT" start-tenant "$TENANT"

  banner "9/10  remove stale pre-1.1.0 weechat unit orphan (if present)"
  local old_unit="/home/$TENANT/.config/systemd/user/weechat-$TENANT.service"
  if [[ -f "$old_unit" ]]; then
    as_user systemctl --user disable --now "weechat-$TENANT.service" 2>/dev/null || true
    rm -f "$old_unit"
    as_user systemctl --user daemon-reload 2>/dev/null || true
    say "  removed $old_unit (replaced by lunarwing-weechat-$TENANT.service)"
  else
    say "  no stale weechat-$TENANT.service unit (ok)"
  fi

  banner "10/10  weechat adapter: kick LAST"
  kick_weechat_adapter
}

# ---- shared verify ----------------------------------------------------
print_verify() {
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
}

# ================================================================================
# MODERN PATH (SOURCE_AGE=modern): original gate/apply logic, unchanged
# ================================================================================
gates_modern() {
  gate_docker_and_pg
  gate_migration_state
  gate_clean_tree
  gate_weechat_and_onboarding
}

apply_modern() {
  confirm "All gates passed. Upgrade $TENANT $cur_rev -> $TARGET now?" || { say "aborted (no changes made)."; exit 0; }

  backup_tenant
  APPLY_STARTED=true; trap on_apply_exit EXIT

  apply_core_steps
  print_verify

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
}

# ================================================================================
# LEGACY PATH (SOURCE_AGE=legacy): for v1.0.3–v1.0.8 sources
# ================================================================================
gates_legacy() {
  gate_docker_and_pg
  gate_migration_state
  gate_clean_tree
  gate_weechat_and_onboarding

  banner "GATE 8  legacy path warning (NOT yet live-validated)"
  warn "This upgrade path (v1.0.3-era -> v1.1.x) has NOT been live-validated."
  warn "Proceed with caution. Ensure you have backups before continuing."
  confirm "  proceed with legacy upgrade to $TARGET?" || die "aborted at GATE 8 (no changes made)"
}

apply_legacy() {
  confirm "All legacy gates passed. Upgrade $TENANT $cur_rev -> $TARGET now?" || { say "aborted (no changes made)."; exit 0; }

  backup_tenant
  APPLY_STARTED=true; trap on_apply_exit EXIT

  apply_core_steps
  print_verify
  print_rollback_legacy
}

print_rollback_legacy() {
  banner "ROLLBACK (only if needed)"
  cat <<EOF
  Rootful + same Docker PG container reused. DB changes are additive migrations (V19+).
    1) sudo $MT stop-tenant $TENANT
    2) sudo -u $TENANT git -c safe.directory=$HOME_DIR -C $HOME_DIR checkout $cur_rev
    3) DB (inline pg_restore from backup):
         docker start $PG_CONTAINER
         docker exec -i $PG_CONTAINER pg_restore -U $PG_USER -d $PG_DB --clean --if-exists < "$NEWEST_DUMP"
    4) env/caps (only if diverged): cp -a $BACKUP_DIR/lunarwing.env.bak $ENV_FILE ; cp -a $BACKUP_DIR/weechat.capabilities.json.bak $CAPS_FILE
    5) sudo $MT build-tenant $TENANT --with-wasm && sudo $MT render-units $TENANT && sudo $MT start-tenant $TENANT
  NEVER delete/recreate $PG_CONTAINER — data is in its writable layer (no named volume pre-1.1.4).
EOF
}

# ================================================================================
# DISPATCH: run the correct path based on SOURCE_AGE
# ================================================================================
if [[ "$SOURCE_AGE" == "legacy" ]]; then
  gates_legacy
else
  gates_modern
fi

if ! $APPLY; then
  banner "DRY-RUN complete — gates evaluated, NOTHING changed"
  say "If green, run:  sudo $SCRIPT_DIR/$(basename "$0") $TENANT --apply --target $TARGET"
  exit 0
fi

if [[ "$SOURCE_AGE" == "legacy" ]]; then
  apply_legacy
else
  apply_modern
fi

banner "DONE — $TENANT upgraded to $TARGET"
