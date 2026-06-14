#!/usr/bin/env bash
#
# create-tenant-vex.sh — provision the full-featured test tenant "vex".
#
# Provisions, in order:
#   1. add-tenant         — OS user (linger auto-enabled), next free 10-port block
#                           from /etc/lunarwing/ports.json (10120-10129 at time of
#                           writing), repo clone, env, Postgres, and ALL systemd
#                           units INCLUDING weechat-vex + lunarwing-weechat-adapter-vex.
#   2. wasm toolchain     — ensure cargo-component + wasm32-wasip2 for the tenant so
#                           build --with-wasm can actually compile every channel.
#   3. build --with-wasm --with-nanocode --with-pebble
#                           — lunarwing + xmpp-bridge + ALL WASM channels/tools, plus
#                           the nanocode and pebble worker Docker images.
#   4. start-tenant       — starts daemon, bridge, proxy, weechat, weechat-adapter.
#   5. verify             — status, linger, service states, adapter/gateway health,
#                           installed channel list.
# Then prints WeeChat-via-tmux configuration instructions.
#
# mt-admin's clone_tenant_repo checks out the source repo's *current* branch, so vex
# gets a fresh clone of whatever HEAD the checkout containing THIS script is on. This
# copy lives in the "2026-06-15-finalize-and-test-1.1.2" tree, so by default vex runs
# the 1.1.2 finalize code (the plan banner prints the exact branch@commit — confirm
# it). To provision from another tree, run that tree's copy, or export
# LUNARWING_MT_SOURCE_REPO=/path and use sudo -E.
#
# Heads-up: with worker images + a full release build + cargo-component compile, a
# cold run can take a while. Re-running is safe — it refuses if vex already exists.
#
# Run as root:   sudo ic/scripts/create-tenant-vex.sh [--yes]
#
# Override any CONFIG value via the environment, e.g.  XMPP_JID=vex@example.org sudo -E ...
set -euo pipefail

# ---- CONFIG (edit me) -------------------------------------------------------
TENANT="vex"
XMPP_JID="${XMPP_JID:-vex@xmpp.sobe.world}"     # <-- confirm the account exists on this domain
XMPP_PASSWORD="${XMPP_PASSWORD:-}"              # blank -> mt-admin generates one
LLM_API_KEY="${LLM_API_KEY:-}"                 # blank -> defaults to token-vex (TensorZero proxy)
GOTIFY_URL="${GOTIFY_URL:-}"                    # optional, e.g. https://gotify.example.com
DOCKER_GROUP="${DOCKER_GROUP:-true}"           # add vex to the docker group (needed for sandbox + workers)
WITH_NANOCODE="${WITH_NANOCODE:-true}"         # build the nanocode worker Docker image
WITH_PEBBLE="${WITH_PEBBLE:-true}"             # build the pebble worker Docker image
ENSURE_WASM_TOOLCHAIN="${ENSURE_WASM_TOOLCHAIN:-true}"  # install cargo-component for vex if missing
# ----------------------------------------------------------------------------

AUTO_YES=false
for a in "$@"; do case "$a" in
  --yes|-y) AUTO_YES=true ;;
  *) printf 'unknown arg: %s\n' "$a" >&2; exit 2 ;;
esac; done

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MT="$SCRIPT_DIR/lunarwing-mt-admin.sh"
REGISTRY="${LUNARWING_PORTS_REGISTRY:-/etc/lunarwing/ports.json}"
TENANT_HOME="/home/$TENANT"
ENV_FILE="$TENANT_HOME/lunarwing/env/lunarwing.env"
CHANNELS_DIR="$TENANT_HOME/lunarwing/state/channels"

say(){ printf '%s\n' "$*"; }
die(){ printf 'error: %s\n' "$*" >&2; exit 1; }
banner(){ printf '\n========== %s ==========\n' "$*"; }
confirm(){ $AUTO_YES && return 0; local a; read -r -p "$1 [y/N] " a; [[ "$a" == y || "$a" == Y ]]; }

[[ "$(id -u)" -eq 0 ]] || die "run as root (sudo) — mt-admin needs root"
[[ -x "$MT" ]] || die "not found/executable: $MT"
command -v jq >/dev/null 2>&1 || die "jq required"

# Guard: this script only CREATES. Refuse if the tenant already exists.
if [[ -f "$REGISTRY" ]] && jq -e ".tenants[\"$TENANT\"]" "$REGISTRY" >/dev/null 2>&1; then
  die "tenant '$TENANT' already exists in $REGISTRY — use an upgrade script, not this one."
fi

# ---- Host dependency report (warn, don't block) -----------------------------
banner "host dependency check"
miss=0
for c in weechat tmux python3 rustup; do
  if command -v "$c" >/dev/null 2>&1; then say "  ok   $c"; else say "  MISS $c"; miss=$((miss+1)); fi
done
if rustup target list --installed 2>/dev/null | grep -q wasm32-wasip2; then
  say "  ok   wasm32-wasip2 target"
else
  say "  MISS wasm32-wasip2 target (add: rustup target add wasm32-wasip2)"; miss=$((miss+1))
fi
if command -v cargo-component >/dev/null 2>&1; then
  say "  ok   cargo-component (host)"
else
  say "  note cargo-component not on host PATH — will ensure it for '$TENANT' (step 2)"
fi
if command -v wasm-tools >/dev/null 2>&1; then
  say "  ok   wasm-tools"
else
  say "  note wasm-tools absent — channels install as raw components (fine; no strip)"
fi
if [[ "$WITH_NANOCODE" == true || "$WITH_PEBBLE" == true ]]; then
  command -v docker >/dev/null 2>&1 || command -v podman >/dev/null 2>&1 \
    || { say "  MISS docker/podman (needed for worker images)"; miss=$((miss+1)); }
fi
[[ "$miss" -gt 0 ]] && say "($miss core dep(s) missing — review before proceeding)"

banner "Plan: create full-featured tenant '$TENANT'"
say "  XMPP JID:        $XMPP_JID"
say "  XMPP password:   $([[ -n "$XMPP_PASSWORD" ]] && echo '(provided)' || echo '(auto-generated)')"
say "  LLM API key:     $([[ -n "$LLM_API_KEY" ]] && echo '(provided)' || echo 'token-vex default')"
say "  Gotify URL:      ${GOTIFY_URL:-(none)}"
say "  docker group:    $DOCKER_GROUP"
say "  linger:          auto-enabled by add-tenant (systemd)"
say "  build wasm:      yes (all channels + tools)"
say "  ensure toolchain:$ENSURE_WASM_TOOLCHAIN (cargo-component for $TENANT)"
say "  build nanocode:  $WITH_NANOCODE"
say "  build pebble:    $WITH_PEBBLE"
say "  weechat service: auto-rendered + started (weechat-$TENANT + adapter)"
say "  source repo:     $(git -C "$SCRIPT_DIR/../.." rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')@$(git -C "$SCRIPT_DIR/../.." rev-parse --short HEAD 2>/dev/null || echo '?')"
confirm "Proceed?" || { say "aborted."; exit 0; }

banner "1/5  add-tenant"
add_args=( add-tenant "$TENANT" --xmpp-jid "$XMPP_JID" )
[[ "$DOCKER_GROUP" == true ]] && add_args+=( --docker-group )
[[ -n "$XMPP_PASSWORD" ]] && add_args+=( --xmpp-password "$XMPP_PASSWORD" )
[[ -n "$LLM_API_KEY" ]] && add_args+=( --llm-api-key "$LLM_API_KEY" )
[[ -n "$GOTIFY_URL" ]] && add_args+=( --gotify-url "$GOTIFY_URL" )
"$MT" "${add_args[@]}"

# Ports are known only after allocation — read them back.
weechat_port="$(jq -r ".tenants[\"$TENANT\"].ports.weechat // empty" "$REGISTRY")"
adapter_port="$(jq -r ".tenants[\"$TENANT\"].ports.weechat_adapter // empty" "$REGISTRY")"
gw_port="$(jq -r ".tenants[\"$TENANT\"].ports.gateway // empty" "$REGISTRY")"

banner "2/5  ensure WASM build toolchain for $TENANT"
if [[ "$ENSURE_WASM_TOOLCHAIN" == true ]]; then
  if sudo -u "$TENANT" bash -lc 'command -v cargo >/dev/null 2>&1'; then
    sudo -u "$TENANT" bash -lc 'rustup target add wasm32-wasip2' >/dev/null 2>&1 \
      || say "  (wasm32-wasip2 target add skipped — likely already present)"
    if sudo -u "$TENANT" bash -lc 'command -v cargo-component >/dev/null 2>&1 || [ -x "$HOME/.cargo/bin/cargo-component" ]'; then
      say "  cargo-component already present for $TENANT"
    else
      say "  installing cargo-component for $TENANT (compiles from source — may take several minutes) ..."
      sudo -u "$TENANT" bash -lc 'cargo install cargo-component --locked' \
        || say "  WARNING: cargo-component install failed — '--with-wasm' will skip channels. Retry: sudo -u $TENANT bash -lc 'cargo install cargo-component --locked'"
    fi
    if ! sudo -u "$TENANT" python3 -c 'import aiohttp' >/dev/null 2>&1; then
      say "  WARNING: python 'aiohttp' not importable for $TENANT — lunarwing-weechat-adapter-$TENANT will exit until installed:"
      say "           system-wide (preferred): sudo pacman -S python-aiohttp   (apt: python3-aiohttp · dnf: python3-aiohttp)"
      say "           per-tenant fallback:     sudo -u $TENANT pip install --user --break-system-packages aiohttp"
    fi
  else
    say "  WARNING: '$TENANT' has no working 'cargo' on PATH — skipping toolchain setup (WASM channels may not build)."
  fi
else
  say "  skipped (ENSURE_WASM_TOOLCHAIN=false)"
fi

build_args=( build-tenant "$TENANT" --with-wasm )
[[ "$WITH_NANOCODE" == true ]] && build_args+=( --with-nanocode )
[[ "$WITH_PEBBLE" == true ]] && build_args+=( --with-pebble )
banner "3/5  ${build_args[*]}"
"$MT" "${build_args[@]}"

banner "4/5  start-tenant"
"$MT" start-tenant "$TENANT"

banner "5/5  verify"
"$MT" status "$TENANT" || say "(status returned non-zero — review above)"
say ""
say "linger: $(loginctl show-user "$TENANT" --property=Linger 2>/dev/null || echo 'Linger=?')"
say ""
say "installed WASM channels ($CHANNELS_DIR):"
if [[ -d "$CHANNELS_DIR" ]]; then
  find "$CHANNELS_DIR" -maxdepth 1 -name '*.wasm' -printf '  %f\n' 2>/dev/null \
    | sort || say "  (none — check the build log above for WASM failures)"
else
  say "  (channels dir not present yet)"
fi
say ""
if [[ -n "$adapter_port" ]] && command -v curl >/dev/null 2>&1; then
  say "weechat adapter health (:$adapter_port):"
  if curl -fsS --max-time 3 "http://127.0.0.1:$adapter_port/api/health" 2>/dev/null; then
    say ""
  else
    say "  (no response yet — adapter connects once WeeChat's relay is configured; see below)"
  fi
fi
if [[ -n "$gw_port" ]] && command -v curl >/dev/null 2>&1; then
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:$gw_port/" 2>/dev/null || true)"
  if [[ -n "$code" && "$code" != 000 ]]; then
    say "gateway (:$gw_port) responding (HTTP $code)"
  else
    say "gateway (:$gw_port) not responding yet — may still be starting"
  fi
fi

# ---- WeeChat-via-tmux configuration instructions ----------------------------
banner "WeeChat setup (via tmux)"
cat <<EOF
The weechat-$TENANT.service runs WeeChat inside a tmux session (socket
"weechat-$TENANT", session "weechat"). The adapter connects to WeeChat's *api*
relay on 127.0.0.1:$weechat_port using RELAY_PASSWORD from the tenant env, and the
in-process WASM channel polls the adapter on :$adapter_port.

1) Get the auto-generated relay password (env and WeeChat must match):
     sudo grep '^RELAY_PASSWORD=' $ENV_FILE

2) Attach to vex's WeeChat (detach later with Ctrl-b then d):
     sudo -u $TENANT tmux -L weechat-$TENANT attach -t weechat

3) Inside WeeChat, enable the api relay the adapter expects:
     /set relay.network.password "<RELAY_PASSWORD from step 1>"
     /set relay.network.bind_address "127.0.0.1"
     /relay add api $weechat_port
     /relay list
     /save

4) Connect to an IRC network and join channels, e.g.:
     /server add libera irc.libera.chat/6697 -tls
     /set irc.server.libera.nicks "vexbot"
     /connect libera
     /join #yourchannel
     /save

5) Choose who may talk to the agent — edit the channel capabilities:
     sudo -u $TENANT \${EDITOR:-nano} $CHANNELS_DIR/weechat.capabilities.json
   set "allow_from": ["yournick"] (or ["*"]), "dm_policy": "pairing"|"open",
   "group_policy": "allowlist"|"open"|"deny", then apply:
     sudo $MT restart-tenant $TENANT

6) Confirm the adapter is connected to WeeChat:
     curl -fsS http://127.0.0.1:$adapter_port/api/health
EOF

banner "done"
say "  status:   sudo $MT status $TENANT"
say "  token:    sudo $MT tokens $TENANT"
say "  logs:     sudo -u $TENANT XDG_RUNTIME_DIR=/run/user/\$(id -u $TENANT) journalctl --user -u lunarwing-$TENANT.service -f"
say "  weechat:  sudo -u $TENANT tmux -L weechat-$TENANT attach -t weechat"
say "  pebble:   sudo $MT configure-pebble $TENANT --nanogpt-api-key <key>   # if you want the pebble worker live"
say "  remove:   sudo $MT remove-tenant $TENANT --purge"
