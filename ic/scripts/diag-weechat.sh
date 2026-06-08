#!/usr/bin/env bash
#
# diag-weechat.sh — one-shot, READ-ONLY weechat diagnostic for a tenant.
# Long-poll aware. Grabs everything we chase piecemeal, with correct auth/quoting,
# so there's nothing fragile to copy-paste. Writes nothing, changes nothing.
#
#   sudo bash ic/scripts/diag-weechat.sh [tenant]   # default: sunburst
set -uo pipefail   # NOT -e: one failing section must not abort the rest

T="${1:-sunburst}"
ENV="/home/$T/lunarwing/env/lunarwing.env"
[ -r "$ENV" ] || { echo "cannot read $ENV (run with sudo)"; exit 1; }

PW="$(grep -E '^RELAY_PASSWORD=' "$ENV" | head -1 | cut -d= -f2-)"
PGURL="$(grep -E '^DATABASE_URL=' "$ENV" | head -1 | cut -d= -f2-)"
AP="$(grep -E '^WS_ADAPTER_URL=' "$ENV" | head -1 | cut -d= -f2-)"
AUTH="Authorization: Basic $(printf 'plain:%s' "$PW" | base64 -w0)"
TUID="$(id -u "$T" 2>/dev/null || echo 0)"

echo "tenant=$T  adapter=${AP:-(unset!)}  relay_password_len=${#PW}  uid=$TUID"
[ -n "$AP" ] || { echo "WS_ADAPTER_URL not set in env — channel can't reach the adapter."; }

echo
echo "===== 1. adapter /api/health  (ws_connected + event_cursor) ====="
# /api/health is UNAUTHENTICATED. event_cursor present => adapter is the long-poll build
# and the WASM will pick long-poll. ws_connected:true => adapter<->WeeChat WS is live.
curl -s --max-time 4 "$AP/api/health" 2>&1 | jq . 2>/dev/null || curl -s --max-time 4 "$AP/api/health" 2>&1
echo "  -> no event_cursor field = OLD adapter (won't long-poll). ws_connected:false = WeeChat not reachable."

echo
echo "===== 2. adapter event log  (/api/wait?cursor=0 — are ANY lines recorded?) ====="
curl -s --max-time 6 -H "$AUTH" "$AP/api/wait?cursor=0&timeout=1" 2>&1 \
  | jq -r 'if has("events")
             then "total_cursor=\(.cursor)  events_returned=\(.events|length)",
                  (.events[-6:][]? | "  seq=\(.seq) buf=\(.full_name) tags=\(.line.tags_array // .line.tags // []) msg=\((.line.message // "")[0:50])")
             else "no .events field (401? old adapter?): \(.)" end' 2>&1 \
  || echo "(curl/jq failed — /api/wait missing => old adapter, would fall back to poll)"
echo "  -> events_returned=0 while ws_connected:true means WeeChat delivered nothing to record."

echo
echo "===== 3. buffers the adapter knows about ====="
curl -s --max-time 6 -H "$AUTH" "$AP/api/buffers" 2>&1 \
  | jq -r 'if type=="array" then (.[] | "\(.full_name // .name // "?")  (id=\(.id // "?"))") else "NON-ARRAY: \(.)" end' 2>&1 \
  | head -40 || echo "(failed)"
echo "  -> no irc.* buffers = WeeChat isn't connected to IRC / relay not set up yet."

echo
echo "===== 4. recent lines + TAGS per irc.* buffer  (does a DM carry irc_privmsg? self_msg?) ====="
BUFS="$(curl -s --max-time 6 -H "$AUTH" "$AP/api/buffers" 2>/dev/null | jq -r '.[]?.full_name // .[]?.name // empty' 2>/dev/null | grep -E '^irc\.' | head -8)"
[ -n "$BUFS" ] || echo "(no irc.* buffers found)"
for b in $BUFS; do
  echo "--- $b ---"
  curl -s --max-time 6 -H "$AUTH" "$AP/api/buffers/$b/lines?limit=4" 2>/dev/null \
    | jq -r 'if type=="array" then (.[] | "tags=\(.tags_array // .tags // [])  nick=\(.prefix // .nick // "?")  msg=\((.message // "")[0:50])") else "NON-ARRAY: \(.)" end' 2>&1
done

echo
echo "===== 5. WASM ingest state on disk  (which path did it actually choose?) ====="
for f in ingest_mode event_cursor dm_policy group_policy allow_from networks ws_adapter_url relay_url; do
  p="$(find "/home/$T/lunarwing/state" -path '*weechat*' -name "$f" 2>/dev/null | head -1)"
  if [ -n "$p" ]; then echo "$f = $(cat "$p" 2>/dev/null)"; else echo "$f = (not on disk — held in DB workspace)"; fi
done
echo "  -> ingest_mode=poll means the WASM did NOT see event_cursor at startup (adapter down at daemon start?)."

echo
echo "===== 6. daemon channel log  (ingest-mode pick is Info-level => always visible) ====="
if [ "$TUID" != 0 ]; then
  sudo -u "$T" XDG_RUNTIME_DIR="/run/user/$TUID" \
    journalctl --user -u "lunarwing-$T.service" -n 400 --no-pager 2>/dev/null \
    | grep -iE "ingest mode|seeded cursor|api/wait|falling back|on_poll completed|emitted_count|weechat.*(error|drop|denied|fail)" \
    | tail -30 || echo "(no matching journal lines)"
else
  echo "(could not resolve uid for $T)"
fi
echo "  -> want: 'WeeChat ingest mode: longpoll'. emitted_count=0 while events exist => policy is dropping."

echo
echo "===== 7. adapter /api/config  (policy the channel pulls each cycle) ====="
curl -s --max-time 4 "$AP/api/config" 2>&1; echo

echo
echo "===== 8. DB setup_fields  (OUTRANKS caps config for dm_policy etc.) ====="
if command -v psql >/dev/null 2>&1; then
  PGSSLMODE=disable psql "$PGURL" -tAc \
    "SELECT key||' => '||value::text FROM settings WHERE key LIKE 'extensions.weechat%';" 2>&1 \
    || echo "(psql query failed)"
  echo "(empty above = no stale weechat setup_fields overriding the caps — expected on a fresh tenant)"
else
  echo "(psql not installed — skipping DB check)"
fi

echo
echo "done — paste this whole block."
