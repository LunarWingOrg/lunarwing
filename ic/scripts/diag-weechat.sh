#!/usr/bin/env bash
#
# diag-weechat.sh — one-shot, READ-ONLY weechat diagnostic for a tenant.
# Grabs everything we've been chasing piecemeal, with correct auth/quoting,
# so there's nothing fragile to copy-paste. Writes nothing, changes nothing.
#
#   sudo bash ic/scripts/diag-weechat.sh [tenant]   # default: sunburst
set -uo pipefail   # NOT -e: one failing section must not abort the rest

T="${1:-sunburst}"
ENV="/home/$T/lunarwing/env/lunarwing.env"
[ -r "$ENV" ] || { echo "cannot read $ENV (run with sudo)"; exit 1; }

PW="$(grep -E '^RELAY_PASSWORD=' "$ENV" | head -1 | cut -d= -f2-)"
PGURL="$(grep -E '^DATABASE_URL=' "$ENV" | head -1 | cut -d= -f2-)"
AP="$(grep -E '^WS_ADAPTER_URL=' "$ENV" | head -1 | cut -d= -f2-)"; AP="${AP:-http://127.0.0.1:10069}"

echo "tenant=$T  adapter=$AP  relay_password_len=${#PW}"

echo
echo "===== 1. DB setup_fields (this OUTRANKS the caps config for dm_policy etc.) ====="
if command -v psql >/dev/null 2>&1; then
  PGSSLMODE=disable psql "$PGURL" -tAc \
    "SELECT key||' => '||value::text FROM settings WHERE key LIKE 'extensions.weechat%';" 2>&1 \
    || echo "(psql query failed)"
  echo "(empty above = no stale weechat setup_fields overriding the caps)"
else
  echo "(psql not installed — skipping DB check)"
fi

echo
echo "===== 2. adapter /api/config (policy the channel pulls every poll) ====="
curl -s --max-time 4 "$AP/api/config" 2>&1; echo

echo
echo "===== 3. recent lines + TAGS from irc.sobes.sun (does a DM carry irc_privmsg?) ====="
AUTH="Authorization: Basic $(printf 'plain:%s' "$PW" | base64 -w0)"
curl -s --max-time 6 -H "$AUTH" "$AP/api/buffers/irc.sobes.sun/lines?limit=6" 2>/tmp/diagwc.err \
  | jq -r 'if type=="array"
             then (.[] | "tags=\(.tags)  nick=\(.prefix // "?")  msg=\((.message // "")[0:50])")
             else "NON-ARRAY RESPONSE: \(.)" end' 2>&1 \
  || { echo "(curl/jq failed)"; cat /tmp/diagwc.err 2>/dev/null; }
rm -f /tmp/diagwc.err

echo
echo "===== 4. runtime policy the WASM is actually using (on-disk workspace state) ====="
for f in dm_policy group_policy allow_from ws_adapter_url relay_url; do
  p="$(find "/home/$T/lunarwing/state" -path '*weechat*' -name "$f" 2>/dev/null | head -1)"
  if [ -n "$p" ]; then echo "$f = $(cat "$p" 2>/dev/null)"; else echo "$f = (not on disk — held in DB workspace)"; fi
done

echo
echo "done — paste this whole block."
