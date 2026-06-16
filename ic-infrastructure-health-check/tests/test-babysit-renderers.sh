#!/usr/bin/env bash
# Test suite for the OpenRC container-babysitter unit renderers in
# lunarwing-mt-admin.sh — specifically that render_pg_ctr_unit and
# render_worker_ctr_unit emit unit files whose `command_args` parse into
# the correct argv when OpenRC splits on whitespace.
#
# Why this exists: OpenRC's `command_args=` is split on whitespace, NOT
# shell-parsed. An earlier draft used `command="/bin/sh"` with
# `command_args="-c '${runtime} start ${ctr}; exec ${runtime} wait ${ctr}'"`
# which is broken — the single quotes become literal argv characters and
# /bin/sh -c receives a malformed command starting with `'`. This suite
# catches that whole bug class.
#
# Strategy: copy lunarwing-mt-admin.sh to a temp file, sed-patch /etc/init.d
# paths to a sandbox, then source the patched copy with a guard that prevents
# the CLI entry point from running. Call the renderers, parse their output.

set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADMIN_SCRIPT="${ADMIN_SCRIPT:-$DIR/../../ic/scripts/lunarwing-mt-admin.sh}"
BABYSIT_WRAPPER="${BABYSIT_WRAPPER:-$DIR/../../ic/scripts/lunarwing-ctr-babysit}"

[[ -r "$ADMIN_SCRIPT" ]]    || { echo "FATAL: admin script not found at $ADMIN_SCRIPT"; exit 1; }
[[ -r "$BABYSIT_WRAPPER" ]] || { echo "FATAL: babysitter wrapper not found at $BABYSIT_WRAPPER"; exit 1; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/babysit-render-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

pass=0; fail=0
ok()  { printf 'PASS: %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL: %s\n      %s\n' "$1" "$2"; fail=$((fail + 1)); }
assert_eq() { if [[ "$1" == "$2" ]]; then ok "$3"; else bad "$3" "got [$1] want [$2]"; fi; }

# Sandbox dirs
mkdir -p "$ROOT/initd" "$ROOT/confd" "$ROOT/babysit-lib"

# Patched copy of the admin script. We rewrite three things:
#   1. /etc/init.d  -> $ROOT/initd   (where units land)
#   2. /etc/conf.d  -> $ROOT/confd
#   3. /usr/local/lib/lunarwing  -> $ROOT/babysit-lib  (where wrapper installs)
# And we strip the `set -euo pipefail` (we source as a library).
PATCHED="$ROOT/admin-patched.sh"
sed -e "s|/etc/init.d|$ROOT/initd|g" \
    -e "s|/etc/conf.d|$ROOT/confd|g" \
    -e "s|/usr/local/lib/lunarwing\b|$ROOT/babysit-lib|g" \
    -e 's|^set -euo pipefail|set +e|' \
    "$ADMIN_SCRIPT" > "$PATCHED"

# Source the patched script under a guard that prevents the CLI dispatch at
# the bottom from firing. The script's tail is `if [[ "${BASH_SOURCE[0]}" ==
# "${0}" ]]; then ... main ... fi` — sourcing makes that condition false.
# We also need to no-op a few helpers the renderers call but which would
# require root or a real environment.
LIB_LOADER="$ROOT/load-renderers.sh"
cat > "$LIB_LOADER" <<LOADER
# Set required env BEFORE sourcing.
MT_ROOTLESS="\${MT_ROOTLESS:-true}"
CONTAINER_RT="\${CONTAINER_RT:-podman}"

# Source the patched admin script. The CLI dispatch is gated on
# BASH_SOURCE==\$0 so it won't fire when we source.
. "$PATCHED" 2>/dev/null || true

# After sourcing, override BABYSIT_SRC to point at the real wrapper (the
# patched script computed it relative to its temp location).
BABYSIT_SRC="$BABYSIT_WRAPPER"

# Override helpers that need root / real system probes. Worker renderer calls
# ensure_container_runtime + tenant_home; we shim them to deterministic values
# so the test doesn't depend on \$PATH or real users.
ensure_container_runtime() { CONTAINER_RT="podman"; }
tenant_home() { printf '/home/%s' "\$1"; }

# Worker renderer resolves the runtime path via \`command -v "\$CONTAINER_RT"\`.
# In the test sandbox we want a deterministic value, so shim \`command\` for
# the renderer's narrow call site by exporting a fake PATH entry first.
mkdir -p "$ROOT/fakebin"
cat > "$ROOT/fakebin/podman" <<'PODMAN'
#!/bin/sh
exit 0
PODMAN
chmod +x "$ROOT/fakebin/podman"
export PATH="$ROOT/fakebin:\$PATH"
LOADER

# Verify the sourced script exposes the render functions.
type_check() {
  ( . "$LIB_LOADER" 2>/dev/null
    declare -F "$1" >/dev/null
  )
}

if type_check render_pg_ctr_unit; then
  ok "setup: render_pg_ctr_unit is defined after sourcing"
else
  bad "setup: render_pg_ctr_unit is defined after sourcing" "function not found"
  printf '\n%d passed, %d failed\n' "$pass" "$fail"
  exit 1
fi
if type_check render_worker_ctr_unit; then
  ok "setup: render_worker_ctr_unit is defined after sourcing"
else
  bad "setup: render_worker_ctr_unit is defined after sourcing" "function not found"
fi

# Render a unit by invoking the function in a subshell that has the loader sourced.
render_pg() {
  local name="$1" container="$2" runtime="$3" home="$4" uid="$5"
  ( . "$LIB_LOADER"; render_pg_ctr_unit "$name" "$container" "$runtime" "$home" "$uid" )
}
render_worker() {
  local name="$1" worker="$2"
  ( . "$LIB_LOADER"; render_worker_ctr_unit "$name" "$worker" )
}

# Parse a single shell variable assignment out of a generated unit file.
# Strips surrounding quotes; does NOT expand $vars (we want the literal form).
get_field() {
  local file="$1" var="$2"
  # Match `var=...` at start of line, capture the rest, strip surrounding quotes.
  local line
  line="$(grep -E "^${var}=" "$file" | head -1)"
  line="${line#${var}=}"
  # Strip surrounding double quotes if present.
  if [[ "$line" == \"*\" ]]; then
    line="${line#\"}"
    line="${line%\"}"
  fi
  printf '%s' "$line"
}

# Expand the unit file's variables to see what the runtime values would be.
# We do this by sourcing only the `: "${var:=default}"` lines and the simple
# assignments, then printing the requested variable. Skip function definitions.
expand_field() {
  local file="$1" var="$2"
  ( set +eu
    # Source only the variable-assignment lines (lines that start with `:`,
    # `export`, or `<word>=`). Skip anything that looks like a function body.
    awk '
      BEGIN { in_fn = 0; depth = 0 }
      /^[a-zA-Z_][a-zA-Z0-9_]*\(\)/ { in_fn = 1 }
      in_fn && /\{/ { depth++ }
      in_fn && /\}/ { depth--; if (depth == 0) { in_fn = 0; next } }
      !in_fn { print }
    ' "$file" > "$ROOT/.expand.sh"
    . "$ROOT/.expand.sh" 2>/dev/null
    eval "printf '%s' \"\${$var:-}\""
  )
}

# ── T1: PG renderer produces correct unit ────────────────────────────────────
render_pg zeus "lunarwing-pg-zeus" "/usr/bin/podman" "/home/zeus" "1001"
UNIT="$ROOT/initd/lunarwing-pg-zeus-ctr"
if [[ -f "$UNIT" ]]; then
  ok "T1: PG -ctr unit file written"
else
  bad "T1: PG -ctr unit file written" "missing $UNIT"
  printf '\n%d passed, %d failed\n' "$pass" "$fail"
  exit 1
fi

# CRITICAL regression guards: the old buggy form looked like
#   command="/bin/sh"
#   command_args="-c '${runtime} start ${ctr} >/dev/null 2>&1 || true; exec ...'"
# Anchored greps catch either reintroduction.
if grep -qE '^command="/bin/sh"' "$UNIT"; then
  bad "T1-REGRESS: command must NOT be /bin/sh (was the old broken pattern)" "$(grep '^command=' "$UNIT")"
else
  ok "T1-REGRESS: command is not /bin/sh"
fi
if grep -qE "^command_args=.*'" "$UNIT"; then
  bad "T1-REGRESS: command_args must NOT contain literal single quote" "$(grep '^command_args=' "$UNIT")"
else
  ok "T1-REGRESS: command_args has no literal single quote"
fi
if grep -qE "^command_args=.*>/dev/null" "$UNIT"; then
  bad "T1-REGRESS: command_args must NOT contain shell redirections" "$(grep '^command_args=' "$UNIT")"
else
  ok "T1-REGRESS: command_args has no shell redirections"
fi
if grep -qE "^command_args=\"-c " "$UNIT"; then
  bad "T1-REGRESS: command_args must NOT use -c <script>" "$(grep '^command_args=' "$UNIT")"
else
  ok "T1-REGRESS: command_args does not use -c <script>"
fi

# Expand the unit's vars and verify what supervise-daemon would see at runtime.
cmd="$(expand_field "$UNIT" command)"
cmd_args="$(expand_field "$UNIT" command_args)"
cmd_user="$(expand_field "$UNIT" command_user)"
sda="$(expand_field "$UNIT" supervise_daemon_args)"

assert_eq "$cmd" "$ROOT/babysit-lib/lunarwing-ctr-babysit" "T1: command points at the wrapper"

# OpenRC splits command_args on whitespace into argv. Simulate that.
read -ra argv <<< "$cmd_args"
assert_eq "${#argv[@]}" "2" "T1: command_args splits into exactly 2 argv tokens"
assert_eq "${argv[0]:-}" "/usr/bin/podman"      "T1: argv[1] = runtime path"
assert_eq "${argv[1]:-}" "lunarwing-pg-zeus"    "T1: argv[2] = container name"

assert_eq "$cmd_user" "zeus:zeus" "T1: command_user = tenant:tenant"

# supervise_daemon_args: "--env HOME=... --env XDG_RUNTIME_DIR=..."
read -ra sda_argv <<< "$sda"
assert_eq "${#sda_argv[@]}" "4" "T1: supervise_daemon_args splits into 4 tokens"
assert_eq "${sda_argv[0]:-}" "--env"                          "T1: sda[0] = --env"
assert_eq "${sda_argv[1]:-}" "HOME=/home/zeus"                "T1: sda[1] = HOME=/home/zeus"
assert_eq "${sda_argv[2]:-}" "--env"                          "T1: sda[2] = --env"
assert_eq "${sda_argv[3]:-}" "XDG_RUNTIME_DIR=/run/user/1001" "T1: sda[3] = XDG_RUNTIME_DIR=/run/user/1001"

# ── T2: Worker renderer (nanocode) ───────────────────────────────────────────
render_worker zeus nanocode
UNIT="$ROOT/initd/lunarwing-nanocode-zeus-ctr"
if [[ -f "$UNIT" ]]; then
  ok "T2: nanocode -ctr unit file written"
else
  bad "T2: nanocode -ctr unit file written" "missing $UNIT"
fi

if [[ -f "$UNIT" ]]; then
  if grep -qE '^command="/bin/sh"' "$UNIT"; then
    bad "T2-REGRESS: nanocode command must NOT be /bin/sh" "$(grep '^command=' "$UNIT")"
  else
    ok "T2-REGRESS: nanocode command is not /bin/sh"
  fi
  if grep -qE "^command_args=.*'" "$UNIT"; then
    bad "T2-REGRESS: nanocode command_args must NOT contain literal single quote" "$(grep '^command_args=' "$UNIT")"
  else
    ok "T2-REGRESS: nanocode command_args has no literal single quote"
  fi

  cmd_args="$(expand_field "$UNIT" command_args)"
  read -ra argv <<< "$cmd_args"
  assert_eq "${#argv[@]}" "2"                      "T2: nanocode command_args splits into 2 argv tokens"
  assert_eq "${argv[1]:-}" "lunarwing-nanocode-zeus" "T2: nanocode argv[2] = container name"
fi

# ── T3: Pebble worker renderer ───────────────────────────────────────────────
render_worker zeus pebble
UNIT="$ROOT/initd/lunarwing-pebble-zeus-ctr"
if [[ -f "$UNIT" ]]; then
  ok "T3: pebble -ctr unit file written"
  cmd_args="$(expand_field "$UNIT" command_args)"
  read -ra argv <<< "$cmd_args"
  assert_eq "${argv[1]:-}" "lunarwing-pebble-zeus" "T3: pebble argv[2] = container name"
else
  bad "T3: pebble -ctr unit file written" "missing $UNIT"
fi

# ── T4: Wrapper script itself behaves correctly ──────────────────────────────
rc=0; "$BABYSIT_WRAPPER" >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "2" "T4: wrapper exits 2 with no args (usage error)"

rc=0; "$BABYSIT_WRAPPER" /no/such/runtime ctr >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "1" "T4: wrapper exits 1 when runtime not executable"

FAKE="$ROOT/fake-runtime"
cat > "$FAKE" <<'FAKEEOF'
#!/bin/sh
case "$1" in
  start) exit 0 ;;
  wait)  exit 0 ;;
  *)     exit 1 ;;
esac
FAKEEOF
chmod +x "$FAKE"
rc=0; "$BABYSIT_WRAPPER" "$FAKE" mycontainer >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "0" "T4: wrapper exits 0 when runtime wait returns 0"

# ── T5: Generated unit files pass bash -n syntax check ───────────────────────
for f in "$ROOT/initd"/lunarwing-*-ctr; do
  [[ -f "$f" ]] || continue
  if bash -n "$f" 2>/tmp/.unit-syntax-err; then
    ok "T5: $(basename "$f") passes bash -n syntax check"
  else
    bad "T5: $(basename "$f") passes bash -n syntax check" "$(cat /tmp/.unit-syntax-err)"
  fi
done

# ── T6: Wrapper is installed by ensure_babysit_wrapper ───────────────────────
if [[ -x "$ROOT/babysit-lib/lunarwing-ctr-babysit" ]]; then
  ok "T6: ensure_babysit_wrapper installed the wrapper to BABYSIT_LIB_DIR"
else
  bad "T6: ensure_babysit_wrapper installed the wrapper to BABYSIT_LIB_DIR" "missing $ROOT/babysit-lib/lunarwing-ctr-babysit"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
