#!/usr/bin/env bash
#
# import-tenant.sh — recreate a tenant on a FRESH LunarWing host from a bundle made
# by export-tenant.sh (see docs/ops/MT-MACHINE-MIGRATION.md). MACHINE MIGRATION.
#
# Runs on the NEW (target) host with a v1.1.4-class mt-admin. Init-system agnostic:
# all init/runtime-specific work is delegated to lunarwing-mt-admin.sh, which
# auto-detects systemd vs OpenRC and rootless-podman vs rootful-docker. The new
# host's init system need not match the old host's.
#
# Flow:
#   add-tenant --no-health (fresh: clone, ports, THROWAWAY secrets, empty PG, units;
#     NO daemon) -> build-tenant + workers -> INJECT carried secrets/config (incl.
#     SECRETS_MASTER_KEY — without it the restored DB's encrypted secrets are dead;
#     verified verbatim before restore) -> restore-tenant (DB) -> restore state dir
#     (OMEMO/workspace) -> install-wasm (fresh v1.1.4 artifacts) -> [--start] start.
#
# Intra-host tokens (gateway/bridge/webhook/relay) are NOT carried — add-tenant minted
# fresh, self-consistent ones (so config.toml's worker auth matches the gateway token).
# Gateway-UI / external-webhook clients re-authenticate after cutover.
#
# CUTOVER: the new daemon uses the SAME XMPP JID as the old one; two simultaneous
# logins conflict. Import STAGES without starting by default. Starting requires you
# to confirm the old side is stopped (export already stops it) — this confirmation is
# NOT satisfied by --yes alone; pass --old-stopped for an unattended start.
#
# Usage (run as root on the new host):
#   sudo ic/scripts/import-tenant.sh <bundle.tar> [--name <t>] [--start] [--old-stopped]
#        [--with-nanocode] [--with-pebble] [--with-opencode] [--with-toolchains]
#        [--with-vision] [--docker-group] [--tensorzero-url <url>]
#        [--dry-run] [--yes] [--force]
set -euo pipefail

BUNDLE=""
NAME_OVERRIDE=""
DO_START=false
OLD_STOPPED=false
WITH_DOCKER_GROUP=false
WITH_NANOCODE=false
WITH_PEBBLE=false
WITH_OPENCODE=false
WITH_TOOLCHAINS=false
WITH_VISION=false
TENSORZERO_URL=""
DRY_RUN=false
AUTO_YES=false
FORCE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)          NAME_OVERRIDE="$2"; shift 2 ;;
    --start)         DO_START=true; shift ;;
    --old-stopped)   OLD_STOPPED=true; shift ;;
    --docker-group)  WITH_DOCKER_GROUP=true; shift ;;
    --tensorzero-url) TENSORZERO_URL="$2"; shift 2 ;;
    --with-nanocode) WITH_NANOCODE=true; shift ;;
    --with-pebble)   WITH_PEBBLE=true; shift ;;
    --with-opencode)   WITH_OPENCODE=true; shift ;;
    --with-toolchains) WITH_TOOLCHAINS=true; shift ;;
    --with-vision)     WITH_VISION=true; shift ;;
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
# ENVIRON, not -v) and CR-tolerant; preserves the live file's inode/owner/mode. The
# read loop's `|| [[ -n "$line" ]]` keeps a final line without a trailing newline.
inject_keys() {  # <manifest> <live_env>
  local man="$1" live="$2" line key tmp
  [[ -f "$man" && -f "$live" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
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

[[ -n "$BUNDLE" ]] || die "usage: $0 <bundle.tar> [--name <t>] [--start] [--old-stopped] [--with-nanocode] [--with-pebble] [--with-opencode] [--with-toolchains] [--with-vision] [--docker-group] [--tensorzero-url <url>] [--dry-run] [--yes] [--force]"
[[ -f "$BUNDLE" ]] || die "bundle not found: $BUNDLE"
[[ "$(id -u)" -eq 0 ]] || die "run as root (sudo) — mt-admin needs root"
command -v jq  >/dev/null 2>&1 || die "jq required"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MT="$SCRIPT_DIR/lunarwing-mt-admin.sh"
WEECHAT_PREFLIGHT="$SCRIPT_DIR/lunarwing-weechat-preflight.sh"
PORTS_REGISTRY="${LUNARWING_PORTS_REGISTRY:-/etc/lunarwing/ports.json}"
[[ -x "$MT" ]] || die "mt-admin not found/executable at $MT"
[[ -x "$WEECHAT_PREFLIGHT" ]] || die "WeeChat preflight not found/executable at $WEECHAT_PREFLIGHT"
grep -qE '^\s*restore-tenant\)' "$MT" || die "mt-admin at $MT predates restore-tenant (need a v1.1.4-class host)"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
chmod 0700 "$WORK"
tar xf "$BUNDLE" -C "$WORK" || die "failed to unpack bundle $BUNDLE"
[[ -f "$WORK/meta.txt" ]] || die "bundle missing meta.txt — not an export-tenant.sh bundle?"

meta() { sed -n "s/^$1=//p" "$WORK/meta.txt" | head -1; }
manifest_value() {
  local key="$1" file="${2:-$WORK/manifest-lunarwing.env}" value
  value="$(sed -n "s/^${key}=//p" "$file" 2>/dev/null | head -1)"
  printf '%s' "${value%$'\r'}"
}
# Sanitize the tenant name the same way mt-admin does ([a-z0-9-]), so our own
# path/getent/chown use exactly the name mt-admin will use internally.
RAW_NAME="${NAME_OVERRIDE:-$(meta tenant)}"
TENANT="$(printf '%s' "$RAW_NAME" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')"
[[ -n "$TENANT" ]] || die "could not determine a valid tenant name (got '$RAW_NAME'; pass --name)"
[[ "$TENANT" == "$RAW_NAME" ]] || note "tenant name sanitized: '$RAW_NAME' -> '$TENANT'"
SRC_VER="$(meta source_version)"; DB_BACKEND="$(meta db_backend)"; DB_BACKEND="${DB_BACKEND:-postgres}"

banner "Import tenant '$TENANT' (from source $SRC_VER, db $DB_BACKEND)"
$DRY_RUN && say "*** DRY RUN — no changes will be made ***"

# ---- preconditions ----
[[ "$DB_BACKEND" == "postgres" ]] || die "bundle db_backend=$DB_BACKEND: only postgres is supported"
[[ -f "$WORK/db.dump" ]] || die "bundle missing db.dump"
grep -q '^SECRETS_MASTER_KEY=' "$WORK/manifest-lunarwing.env" 2>/dev/null \
  || die "bundle has no SECRETS_MASTER_KEY — the restored DB's encrypted secrets would be unrecoverable; abort"
if jq -e ".tenants[\"$TENANT\"]" "$PORTS_REGISTRY" >/dev/null 2>&1; then
  $FORCE || die "tenant '$TENANT' already exists in $PORTS_REGISTRY — refusing (use --force only to re-import over it)"
  say "WARNING: tenant '$TENANT' already exists — proceeding due to --force"
fi
XMPP_JID="$(sed -n 's/^XMPP_JID=//p' "$WORK/manifest-lunarwing.env" | head -1)"; XMPP_JID="${XMPP_JID%$'\r'}"
XMPP_ALLOW_FROM="$(manifest_value XMPP_ALLOW_FROM)"
GATEWAY_HOST="$(manifest_value GATEWAY_HOST)"
[[ -n "$GATEWAY_HOST" ]] || GATEWAY_HOST="$(manifest_value HTTP_HOST)"
LLM_MODEL="$(manifest_value LLM_MODEL)"
LLM_BASE_URL="$(manifest_value LLM_BASE_URL)"
OPENCODE_MODEL="$(manifest_value OPENCODE_MODEL)"
OPENCODE_BASE_URL="$(manifest_value OPENCODE_BASE_URL)"
GOTIFY_URL="$(manifest_value GOTIFY_URL)"

confirm "Stage tenant '$TENANT' on THIS host from the bundle?" || die "aborted by user"

# ---- 1. provision fresh (no daemon, no health) -------------------------------
banner "1/6  Provision (add-tenant --no-health)"
add_args=(add-tenant "$TENANT" --no-health)
$WITH_DOCKER_GROUP && add_args+=(--docker-group)
[[ -n "$XMPP_JID" ]] && add_args+=(--xmpp-jid "$XMPP_JID")
[[ -n "$XMPP_ALLOW_FROM" ]] && add_args+=(--xmpp-allow-from "$XMPP_ALLOW_FROM")
[[ -n "$GATEWAY_HOST" ]] && add_args+=(--gateway-host "$GATEWAY_HOST")
[[ -n "$LLM_MODEL" ]] && add_args+=(--llm-model "$LLM_MODEL")
[[ -n "$LLM_BASE_URL" ]] && add_args+=(--llm-base-url "$LLM_BASE_URL")
[[ -n "$TENSORZERO_URL" ]] && add_args+=(--tensorzero-url "$TENSORZERO_URL")
[[ -n "$OPENCODE_MODEL" ]] && add_args+=(--opencode-model "$OPENCODE_MODEL")
[[ -n "$OPENCODE_BASE_URL" ]] && add_args+=(--opencode-base-url "$OPENCODE_BASE_URL")
[[ -n "$GOTIFY_URL" ]] && add_args+=(--gotify-url "$GOTIFY_URL")
run "$MT" "${add_args[@]}"

HOME_T="$(getent passwd "$TENANT" | cut -d: -f6 2>/dev/null || echo "/home/$TENANT")"
LWROOT="$HOME_T/lunarwing"
ENVF="$LWROOT/env/lunarwing.env"
BRIDGE_ENVF="$LWROOT/env/xmpp-bridge.env"
VISION_ENVF="$LWROOT/env/vision.env"

# ---- 2. build daemon + workers -----------------------------------------------
banner "2/6  Build"
build_args=(build-tenant "$TENANT" --with-wasm)
$WITH_NANOCODE && build_args+=(--with-nanocode)
$WITH_PEBBLE  && build_args+=(--with-pebble)
$WITH_OPENCODE && build_args+=(--with-opencode)
$WITH_TOOLCHAINS && build_args+=(--with-toolchains)
run "$MT" "${build_args[@]}"
$WITH_VISION && run "$MT" build-vision-sidecar

# ---- 3. inject carried secrets + config (CRITICAL: SECRETS_MASTER_KEY) -------
banner "3/6  Inject carried secrets + config"
if $DRY_RUN; then
  note "[dry-run] would inject manifest-lunarwing.env -> $ENVF and manifest-bridge.env -> $BRIDGE_ENVF (incl. SECRETS_MASTER_KEY, XMPP password, XMPP/LLM config)"
  [[ -s "$WORK/manifest-vision.env" ]] && note "[dry-run] would inject manifest-vision.env -> $VISION_ENVF (VL_URL, VL_MODEL, LUNARWING_AUTH_TOKEN)"
else
  inject_keys "$WORK/manifest-lunarwing.env" "$ENVF"
  [[ -f "$WORK/manifest-bridge.env" ]] && inject_keys "$WORK/manifest-bridge.env" "$BRIDGE_ENVF"
  if [[ -s "$WORK/manifest-vision.env" ]]; then
    [[ -f "$VISION_ENVF" ]] || die "bundle carries vision config, but target mt-admin did not render $VISION_ENVF"
    inject_keys "$WORK/manifest-vision.env" "$VISION_ENVF"
    chown "$TENANT:$TENANT" "$VISION_ENVF" 2>/dev/null || true
    note "vision.env carried config injected"
  fi
  chown "$TENANT:$TENANT" "$ENVF" "$BRIDGE_ENVF" 2>/dev/null || true
  # Verify the master key landed VERBATIM — without putting the value on argv
  # (command substitution keeps it out of /proc/<pid>/cmdline) and without the
  # grep -F "" empty-pattern false-PASS.
  man_key="$(grep -m1 '^SECRETS_MASTER_KEY=' "$WORK/manifest-lunarwing.env" || true)"
  live_key="$(grep -m1 '^SECRETS_MASTER_KEY=' "$ENVF" || true)"
  [[ -n "$man_key" && "$live_key" == "$man_key" ]] \
    || die "SECRETS_MASTER_KEY did not land in $ENVF after injection — abort before restore (the DB's secrets would be undecryptable)"
  note "SECRETS_MASTER_KEY confirmed in place (verbatim)"
fi

# ---- 4. restore the database (PG up from step 1, daemon not started) ---------
banner "4/6  Restore database"
if $DRY_RUN; then note "[dry-run] would: $MT restore-tenant $TENANT <bundle db.dump> --yes"
else "$MT" restore-tenant "$TENANT" "$WORK/db.dump" --yes; fi

# ---- 5. restore on-disk state (OMEMO/workspace), then fresh WASM -------------
banner "5/6  Restore state + install WASM"
if [[ -f "$WORK/state.tar.gz" ]]; then
  if $DRY_RUN; then note "[dry-run] would: tar xzf state.tar.gz into $LWROOT (OMEMO + workspace), chown to $TENANT"
  else
    # Defensive excludes (export already strips these): never let a stale config.toml
    # or old *.wasm overwrite the fresh host-specific ones.
    tar xzf "$WORK/state.tar.gz" -C "$LWROOT" \
      --exclude='state/config.toml' --exclude='state/tools/*.wasm' --exclude='state/channels/*.wasm'
    chown -R "$TENANT:$TENANT" "$LWROOT/state"
    note "restored state dir$( [[ -d "$LWROOT/state/xmpp" ]] && echo ' (incl. OMEMO store)' )"
  fi
else
  note "bundle has no state.tar.gz — OMEMO/workspace start fresh"
fi
run "$MT" install-wasm "$TENANT"   # lay down current v1.1.4 .wasm artifacts

banner "WeeChat migration preflight"
run "$WEECHAT_PREFLIGHT" "$TENANT"

# ---- 6. cutover ---------------------------------------------------------------
banner "6/6  Cutover"
stage_msg() {
  say "Tenant '$TENANT' is STAGED (DB + secrets + state restored, units rendered) but NOT started."
  say ""
  say "To cut over:"
  say "  1. Ensure '$TENANT' is stopped on the OLD host (export already stops it; same"
  say "     XMPP JID '${XMPP_JID:-?}' — avoid a double login)."
  say "  2. sudo $MT start-tenant $TENANT"
  say "  3. Verify, then once ALL agents are migrated enable self-heal fleet-wide:"
  say "     sudo ic/scripts/enable-health-fleet.sh --gotify-url <url> --gotify-token-file <path>"
  say ""
  say "Rollback: the OLD host is intact — restart '$TENANT' there."
}
if ! $DO_START; then stage_msg; exit 0; fi

# --start: the double-login gate is NOT satisfied by --yes alone.
if ! $OLD_STOPPED; then
  if [[ -t 0 ]]; then
    say "⚠  The new daemon will log into XMPP JID '${XMPP_JID:-?}'. Two simultaneous logins on one JID conflict."
    confirm "Confirm the OLD host's '$TENANT' is STOPPED — start it here now?" \
      || { say ""; stage_msg; exit 0; }
  else
    die "refusing to start unattended without --old-stopped (would risk a double login on JID '${XMPP_JID:-?}'). Re-run with --old-stopped once the old host is stopped, or omit --start to stage."
  fi
fi
run "$MT" start-tenant "$TENANT"
if ! $DRY_RUN; then
  run "$MT" status "$TENANT"
  note "Smoke-test: a message round-trips, history present, routines + channels load, OMEMO decrypts."
fi
say ""
say "Rollback: the OLD host is intact — stop '$TENANT' here and restart it there."
