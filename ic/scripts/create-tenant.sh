#!/usr/bin/env bash
#
# create-tenant.sh — provision a full-featured LunarWing tenant for ANY name.
#
# Generic version of create-tenant-<name>.sh: pass the tenant name as the first
# argument. Everything name-specific (XMPP JID, token-<name> key, home paths,
# WeeChat instructions) is derived from it.
#
# Provisions, in order:
#   1. add-tenant   — OS user (linger auto-enabled), next free 10-port block from
#                     /etc/lunarwing/ports.json, repo clone, env, Postgres, and ALL
#                     systemd units INCLUDING lunarwing-weechat-<name> + the WS adapter.
#   2. wasm toolchain — ensure cargo-component + wasm32-wasip2 for the tenant so
#                     build --with-wasm can actually compile every channel.
#   3. build        — lunarwing + xmpp-bridge + (optionally) all WASM channels/tools
#                     and the nanocode / pebble worker Docker images.
#   4. start-tenant — daemon, bridge, proxy, weechat, weechat-adapter.
#   5. verify       — status, linger, service states, adapter/gateway health,
#                     installed channel list.
# Then prints WeeChat-via-tmux configuration instructions.
#
# mt-admin's clone_tenant_repo checks out the source repo's *current* branch, so the
# tenant runs whatever HEAD the checkout containing THIS script is on (the plan
# banner prints the exact branch@commit — confirm it). Provision from another tree by
# running that tree's copy, or export LUNARWING_MT_SOURCE_REPO=/path and use sudo -E.
#
# Examples:
#   sudo ic/scripts/create-tenant.sh vex
#   sudo ic/scripts/create-tenant.sh acme --xmpp-jid acme@xmpp.example.org --yes
#   sudo ic/scripts/create-tenant.sh scratch --minimal           # core daemon only
#   sudo ic/scripts/create-tenant.sh bot --no-pebble --no-nanocode
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MT="$SCRIPT_DIR/lunarwing-mt-admin.sh"
REGISTRY="${LUNARWING_PORTS_REGISTRY:-/etc/lunarwing/ports.json}"

say(){ printf '%s\n' "$*"; }
die(){ printf 'error: %s\n' "$*" >&2; exit 1; }
banner(){ printf '\n========== %s ==========\n' "$*"; }

# mirror of mt-admin's sanitize_name: lowercase, [a-z0-9-], trim leading/trailing -
sanitize_name(){ printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9-' '-' | sed 's/^-//;s/-$//'; }

usage(){
  cat <<EOF
Usage: sudo $(basename "$0") <name> [options]

Provision a LunarWing tenant. <name> is required and lowercased to [a-z0-9-].

Options (all also settable via the matching ENV var):
  --xmpp-jid <jid>          XMPP JID         (default: <name>@\$XMPP_DOMAIN)
  --xmpp-domain <domain>    domain for the derived JID   (default: xmpp.sobe.world)
  --xmpp-password <pw>      XMPP password    (default: mt-admin generates one)
  --llm-api-key <key>       LLM/provider key (default: token-<name> via TensorZero)
  --llm-base-url <url>      LLM endpoint (LLM_BASE_URL)  (default: tenant's local proxy)
  --gotify-url <url>        custom Gotify URL            (default: none)
  --[no-]docker-group       add user to docker group     (default: on)
  --[no-]nanocode           build nanocode worker image  (default: on)
  --[no-]pebble             build pebble worker image    (default: on)
  --[no-]wasm               build + install all WASM channels/tools (default: on)
  --[no-]ensure-toolchain   install cargo-component for the tenant if missing (default: on)
  --minimal                 shorthand for --no-docker-group --no-nanocode --no-pebble
  -y, --yes                 don't prompt for confirmation
  -h, --help                show this help

Env overrides: XMPP_JID, XMPP_DOMAIN, XMPP_PASSWORD, LLM_API_KEY, LLM_BASE_URL, GOTIFY_URL,
  DOCKER_GROUP, WITH_NANOCODE, WITH_PEBBLE, WITH_WASM, ENSURE_WASM_TOOLCHAIN (true/false).
EOF
}

# ---- defaults (env first, flags override below) -----------------------------
TENANT=""
XMPP_JID="${XMPP_JID:-}"
XMPP_DOMAIN="${XMPP_DOMAIN:-xmpp.sobe.world}"
XMPP_PASSWORD="${XMPP_PASSWORD:-}"
LLM_API_KEY="${LLM_API_KEY:-}"
LLM_BASE_URL="${LLM_BASE_URL:-}"
GOTIFY_URL="${GOTIFY_URL:-}"
DOCKER_GROUP="${DOCKER_GROUP:-true}"
WITH_NANOCODE="${WITH_NANOCODE:-true}"
WITH_PEBBLE="${WITH_PEBBLE:-true}"
WITH_WASM="${WITH_WASM:-true}"
ENSURE_WASM_TOOLCHAIN="${ENSURE_WASM_TOOLCHAIN:-true}"
AUTO_YES=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --xmpp-jid)             XMPP_JID="$2"; shift 2 ;;
    --xmpp-domain)          XMPP_DOMAIN="$2"; shift 2 ;;
    --xmpp-password)        XMPP_PASSWORD="$2"; shift 2 ;;
    --llm-api-key)          LLM_API_KEY="$2"; shift 2 ;;
    --llm-base-url)         LLM_BASE_URL="$2"; shift 2 ;;
    --gotify-url)           GOTIFY_URL="$2"; shift 2 ;;
    --docker-group)         DOCKER_GROUP=true; shift ;;
    --no-docker-group)      DOCKER_GROUP=false; shift ;;
    --nanocode|--with-nanocode)   WITH_NANOCODE=true; shift ;;
    --no-nanocode)          WITH_NANOCODE=false; shift ;;
    --pebble|--with-pebble)       WITH_PEBBLE=true; shift ;;
    --no-pebble)            WITH_PEBBLE=false; shift ;;
    --wasm|--with-wasm)     WITH_WASM=true; shift ;;
    --no-wasm)              WITH_WASM=false; shift ;;
    --ensure-toolchain)     ENSURE_WASM_TOOLCHAIN=true; shift ;;
    --no-ensure-toolchain)  ENSURE_WASM_TOOLCHAIN=false; shift ;;
    --minimal)              DOCKER_GROUP=false; WITH_NANOCODE=false; WITH_PEBBLE=false; shift ;;
    -y|--yes)               AUTO_YES=true; shift ;;
    -h|--help)              usage; exit 0 ;;
    --)                     shift; break ;;
    -*)                     die "unknown option: $1 (see --help)" ;;
    *)
      if [[ -z "$TENANT" ]]; then TENANT="$1"; shift
      else die "unexpected argument: $1 (name already set to '$TENANT')"; fi
      ;;
  esac
done

[[ -n "$TENANT" ]] || { usage >&2; die "missing required <name>"; }
raw_name="$TENANT"
TENANT="$(sanitize_name "$TENANT")"
[[ -n "$TENANT" ]] || die "name '$raw_name' is empty after sanitizing to [a-z0-9-]"
[[ "$TENANT" == "$raw_name" ]] || say "note: using sanitized tenant name '$TENANT' (from '$raw_name')"

# derived, name-specific
XMPP_JID="${XMPP_JID:-$TENANT@$XMPP_DOMAIN}"
TENANT_HOME="/home/$TENANT"
ENV_FILE="$TENANT_HOME/lunarwing/env/lunarwing.env"
CHANNELS_DIR="$TENANT_HOME/lunarwing/state/channels"

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
if [[ "$WITH_WASM" == true ]]; then
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
fi
if [[ "$WITH_NANOCODE" == true || "$WITH_PEBBLE" == true ]]; then
  if ! command -v docker >/dev/null 2>&1 && ! command -v podman >/dev/null 2>&1; then
    say "  MISS docker/podman (needed for worker images)"; miss=$((miss+1))
  fi
fi
[[ "$miss" -gt 0 ]] && say "($miss core dep(s) missing — review before proceeding)"

banner "Plan: create tenant '$TENANT'"
say "  XMPP JID:         $XMPP_JID"
say "  XMPP password:    $([[ -n "$XMPP_PASSWORD" ]] && echo '(provided)' || echo '(auto-generated)')"
say "  LLM API key:      $([[ -n "$LLM_API_KEY" ]] && echo '(provided)' || echo "token-$TENANT default")"
say "  LLM base URL:     ${LLM_BASE_URL:-(tenant local proxy)}"
say "  Gotify URL:       ${GOTIFY_URL:-(none)}"
say "  docker group:     $DOCKER_GROUP"
say "  linger:           auto-enabled by add-tenant (systemd)"
say "  build wasm:       $WITH_WASM (all channels + tools)"
say "  ensure toolchain: $([[ "$WITH_WASM" == true ]] && echo "$ENSURE_WASM_TOOLCHAIN" || echo 'n/a (wasm off)')"
say "  build nanocode:   $WITH_NANOCODE"
say "  build pebble:     $WITH_PEBBLE"
say "  weechat service:  auto-rendered + started (lunarwing-weechat-$TENANT + adapter)"
say "  source repo:      $(git -C "$SCRIPT_DIR/../.." rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')@$(git -C "$SCRIPT_DIR/../.." rev-parse --short HEAD 2>/dev/null || echo '?')"
confirm "Proceed?" || { say "aborted."; exit 0; }

banner "1/5  add-tenant"
add_args=( add-tenant "$TENANT" --xmpp-jid "$XMPP_JID" )
[[ "$DOCKER_GROUP" == true ]] && add_args+=( --docker-group )
[[ -n "$XMPP_PASSWORD" ]] && add_args+=( --xmpp-password "$XMPP_PASSWORD" )
[[ -n "$LLM_API_KEY" ]] && add_args+=( --llm-api-key "$LLM_API_KEY" )
[[ -n "$LLM_BASE_URL" ]] && add_args+=( --llm-base-url "$LLM_BASE_URL" )
[[ -n "$GOTIFY_URL" ]] && add_args+=( --gotify-url "$GOTIFY_URL" )
"$MT" "${add_args[@]}"

# Ports are known only after allocation — read them back.
weechat_port="$(jq -r ".tenants[\"$TENANT\"].ports.weechat // empty" "$REGISTRY")"
adapter_port="$(jq -r ".tenants[\"$TENANT\"].ports.weechat_adapter // empty" "$REGISTRY")"
gw_port="$(jq -r ".tenants[\"$TENANT\"].ports.gateway // empty" "$REGISTRY")"

banner "2/5  ensure WASM build toolchain for $TENANT"
if [[ "$WITH_WASM" == true && "$ENSURE_WASM_TOOLCHAIN" == true ]]; then
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
  say "  skipped (wasm=$WITH_WASM, ensure_toolchain=$ENSURE_WASM_TOOLCHAIN)"
fi

build_args=( build-tenant "$TENANT" )
[[ "$WITH_WASM" == true ]] && build_args+=( --with-wasm )
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
The lunarwing-weechat-$TENANT.service runs WeeChat inside a tmux session (socket
"weechat-$TENANT", session "weechat"). The adapter connects to WeeChat's *api*
relay on 127.0.0.1:$weechat_port using RELAY_PASSWORD from the tenant env, and the
in-process WASM channel polls the adapter on :$adapter_port.

1) Get the auto-generated relay password (env and WeeChat must match):
     sudo grep '^RELAY_PASSWORD=' $ENV_FILE

2) Attach to $TENANT's WeeChat (detach later with Ctrl-b then d):
     sudo -u $TENANT tmux -L weechat-$TENANT attach -t weechat

3) Inside WeeChat, enable the api relay the adapter expects:
     /set relay.network.password "<RELAY_PASSWORD from step 1>"
     /set relay.network.bind_address "127.0.0.1"
     /relay add api $weechat_port
     /relay list
     /save

4) Connect to an IRC network and join channels, e.g.:
     /server add libera irc.libera.chat/6697 -tls
     /set irc.server.libera.nicks "${TENANT}bot"
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
