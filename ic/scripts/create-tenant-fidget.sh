#!/usr/bin/env bash
#
# create-tenant-fidget.sh — provision the NEW throwaway test tenant "fidget" from
# whatever branch the source repo (/home/cmc/lunarwing) is currently on.
#
# Purpose: a clean tenant for validating the WeeChat **long-poll real-time ingestion**
# path plus the **adapter-layer first-DM capture fix** end-to-end:
#   - long-poll: adapter `/api/wait` + global event cursor; WASM `do_longpoll`
#     (fallback to per-buffer polling on old adapters).            commit 39a75334
#   - first-DM: adapter records the FIRST line in a brand-new query/DM buffer
#     (synchronous buffer-list refresh + retry), and `/api/wait` replays the
#     post-restart backlog instead of skipping it.                commit 9ca64bd9
# As of this writing the source repo is on
# `1.1.1-444-weechat-polish-and-fixes-4-abc`, so a fresh clone gets all of it.
#
# Wraps:  add-tenant  ->  build-tenant --with-wasm  ->  start-tenant  ->  verify
#
# mt-admin's clone_tenant_repo checks out the source repo's *current* branch
# (origin/<branch>), so fidget gets the long-poll adapter + WASM consumer with NO
# patch-env / install-wasm backfill: its lunarwing.env gets WS_ADAPTER_URL and its
# capabilities declare the env sources from the start. The banner below prints the
# exact branch@commit being provisioned — confirm it's the right branch first.
#
# Run as root:   sudo ic/scripts/create-tenant-fidget.sh [--yes]
#
# Edit the CONFIG block below (the XMPP JID especially) before running, or
# override any value via the environment, e.g.  XMPP_JID=fidget@example.org sudo -E ...
set -euo pipefail

# ---- CONFIG (edit me) -------------------------------------------------------
TENANT="fidget"
XMPP_JID="${XMPP_JID:-fidget@xmpp.sobe.world}"   # <-- confirm your XMPP domain
XMPP_PASSWORD="${XMPP_PASSWORD:-}"              # blank -> mt-admin generates one
LLM_API_KEY="${LLM_API_KEY:-}"                 # blank -> defaults to token-fidget (TensorZero proxy)
GOTIFY_URL="${GOTIFY_URL:-}"                    # optional, e.g. https://gotify.example.com
DOCKER_GROUP="${DOCKER_GROUP:-false}"          # set true ONLY if fidget runs Docker sandbox/workers
                                               #   (docker group is ~root-equivalent — opt in deliberately)
WITH_NANOCODE="${WITH_NANOCODE:-false}"        # also build the nanocode worker image
# ----------------------------------------------------------------------------

AUTO_YES=false
for a in "$@"; do case "$a" in
  --yes|-y) AUTO_YES=true ;;
  *) printf 'unknown arg: %s\n' "$a" >&2; exit 2 ;;
esac; done

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MT="$SCRIPT_DIR/lunarwing-mt-admin.sh"
PF="$SCRIPT_DIR/lunarwing-weechat-preflight.sh"
REGISTRY="${LUNARWING_PORTS_REGISTRY:-/etc/lunarwing/ports.json}"

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

banner "Plan: create new tenant '$TENANT'"
say "  XMPP JID:       $XMPP_JID"
say "  XMPP password:  $([[ -n "$XMPP_PASSWORD" ]] && echo '(provided)' || echo '(auto-generated)')"
say "  LLM API key:    $([[ -n "$LLM_API_KEY" ]] && echo '(provided)' || echo 'token-fidget default')"
say "  Gotify URL:     ${GOTIFY_URL:-(none)}"
say "  docker group:   $DOCKER_GROUP"
say "  build nanocode: $WITH_NANOCODE"
say "  source repo:    $(git -C "$SCRIPT_DIR/../.." rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')@$(git -C "$SCRIPT_DIR/../.." rev-parse --short HEAD 2>/dev/null || echo '?')"
confirm "Proceed?" || { say "aborted."; exit 0; }

banner "1/4  add-tenant"
add_args=( add-tenant "$TENANT" --xmpp-jid "$XMPP_JID" )
[[ "$DOCKER_GROUP" == true ]] && add_args+=( --docker-group )
[[ -n "$XMPP_PASSWORD" ]] && add_args+=( --xmpp-password "$XMPP_PASSWORD" )
[[ -n "$LLM_API_KEY" ]] && add_args+=( --llm-api-key "$LLM_API_KEY" )
[[ -n "$GOTIFY_URL" ]] && add_args+=( --gotify-url "$GOTIFY_URL" )
"$MT" "${add_args[@]}"

banner "2/4  build-tenant --with-wasm"
build_args=( build-tenant "$TENANT" --with-wasm )
[[ "$WITH_NANOCODE" == true ]] && build_args+=( --with-nanocode )
"$MT" "${build_args[@]}"

banner "3/4  start-tenant"
"$MT" start-tenant "$TENANT"

banner "4/4  verify"
"$PF" "$TENANT" || say "(pre-flight returned non-zero — review above)"
adapter_port="$(jq -r ".tenants[\"$TENANT\"].ports.weechat_adapter // empty" "$REGISTRY")"
if [[ -n "$adapter_port" ]]; then
  say "adapter health (:$adapter_port):"
  curl -fsS --max-time 3 "http://127.0.0.1:$adapter_port/api/health" 2>/dev/null && say "" \
    || say "  (no response yet — adapter may still be connecting to WeeChat)"
fi
say ""
say "weechat startup log (expect the tenant's real ports):"
sudo -u "$TENANT" XDG_RUNTIME_DIR="/run/user/$(id -u "$TENANT")" \
  journalctl --user -u "lunarwing-$TENANT.service" -n 150 --no-pager 2>/dev/null \
  | grep -i "WeeChat Relay channel starting\|ws_adapter" \
  || say "  (no journal lines yet; check '$MT status $TENANT')"

banner "done"
say "  status:  $MT status $TENANT"
say "  token:   $MT tokens $TENANT"
say "  remove:  $MT remove-tenant $TENANT --purge"
