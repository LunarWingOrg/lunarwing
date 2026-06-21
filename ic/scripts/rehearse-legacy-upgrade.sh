#!/usr/bin/env bash
#
# rehearse-legacy-upgrade.sh — build a GENUINE pre-reflex (maxv<19) fixture tenant,
# seed a duplicate NULL-agent_id memory_documents group, run the legacy upgrade path,
# and ASSERT the V21 dedup actually ran (dup group collapsed, counts consistent).
# Modeled after rehearse-testbot.sh.
#
# Why build the fixture at the SOURCE ref (not HEAD): a fresh add-tenant boots at HEAD
# and migrates straight to V21, so the destructive dedup path is never exercised. We
# bring up an EMPTY PG (add-tenant --no-health, no daemon), check out the legacy source,
# build + start THAT, so refinery stops at the legacy head (V1..V18), then seed the
# hazard. NOTE: building old (v1.0.x) code with the current toolchain MAY fail — that is
# itself a useful finding. Finish/validate this harness on the MT test-VM before trusting
# the upgrade tool on a real tenant.
#
# Usage (run as root):
#   sudo ic/scripts/rehearse-legacy-upgrade.sh up         # build fixture @ source ref + seed dups
#   sudo ic/scripts/rehearse-legacy-upgrade.sh verify     # run the upgrade + assert dedup
#   sudo ic/scripts/rehearse-legacy-upgrade.sh --cleanup  # tear down
#   sudo ic/scripts/rehearse-legacy-upgrade.sh --dry-run  # print plan, no changes
#     --name <t>        rehearsal tenant name (default rehearse-legacy)
#     --source-ref <r>  legacy source tag to build the fixture at (default v1.0.4)
#     --target <tag>    upgrade target (default v1.1.2)
set -euo pipefail

NAME="rehearse-legacy"
ACTION="up"
DRY_RUN=false
AUTO_YES=false
SOURCE_REF="v1.0.4"
TARGET="v1.1.2"
DUP_USER="rehearsal-dup-user"
DUP_PATH="rehearsal/dup.md"

while [[ $# -gt 0 ]]; do
  case "$1" in
    up)            ACTION="up"; shift ;;
    verify)        ACTION="verify"; shift ;;
    --cleanup)     ACTION="cleanup"; shift ;;
    --dry-run)     DRY_RUN=true; shift ;;
    --yes|-y)      AUTO_YES=true; shift ;;
    --name)        NAME="$2"; shift 2 ;;
    --source-ref)  SOURCE_REF="$2"; shift 2 ;;
    --target)      TARGET="$2"; shift 2 ;;
    *)             printf 'unknown arg: %s\n' "$1" >&2; exit 2 ;;
  esac
done

say()    { printf '%s\n' "$*"; }
die()    { printf 'error: %s\n' "$*" >&2; exit 1; }
banner() { printf '\n========== %s ==========\n' "$*"; }
confirm(){ $AUTO_YES && return 0; local a; read -r -p "$1 [y/N] " a; [[ "$a" == y || "$a" == Y ]]; }
run()    { if $DRY_RUN; then printf '  [dry-run] %s\n' "$*"; return 0; fi; printf '  + %s\n' "$*"; "$@"; }

[[ "$(id -u)" -eq 0 ]] || die "run as root (sudo) — mt-admin needs root"
NAME="$(printf '%s' "$NAME" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')"
[[ -n "$NAME" ]] || die "invalid --name"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MT="$SCRIPT_DIR/lunarwing-mt-admin.sh"
UPGRADE="$SCRIPT_DIR/upgrade-tenant-version.sh"
REGISTRY="${LUNARWING_PORTS_REGISTRY:-/etc/lunarwing/ports.json}"

[[ -x "$MT" ]] || die "mt-admin not found/executable at $MT"
[[ -f "$UPGRADE" ]] || die "upgrade-tenant-version.sh not found at $UPGRADE"

HOME_DIR="/home/$NAME/lunarwing"
PG="lunarwing-pg-$NAME"
dpsql() { docker exec "$PG" psql -U lunarwing -d lunarwing -tAc "$1"; }
dupgroups_for() { dpsql "SELECT count(*) FROM (SELECT 1 FROM memory_documents WHERE user_id='$DUP_USER' GROUP BY user_id, COALESCE(agent_id::text,''), path HAVING count(*)>1) x;" | tr -d '[:space:]'; }
rows_for() { dpsql "SELECT count(*) FROM memory_documents WHERE user_id='$DUP_USER';" | tr -d '[:space:]'; }

# ---- cleanup action ---------------------------------------------------
if [[ "$ACTION" == "cleanup" ]]; then
  banner "Tear down rehearsal tenant '$NAME'"
  confirm "Remove tenant '$NAME' (DESTRUCTIVE: remove-tenant --purge)?" || die "aborted"
  run "$MT" remove-tenant "$NAME" --purge
  say "removed '$NAME'."
  exit 0
fi

# ---- up action: build a genuine pre-reflex fixture --------------------
if [[ "$ACTION" == "up" ]]; then
  banner "Build rehearsal fixture '$NAME' @ $SOURCE_REF (genuine maxv<19 DB)"
  $DRY_RUN && say "*** DRY RUN — no changes will be made ***"

  if [[ -f "$REGISTRY" ]] && jq -e ".tenants[\"$NAME\"]" "$REGISTRY" >/dev/null 2>&1; then
    die "tenant '$NAME' already exists in ports.json — use --name <other> or run --cleanup first"
  fi
  confirm "Create rehearsal tenant '$NAME' on THIS host?" || die "aborted"

  # 1) Provision PG + units WITHOUT starting the daemon — leaves an EMPTY, unmigrated DB.
  add_flags=()
  grep -q 'no-health' "$MT" && add_flags+=(--no-health)
  run "$MT" add-tenant "$NAME" "${add_flags[@]}"

  # 2) Check out the LEGACY source BEFORE building, so the binary we boot is the legacy
  #    one and refinery stops at the legacy head (V1..V18), not HEAD/V21.
  banner "Checkout $SOURCE_REF + build the legacy binary"
  if ! $DRY_RUN; then
    sudo -u "$NAME" git -c safe.directory="$HOME_DIR" -C "$HOME_DIR" fetch --tags --prune origin || die "git fetch failed"
    sudo -u "$NAME" git -c safe.directory="$HOME_DIR" -C "$HOME_DIR" checkout "$SOURCE_REF" || die "git checkout $SOURCE_REF failed — tag may not exist"
    say "  checked out: $(sudo -u "$NAME" git -c safe.directory="$HOME_DIR" -C "$HOME_DIR" describe --tags --always)"
  fi
  run "$MT" build-tenant "$NAME" --with-wasm   # may fail building old code — that is a finding
  run "$MT" install-wasm "$NAME"

  # 3) Start the legacy daemon so refinery migrates the empty DB up to the legacy head.
  run "$MT" start-tenant "$NAME"

  if ! $DRY_RUN; then
    banner "Verify fixture is a genuine pre-reflex (maxv<19) DB"
    maxv="$(dpsql 'SELECT COALESCE(max(version),0) FROM refinery_schema_history;' | tr -d '[:space:]')"
    [[ "$maxv" =~ ^[0-9]+$ ]] || die "could not read migration version (got '$maxv') — did the legacy daemon boot + migrate?"
    say "  fixture migration head: V$maxv"
    (( maxv < 19 )) || die "fixture is at V$maxv (>=19) — not a pre-reflex fixture; the dedup path won't be exercised. Try an older --source-ref, or check that add-tenant did not boot at HEAD."

    banner "Seed a duplicate NULL-agent_id memory_documents group (the V21 hazard)"
    dpsql "INSERT INTO memory_documents (user_id, agent_id, path, content, created_at) VALUES
      ('$DUP_USER', NULL, '$DUP_PATH', 'KEEP oldest',  NOW() - INTERVAL '2 hours'),
      ('$DUP_USER', NULL, '$DUP_PATH', 'DELETE newer', NOW() - INTERVAL '1 hour');" >/dev/null \
      || die "failed to seed duplicate rows (schema mismatch at $SOURCE_REF?)"
    before="$(rows_for)"; dupg="$(dupgroups_for)"
    say "  seeded: $before rows for $DUP_USER, $dupg duplicate group(s)"
    (( before >= 2 && dupg >= 1 )) || die "seed did not create a dup group (rows=$before groups=$dupg)"
  fi

  banner "Next: run the upgrade rehearsal"
  say "  sudo ic/scripts/rehearse-legacy-upgrade.sh verify --name $NAME --source-ref $SOURCE_REF --target $TARGET"
  say "  tear down:  sudo ic/scripts/rehearse-legacy-upgrade.sh --cleanup --name $NAME"
  exit 0
fi

# ---- verify action: run the upgrade and ASSERT the dedup happened -----
if [[ "$ACTION" == "verify" ]]; then
  banner "Run legacy upgrade on fixture '$NAME' and assert V21 dedup"

  [[ -f "$REGISTRY" ]] || die "ports registry not found: $REGISTRY"
  jq -e ".tenants[\"$NAME\"]" "$REGISTRY" >/dev/null 2>&1 || die "tenant '$NAME' not in ports.json — run 'up' first"
  [[ "$(docker inspect -f '{{.State.Running}}' "$PG" 2>/dev/null)" == "true" ]] \
    || die "'$PG' is not running — is the rehearsal fixture up?"

  before="$(rows_for)"
  say "  pre-upgrade: $before rows for $DUP_USER"

  if $DRY_RUN; then
    say "[dry-run] would run: $UPGRADE $NAME --source-version-override $SOURCE_REF --apply --target $TARGET --yes"
    exit 0
  fi

  # Capture the exit code WITHOUT letting set -e abort first (the old `rc=$?` was dead code).
  rc=0
  "$UPGRADE" "$NAME" --source-version-override "$SOURCE_REF" --apply --target "$TARGET" --yes || rc=$?

  banner "Rehearsal assertions"
  (( rc == 0 )) || die "FAIL: upgrade exited $rc — investigate above. Fixture left running; tear down with --cleanup."
  maxv="$(dpsql 'SELECT COALESCE(max(version),0) FROM refinery_schema_history;' | tr -d '[:space:]')"
  after="$(rows_for)"; dupg="$(dupgroups_for)"
  say "  migration head : V$maxv     (expect >= 21)"
  say "  $DUP_USER rows : $before -> $after  (expect one fewer — dup loser deleted)"
  say "  dup groups now : $dupg     (expect 0)"
  fail=0
  (( maxv >= 21 ))           || { say "  ASSERT FAIL: maxv $maxv < 21"; fail=1; }
  (( dupg == 0 ))            || { say "  ASSERT FAIL: $dupg dup group(s) remain"; fail=1; }
  (( after == before - 1 )) || { say "  ASSERT FAIL: expected $((before-1)) rows, got $after"; fail=1; }
  (( fail == 0 )) || die "rehearsal assertions FAILED — the dedup did not behave as expected."
  say ""
  say "GO: legacy upgrade dedup verified on '$NAME' (V$maxv, dup group collapsed, counts consistent)."
  say "Tear down:  sudo ic/scripts/rehearse-legacy-upgrade.sh --cleanup --name $NAME"
fi
