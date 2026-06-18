#!/usr/bin/env bash
# F3 per-tenant classification tests for health-systemd.sh.
#
# Self-contained mock (systemctl/sudo/id) driven by a unit-state directory — no
# real systemd bus and no real services are touched. Validates the F3 rework:
#   - a not-started/disabled unit on a not-started tenant -> `skipped`
#   - a down unit on a STARTED tenant (primary daemon active) -> `critical`
#     (F3-A; covers `generated` Quadlet pg/worker units that are never "enabled")
#   - crashed (failed / auto-restart) -> `critical` regardless of enable-state
#   - enabled-but-down OR inconclusive enable-state -> `critical` (fail loud, F3-B)
#
# Each unit's state file holds five space-separated fields:
#   <LoadState> <ActiveState> <SubState> <NRestarts> <UnitFileState>
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
source "$DIR/lib.sh"
HS="$DIR/../health-systemd.sh"

mk_hs_mock() {
    local sb="$1" bin="$1/bin" sd="$1/units"
    mkdir -p "$bin" "$sd"
    # Mock systemctl: serves unit state from $HS_UNIT_DIR. `*) exit 0` covers any
    # subcommand we don't model. show returns props in the ORDER requested (the
    # caller asks for LoadState/ActiveState/SubState/NRestarts together, and asks
    # for UnitFileState/ActiveState separately), so no canonical-order coupling.
    cat > "$bin/systemctl" <<'EOF'
#!/usr/bin/env bash
SD="${HS_UNIT_DIR:?}"
sub="${1:-}"; shift || true
case "$sub" in
  --user) exec "$0" "$@" ;;
  list-unit-files)
    pats=(); for a in "$@"; do case "$a" in --no-legend|--user) ;; *) pats+=("$a");; esac; done
    globby=false; for p in "${pats[@]}"; do [[ "$p" == *'*'* ]] && globby=true; done
    if $globby; then
      for f in "$SD"/*.service; do [ -e "$f" ] || continue; printf '%s generated\n' "$(basename "$f")"; done
    else
      for p in "${pats[@]}"; do [ -e "$SD/$p" ] || exit 1; printf '%s generated\n' "$p"; done
    fi ;;
  status) [ -e "$SD/${1:-}" ] ;;
  show)
    props=(); unit=""
    while [ $# -gt 0 ]; do case "$1" in --value|--user) ;; -p) props+=("$2"); shift;; -*) ;; *) unit="$1";; esac; shift; done
    if [ -e "$SD/$unit" ]; then read -r LS AS SS NR UF < "$SD/$unit"; else LS=""; AS=""; SS=""; NR=""; UF=""; fi
    for p in "${props[@]}"; do case "$p" in
      LoadState) printf '%s\n' "$LS";; ActiveState) printf '%s\n' "$AS";; SubState) printf '%s\n' "$SS";;
      NRestarts) printf '%s\n' "${NR:-0}";; UnitFileState) printf '%s\n' "$UF";; *) printf '\n';;
    esac; done ;;
  *) exit 0 ;;
esac
EOF
    # Mock sudo: drop -n, -u <user>, env, VAR=VAL, exec the rest (same shape as
    # health-systemd's `sudo -n -u <u> env XDG_RUNTIME_DIR=.. systemctl --user ..`).
    cat > "$bin/sudo" <<'EOF'
#!/usr/bin/env bash
a=("$@"); i=0
while [ $i -lt ${#a[@]} ]; do case "${a[$i]}" in -n) ;; -u) i=$((i+1)) ;; env) ;; *=*) ;; -*) break ;; *) break ;; esac; i=$((i+1)); done
exec "${a[@]:$i}"
EOF
    # Mock id: tenant uid resolves to a fixed value (only used to build the XDG path
    # for the mocked --user bus, which the mock ignores).
    cat > "$bin/id" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "-u" ] && { echo 1000; exit 0; }
exec /usr/bin/id "$@"
EOF
    chmod +x "$bin"/*
}

unit_set() { printf '%s\n' "$3" > "$1/units/$2"; }   # <sb> <unit> "<ls> <as> <ss> <nr> <uf>"

run_hs() {  # <sb> <tenant> <user> -> health-systemd.sh JSON on stdout
    local sb="$1" t="$2" u="$3"
    jq -n --arg t "$t" --arg u "$u" '{tenants:{($t):{user:$u}}}' > "$sb/ports.json"
    env PATH="$sb/bin:$PATH" HS_UNIT_DIR="$sb/units" \
        LUNARWING_SERVICE_MANAGER=systemd LUNARWING_TENANTS_FILE="$sb/ports.json" \
        bash "$HS" 2>/dev/null
}
ustat() { jq -r --arg n "$2" '(.metrics.units[]?|select(.name==$n)|.status) // "ABSENT"' <<<"$1"; }
oall()  { jq -r '.status' <<<"$1"; }

# ── A: not-started tenant (primary daemon inactive+disabled) ─────────────────
echo "=== Section A: not-started tenant -> skipped, overall healthy ==="
a="$(sb)"; mk_hs_mock "$a"
unit_set "$a" lunarwing-acme.service        "loaded inactive dead 0 disabled"
unit_set "$a" lunarwing-pg-acme.service     "loaded active running 0 generated"
unit_set "$a" lunarwing-proxy-acme.service  "loaded inactive dead 0 disabled"
oA="$(run_hs "$a" acme acme)"
assert_eq "$(ustat "$oA" lunarwing-acme.service)"       "skipped" "A1: not-started daemon -> skipped"
assert_eq "$(ustat "$oA" lunarwing-pg-acme.service)"    "healthy" "A2: active pg -> healthy"
assert_eq "$(ustat "$oA" lunarwing-proxy-acme.service)" "skipped" "A3: not-started proxy -> skipped"
assert_eq "$(oall "$oA")"                               "healthy" "A4: overall healthy (no false critical)"

# ── B: started tenant (daemon active) with a down generated pg (F3-A) ────────
echo "=== Section B: down unit on a started tenant -> critical (F3-A) ==="
b="$(sb)"; mk_hs_mock "$b"
unit_set "$b" lunarwing-acme.service     "loaded active running 0 enabled"
unit_set "$b" lunarwing-pg-acme.service  "loaded inactive dead 0 generated"
oB="$(run_hs "$b" acme acme)"
assert_eq "$(ustat "$oB" lunarwing-acme.service)"    "healthy"  "B1: started daemon -> healthy"
assert_eq "$(ustat "$oB" lunarwing-pg-acme.service)" "critical" "B2: down generated pg on started tenant -> critical (F3-A)"
assert_eq "$(oall "$oB")"                            "critical" "B3: overall critical"

# ── C: crashed + enabled-down + unknown-enable -> critical (fail loud, F3-B) ─
echo "=== Section C: crashed / enabled-down / unknown -> critical (fail loud) ==="
c="$(sb)"; mk_hs_mock "$c"
unit_set "$c" lunarwing-acme.service       "loaded inactive dead 0 disabled"  # not-started daemon -> skipped
unit_set "$c" lunarwing-pg-acme.service    "loaded failed failed 0 generated" # crashed -> critical
unit_set "$c" xmpp-bridge-acme.service     "loaded inactive dead 0 enabled"   # enabled+down -> critical
unit_set "$c" lunarwing-proxy-acme.service "loaded inactive dead 0 "          # unknown enable -> critical
oC="$(run_hs "$c" acme acme)"
assert_eq "$(ustat "$oC" lunarwing-acme.service)"       "skipped"  "C1: not-started daemon -> skipped"
assert_eq "$(ustat "$oC" lunarwing-pg-acme.service)"    "critical" "C2: crashed (failed) -> critical"
assert_eq "$(ustat "$oC" xmpp-bridge-acme.service)"     "critical" "C3: enabled+down -> critical (fail loud)"
assert_eq "$(ustat "$oC" lunarwing-proxy-acme.service)" "critical" "C4: unknown enable-state -> critical (fail loud)"

# ── D: auto-restart (crash loop) and elevated restart count ──────────────────
echo "=== Section D: auto-restart -> critical; high restart count -> degraded ==="
d="$(sb)"; mk_hs_mock "$d"
unit_set "$d" lunarwing-acme.service       "loaded active running 0 enabled"        # started
unit_set "$d" xmpp-bridge-acme.service     "loaded activating auto-restart 0 enabled" # crash loop
unit_set "$d" lunarwing-proxy-acme.service "loaded active running 7 generated"       # flapping-ish
oD="$(run_hs "$d" acme acme)"
assert_eq "$(ustat "$oD" xmpp-bridge-acme.service)"     "critical" "D1: auto-restart -> critical"
assert_eq "$(ustat "$oD" lunarwing-proxy-acme.service)" "degraded" "D2: active w/ restart_count>=3 -> degraded"
assert_eq "$(oall "$oD")"                               "critical" "D3: overall critical (auto-restart dominates)"

finish
