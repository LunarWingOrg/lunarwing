#!/usr/bin/env bash
#
# upgrade-tenant-sunburst.sh — apply the WeeChat multi-tenant port fix to the
# EXISTING tenant "sunburst".
#
# Flow:
#   baseline pre-flight -> backup(env + installed caps) -> git status check ->
#   git pull (staging) -> verify fix in repo -> build-tenant --with-wasm ->
#   patch-env -> pre-flight GATE -> restart-tenant -> verify
#
# It backs up the env file and the installed weechat.capabilities.json first,
# and will NOT restart unless the pre-flight passes. Rollback steps are printed
# at the end.
#
# Run as root:
#   sudo ic/scripts/upgrade-tenant-sunburst.sh [--skip-pull] [--yes]
#     --skip-pull  you have already updated /home/sunburst/lunarwing to staging
#     --yes        skip confirmation prompts (still honors the pre-flight gate)
set -euo pipefail

TENANT="sunburst"

SKIP_PULL=false; AUTO_YES=false
for a in "$@"; do case "$a" in
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
CAPS_FILE="$HOME_DIR/state/channels/weechat.capabilities.json"
SCHEMA_FILE="$HOME_DIR/ic/src/tools/wasm/capabilities_schema.rs"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$HOME_DIR/backups/weechat-upgrade-$STAMP"

say(){ printf '%s\n' "$*"; }
die(){ printf 'error: %s\n' "$*" >&2; exit 1; }
banner(){ printf '\n========== %s ==========\n' "$*"; }
confirm(){ $AUTO_YES && return 0; local a; read -r -p "$1 [y/N] " a; [[ "$a" == y || "$a" == Y ]]; }

[[ "$(id -u)" -eq 0 ]] || die "run as root (sudo) — mt-admin needs root"
[[ -x "$MT" && -x "$PF" ]] || die "mt-admin / pre-flight not found in $SCRIPT_DIR"
command -v jq >/dev/null 2>&1 || die "jq required"
jq -e ".tenants[\"$TENANT\"]" "$REGISTRY" >/dev/null 2>&1 || die "tenant '$TENANT' not in $REGISTRY"

wc_port="$(jq -r ".tenants[\"$TENANT\"].ports.weechat // empty" "$REGISTRY")"
adapter_port="$(jq -r ".tenants[\"$TENANT\"].ports.weechat_adapter // empty" "$REGISTRY")"

banner "Baseline pre-flight (read-only) — sunburst"
"$PF" "$TENANT" || true

banner "1/7  backup env + installed capabilities"
mkdir -p "$BACKUP_DIR"
if [[ -f "$ENV_FILE" ]]; then cp -a "$ENV_FILE" "$BACKUP_DIR/lunarwing.env.bak"; say "  saved $BACKUP_DIR/lunarwing.env.bak"; fi
if [[ -f "$CAPS_FILE" ]]; then cp -a "$CAPS_FILE" "$BACKUP_DIR/weechat.capabilities.json.bak"; say "  saved $BACKUP_DIR/weechat.capabilities.json.bak"; fi
chown -R "$TENANT:$TENANT" "$HOME_DIR/backups" 2>/dev/null || true

banner "2/7  tenant repo status (surfaces any hand-edited TRACKED files)"
# --untracked-files=no: ignore the tenant's runtime data dirs (env/, state/,
# logs/, backups/, nanocode-workspace/) that live next to the clone — git pull
# never touches untracked files, so only modified TRACKED files are a hazard.
dirty="$(sudo -u "$TENANT" git -C "$HOME_DIR" status --short --untracked-files=no 2>/dev/null || true)"
if [[ -n "$dirty" ]]; then
  say "  MODIFIED TRACKED files detected in $HOME_DIR:"
  printf '%s\n' "$dirty" | sed 's/^/    /'
  say "  A 'git pull' may conflict or overwrite these. Review with:"
  say "    sudo -u $TENANT git -C $HOME_DIR diff"
  if ! $SKIP_PULL; then
    confirm "  Continue and attempt 'git pull' anyway?" || { say "aborted (backup kept). Reconcile the repo, then re-run with --skip-pull."; exit 0; }
  fi
else
  say "  clean working tree"
fi

confirm "Proceed with the upgrade?" || { say "aborted (backup kept)."; exit 0; }

if ! $SKIP_PULL; then
  banner "3/7  git pull (as $TENANT) -> staging"
  sudo -u "$TENANT" git -C "$HOME_DIR" pull || die "git pull failed; update the repo to staging manually, then re-run with --skip-pull"
  say "  now at: $(sudo -u "$TENANT" git -C "$HOME_DIR" log --oneline -1 2>/dev/null || echo '?')"
else
  banner "3/7  git pull SKIPPED (--skip-pull)"
fi

banner "4/7  verify the fix is present in the tenant repo"
grep -q 'pub env: Option' "$SCHEMA_FILE" 2>/dev/null \
  || die "tenant repo is missing the fix ($SCHEMA_FILE). Update $HOME_DIR to staging, then re-run."
say "  ok: capabilities_schema.rs has the env field"

banner "5/7  build-tenant --with-wasm  (rebuilds binary + refreshes installed capabilities.json)"
"$MT" build-tenant "$TENANT" --with-wasm

banner "6/7  patch-env  (adds WS_ADAPTER_URL=http://127.0.0.1:$adapter_port)"
"$MT" patch-env "$TENANT"

banner "7/7  pre-flight GATE — must pass before any restart"
if ! "$PF" "$TENANT"; then
  die "pre-flight FAILED — NOT restarting. A value disagrees with the registry. Investigate (or restore from $BACKUP_DIR), then re-run with --skip-pull."
fi

confirm "Pre-flight clean. Restart sunburst now?" \
  || { say "Stopped before restart — changes are staged but NOT live. Restart later: $MT restart-tenant $TENANT"; exit 0; }

"$MT" restart-tenant "$TENANT"

banner "verify"
"$PF" "$TENANT" || true
if [[ -n "$adapter_port" ]]; then
  say "adapter health (:$adapter_port):"
  curl -fsS --max-time 3 "http://127.0.0.1:$adapter_port/api/health" 2>/dev/null && say "" \
    || say "  (no response on :$adapter_port)"
fi
say ""
say "weechat startup log (expect relay :$wc_port / ws_adapter :$adapter_port, NOT :9001/:6681):"
sudo -u "$TENANT" XDG_RUNTIME_DIR="/run/user/$(id -u "$TENANT")" \
  journalctl --user -u "lunarwing-$TENANT.service" -n 150 --no-pager 2>/dev/null \
  | grep -i "WeeChat Relay channel starting\|ws_adapter" \
  || say "  (no journal lines; check '$MT status $TENANT')"

banner "done — ROLLBACK if needed"
say "  cp '$BACKUP_DIR/lunarwing.env.bak' '$ENV_FILE'"
say "  cp '$BACKUP_DIR/weechat.capabilities.json.bak' '$CAPS_FILE'"
say "  chown $TENANT:$TENANT '$ENV_FILE' '$CAPS_FILE'"
say "  $MT restart-tenant $TENANT"
