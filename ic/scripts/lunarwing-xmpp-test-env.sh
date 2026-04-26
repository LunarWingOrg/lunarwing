#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LUNARWING_ROOT="$(cd "$REPO_ROOT/.." && pwd)"
TEST_ROOT="${LUNARWING_TEST_ROOT:-${TMPDIR:-/tmp}/lunarwing-xmpp-test}"
ENV_DIR="$TEST_ROOT/env"
LOG_DIR="$TEST_ROOT/logs"
RUN_DIR="$TEST_ROOT/run"
STATE_DIR="$TEST_ROOT/state"
SYSTEMD_DIR="$TEST_ROOT/systemd"
CHANNELS_DIR="$STATE_DIR/channels"
TOOLS_DIR="$STATE_DIR/tools"
PROFILE="${LUNARWING_TEST_PROFILE:-debug}"

# Database
DB_KIND="${LUNARWING_TEST_DATABASE_KIND:-postgres}"
PG_CONTAINER="${LUNARWING_TEST_PG_CONTAINER:-lunarwing-test-postgres}"
PG_PORT="${LUNARWING_TEST_PG_PORT:-5432}"
DATABASE_URL="${LUNARWING_TEST_DATABASE_URL:-postgres://ironclaw:ironclaw@127.0.0.1:${PG_PORT}/ironclaw}"
LIBSQL_PATH="${LUNARWING_TEST_LIBSQL_PATH:-$STATE_DIR/ironclaw.db}"

# TensorZero proxy
PROXY_PORT="${LUNARWING_TEST_PROXY_PORT:-3002}"
PROXY_BIND="${LUNARWING_TEST_PROXY_BIND:-127.0.0.1}"
TENSORZERO_URL="${LUNARWING_TEST_TENSORZERO_URL:-http://192.168.1.157:3000}"

usage() {
  cat <<'EOF'
Usage:
  scripts/lunarwing-xmpp-test-env.sh <command> [args...]

Full-stack integration test harness for LunarWing.
Manages PostgreSQL, TensorZero proxy, XMPP bridge, WASM channels/tools, and
the LunarWing daemon in an isolated test environment.

Commands:
  init                     create isolated env, state, run, and log dirs
  build [--with-wasm]      build LunarWing, xmpp-bridge [and WASM channels/tools]
  build-wasm               build all WASM channels and tools
  install-wasm             install built WASM artifacts to test directories
  doctor                   show dependency, binary, env, and service checks
  up                       bring up full stack (postgres -> proxy -> bridge -> lunarwing)
  down                     tear down full stack
  status                   show status of all components
  verify                   run health checks against running stack
  gateway-status           call authenticated GET /api/gateway/status

  start-postgres           start PostgreSQL container (pgvector/pg16)
  stop-postgres            stop PostgreSQL container (preserves data)
  reset-postgres           remove PostgreSQL container entirely
  start-proxy              start TensorZero ironclaw-proxy
  stop-proxy               stop TensorZero ironclaw-proxy
  start-bridge             start xmpp-bridge with the test env
  stop-bridge              stop the bridge started by this script
  start-lunarwing [-- args]
                           start target/<profile>/ironclaw with isolated state
  stop-lunarwing           stop LunarWing started by this script

  bridge-status            call authenticated GET /v1/status
  bridge-auth-check        verify missing-token rejection and valid-token status
  lunarwing-status         show pid/log hints for the local LunarWing process
  repl [-- args]           launch the standalone REPLv2 client for this harness
  smoke                    run bridge start/auth/status smoke test
  configure-bridge [args]  run scripts/xmpp-configure.sh with the test env
  rate-limit [args]        run scripts/xmpp-rate-limit.sh with the test env
  render-systemd           write systemd --user unit files under the test root
  logs [lines]             tail all test logs (including docker)

Environment:
  LUNARWING_TEST_ROOT      default: ${TMPDIR:-/tmp}/lunarwing-xmpp-test
  LUNARWING_TEST_PROFILE   debug or release; default: debug

  LUNARWING_TEST_DATABASE_KIND   postgres or libsql; default: postgres
  LUNARWING_TEST_PG_CONTAINER    default: lunarwing-test-postgres
  LUNARWING_TEST_PG_PORT         default: 5432
  LUNARWING_TEST_DATABASE_URL    override full postgres connection URL
  LUNARWING_TEST_LIBSQL_PATH     default: $LUNARWING_TEST_ROOT/state/ironclaw.db

  LUNARWING_TEST_PROXY_PORT      default: 3002
  LUNARWING_TEST_PROXY_BIND      default: 127.0.0.1
  LUNARWING_TEST_TENSORZERO_URL  default: http://192.168.1.157:3000

  LUNARWING_TEST_SERVICE_NAME    default: lunarwing-test.service
  LUNARWING_TEST_BRIDGE_SERVICE_NAME
                                 default: xmpp-bridge-test.service
  LUNARWING_TEST_PROXY_SERVICE_NAME
                                 default: ironclaw-proxy-test.service
  LUNARWING_TEST_SYSTEMCTL_SCOPE user or system; default: user
  LUNARWING_TEST_KEEP_BRIDGE=1   keeps smoke-test bridge running

Quick start:
  scripts/lunarwing-xmpp-test-env.sh init
  scripts/lunarwing-xmpp-test-env.sh build --with-wasm
  scripts/lunarwing-xmpp-test-env.sh install-wasm
  scripts/lunarwing-xmpp-test-env.sh up
  scripts/lunarwing-xmpp-test-env.sh verify

Notes:
  The generated env files are chmod 600 and may contain live secrets.
  This script never prints XMPP_BRIDGE_TOKEN, XMPP_PASSWORD, or API keys.
  Delete $ENV_DIR/lunarwing.env and re-run init to regenerate with new defaults.
EOF
}

say() {
  printf '%s\n' "$*"
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    die "$1 is required"
  fi
}

profile_dir() {
  case "$PROFILE" in
    debug|"")
      printf 'debug'
      ;;
    release)
      printf 'release'
      ;;
    *)
      die "LUNARWING_TEST_PROFILE must be 'debug' or 'release'"
      ;;
  esac
}

lunarwing_bin() {
  printf '%s/target/%s/ironclaw' "$REPO_ROOT" "$(profile_dir)"
}

bridge_bin() {
  printf '%s/bridges/xmpp-bridge/target/%s/xmpp-bridge' "$REPO_ROOT" "$(profile_dir)"
}

replv2_client_dir() {
  printf '%s/replv2git/git-ironclaw-unix-socket-client-repo' "$LUNARWING_ROOT"
}

replv2_client_bin() {
  printf '%s/target/release/unix-socket-client-v2' "$(replv2_client_dir)"
}

harness_socket_path() {
  printf '%s/ironclaw.sock' "$RUN_DIR"
}

generate_token() {
  if command -v od >/dev/null 2>&1; then
    dd if=/dev/urandom bs=32 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n'
  else
    printf 'replace-with-random-token-%s' "$(date +%s)"
  fi
}

database_kind() {
  case "$DB_KIND" in
    postgres|libsql)
      printf '%s' "$DB_KIND"
      ;;
    *)
      die "LUNARWING_TEST_DATABASE_KIND must be 'postgres' or 'libsql'"
      ;;
  esac
}

env_value_from_file() {
  local path="$1"
  local key="$2"
  [[ -f "$path" ]] || return 1
  awk -F= -v key="$key" '
    $1 == key {
      sub(/^[^=]*=/, "", $0)
      print
      exit
    }
  ' "$path"
}

shared_xmpp_jid() {
  local value="${LUNARWING_TEST_XMPP_JID:-}"
  if [[ -n "$value" ]]; then
    printf '%s' "$value"
    return 0
  fi
  value="$(env_value_from_file "$ENV_DIR/lunarwing.env" "XMPP_JID" 2>/dev/null || true)"
  if [[ -n "$value" ]]; then
    printf '%s' "$value"
    return 0
  fi
  value="$(env_value_from_file "$ENV_DIR/xmpp-bridge.env" "XMPP_JID" 2>/dev/null || true)"
  if [[ -n "$value" ]]; then
    printf '%s' "$value"
    return 0
  fi
  printf 'lw-%s@harness.invalid' "$(generate_token | cut -c1-12)"
}

shared_xmpp_password() {
  local value="${LUNARWING_TEST_XMPP_PASSWORD:-}"
  if [[ -n "$value" ]]; then
    printf '%s' "$value"
    return 0
  fi
  value="$(env_value_from_file "$ENV_DIR/lunarwing.env" "XMPP_PASSWORD" 2>/dev/null || true)"
  if [[ -n "$value" ]]; then
    printf '%s' "$value"
    return 0
  fi
  value="$(env_value_from_file "$ENV_DIR/xmpp-bridge.env" "XMPP_PASSWORD" 2>/dev/null || true)"
  if [[ -n "$value" ]]; then
    printf '%s' "$value"
    return 0
  fi
  printf '%s' "$(generate_token | cut -c1-32)"
}

shared_xmpp_bridge_token() {
  local value="${LUNARWING_TEST_XMPP_BRIDGE_TOKEN:-}"
  if [[ -n "$value" ]]; then
    printf '%s' "$value"
    return 0
  fi
  value="$(env_value_from_file "$ENV_DIR/lunarwing.env" "XMPP_BRIDGE_TOKEN" 2>/dev/null || true)"
  if [[ -n "$value" ]]; then
    printf '%s' "$value"
    return 0
  fi
  value="$(env_value_from_file "$ENV_DIR/xmpp-bridge.env" "XMPP_BRIDGE_TOKEN" 2>/dev/null || true)"
  if [[ -n "$value" ]]; then
    printf '%s' "$value"
    return 0
  fi
  printf '%s' "$(generate_token)"
}

shared_secrets_master_key() {
  local value="${LUNARWING_TEST_SECRETS_MASTER_KEY:-}"
  if [[ -n "$value" ]]; then
    printf '%s' "$value"
    return 0
  fi
  value="$(env_value_from_file "$ENV_DIR/lunarwing.env" "SECRETS_MASTER_KEY" 2>/dev/null || true)"
  if [[ -n "$value" ]]; then
    printf '%s' "$value"
    return 0
  fi
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
  else
    generate_token
  fi
}

shared_xmpp_allow_from_json() {
  printf '["%s"]' "$(shared_xmpp_jid)"
}

# Map channel directory name to crate binary name (per bundled.rs KNOWN_CHANNELS).
channel_crate_name() {
  case "$1" in
    weechat) printf 'weechat_relay_channel' ;;
    *)       printf '%s_channel' "$1" ;;
  esac
}

# Map tool directory name to crate binary name (per loader.rs convention).
# Replace hyphens with underscores, append _tool.
tool_binary_name() {
  printf '%s_tool' "$(printf '%s' "$1" | tr '-' '_')"
}

init_dirs() {
  mkdir -p "$ENV_DIR" "$LOG_DIR" "$RUN_DIR" "$STATE_DIR/xmpp" "$SYSTEMD_DIR" \
    "$CHANNELS_DIR" "$TOOLS_DIR"
  chmod 700 "$ENV_DIR" "$RUN_DIR" "$STATE_DIR" 2>/dev/null || true
}

append_env_if_missing() {
  local path="$1"
  local key="$2"
  local value="$3"
  if ! grep -q "^${key}=" "$path" 2>/dev/null; then
    printf '%s=%s\n' "$key" "$value" >>"$path"
  fi
}

replace_env_value() {
  local path="$1"
  local key="$2"
  local value="$3"
  if [[ ! -f "$path" ]]; then
    return 0
  fi
  sed -i "s|^${key}=.*|${key}=${value}|" "$path"
}

ensure_lunarwing_env_defaults() {
  local path="$1"
  append_env_if_missing "$path" "AGENT_NAME" "lunarwing"
  append_env_if_missing "$path" "ALLOW_PRIVATE_IPS" "1"
  append_env_if_missing "$path" "SECRETS_MASTER_KEY" "$(shared_secrets_master_key)"
  if [[ "$(database_kind)" == "postgres" ]]; then
    append_env_if_missing "$path" "DATABASE_BACKEND" "postgres"
    append_env_if_missing "$path" "DATABASE_URL" "$DATABASE_URL"
    append_env_if_missing "$path" "DATABASE_SSLMODE" "disable"
    append_env_if_missing "$path" "PGSSLMODE" "disable"
    replace_env_value "$path" "DATABASE_BACKEND" "postgres"
    replace_env_value "$path" "DATABASE_URL" "$DATABASE_URL"
    replace_env_value "$path" "DATABASE_SSLMODE" "disable"
    replace_env_value "$path" "PGSSLMODE" "disable"
  else
    append_env_if_missing "$path" "DATABASE_BACKEND" "libsql"
    append_env_if_missing "$path" "LIBSQL_PATH" "$LIBSQL_PATH"
    replace_env_value "$path" "DATABASE_BACKEND" "libsql"
    replace_env_value "$path" "LIBSQL_PATH" "$LIBSQL_PATH"
  fi
  append_env_if_missing "$path" "WASM_CHANNELS_ENABLED" "true"
  append_env_if_missing "$path" "XMPP_BRIDGE_URL" "$(bridge_base)"
  append_env_if_missing "$path" "XMPP_BRIDGE_TOKEN" "$(shared_xmpp_bridge_token)"
  append_env_if_missing "$path" "XMPP_JID" "$(shared_xmpp_jid)"
  append_env_if_missing "$path" "XMPP_PASSWORD" "$(shared_xmpp_password)"
  append_env_if_missing "$path" "XMPP_DM_POLICY" "allowlist"
  append_env_if_missing "$path" "XMPP_ALLOW_FROM" "$(shared_xmpp_jid)"
  append_env_if_missing "$path" "XMPP_ALLOW_ROOMS" ""
  append_env_if_missing "$path" "XMPP_ENCRYPTED_ROOMS" ""
  append_env_if_missing "$path" "XMPP_OMEMO_DEVICE_ID" "0"
  append_env_if_missing "$path" "XMPP_OMEMO_STORE_DIR" "$STATE_DIR/xmpp"
  append_env_if_missing "$path" "XMPP_ALLOW_PLAINTEXT_FALLBACK" "true"
  append_env_if_missing "$path" "XMPP_RESOURCE" "lunarwing-test"
  append_env_if_missing "$path" "IRONCLAW_SOCKET" "$(harness_socket_path)"
  append_env_if_missing "$path" "LUNARWING_SOCKET" "$(harness_socket_path)"
  replace_env_value "$path" "IRONCLAW_SOCKET" "$(harness_socket_path)"
  replace_env_value "$path" "LUNARWING_SOCKET" "$(harness_socket_path)"
  replace_env_value "$path" "LLM_MODEL" "tensorzero::function_name::ironclaw"
}

ensure_bridge_env_defaults() {
  local path="$1"
  append_env_if_missing "$path" "IRONCLAW_BASE_DIR" "$STATE_DIR"
  append_env_if_missing "$path" "XMPP_BRIDGE_BIND" "127.0.0.1:8787"
  append_env_if_missing "$path" "XMPP_BRIDGE_TOKEN" "$(shared_xmpp_bridge_token)"
  append_env_if_missing "$path" "XMPP_BRIDGE_MAX_MESSAGES" "256"
  append_env_if_missing "$path" "RUST_LOG" "xmpp_bridge=info,info"
  append_env_if_missing "$path" "XMPP_JID" "$(shared_xmpp_jid)"
  append_env_if_missing "$path" "XMPP_PASSWORD" "$(shared_xmpp_password)"
  append_env_if_missing "$path" "XMPP_DM_POLICY" "allowlist"
  append_env_if_missing "$path" "XMPP_ALLOW_FROM_JSON" "$(shared_xmpp_allow_from_json)"
  append_env_if_missing "$path" "XMPP_ALLOW_ROOMS_JSON" "[]"
  append_env_if_missing "$path" "XMPP_ENCRYPTED_ROOMS_JSON" "[]"
  append_env_if_missing "$path" "XMPP_DEVICE_ID" "0"
  append_env_if_missing "$path" "XMPP_OMEMO_STORE_DIR" "$STATE_DIR/xmpp"
  append_env_if_missing "$path" "XMPP_ALLOW_PLAINTEXT_FALLBACK" "true"
  append_env_if_missing "$path" "XMPP_RESOURCE" "lunarwing-test"
  append_env_if_missing "$path" "XMPP_BRIDGE_WAIT_SECONDS" "15"
}

write_lunarwing_env_if_missing() {
  local path="$ENV_DIR/lunarwing.env"
  if [[ -f "$path" ]]; then
    ensure_lunarwing_env_defaults "$path"
    return 0
  fi

  local gateway_token
  gateway_token="$(generate_token)"

  (
    umask 077
    {
      printf 'IRONCLAW_BASE_DIR=%s\n' "$STATE_DIR"
      printf 'IRONCLAW_SOCKET=%s\n' "$(harness_socket_path)"
      printf 'LUNARWING_SOCKET=%s\n' "$(harness_socket_path)"
      printf '\n'
      if [[ "$(database_kind)" == "postgres" ]]; then
        printf '# Database — PostgreSQL (start with: start-postgres)\n'
        printf 'DATABASE_BACKEND=postgres\n'
        printf 'DATABASE_URL=%s\n' "$DATABASE_URL"
        printf 'DATABASE_SSLMODE=disable\n'
        printf 'PGSSLMODE=disable\n'
      else
        printf '# Database — libSQL\n'
        printf 'DATABASE_BACKEND=libsql\n'
        printf 'LIBSQL_PATH=%s\n' "$LIBSQL_PATH"
      fi
      printf '\n'
      printf '# LLM — TensorZero proxy (start with: start-proxy)\n'
      printf 'LLM_BACKEND=openai_compatible\n'
      printf 'LLM_BASE_URL=http://%s:%s/openai/v1\n' "$PROXY_BIND" "$PROXY_PORT"
      printf 'LLM_API_KEY=token-integration-test\n'
      printf 'LLM_MODEL=tensorzero::function_name::ironclaw\n'
      printf 'ALLOW_PRIVATE_IPS=1\n'
      printf '\n'
      printf '# Runtime identity\n'
      printf 'AGENT_NAME=lunarwing\n'
      printf 'SECRETS_MASTER_KEY=%s\n' "$(shared_secrets_master_key)"
      printf '\n'
      printf '# XMPP — seeded so the WASM channel has a full config on first boot\n'
      printf 'XMPP_BRIDGE_URL=%s\n' "$(bridge_base)"
      printf 'XMPP_BRIDGE_TOKEN=%s\n' "$(shared_xmpp_bridge_token)"
      printf 'XMPP_JID=%s\n' "$(shared_xmpp_jid)"
      printf 'XMPP_PASSWORD=%s\n' "$(shared_xmpp_password)"
      printf 'XMPP_DM_POLICY=allowlist\n'
      printf 'XMPP_ALLOW_FROM=%s\n' "$(shared_xmpp_jid)"
      printf 'XMPP_ALLOW_ROOMS=\n'
      printf 'XMPP_ENCRYPTED_ROOMS=\n'
      printf 'XMPP_OMEMO_DEVICE_ID=0\n'
      printf 'XMPP_OMEMO_STORE_DIR=%s/xmpp\n' "$STATE_DIR"
      printf 'XMPP_ALLOW_PLAINTEXT_FALLBACK=true\n'
      printf 'XMPP_RESOURCE=lunarwing-test\n'
      printf '\n'
      printf '# WASM channels and tools (build with: build-wasm, install with: install-wasm)\n'
      printf 'WASM_ENABLED=true\n'
      printf 'WASM_CHANNELS_ENABLED=true\n'
      printf 'WASM_TOOLS_DIR=%s\n' "$TOOLS_DIR"
      printf 'WASM_CHANNELS_DIR=%s\n' "$CHANNELS_DIR"
      printf '\n'
      printf '# Gateway\n'
      printf 'GATEWAY_ENABLED=true\n'
      printf 'GATEWAY_HOST=127.0.0.1\n'
      printf 'GATEWAY_PORT=8765\n'
      printf 'GATEWAY_AUTH_TOKEN=%s\n' "$gateway_token"
      printf '\n'
      printf '# Daemon mode\n'
      printf 'CLI_ENABLED=false\n'
      printf 'ONBOARD_COMPLETED=true\n'
      printf 'HEARTBEAT_ENABLED=false\n'
      printf 'RUST_LOG=ironclaw=info,lunarwing=info\n'
    } >"$path"
  )

  ensure_lunarwing_env_defaults "$path"
}

write_proxy_env_if_missing() {
  local path="$ENV_DIR/proxy.env"
  if [[ -f "$path" ]]; then
    return 0
  fi

  (
    umask 077
    {
      printf 'PROXY_PORT=%s\n' "$PROXY_PORT"
      printf 'PROXY_BIND=%s\n' "$PROXY_BIND"
      printf 'TENSORZERO_URL=%s\n' "$TENSORZERO_URL"
    } >"$path"
  )
}

write_bridge_env_if_missing() {
  local path="$ENV_DIR/xmpp-bridge.env"
  if [[ -f "$path" ]]; then
    ensure_bridge_env_defaults "$path"
    return 0
  fi

  (
    umask 077
    {
      printf 'IRONCLAW_BASE_DIR=%s\n' "$STATE_DIR"
      printf 'XMPP_BRIDGE_BIND=127.0.0.1:8787\n'
      printf 'XMPP_BRIDGE_TOKEN=%s\n' "$(shared_xmpp_bridge_token)"
      printf 'XMPP_BRIDGE_MAX_MESSAGES=256\n'
      printf 'RUST_LOG=xmpp_bridge=info,info\n'
      printf '\n'
      printf '# Seeded XMPP placeholders for bridge configure tests.\n'
      printf 'XMPP_JID=%s\n' "$(shared_xmpp_jid)"
      printf 'XMPP_PASSWORD=%s\n' "$(shared_xmpp_password)"
      printf 'XMPP_DM_POLICY=allowlist\n'
      printf 'XMPP_ALLOW_FROM_JSON=%s\n' "$(shared_xmpp_allow_from_json)"
      printf 'XMPP_ALLOW_ROOMS_JSON=[]\n'
      printf 'XMPP_ENCRYPTED_ROOMS_JSON=[]\n'
      printf 'XMPP_DEVICE_ID=0\n'
      printf 'XMPP_OMEMO_STORE_DIR=%s/xmpp\n' "$STATE_DIR"
      printf 'XMPP_ALLOW_PLAINTEXT_FALLBACK=true\n'
      printf 'XMPP_RESOURCE=lunarwing-test\n'
      printf 'XMPP_BRIDGE_WAIT_SECONDS=15\n'
    } >"$path"
  )

  ensure_bridge_env_defaults "$path"
}

init_env() {
  init_dirs
  write_lunarwing_env_if_missing
  write_bridge_env_if_missing
  write_proxy_env_if_missing
  say "test root: $TEST_ROOT"
  say "lunarwing env: $ENV_DIR/lunarwing.env"
  say "xmpp bridge env: $ENV_DIR/xmpp-bridge.env"
  say "proxy env: $ENV_DIR/proxy.env"
  say "repl socket: $(harness_socket_path)"
  say "channels dir: $CHANNELS_DIR"
  say "tools dir: $TOOLS_DIR"
  say "edit the env files for live XMPP or agent credentials; secrets are not printed"
}

load_env_file() {
  local path="$1"
  [[ -f "$path" ]] || die "missing env file: $path; run init first"
  set -a
  # shellcheck disable=SC1090
  . "$path"
  set +a
}

load_lunarwing_env() {
  load_env_file "$ENV_DIR/lunarwing.env"
}

load_bridge_env() {
  load_env_file "$ENV_DIR/xmpp-bridge.env"
}

load_all_envs() {
  load_lunarwing_env
  load_bridge_env
}

ensure_env() {
  init_dirs
  write_lunarwing_env_if_missing
  write_bridge_env_if_missing
  write_proxy_env_if_missing
}

bridge_base() {
  local bind="${XMPP_BRIDGE_BIND:-127.0.0.1:8787}"
  local port="${bind##*:}"
  if [[ "$port" == "$bind" || -z "$port" ]]; then
    port="8787"
  fi
  printf 'http://127.0.0.1:%s' "$port"
}

normalize_service_name() {
  local name="$1"
  if [[ -z "$name" ]]; then
    die "service name cannot be empty"
  fi
  if [[ "$name" == *"/"* || "$name" =~ [[:space:]] ]]; then
    die "service name must not contain slashes or whitespace: $name"
  fi
  case "$name" in
    *.service)
      printf '%s' "$name"
      ;;
    *)
      printf '%s.service' "$name"
      ;;
  esac
}

lunarwing_service_name() {
  normalize_service_name "${LUNARWING_TEST_SERVICE_NAME:-lunarwing-test.service}"
}

bridge_service_name() {
  normalize_service_name "${LUNARWING_TEST_BRIDGE_SERVICE_NAME:-xmpp-bridge-test.service}"
}

require_binary() {
  local path="$1"
  local build_hint="$2"
  [[ -x "$path" ]] || die "missing executable: $path; run $build_hint"
}

pid_alive() {
  local pid_file="$1"
  local pid
  [[ -f "$pid_file" ]] || return 1
  pid="$(<"$pid_file")"
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" >/dev/null 2>&1
}

bridge_ready() {
  local base
  base="$(bridge_base)"
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' \
    "$base/v1/status" \
    -H "Authorization: Bearer ${XMPP_BRIDGE_TOKEN:-}" 2>/dev/null || true)"
  [[ "$code" == "200" ]]
}

wait_for_bridge() {
  local wait_seconds="${XMPP_BRIDGE_WAIT_SECONDS:-15}"
  local deadline=$((SECONDS + wait_seconds))
  while (( SECONDS < deadline )); do
    if bridge_ready; then
      return 0
    fi
    sleep 1
  done

  say "xmpp-bridge did not become ready within ${wait_seconds}s" >&2
  if [[ -f "$LOG_DIR/xmpp-bridge.log" ]]; then
    tail -n 40 "$LOG_DIR/xmpp-bridge.log" >&2 || true
  fi
  return 1
}

# --- PostgreSQL management ---

pg_container_state() {
  if [[ "$(database_kind)" == "libsql" ]]; then
    printf 'not-used'
    return 0
  fi
  local state
  state="$(docker inspect -f '{{.State.Status}}' "$PG_CONTAINER" 2>/dev/null)" || state="not-created"
  printf '%s' "$state"
}

start_postgres() {
  if [[ "$(database_kind)" == "libsql" ]]; then
    say "database backend is libsql; no PostgreSQL container to start"
    return 0
  fi
  require_cmd docker

  local state
  state="$(pg_container_state)"
  case "$state" in
    running)
      say "PostgreSQL already running (container $PG_CONTAINER)"
      return 0
      ;;
    exited|created)
      say "starting existing PostgreSQL container $PG_CONTAINER"
      docker start "$PG_CONTAINER" >/dev/null
      ;;
    *)
      say "creating PostgreSQL container $PG_CONTAINER on port $PG_PORT"
      docker run -d \
        --name "$PG_CONTAINER" \
        -e POSTGRES_DB=ironclaw \
        -e POSTGRES_USER=ironclaw \
        -e POSTGRES_PASSWORD=ironclaw \
        -p "127.0.0.1:${PG_PORT}:5432" \
        pgvector/pgvector:pg16 >/dev/null
      ;;
  esac

  wait_for_postgres
  say "PostgreSQL ready on port $PG_PORT"
}

wait_for_postgres() {
  local deadline=$((SECONDS + 30))
  while (( SECONDS < deadline )); do
    if docker exec "$PG_CONTAINER" pg_isready -U ironclaw >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  die "PostgreSQL did not become ready within 30s"
}

stop_postgres() {
  if [[ "$(database_kind)" == "libsql" ]]; then
    say "database backend is libsql; no PostgreSQL container to stop"
    return 0
  fi
  require_cmd docker
  local state
  state="$(pg_container_state)"
  if [[ "$state" != "running" ]]; then
    say "PostgreSQL is not running (state: $state)"
    return 0
  fi
  say "stopping PostgreSQL container $PG_CONTAINER"
  docker stop "$PG_CONTAINER" >/dev/null
  say "PostgreSQL stopped (container preserved; use reset-postgres to remove)"
}

reset_postgres() {
  if [[ "$(database_kind)" == "libsql" ]]; then
    say "database backend is libsql; no PostgreSQL container to remove"
    return 0
  fi
  require_cmd docker
  local state
  state="$(pg_container_state)"
  if [[ "$state" == "not-created" ]]; then
    say "PostgreSQL container $PG_CONTAINER does not exist"
    return 0
  fi
  say "removing PostgreSQL container $PG_CONTAINER"
  docker rm -f "$PG_CONTAINER" >/dev/null
  say "PostgreSQL container removed"
}

# --- TensorZero proxy management ---

proxy_bin() {
  printf '%s/tensorzero-proxy-configurations/ironclaw-proxy.py' "$LUNARWING_ROOT"
}

proxy_ready() {
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' \
    "http://${PROXY_BIND}:${PROXY_PORT}/openai/v1/models" 2>/dev/null || true)"
  [[ -n "$code" && "$code" != "000" ]]
}

wait_for_proxy() {
  local deadline=$((SECONDS + 15))
  while (( SECONDS < deadline )); do
    if proxy_ready; then
      return 0
    fi
    sleep 1
  done
  say "proxy did not become ready within 15s" >&2
  if [[ -f "$LOG_DIR/proxy.log" ]]; then
    tail -n 20 "$LOG_DIR/proxy.log" >&2 || true
  fi
  return 1
}

start_proxy() {
  ensure_env
  require_cmd python3
  require_cmd curl
  local bin
  bin="$(proxy_bin)"
  [[ -f "$bin" ]] || die "proxy script not found: $bin"

  if pid_alive "$RUN_DIR/proxy.pid"; then
    say "proxy already running with pid $(<"$RUN_DIR/proxy.pid")"
    return 0
  fi

  if proxy_ready; then
    say "proxy already responds at http://${PROXY_BIND}:${PROXY_PORT}"
    return 0
  fi

  say "starting TensorZero proxy at ${PROXY_BIND}:${PROXY_PORT} -> $TENSORZERO_URL"
  python3 "$bin" \
    --port "$PROXY_PORT" \
    --bind "$PROXY_BIND" \
    --tensorzero "$TENSORZERO_URL" \
    >>"$LOG_DIR/proxy.log" 2>&1 &
  printf '%s\n' "$!" >"$RUN_DIR/proxy.pid"

  wait_for_proxy
  say "proxy ready; pid $(<"$RUN_DIR/proxy.pid")"
}

stop_proxy() {
  stop_by_pid_file "proxy" "$RUN_DIR/proxy.pid"
}

# --- WASM build and install ---

build_wasm() {
  require_cmd cargo

  local built=0 skipped=0 failed=0
  local log_file="$LOG_DIR/wasm-build.log"
  : >"$log_file"

  # Check for wasm32-wasip2 target
  if ! rustup target list --installed 2>/dev/null | grep -q wasm32-wasip2; then
    say "installing wasm32-wasip2 target"
    rustup target add wasm32-wasip2
  fi

  say "building WASM channels..."
  for dir in "$REPO_ROOT/channels-src"/*/; do
    [[ -d "$dir" ]] || continue
    local name
    name="$(basename "$dir")"

    # Skip symlinks with missing targets
    if [[ -L "$dir" ]] && [[ ! -e "$dir/Cargo.toml" ]]; then
      say "  skip $name (symlink target not available)"
      skipped=$((skipped + 1))
      continue
    fi

    say "  build $name"
    if (cd "$dir" && cargo build --release --target wasm32-wasip2) >>"$log_file" 2>&1; then
      built=$((built + 1))
    else
      say "  FAILED: $name (see $log_file)"
      failed=$((failed + 1))
    fi
  done

  say "building WASM tools..."
  for dir in "$REPO_ROOT/tools-src"/*/; do
    [[ -d "$dir" ]] || continue
    local name
    name="$(basename "$dir")"

    if [[ -L "$dir" ]] && [[ ! -e "$dir/Cargo.toml" ]]; then
      say "  skip $name (symlink target not available)"
      skipped=$((skipped + 1))
      continue
    fi

    say "  build $name"
    if (cd "$dir" && cargo build --release --target wasm32-wasip2) >>"$log_file" 2>&1; then
      built=$((built + 1))
    else
      say "  FAILED: $name (see $log_file)"
      failed=$((failed + 1))
    fi
  done

  say "WASM build: $built built, $skipped skipped, $failed failed"
  [[ "$failed" -eq 0 ]]
}

install_wasm() {
  ensure_env

  local installed=0 skipped=0
  local has_wasm_tools=true
  if ! command -v wasm-tools >/dev/null 2>&1; then
    say "wasm-tools not found; copying raw WASM files without componentize/strip"
    has_wasm_tools=false
  fi

  say "installing WASM channels to $CHANNELS_DIR..."
  for dir in "$REPO_ROOT/channels-src"/*/; do
    [[ -d "$dir" ]] || continue
    local name crate_name src_wasm dest_wasm caps_src caps_dest
    name="$(basename "$dir")"
    crate_name="$(channel_crate_name "$name")"
    src_wasm="$dir/target/wasm32-wasip2/release/${crate_name}.wasm"
    dest_wasm="$CHANNELS_DIR/${name}.wasm"
    caps_src="$dir/${name}.capabilities.json"
    caps_dest="$CHANNELS_DIR/${name}.capabilities.json"

    if [[ ! -f "$src_wasm" ]]; then
      skipped=$((skipped + 1))
      continue
    fi

    if [[ "$has_wasm_tools" == "true" ]]; then
      wasm-tools component new "$src_wasm" -o "$dest_wasm" 2>/dev/null \
        || cp "$src_wasm" "$dest_wasm"
      wasm-tools strip "$dest_wasm" -o "$dest_wasm" 2>/dev/null || true
    else
      cp "$src_wasm" "$dest_wasm"
    fi

    if [[ -f "$caps_src" ]]; then
      cp "$caps_src" "$caps_dest"
    fi
    say "  installed channel: $name"
    installed=$((installed + 1))
  done

  say "installing WASM tools to $TOOLS_DIR..."
  for dir in "$REPO_ROOT/tools-src"/*/; do
    [[ -d "$dir" ]] || continue
    local name bin_name install_name src_wasm dest_wasm caps_src caps_dest
    name="$(basename "$dir")"
    bin_name="$(tool_binary_name "$name")"
    install_name="${name}-tool"
    src_wasm="$dir/target/wasm32-wasip2/release/${bin_name}.wasm"
    dest_wasm="$TOOLS_DIR/${install_name}.wasm"
    caps_dest="$TOOLS_DIR/${install_name}.capabilities.json"

    if [[ ! -f "$src_wasm" ]]; then
      skipped=$((skipped + 1))
      continue
    fi

    if [[ "$has_wasm_tools" == "true" ]]; then
      wasm-tools component new "$src_wasm" -o "$dest_wasm" 2>/dev/null \
        || cp "$src_wasm" "$dest_wasm"
      wasm-tools strip "$dest_wasm" -o "$dest_wasm" 2>/dev/null || true
    else
      cp "$src_wasm" "$dest_wasm"
    fi

    # Capabilities sidecar: try <name>-tool.capabilities.json first, then <name>.capabilities.json
    caps_src="$dir/${install_name}.capabilities.json"
    if [[ ! -f "$caps_src" ]]; then
      caps_src="$dir/${name}.capabilities.json"
    fi
    if [[ -f "$caps_src" ]]; then
      cp "$caps_src" "$caps_dest"
    fi
    say "  installed tool: $install_name"
    installed=$((installed + 1))
  done

  say "WASM install: $installed installed, $skipped skipped (not built)"
}

# --- Orchestration ---

lunarwing_gateway_ready() {
  load_lunarwing_env
  local port="${GATEWAY_PORT:-8765}"
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' \
    "http://127.0.0.1:${port}/api/health" 2>/dev/null || true)"
  [[ "$code" == "200" ]]
}

wait_for_lunarwing() {
  local deadline=$((SECONDS + 30))
  while (( SECONDS < deadline )); do
    if lunarwing_gateway_ready; then
      return 0
    fi
    sleep 1
  done
  say "LunarWing gateway did not become ready within 30s" >&2
  if [[ -f "$LOG_DIR/lunarwing.log" ]]; then
    tail -n 40 "$LOG_DIR/lunarwing.log" >&2 || true
  fi
  return 1
}

stack_up() {
  ensure_env

  say "=== bringing up full stack ==="

  if [[ "$(database_kind)" == "postgres" ]]; then
    say "--- PostgreSQL ---"
    start_postgres || die "PostgreSQL failed to start"
  else
    say "--- libSQL ---"
    say "libSQL path: $LIBSQL_PATH"
  fi

  say "--- TensorZero proxy ---"
  start_proxy || die "proxy failed to start"

  say "--- XMPP bridge ---"
  start_bridge || die "XMPP bridge failed to start"

  say "--- LunarWing ---"
  start_lunarwing || die "LunarWing failed to start"
  wait_for_lunarwing || die "LunarWing gateway not reachable"

  say "=== full stack is up ==="
  status_all
}

stack_down() {
  say "=== tearing down stack ==="
  stop_lunarwing || true
  stop_bridge || true
  stop_proxy || true
  stop_postgres || true
  say "=== stack is down ==="
}

status_all() {
  if [[ "$(database_kind)" == "postgres" ]]; then
    local pg_state
    pg_state="$(pg_container_state)"
    printf 'PostgreSQL:    %s (container %s, port %s)\n' "$pg_state" "$PG_CONTAINER" "$PG_PORT"
  else
    local libsql_state="missing"
    [[ -f "$LIBSQL_PATH" ]] && libsql_state="present"
    printf 'libSQL:        %s (%s)\n' "$libsql_state" "$LIBSQL_PATH"
  fi

  if pid_alive "$RUN_DIR/proxy.pid"; then
    printf 'Proxy:         running (pid %s, port %s)\n' "$(<"$RUN_DIR/proxy.pid")" "$PROXY_PORT"
  else
    printf 'Proxy:         stopped\n'
  fi

  if pid_alive "$RUN_DIR/xmpp-bridge.pid"; then
    printf 'XMPP Bridge:   running (pid %s)\n' "$(<"$RUN_DIR/xmpp-bridge.pid")"
  else
    printf 'XMPP Bridge:   stopped\n'
  fi

  if pid_alive "$RUN_DIR/lunarwing.pid"; then
    printf 'LunarWing:     running (pid %s)\n' "$(<"$RUN_DIR/lunarwing.pid")"
  else
    printf 'LunarWing:     stopped\n'
  fi

  local ch_count tool_count
  ch_count=0
  tool_count=0
  if [[ -d "$CHANNELS_DIR" ]]; then
    ch_count="$(find "$CHANNELS_DIR" -maxdepth 1 -name '*.wasm' 2>/dev/null | wc -l | tr -d ' ')"
  fi
  if [[ -d "$TOOLS_DIR" ]]; then
    tool_count="$(find "$TOOLS_DIR" -maxdepth 1 -name '*.wasm' 2>/dev/null | wc -l | tr -d ' ')"
  fi
  printf 'WASM channels: %s installed\n' "$ch_count"
  printf 'WASM tools:    %s installed\n' "$tool_count"
}

verify_stack() {
  ensure_env
  load_all_envs

  local pass=0 fail=0

  _check() {
    local label="$1"
    shift
    if "$@" >/dev/null 2>&1; then
      printf '[PASS] %s\n' "$label"
      pass=$((pass + 1))
    else
      printf '[FAIL] %s\n' "$label"
      fail=$((fail + 1))
    fi
  }

  if [[ "$(database_kind)" == "postgres" ]]; then
    _check "PostgreSQL is reachable" \
      docker exec "$PG_CONTAINER" pg_isready -U ironclaw
  else
    _check "libSQL database file exists" \
      test -f "$LIBSQL_PATH"
  fi

  _check "TensorZero proxy responds at :${PROXY_PORT}" \
    proxy_ready

  local base
  base="$(bridge_base)"
  _check "XMPP bridge rejects missing token" \
    sh -c "code=\$(curl -sS -o /dev/null -w '%{http_code}' '$base/v1/status' 2>/dev/null); [ \"\$code\" != '200' ]"

  _check "XMPP bridge accepts valid token" \
    bridge_ready

  local gw_port="${GATEWAY_PORT:-8765}"
  _check "LunarWing gateway responds at :${gw_port}" \
    lunarwing_gateway_ready

  _check "Gateway status API responds" \
    gateway_status_json

  local ch_count tool_count
  ch_count=0
  tool_count=0
  if [[ -d "$CHANNELS_DIR" ]]; then
    ch_count="$(find "$CHANNELS_DIR" -maxdepth 1 -name '*.wasm' 2>/dev/null | wc -l | tr -d ' ')"
  fi
  if [[ -d "$TOOLS_DIR" ]]; then
    tool_count="$(find "$TOOLS_DIR" -maxdepth 1 -name '*.wasm' 2>/dev/null | wc -l | tr -d ' ')"
  fi
  _check "WASM channels installed: ${ch_count}" \
    test "$ch_count" -gt 0

  _check "WASM tools installed: ${tool_count}" \
    test "$tool_count" -gt 0

  if [[ -f "$CHANNELS_DIR/xmpp.wasm" ]]; then
    _check "Gateway reports xmpp channel active" \
      gateway_has_channel xmpp
  fi

  if [[ -f "$CHANNELS_DIR/weechat.wasm" ]]; then
    _check "Gateway reports weechat channel active" \
      gateway_has_channel weechat
  fi

  if [[ -f "$CHANNELS_DIR/darkirc.wasm" ]]; then
    _check "Gateway reports darkirc channel active" \
      gateway_has_channel darkirc
  fi

  if [[ -f "$TOOLS_DIR/gotify-tool.wasm" ]]; then
    _check "Gateway reports gotify tool available" \
      gateway_has_tool gotify-tool
  fi

  printf '\n%s/%s checks passed\n' "$pass" "$((pass + fail))"
  [[ "$fail" -eq 0 ]]
}

build_bins() {
  ensure_env
  require_cmd cargo

  local cargo_args=(build)
  if [[ "$(profile_dir)" == "release" ]]; then
    cargo_args+=(--release)
  fi

  say "building LunarWing binary: $(lunarwing_bin)"
  (cd "$REPO_ROOT" && cargo "${cargo_args[@]}" --bin ironclaw)

  say "building xmpp-bridge binary: $(bridge_bin)"
  (cd "$REPO_ROOT/bridges/xmpp-bridge" && cargo "${cargo_args[@]}")

  local repl_dir
  repl_dir="$(replv2_client_dir)"
  [[ -f "$repl_dir/Cargo.toml" ]] || die "missing REPLv2 client repo at $repl_dir"
  say "building REPLv2 client binary: $(replv2_client_bin)"
  (cd "$repl_dir" && cargo build --release)

  if [[ "${1:-}" == "--with-wasm" ]]; then
    build_wasm
    install_wasm
  fi
}

start_bridge() {
  ensure_env
  load_bridge_env
  require_cmd curl
  local bin
  bin="$(bridge_bin)"
  require_binary "$bin" "build"

  if pid_alive "$RUN_DIR/xmpp-bridge.pid"; then
    say "xmpp-bridge already running with pid $(<"$RUN_DIR/xmpp-bridge.pid")"
    return 0
  fi

  if bridge_ready; then
    say "xmpp-bridge already responds at $(bridge_base)"
    return 0
  fi

  say "starting xmpp-bridge at $(bridge_base)"
  (
    cd "$REPO_ROOT/bridges/xmpp-bridge"
    "$bin"
  ) >>"$LOG_DIR/xmpp-bridge.log" 2>&1 &
  printf '%s\n' "$!" >"$RUN_DIR/xmpp-bridge.pid"

  wait_for_bridge
  say "xmpp-bridge ready; pid $(<"$RUN_DIR/xmpp-bridge.pid")"
}

stop_by_pid_file() {
  local name="$1"
  local pid_file="$2"
  if ! pid_alive "$pid_file"; then
    rm -f "$pid_file"
    say "$name is not running from this test harness"
    return 0
  fi

  local pid
  pid="$(<"$pid_file")"
  say "stopping $name pid $pid"
  kill "$pid" 2>/dev/null || true

  local deadline=$((SECONDS + 10))
  while (( SECONDS < deadline )); do
    if ! kill -0 "$pid" >/dev/null 2>&1; then
      rm -f "$pid_file"
      say "$name stopped"
      return 0
    fi
    sleep 1
  done

  say "$name did not exit after SIGTERM; leaving pid file for inspection" >&2
  return 1
}

stop_bridge() {
  stop_by_pid_file "xmpp-bridge" "$RUN_DIR/xmpp-bridge.pid"
}

maybe_jq() {
  if command -v jq >/dev/null 2>&1; then
    jq .
  else
    cat
  fi
}

gateway_status_base() {
  load_lunarwing_env
  local host="${GATEWAY_HOST:-127.0.0.1}"
  local port="${GATEWAY_PORT:-8765}"
  printf 'http://%s:%s' "$host" "$port"
}

gateway_status_json() {
  ensure_env
  load_lunarwing_env
  require_cmd curl
  curl -fsS "$(gateway_status_base)/api/gateway/status" \
    -H "Authorization: Bearer ${GATEWAY_AUTH_TOKEN:-}"
}

gateway_enabled_channels() {
  local payload
  payload="$(gateway_status_json)"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$payload" | jq -r '.enabled_channels[]?'
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$payload" | python3 -c 'import json,sys; [print(x) for x in json.load(sys.stdin).get("enabled_channels", [])]'
    return 0
  fi
  printf '%s' "$payload" | tr -d '\n' | sed -n 's/.*"enabled_channels":[[:space:]]*\[\([^]]*\)\].*/\1/p' \
    | tr ',' '\n' | tr -d ' "'
}

gateway_has_channel() {
  local channel_name="$1"
  gateway_enabled_channels | grep -Fxq "$channel_name"
}

gateway_tools_json() {
  ensure_env
  load_lunarwing_env
  require_cmd curl
  curl -fsS "$(gateway_status_base)/api/extensions/tools" \
    -H "Authorization: Bearer ${GATEWAY_AUTH_TOKEN:-}"
}

gateway_enabled_tools() {
  local payload
  payload="$(gateway_tools_json)"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$payload" | jq -r '.tools[]?.name'
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$payload" | python3 -c 'import json,sys; [print(x.get("name","")) for x in json.load(sys.stdin).get("tools", []) if x.get("name")]'
    return 0
  fi
  printf '%s' "$payload" | tr -d '\n' | sed -n 's/.*"name":"\([^"]*\)".*/\1/p'
}

gateway_has_tool() {
  local tool_name="$1"
  gateway_enabled_tools | grep -Fxq "$tool_name"
}

bridge_status() {
  ensure_env
  load_bridge_env
  require_cmd curl
  curl -sS "$(bridge_base)/v1/status" \
    -H "Authorization: Bearer $XMPP_BRIDGE_TOKEN" | maybe_jq
}

gateway_status() {
  gateway_status_json | maybe_jq
}

bridge_auth_check() {
  ensure_env
  load_bridge_env
  require_cmd curl

  local base unauth_code auth_code
  base="$(bridge_base)"
  unauth_code="$(curl -sS -o /dev/null -w '%{http_code}' "$base/v1/status" 2>/dev/null || true)"
  auth_code="$(curl -sS -o /dev/null -w '%{http_code}' "$base/v1/status" \
    -H "Authorization: Bearer $XMPP_BRIDGE_TOKEN" 2>/dev/null || true)"

  if [[ "$unauth_code" == "200" ]]; then
    die "bridge accepted a request without the bearer token"
  fi
  if [[ "$auth_code" != "200" ]]; then
    die "authenticated bridge status failed with HTTP $auth_code"
  fi

  say "missing-token status: HTTP $unauth_code"
  say "valid-token status: HTTP $auth_code"
}

smoke() {
  ensure_env
  load_bridge_env
  require_cmd curl

  local started=false
  if ! bridge_ready; then
    start_bridge
    started=true
  fi

  bridge_auth_check
  bridge_status

  if [[ "$started" == "true" && "${LUNARWING_TEST_KEEP_BRIDGE:-0}" != "1" ]]; then
    stop_bridge
  else
    say "bridge left running; stop it with: scripts/lunarwing-xmpp-test-env.sh stop-bridge"
  fi
}

configure_bridge() {
  ensure_env
  load_all_envs
  BASE="$(bridge_base)" \
    XMPP_BRIDGE_SERVICE="$(bridge_service_name)" \
    XMPP_BRIDGE_SYSTEMCTL_SCOPE="${LUNARWING_TEST_SYSTEMCTL_SCOPE:-user}" \
    "$SCRIPT_DIR/xmpp-configure.sh" "$@"
}

rate_limit() {
  ensure_env
  load_bridge_env
  BASE="$(bridge_base)" "$SCRIPT_DIR/xmpp-rate-limit.sh" "$@"
}

start_lunarwing() {
  ensure_env
  load_lunarwing_env
  local bin
  bin="$(lunarwing_bin)"
  require_binary "$bin" "build"

  if pid_alive "$RUN_DIR/lunarwing.pid"; then
    say "LunarWing already running with pid $(<"$RUN_DIR/lunarwing.pid")"
    return 0
  fi

  local args=(--no-onboard run)
  if [[ "${1:-}" == "--" ]]; then
    shift
    args=("$@")
  elif [[ "$#" -gt 0 ]]; then
    args=("$@")
  fi

  say "starting LunarWing with isolated IRONCLAW_BASE_DIR=$IRONCLAW_BASE_DIR"
  (
    cd "$REPO_ROOT"
    "$bin" "${args[@]}"
  ) >>"$LOG_DIR/lunarwing.log" 2>&1 &
  printf '%s\n' "$!" >"$RUN_DIR/lunarwing.pid"

  sleep 2
  if ! pid_alive "$RUN_DIR/lunarwing.pid"; then
    say "LunarWing exited during startup; recent log follows" >&2
    tail -n 60 "$LOG_DIR/lunarwing.log" >&2 || true
    rm -f "$RUN_DIR/lunarwing.pid"
    return 1
  fi

  say "LunarWing started; pid $(<"$RUN_DIR/lunarwing.pid")"
}

stop_lunarwing() {
  stop_by_pid_file "LunarWing" "$RUN_DIR/lunarwing.pid"
}

lunarwing_status() {
  if pid_alive "$RUN_DIR/lunarwing.pid"; then
    say "LunarWing pid: $(<"$RUN_DIR/lunarwing.pid")"
  else
    say "LunarWing is not running from this test harness"
  fi
  say "log: $LOG_DIR/lunarwing.log"
  say "state: $STATE_DIR"
}

launch_repl() {
  ensure_env
  load_lunarwing_env
  local bin
  bin="$(replv2_client_bin)"
  require_binary "$bin" "build"

  if [[ "${1:-}" == "--" ]]; then
    shift
  fi

  if [[ "$#" -eq 0 ]]; then
    say "launching REPLv2 client via socket ${LUNARWING_SOCKET:-${IRONCLAW_SOCKET:-$(harness_socket_path)}}"
  fi

  "$bin" "$@"
}

proxy_service_name() {
  normalize_service_name "${LUNARWING_TEST_PROXY_SERVICE_NAME:-ironclaw-proxy-test.service}"
}

render_systemd() {
  ensure_env
  local main_service bridge_service proxy_service
  local lunarwing_unit bridge_unit proxy_unit
  main_service="$(lunarwing_service_name)"
  bridge_service="$(bridge_service_name)"
  proxy_service="$(proxy_service_name)"
  lunarwing_unit="$SYSTEMD_DIR/$main_service"
  bridge_unit="$SYSTEMD_DIR/$bridge_service"
  proxy_unit="$SYSTEMD_DIR/$proxy_service"

  cat >"$proxy_unit" <<EOF
[Unit]
Description=LunarWing TensorZero proxy test sidecar
After=network.target

[Service]
Type=simple
ExecStart=$(command -v python3) $(proxy_bin) --port $PROXY_PORT --bind $PROXY_BIND --tensorzero $TENSORZERO_URL
EnvironmentFile=$ENV_DIR/proxy.env
Restart=on-failure
RestartSec=5
NoNewPrivileges=true

[Install]
WantedBy=default.target
EOF

  cat >"$bridge_unit" <<EOF
[Unit]
Description=LunarWing XMPP bridge test sidecar
After=network.target
Wants=network.target
PartOf=$main_service

[Service]
Type=simple
WorkingDirectory=$REPO_ROOT/bridges/xmpp-bridge
EnvironmentFile=$ENV_DIR/xmpp-bridge.env
ExecStart=$(bridge_bin)
Restart=on-failure
RestartSec=5
NoNewPrivileges=true

[Install]
WantedBy=default.target
EOF

  cat >"$lunarwing_unit" <<EOF
[Unit]
Description=LunarWing test daemon
After=network.target $bridge_service $proxy_service
Wants=$bridge_service $proxy_service

[Service]
Type=simple
WorkingDirectory=$REPO_ROOT
EnvironmentFile=$ENV_DIR/lunarwing.env
ExecStart=$(lunarwing_bin) --no-onboard run
Restart=on-failure
RestartSec=5
NoNewPrivileges=true

[Install]
WantedBy=default.target
EOF

  say "wrote: $proxy_unit"
  say "wrote: $bridge_unit"
  say "wrote: $lunarwing_unit"
  say "install for user-mode testing with:"
  say "  mkdir -p ~/.config/systemd/user"
  say "  cp $SYSTEMD_DIR/*.service ~/.config/systemd/user/"
  say "  systemctl --user daemon-reload"
  say "  systemctl --user start $main_service"
}

doctor() {
  say "=== environment ==="
  say "test root: $TEST_ROOT"
  say "repo root: $REPO_ROOT"
  say "lunarwing root: $LUNARWING_ROOT"
  say "profile: $(profile_dir)"
  say "database backend: $(database_kind)"
  if [[ "$(database_kind)" == "libsql" ]]; then
    say "libsql path: $LIBSQL_PATH"
  else
    say "postgres url: $DATABASE_URL"
  fi

  say ""
  say "=== commands ==="
  for cmd_name in cargo curl jq docker python3 systemctl wasm-tools; do
    if command -v "$cmd_name" >/dev/null 2>&1; then
      say "$cmd_name: found"
    else
      say "$cmd_name: MISSING"
    fi
  done

  # WASM target
  if rustup target list --installed 2>/dev/null | grep -q wasm32-wasip2; then
    say "wasm32-wasip2 target: installed"
  else
    say "wasm32-wasip2 target: MISSING (run: rustup target add wasm32-wasip2)"
  fi

  say ""
  say "=== env files ==="
  for env_name in lunarwing.env xmpp-bridge.env proxy.env; do
    if [[ -f "$ENV_DIR/$env_name" ]]; then
      say "$env_name: present"
    else
      say "$env_name: missing; run init"
    fi
  done

  say ""
  say "=== binaries ==="
  if [[ -x "$(lunarwing_bin)" ]]; then
    say "LunarWing: $(lunarwing_bin)"
  else
    say "LunarWing: MISSING; run build"
  fi
  if [[ -x "$(bridge_bin)" ]]; then
    say "xmpp-bridge: $(bridge_bin)"
  else
    say "xmpp-bridge: MISSING; run build"
  fi
  if [[ -x "$(replv2_client_bin)" ]]; then
    say "REPLv2 client: $(replv2_client_bin)"
  else
    say "REPLv2 client: MISSING; run build"
  fi
  say "REPL socket: $(harness_socket_path)"
  if [[ -f "$(proxy_bin)" ]]; then
    say "ironclaw-proxy: $(proxy_bin)"
  else
    say "ironclaw-proxy: MISSING at $(proxy_bin)"
  fi

  say ""
  say "=== services ==="

  # PostgreSQL
  local pg_state
  pg_state="$(pg_container_state)"
  say "PostgreSQL: $pg_state (container $PG_CONTAINER, port $PG_PORT)"

  # Proxy
  if pid_alive "$RUN_DIR/proxy.pid"; then
    say "proxy: running (pid $(<"$RUN_DIR/proxy.pid"), port $PROXY_PORT)"
    if proxy_ready; then
      say "  health: OK"
    else
      say "  health: NOT responding (TensorZero may be down)"
    fi
  else
    say "proxy: stopped"
  fi

  # Bridge
  if [[ -f "$ENV_DIR/xmpp-bridge.env" ]]; then
    load_bridge_env
    if pid_alive "$RUN_DIR/xmpp-bridge.pid"; then
      say "xmpp-bridge: running (pid $(<"$RUN_DIR/xmpp-bridge.pid"))"
    else
      say "xmpp-bridge: stopped"
    fi
    if command -v curl >/dev/null 2>&1; then
      local code
      code="$(curl -sS -o /dev/null -w '%{http_code}' "$(bridge_base)/v1/status" \
        -H "Authorization: Bearer ${XMPP_BRIDGE_TOKEN:-}" 2>/dev/null || true)"
      say "  status endpoint: HTTP $code"
    fi
  fi

  # LunarWing
  if pid_alive "$RUN_DIR/lunarwing.pid"; then
    say "LunarWing: running (pid $(<"$RUN_DIR/lunarwing.pid"))"
  else
    say "LunarWing: stopped"
  fi

  # TensorZero gateway
  local tz_code
  tz_code="$(curl -sS -o /dev/null -w '%{http_code}' "$TENSORZERO_URL/status" 2>/dev/null || true)"
  say "TensorZero gateway ($TENSORZERO_URL): HTTP $tz_code"

  say ""
  say "=== WASM artifacts ==="
  local ch_count tool_count
  ch_count=0
  tool_count=0
  if [[ -d "$CHANNELS_DIR" ]]; then
    ch_count="$(find "$CHANNELS_DIR" -maxdepth 1 -name '*.wasm' 2>/dev/null | wc -l | tr -d ' ')"
  fi
  if [[ -d "$TOOLS_DIR" ]]; then
    tool_count="$(find "$TOOLS_DIR" -maxdepth 1 -name '*.wasm' 2>/dev/null | wc -l | tr -d ' ')"
  fi
  say "channels installed: $ch_count (in $CHANNELS_DIR)"
  say "tools installed: $tool_count (in $TOOLS_DIR)"
  if pid_alive "$RUN_DIR/lunarwing.pid"; then
    local enabled_channels
    if enabled_channels="$(gateway_enabled_channels 2>/dev/null | paste -sd ',' - | sed 's/,/, /g')"; then
      if [[ -n "$enabled_channels" ]]; then
        say "gateway active channels: $enabled_channels"
      else
        say "gateway active channels: unavailable"
      fi
    else
      say "gateway active channels: unavailable"
    fi

    local enabled_tools
    if enabled_tools="$(gateway_enabled_tools 2>/dev/null | paste -sd ',' - | sed 's/,/, /g')"; then
      if [[ -n "$enabled_tools" ]]; then
        say "gateway active tools: $enabled_tools"
      else
        say "gateway active tools: unavailable"
      fi
    else
      say "gateway active tools: unavailable"
    fi
  fi

  # Systemd
  if command -v systemctl >/dev/null 2>&1; then
    say ""
    say "=== systemd (user) ==="
    for svc_name in "$(lunarwing_service_name)" "$(bridge_service_name)" "$(proxy_service_name)"; do
      if systemctl --user --no-pager --plain status "$svc_name" >/dev/null 2>&1; then
        say "$svc_name: active"
      else
        say "$svc_name: not active or not installed"
      fi
    done
  fi
}

logs() {
  local lines="${1:-80}"
  [[ "$lines" =~ ^[0-9]+$ ]] || die "lines must be an integer"

  for log_name in proxy.log xmpp-bridge.log lunarwing.log wasm-build.log; do
    if [[ -f "$LOG_DIR/$log_name" ]]; then
      say "== $log_name =="
      tail -n "$lines" "$LOG_DIR/$log_name"
      say ""
    fi
  done

  # PostgreSQL logs from Docker
  if docker inspect "$PG_CONTAINER" >/dev/null 2>&1; then
    say "== PostgreSQL (docker) =="
    docker logs --tail "$lines" "$PG_CONTAINER" 2>&1
    say ""
  fi
}

main() {
  local command_name="${1:-}"
  if [[ -z "$command_name" ]]; then
    usage
    exit 1
  fi
  shift || true

  case "$command_name" in
    -h|--help|help)
      usage
      ;;
    init)
      init_env
      ;;
    build)
      build_bins "$@"
      ;;
    build-wasm)
      ensure_env
      build_wasm
      ;;
    install-wasm)
      install_wasm
      ;;
    doctor)
      doctor
      ;;
    # --- PostgreSQL ---
    start-postgres)
      start_postgres
      ;;
    stop-postgres)
      stop_postgres
      ;;
    reset-postgres)
      reset_postgres
      ;;
    # --- TensorZero proxy ---
    start-proxy)
      start_proxy
      ;;
    stop-proxy)
      stop_proxy
      ;;
    # --- XMPP bridge ---
    start-bridge)
      start_bridge
      ;;
    stop-bridge)
      stop_bridge
      ;;
    bridge-status)
      bridge_status
      ;;
    gateway-status)
      gateway_status
      ;;
    bridge-auth-check)
      bridge_auth_check
      ;;
    # --- LunarWing ---
    start-lunarwing)
      start_lunarwing "$@"
      ;;
    stop-lunarwing)
      stop_lunarwing
      ;;
    lunarwing-status)
      lunarwing_status
      ;;
    repl)
      launch_repl "$@"
      ;;
    # --- Orchestration ---
    up)
      stack_up
      ;;
    down)
      stack_down
      ;;
    status)
      status_all
      ;;
    verify)
      verify_stack
      ;;
    # --- Other ---
    smoke)
      smoke
      ;;
    configure-bridge)
      configure_bridge "$@"
      ;;
    rate-limit)
      rate_limit "$@"
      ;;
    render-systemd)
      render_systemd
      ;;
    logs)
      logs "$@"
      ;;
    *)
      die "unknown command: $command_name"
      ;;
  esac
}

main "$@"
