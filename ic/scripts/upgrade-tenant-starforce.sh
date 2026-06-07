#!/usr/bin/env bash
#
# upgrade-tenant-starforce.sh — CAUTIOUS migration for "starforce".
#
# starforce's WeeChat currently WORKS, because its installed capabilities (and
# possibly other files) were hand-edited to the right ports. The generic fix
# replaces that hand-editing with env-sourced config — but `build --with-wasm`
# OVERWRITES the installed capabilities.json, and `git pull` can clobber or
# conflict with hand-edited tracked files. So this script:
#
#   * DEFAULTS TO INSPECT-ONLY (no changes). It shows WHY weechat works now,
#     surfaces any local repo modifications, and runs the read-only pre-flight.
#   * Only with --apply does it change anything, and then it: backs up the
#     ENTIRE state/channels dir + env, HARD-STOPS on a dirty repo (unless
#     --skip-pull), requires you to type the tenant name, gates on the
#     pre-flight before restart, and prints rollback steps.
#
# Usage:
#   sudo ic/scripts/upgrade-tenant-starforce.sh                 # inspect only
#   sudo ic/scripts/upgrade-tenant-starforce.sh --apply [--skip-pull] [--yes]
set -euo pipefail

TENANT="starforce"

APPLY=false; SKIP_PULL=false; AUTO_YES=false
for a in "$@"; do case "$a" in
  --apply)     APPLY=true ;;
  --skip-pull) SKIP_PULL=true ;;
  --yes|-y)    AUTO_YES=true ;;
  *) printf 'unknown arg: %s\n' "$a" >&2; exit 2 ;;
esac; done

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MT="$SCRIPT_DIR/lunarwing-mt-admin.sh"
PF="$SCRIPT_DIR/lunarwing-weechat-preflight.sh"
REGISTRY="${LUNARWING_PORTS_REGISTRY:-/etc/lunarwing/ports.json}"
HOME_DIR="/home/$TENANT/lunarwing"
ENV_FILE="$HOME_DIR/env/lunarwing.env"
CHANNELS_DIR="$HOME_DIR/state/channels"
CAPS_FILE="$CHANNELS_DIR/weechat.capabilities.json"
SCHEMA_FILE="$HOME_DIR/ic/src/tools/wasm/capabilities_schema.rs"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$HOME_DIR/backups/weechat-upgrade-$STAMP"

say(){ printf '%s\n' "$*"; }
die(){ printf 'error: %s\n' "$*" >&2; exit 1; }
banner(){ printf '\n========== %s ==========\n' "$*"; }
confirm(){ $AUTO_YES && return 0; local a; read -r -p "$1 [y/N] " a; [[ "$a" == y || "$a" == Y ]]; }
print_rollback(){
  say "  # restore the entire installed channels dir + env, then restart:"
  say "  rm -rf '$CHANNELS_DIR' && cp -a '$BACKUP_DIR/channels' '$CHANNELS_DIR'"
  say "  cp -a '$BACKUP_DIR/lunarwing.env.bak' '$ENV_FILE'"
  say "  chown -R $TENANT:$TENANT '$CHANNELS_DIR' '$ENV_FILE'"
  say "  $MT restart-tenant $TENANT"
}

[[ "$(id -u)" -eq 0 ]] || die "run as root (sudo)"
[[ -x "$MT" && -x "$PF" ]] || die "mt-admin / pre-flight not found in $SCRIPT_DIR"
command -v jq >/dev/null 2>&1 || die "jq required"
jq -e ".tenants[\"$TENANT\"]" "$REGISTRY" >/dev/null 2>&1 || die "tenant '$TENANT' not in $REGISTRY"

wc_port="$(jq -r ".tenants[\"$TENANT\"].ports.weechat // empty" "$REGISTRY")"
adapter_port="$(jq -r ".tenants[\"$TENANT\"].ports.weechat_adapter // empty" "$REGISTRY")"

# ---------------------------------------------------------------- INSPECT ----
banner "INSPECT — why does starforce's weechat work today?"
say "registry ports:  weechat=$wc_port  weechat_adapter=$adapter_port"
say "expected env:    RELAY_URL=http://127.0.0.1:$wc_port   WS_ADAPTER_URL=http://127.0.0.1:$adapter_port"
say ""
say "Installed capabilities config block:"
say "  (if config_ws_adapter_url already points at :$adapter_port, it was hand-edited —"
say "   that hand-edit is what makes weechat work, and build --with-wasm will reset it)"
if [[ -r "$CAPS_FILE" ]]; then
  jq '{config_relay_url: .config.relay_url,
       config_ws_adapter_url: .config.ws_adapter_url,
       declares_env_sources: [.setup.required_fields[]? | select(.env) | .name]}' "$CAPS_FILE" 2>/dev/null | sed 's/^/  /' || say "  (could not parse $CAPS_FILE)"
else
  say "  (cannot read $CAPS_FILE — not installed?)"
fi
say ""
say "Current env (weechat vars only; password shown as presence, never value):"
if [[ -r "$ENV_FILE" ]]; then
  grep -E '^(RELAY_URL|WS_ADAPTER_URL|ADAPTER_PORT|WEECHAT_ADAPTER_PORT)=' "$ENV_FILE" | sed 's/^/  /' || say "  (none of the weechat vars present)"
  say "  RELAY_PASSWORD present: $(grep -q '^RELAY_PASSWORD=' "$ENV_FILE" && echo yes || echo no)"
else
  say "  (cannot read $ENV_FILE)"
fi
say ""
say "Tenant repo hand-edited TRACKED files (untracked data dirs are ignored — git pull never touches them):"
# --untracked-files=no so normal runtime dirs (env/, state/, logs/, backups/,
# nanocode-workspace/) don't masquerade as hand-edits.
dirty="$(sudo -u "$TENANT" git -C "$HOME_DIR" status --short --untracked-files=no 2>/dev/null || true)"
if [[ -n "$dirty" ]]; then
  printf '%s\n' "$dirty" | sed 's/^/  /'
  say "  -> 'git pull' would conflict with / overwrite these. Inspect: sudo -u $TENANT git -C $HOME_DIR diff"
else
  say "  no modified tracked files (clean)"
fi
say ""
banner "pre-flight (read-only)"
"$PF" "$TENANT" || true

if ! $APPLY; then
  banner "INSPECT-ONLY — nothing was changed"
  say "You have three options:"
  say ""
  say "  (a) LEAVE IT. starforce already works. The fix only matters for tenants"
  say "      that are broken; there is no obligation to migrate a working one."
  say ""
  say "  (b) MIGRATE to env-sourced config (what --apply does):"
  say "        1. back up state/channels + env to $HOME_DIR/backups/"
  say "        2. git pull -> staging   (HARD-STOPS if the repo is dirty; use --skip-pull"
  say "           after you reconcile your hand-edits)"
  say "        3. build-tenant --with-wasm   (OVERWRITES installed capabilities.json —"
  say "           resets the config block; the env tier then injects the ports)"
  say "        4. patch-env  (adds WS_ADAPTER_URL=http://127.0.0.1:$adapter_port)"
  say "        5. pre-flight GATE, type-to-confirm, restart-tenant, verify"
  say "      Net effect: identical ports, sourced from env instead of a hand-edited file."
  say ""
  say "  (c) Reconcile your hand-edits into the repo first, then run: sudo $0 --apply --skip-pull"
  say ""
  say "When ready:  sudo $0 --apply"
  exit 0
fi

# ------------------------------------------------------------------ APPLY ----
banner "APPLY requested for starforce (a CURRENTLY-WORKING tenant)"
if ! $AUTO_YES; then
  read -r -p "Type the tenant name '$TENANT' to confirm you want to change it: " typed
  [[ "$typed" == "$TENANT" ]] || die "confirmation mismatch — aborted, nothing changed."
fi

# Protect hand-edited tracked files: do not let git pull clobber them.
if [[ -n "$dirty" && "$SKIP_PULL" == false ]]; then
  die "tenant repo has local modifications and --skip-pull was not given.
  A 'git pull' could overwrite hand-edited files. Reconcile them first
  (commit/stash, or get the repo onto staging your own way), then re-run:
    sudo $0 --apply --skip-pull"
fi

banner "1/7  backup state/channels + env  (full channels dir — other files may be hand-edited)"
mkdir -p "$BACKUP_DIR"
if [[ -d "$CHANNELS_DIR" ]]; then cp -a "$CHANNELS_DIR" "$BACKUP_DIR/channels"; say "  saved $BACKUP_DIR/channels (entire installed channels dir)"; fi
if [[ -f "$ENV_FILE" ]]; then cp -a "$ENV_FILE" "$BACKUP_DIR/lunarwing.env.bak"; say "  saved $BACKUP_DIR/lunarwing.env.bak"; fi
chown -R "$TENANT:$TENANT" "$HOME_DIR/backups" 2>/dev/null || true

if ! $SKIP_PULL; then
  banner "2/7  git pull (as $TENANT) -> staging"
  sudo -u "$TENANT" git -C "$HOME_DIR" pull || die "git pull failed; reconcile the repo manually then re-run with --apply --skip-pull"
  say "  now at: $(sudo -u "$TENANT" git -C "$HOME_DIR" log --oneline -1 2>/dev/null || echo '?')"
else
  banner "2/7  git pull SKIPPED (--skip-pull)"
fi

banner "3/7  verify the fix is present in the tenant repo"
grep -q 'pub env: Option' "$SCHEMA_FILE" 2>/dev/null \
  || die "tenant repo missing the fix ($SCHEMA_FILE). Get $HOME_DIR onto staging, then re-run."
say "  ok"

banner "4/7  build-tenant --with-wasm  (this OVERWRITES the installed capabilities.json)"
"$MT" build-tenant "$TENANT" --with-wasm

banner "5/7  patch-env  (adds WS_ADAPTER_URL=http://127.0.0.1:$adapter_port)"
"$MT" patch-env "$TENANT"

banner "6/7  pre-flight GATE — must pass before any restart"
if ! "$PF" "$TENANT"; then
  die "pre-flight FAILED — NOT restarting. Restore from $BACKUP_DIR if needed, investigate, then re-run."
fi

confirm "Pre-flight clean. Restart starforce now?" \
  || { say "Stopped before restart — changes staged but NOT live. Restart later: $MT restart-tenant $TENANT (rollback below if you change your mind)."; print_rollback; exit 0; }

"$MT" restart-tenant "$TENANT"

banner "verify"
"$PF" "$TENANT" || true
if [[ -n "$adapter_port" ]]; then
  say "adapter health (:$adapter_port):"
  curl -fsS --max-time 3 "http://127.0.0.1:$adapter_port/api/health" 2>/dev/null && say "" \
    || say "  (no response on :$adapter_port)"
fi
say ""
say "weechat startup log (expect relay :$wc_port / ws_adapter :$adapter_port):"
sudo -u "$TENANT" XDG_RUNTIME_DIR="/run/user/$(id -u "$TENANT")" \
  journalctl --user -u "lunarwing-$TENANT.service" -n 150 --no-pager 2>/dev/null \
  | grep -i "WeeChat Relay channel starting\|ws_adapter" \
  || say "  (no journal lines; check '$MT status $TENANT')"

banner "done — ROLLBACK if weechat misbehaves"
print_rollback
