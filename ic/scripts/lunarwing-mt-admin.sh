#!/usr/bin/env bash
set -euo pipefail

# ── Production Multi-Tenant Admin ─────────────────────────────────────────────
#
# Creates and manages OS-level LunarWing tenants. Each tenant is a real system
# user with its own repo clone, build artifacts, services, PostgreSQL container,
# TensorZero proxy, and XMPP bridge.
#
# Must be run as root (or via sudo).

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
LUNARWING_ROOT="$(cd -- "${REPO_ROOT}/.." && pwd)"

PORTS_REGISTRY="/etc/lunarwing/ports.json"
PORT_RANGE_START=10000
PORT_RANGE_END=19999
PORT_BLOCK_SIZE=10
BUILD_LOCK="/var/lock/lunarwing-build.lock"
PROFILE="${LUNARWING_MT_PROFILE:-release}"
SOURCE_REPO="${LUNARWING_MT_SOURCE_REPO:-$LUNARWING_ROOT}"
DEFAULT_TENSORZERO_URL="${LUNARWING_MT_TENSORZERO_URL:-http://192.168.1.157:3000}"

# ── Helpers ───────────────────────────────────────────────────────────────────

say() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

generate_token() {
  if command -v od >/dev/null 2>&1; then
    dd if=/dev/urandom bs=32 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n'
  else
    printf 'replace-with-random-token-%s' "$(date +%s)"
  fi
}

sanitize_name() {
  local raw="$1"
  printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9-' '-' | sed 's/^-//;s/-$//'
}

tenant_home() { printf '/home/%s' "$1"; }
tenant_lw_root() { printf '%s/lunarwing' "$(tenant_home "$1")"; }
tenant_repo() { printf '%s/ic' "$(tenant_lw_root "$1")"; }
tenant_env_dir() { printf '%s/env' "$(tenant_lw_root "$1")"; }
tenant_state_dir() { printf '%s/state' "$(tenant_lw_root "$1")"; }
tenant_log_dir() { printf '%s/logs' "$(tenant_lw_root "$1")"; }
tenant_run_dir() { printf '%s/run' "$(tenant_lw_root "$1")"; }

usage() {
  cat <<'EOF'
Usage:
  sudo lunarwing-mt-admin.sh <command> [args...]

Production multi-tenant administration for LunarWing.
Manages OS users, port allocation, per-tenant services, and builds.

Commands:
  add-tenant <name> [options]      Create user, allocate ports, clone repo,
                                   generate env, render and install services
    --docker-group                 Add user to docker/podman group
    --xmpp-jid <jid>              XMPP JID for this tenant
    --xmpp-password <pass>        XMPP password (generated if omitted)
    --tensorzero-url <url>         Upstream TensorZero URL

  add-tenants <names> [options]    Comma-separated list (e.g. "Ruffles,Miyuki")
    (same options as add-tenant apply to all)

  remove-tenant <name>             Stop services, deallocate ports
    --purge                        Also delete OS user and home directory

  build-tenant <name>             Build binaries for one tenant (OOM-safe flock)
    --with-wasm                    Also build WASM extensions

  build-all                        Build each tenant sequentially
    --with-wasm                    Also build WASM extensions

  start-tenant <name>             Start all services for a tenant
  stop-tenant <name>              Stop all services for a tenant
  restart-tenant <name>           Stop then start

  list-tenants                     Show all tenants with ports and status
  status <name>                    Detailed status for one tenant
  tokens [name]                    Print gateway auth tokens (all or one)
  doctor                           System dependency and health checks

Environment:
  LUNARWING_SERVICE_MANAGER        Override: systemd or openrc
  LUNARWING_CONTAINER_RUNTIME      Override: docker or podman
  LUNARWING_MT_PROFILE             Build profile: release (default) or debug
  LUNARWING_MT_SOURCE_REPO         Path to source repo to clone from
  LUNARWING_MT_TENSORZERO_URL      Default upstream TensorZero URL
EOF
}

# ── Root check ────────────────────────────────────────────────────────────────

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "run with sudo: sudo $0 $*"
}

# ── Init system detection ────────────────────────────────────────────────────

detect_init_system() {
  local override="${LUNARWING_SERVICE_MANAGER:-}"
  if [[ -n "$override" ]]; then
    case "${override,,}" in
      systemd|systemd-user) printf 'systemd'; return 0 ;;
      openrc)               printf 'openrc';  return 0 ;;
      *) die "unsupported service manager override '$override'; use systemd or openrc" ;;
    esac
  fi

  if [[ -e /run/openrc/softlevel ]]; then printf 'openrc'; return 0; fi
  if [[ -e /run/systemd/system ]];   then printf 'systemd'; return 0; fi

  if command -v rc-service >/dev/null 2>&1 && ! command -v systemctl >/dev/null 2>&1; then
    printf 'openrc'; return 0
  fi
  if command -v systemctl >/dev/null 2>&1; then printf 'systemd'; return 0; fi
  if command -v rc-service >/dev/null 2>&1; then printf 'openrc'; return 0; fi

  die "could not detect a supported service manager; set LUNARWING_SERVICE_MANAGER=systemd or openrc"
}

INIT_SYSTEM=""
ensure_init_system() {
  [[ -n "$INIT_SYSTEM" ]] || INIT_SYSTEM="$(detect_init_system)"
}

# ── Container runtime detection ──────────────────────────────────────────────

detect_container_runtime() {
  local override="${LUNARWING_CONTAINER_RUNTIME:-}"
  if [[ -n "$override" ]]; then
    case "${override,,}" in
      docker|podman) printf '%s' "${override,,}"; return 0 ;;
      *) die "unsupported container runtime '$override'; use docker or podman" ;;
    esac
  fi

  if command -v podman >/dev/null 2>&1 && ! command -v docker >/dev/null 2>&1; then
    printf 'podman'; return 0
  fi
  if command -v docker >/dev/null 2>&1; then printf 'docker'; return 0; fi
  if command -v podman >/dev/null 2>&1; then printf 'podman'; return 0; fi

  die "neither docker nor podman found; install one or set LUNARWING_CONTAINER_RUNTIME"
}

CONTAINER_RT=""
ensure_container_runtime() {
  [[ -n "$CONTAINER_RT" ]] || CONTAINER_RT="$(detect_container_runtime)"
}

# ── Port registry ────────────────────────────────────────────────────────────

ports_registry_init() {
  if [[ ! -d /etc/lunarwing ]]; then
    mkdir -p /etc/lunarwing
    chmod 0755 /etc/lunarwing
  fi

  if [[ ! -f "$PORTS_REGISTRY" ]]; then
    local tmp
    tmp="$(mktemp "$PORTS_REGISTRY.tmp.XXXXXX")"
    cat >"$tmp" <<'ENDJSON'
{
  "version": 1,
  "range": { "start": 10000, "end": 19999 },
  "block_size": 10,
  "tenants": {}
}
ENDJSON
    chmod 0644 "$tmp"
    mv "$tmp" "$PORTS_REGISTRY"
    say "initialized port registry: $PORTS_REGISTRY"
  fi
}

ports_allocate() {
  local name="$1"
  require_cmd jq

  if jq -e ".tenants[\"$name\"]" "$PORTS_REGISTRY" >/dev/null 2>&1; then
    die "tenant '$name' already has ports allocated"
  fi

  local base=-1
  local p
  for ((p = PORT_RANGE_START; p <= PORT_RANGE_END - PORT_BLOCK_SIZE + 1; p += PORT_BLOCK_SIZE)); do
    if ! jq -e ".tenants | to_entries[] | select(.value.base_port == $p)" "$PORTS_REGISTRY" >/dev/null 2>&1; then
      base=$p
      break
    fi
  done

  [[ $base -ge 0 ]] || die "no free port blocks in range $PORT_RANGE_START-$PORT_RANGE_END"

  local tmp
  tmp="$(mktemp "$PORTS_REGISTRY.tmp.XXXXXX")"
  jq --arg name "$name" --argjson base "$base" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    .tenants[$name] = {
      base_port: $base,
      user: $name,
      created_at: $ts,
      ports: {
        gateway:    ($base + 0),
        http:       ($base + 1),
        bridge:     ($base + 2),
        postgres:   ($base + 3),
        proxy:      ($base + 4),
        weechat:    ($base + 5),
        reserved_0: ($base + 6),
        reserved_1: ($base + 7),
        reserved_2: ($base + 8),
        reserved_3: ($base + 9)
      }
    }
  ' "$PORTS_REGISTRY" >"$tmp"
  chmod 0644 "$tmp"
  mv "$tmp" "$PORTS_REGISTRY"

  say "allocated port block $base-$((base + PORT_BLOCK_SIZE - 1)) for tenant '$name'"
  printf '%s' "$base"
}

ports_deallocate() {
  local name="$1"
  require_cmd jq

  if ! jq -e ".tenants[\"$name\"]" "$PORTS_REGISTRY" >/dev/null 2>&1; then
    say "tenant '$name' not in port registry (already removed?)"
    return 0
  fi

  local tmp
  tmp="$(mktemp "$PORTS_REGISTRY.tmp.XXXXXX")"
  jq --arg name "$name" 'del(.tenants[$name])' "$PORTS_REGISTRY" >"$tmp"
  chmod 0644 "$tmp"
  mv "$tmp" "$PORTS_REGISTRY"

  say "deallocated ports for tenant '$name'"
}

ports_get() {
  local name="$1" port_name="$2"
  require_cmd jq
  jq -r ".tenants[\"$name\"].ports.$port_name // empty" "$PORTS_REGISTRY"
}

ports_list() {
  require_cmd jq
  if [[ ! -f "$PORTS_REGISTRY" ]]; then
    say "no port registry found; run add-tenant first"
    return 0
  fi
  jq -r '.tenants | to_entries[] | "\(.key)\t\(.value.ports.gateway)\t\(.value.ports.http)\t\(.value.ports.bridge)\t\(.value.ports.postgres)\t\(.value.ports.proxy)\t\(.value.ports.weechat)"' "$PORTS_REGISTRY" \
    | column -t -N "TENANT,GATEWAY,HTTP,BRIDGE,PG,PROXY,WEECHAT"
}

tenant_exists_in_registry() {
  local name="$1"
  require_cmd jq
  jq -e ".tenants[\"$name\"]" "$PORTS_REGISTRY" >/dev/null 2>&1
}

all_tenant_names() {
  require_cmd jq
  jq -r '.tenants | keys[]' "$PORTS_REGISTRY" 2>/dev/null
}

# ── User management ──────────────────────────────────────────────────────────

create_tenant_user() {
  local name="$1"
  local add_docker_group="${2:-false}"

  if id "$name" &>/dev/null; then
    say "user '$name' already exists"
  else
    useradd --create-home --shell /bin/bash --comment "LunarWing tenant: $name" "$name"
    say "created user: $name"
  fi

  ensure_init_system
  if [[ "$INIT_SYSTEM" == "systemd" ]]; then
    loginctl enable-linger "$name"
    say "enabled linger for $name"
  fi

  if [[ "$add_docker_group" == "true" ]]; then
    ensure_container_runtime
    local group_name="$CONTAINER_RT"
    if getent group "$group_name" >/dev/null 2>&1; then
      usermod -aG "$group_name" "$name"
      say "added $name to $group_name group"
    else
      say "WARNING: group '$group_name' does not exist; skipping"
    fi
  fi

  local lw_root
  lw_root="$(tenant_lw_root "$name")"
  sudo -u "$name" mkdir -p \
    "$lw_root/env" \
    "$lw_root/state/channels" \
    "$lw_root/state/tools" \
    "$lw_root/state/xmpp" \
    "$lw_root/logs" \
    "$lw_root/run"
  chmod 0700 "$lw_root/env"
  say "created directories under $lw_root"
}

remove_tenant_user() {
  local name="$1"
  local purge="${2:-false}"

  ensure_init_system
  if [[ "$INIT_SYSTEM" == "systemd" ]]; then
    loginctl disable-linger "$name" 2>/dev/null || true
  fi

  if [[ "$purge" == "true" ]]; then
    userdel --remove "$name" 2>/dev/null || true
    say "removed user and home directory: $name"
  else
    say "user $name preserved (use --purge to remove)"
  fi
}

# ── Repo cloning ─────────────────────────────────────────────────────────────

clone_tenant_repo() {
  local name="$1"
  local dest
  dest="$(tenant_lw_root "$name")"

  if [[ -d "$dest/ic/.git" ]]; then
    say "repo already cloned at $dest/ic"
    return 0
  fi

  say "cloning repo from $SOURCE_REPO to $dest ..."
  sudo -u "$name" git clone --single-branch "$SOURCE_REPO" "$dest" 2>&1 | tail -1
  say "repo cloned for $name"
}

# ── Build management ─────────────────────────────────────────────────────────

build_tenant() {
  local name="$1"
  local with_wasm="${2:-false}"
  local repo
  repo="$(tenant_repo "$name")"

  [[ -d "$repo" ]] || die "repo not found at $repo; run add-tenant first"

  say "acquiring build lock (only one tenant builds at a time) ..."
  (
    flock -x 200

    say "building lunarwing for $name ..."
    sudo -u "$name" bash -c "cd '$repo' && cargo build --profile $PROFILE --bin lunarwing" \
      || die "lunarwing build failed for $name"

    say "building xmpp-bridge for $name ..."
    sudo -u "$name" bash -c "cd '$repo/bridges/xmpp-bridge' && cargo build --profile $PROFILE" \
      || die "xmpp-bridge build failed for $name"

    if [[ "$with_wasm" == "true" ]]; then
      say "building WASM extensions for $name ..."
      sudo -u "$name" bash -c "cd '$repo' && scripts/build-wasm-extensions.sh" || true
    fi

    say "build complete for $name"
  ) 200>"$BUILD_LOCK"
}

build_all() {
  local with_wasm="${1:-false}"
  local names
  names="$(all_tenant_names)"

  if [[ -z "$names" ]]; then
    say "no tenants registered"
    return 0
  fi

  while IFS= read -r name; do
    say ""
    say "=== Building tenant: $name ==="
    build_tenant "$name" "$with_wasm"
  done <<< "$names"
}

# ── Environment file generation ──────────────────────────────────────────────

write_tenant_lunarwing_env() {
  local name="$1"
  local xmpp_jid="${2:-$name@xmpp.localhost}"
  local xmpp_password="${3:-$(generate_token | cut -c1-32)}"
  local tensorzero_url="${4:-$DEFAULT_TENSORZERO_URL}"

  local path gateway_port http_port bridge_port pg_port proxy_port
  path="$(tenant_env_dir "$name")/lunarwing.env"
  gateway_port="$(ports_get "$name" gateway)"
  http_port="$(ports_get "$name" http)"
  bridge_port="$(ports_get "$name" bridge)"
  pg_port="$(ports_get "$name" postgres)"
  proxy_port="$(ports_get "$name" proxy)"

  local state_dir run_dir repo_dir
  state_dir="$(tenant_state_dir "$name")"
  run_dir="$(tenant_run_dir "$name")"
  repo_dir="$(tenant_repo "$name")"

  local gateway_token bridge_token secrets_key
  gateway_token="$(generate_token)"
  bridge_token="$(generate_token | cut -c1-32)"
  secrets_key="$(generate_token)"

  (
    umask 077
    cat >"$path" <<ENVEOF
LUNARWING_BASE_DIR=$state_dir
IRONCLAW_BASE_DIR=$state_dir
LUNARWING_SOCKET=$run_dir/lunarwing.sock
IRONCLAW_SOCKET=$run_dir/lunarwing.sock

# Database
DATABASE_BACKEND=postgres
DATABASE_URL=postgres://lunarwing:lunarwing@127.0.0.1:${pg_port}/lunarwing
DATABASE_SSLMODE=disable
PGSSLMODE=disable

# LLM — TensorZero proxy
LLM_BACKEND=openai_compatible
LLM_BASE_URL=http://127.0.0.1:${proxy_port}/v1
LLM_API_KEY=token-${name}
LLM_MODEL=tensorzero::function_name::lunarwing
ALLOW_PRIVATE_IPS=1

# Runtime identity
AGENT_NAME=$name
SECRETS_MASTER_KEY=$secrets_key

# XMPP
XMPP_BRIDGE_URL=http://127.0.0.1:${bridge_port}
XMPP_BRIDGE_TOKEN=$bridge_token
XMPP_JID=$xmpp_jid
XMPP_PASSWORD=$xmpp_password
XMPP_DM_POLICY=allowlist
XMPP_ALLOW_FROM=$xmpp_jid
XMPP_ALLOW_ROOMS=
XMPP_ENCRYPTED_ROOMS=
XMPP_OMEMO_DEVICE_ID=0
XMPP_OMEMO_STORE_DIR=$state_dir/xmpp
XMPP_ALLOW_PLAINTEXT_FALLBACK=true
XMPP_RESOURCE=$name

# WASM
WASM_ENABLED=true
WASM_CHANNELS_ENABLED=true
WASM_TOOLS_DIR=$state_dir/tools
WASM_CHANNELS_DIR=$state_dir/channels

# Gateway
GATEWAY_ENABLED=true
GATEWAY_HOST=127.0.0.1
GATEWAY_PORT=$gateway_port
GATEWAY_AUTH_TOKEN=$gateway_token

# HTTP webhook
HTTP_PORT=$http_port

# Daemon mode
CLI_ENABLED=false
ONBOARD_COMPLETED=true
HEARTBEAT_ENABLED=false
RUST_LOG=lunarwing=info
ENVEOF
  )
  chown "$name:$name" "$path"
  say "wrote: $path"
}

write_tenant_bridge_env() {
  local name="$1"
  local xmpp_jid="${2:-$name@xmpp.localhost}"
  local xmpp_password="${3:-}"

  local path bridge_port
  path="$(tenant_env_dir "$name")/xmpp-bridge.env"
  bridge_port="$(ports_get "$name" bridge)"

  local state_dir bridge_token
  state_dir="$(tenant_state_dir "$name")"
  bridge_token="$(grep -s '^XMPP_BRIDGE_TOKEN=' "$(tenant_env_dir "$name")/lunarwing.env" | cut -d= -f2-)"
  [[ -n "$bridge_token" ]] || bridge_token="$(generate_token | cut -c1-32)"

  local xmpp_pass_val
  xmpp_pass_val="$(grep -s '^XMPP_PASSWORD=' "$(tenant_env_dir "$name")/lunarwing.env" | cut -d= -f2-)"
  [[ -n "$xmpp_pass_val" ]] || xmpp_pass_val="${xmpp_password:-$(generate_token | cut -c1-32)}"

  (
    umask 077
    cat >"$path" <<ENVEOF
IRONCLAW_BASE_DIR=$state_dir
XMPP_BRIDGE_BIND=127.0.0.1:${bridge_port}
XMPP_BRIDGE_TOKEN=$bridge_token
XMPP_BRIDGE_MAX_MESSAGES=256
RUST_LOG=xmpp_bridge=info,info

XMPP_JID=$xmpp_jid
XMPP_PASSWORD=$xmpp_pass_val
XMPP_DM_POLICY=allowlist
XMPP_ALLOW_FROM_JSON=["${xmpp_jid}"]
XMPP_ALLOW_ROOMS_JSON=[]
XMPP_ENCRYPTED_ROOMS_JSON=[]
XMPP_DEVICE_ID=0
XMPP_OMEMO_STORE_DIR=$state_dir/xmpp
XMPP_ALLOW_PLAINTEXT_FALLBACK=true
XMPP_RESOURCE=$name
XMPP_BRIDGE_WAIT_SECONDS=15
ENVEOF
  )
  chown "$name:$name" "$path"
  say "wrote: $path"
}

write_tenant_proxy_env() {
  local name="$1"
  local tensorzero_url="${2:-$DEFAULT_TENSORZERO_URL}"

  local path proxy_port
  path="$(tenant_env_dir "$name")/proxy.env"
  proxy_port="$(ports_get "$name" proxy)"

  (
    umask 077
    cat >"$path" <<ENVEOF
PROXY_PORT=$proxy_port
PROXY_BIND=127.0.0.1
TENSORZERO_URL=$tensorzero_url
ENVEOF
  )
  chown "$name:$name" "$path"
  say "wrote: $path"
}

# ── PostgreSQL container ─────────────────────────────────────────────────────

start_tenant_postgres() {
  local name="$1"
  ensure_container_runtime

  local pg_port container_name
  pg_port="$(ports_get "$name" postgres)"
  container_name="lunarwing-pg-$name"

  if $CONTAINER_RT inspect "$container_name" &>/dev/null; then
    if $CONTAINER_RT inspect -f '{{.State.Running}}' "$container_name" 2>/dev/null | grep -q true; then
      say "PostgreSQL already running ($container_name, port $pg_port)"
      return 0
    fi
    say "starting existing PostgreSQL container $container_name"
    $CONTAINER_RT start "$container_name" >/dev/null
  else
    say "creating PostgreSQL container $container_name on port $pg_port"
    $CONTAINER_RT run -d \
      --name "$container_name" \
      -e POSTGRES_USER=lunarwing \
      -e POSTGRES_PASSWORD=lunarwing \
      -e POSTGRES_DB=lunarwing \
      -p "127.0.0.1:${pg_port}:5432" \
      --restart unless-stopped \
      pgvector/pgvector:pg16 >/dev/null
  fi

  local attempts=0
  while ! $CONTAINER_RT exec "$container_name" pg_isready -U lunarwing -q 2>/dev/null; do
    attempts=$((attempts + 1))
    [[ $attempts -lt 30 ]] || die "PostgreSQL for $name did not become ready"
    sleep 1
  done
  say "PostgreSQL ready ($container_name, port $pg_port)"
}

stop_tenant_postgres() {
  local name="$1"
  ensure_container_runtime

  local container_name="lunarwing-pg-$name"
  if $CONTAINER_RT inspect "$container_name" &>/dev/null; then
    $CONTAINER_RT stop "$container_name" >/dev/null 2>&1 || true
    say "PostgreSQL stopped ($container_name)"
  fi
}

reset_tenant_postgres() {
  local name="$1"
  ensure_container_runtime

  local container_name="lunarwing-pg-$name"
  stop_tenant_postgres "$name"
  $CONTAINER_RT rm -f "$container_name" >/dev/null 2>&1 || true
  say "PostgreSQL removed ($container_name)"
}

# ── Systemd service units ────────────────────────────────────────────────────

render_tenant_systemd_units() {
  local name="$1"
  local user_unit_dir
  user_unit_dir="$(tenant_home "$name")/.config/systemd/user"
  mkdir -p "$user_unit_dir"
  chown -R "$name:$name" "$(tenant_home "$name")/.config"

  local repo env_dir state_dir proxy_port bridge_port
  repo="$(tenant_repo "$name")"
  env_dir="$(tenant_env_dir "$name")"
  state_dir="$(tenant_state_dir "$name")"
  proxy_port="$(ports_get "$name" proxy)"
  bridge_port="$(ports_get "$name" bridge)"

  local proxy_bin
  proxy_bin="$SOURCE_REPO/tensorzero-proxy-configurations/lunarwing-proxy.py"

  # Proxy unit
  cat >"$user_unit_dir/lunarwing-proxy-${name}.service" <<EOF
[Unit]
Description=LunarWing TensorZero proxy ($name)
After=network.target

[Service]
Type=simple
ExecStart=$(command -v python3) $proxy_bin --port $proxy_port --bind 127.0.0.1 --tensorzero $DEFAULT_TENSORZERO_URL
EnvironmentFile=$env_dir/proxy.env
Restart=on-failure
RestartSec=5
NoNewPrivileges=true

[Install]
WantedBy=default.target
EOF

  # Bridge unit
  cat >"$user_unit_dir/xmpp-bridge-${name}.service" <<EOF
[Unit]
Description=LunarWing XMPP bridge ($name)
After=network.target
PartOf=lunarwing-${name}.service

[Service]
Type=simple
WorkingDirectory=$repo/bridges/xmpp-bridge
EnvironmentFile=$env_dir/xmpp-bridge.env
ExecStart=$repo/bridges/xmpp-bridge/target/${PROFILE}/xmpp-bridge
Restart=on-failure
RestartSec=5
NoNewPrivileges=true

[Install]
WantedBy=default.target
EOF

  # Main daemon unit
  cat >"$user_unit_dir/lunarwing-${name}.service" <<EOF
[Unit]
Description=LunarWing AI assistant ($name)
After=network.target xmpp-bridge-${name}.service lunarwing-proxy-${name}.service
Wants=xmpp-bridge-${name}.service lunarwing-proxy-${name}.service

[Service]
Type=simple
WorkingDirectory=$repo
EnvironmentFile=$env_dir/lunarwing.env
ExecStart=$repo/target/${PROFILE}/lunarwing --no-onboard run
Restart=always
RestartSec=5
TimeoutStartSec=60
TimeoutStopSec=30
KillSignal=SIGTERM
UMask=0077
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=default.target
EOF

  chown -R "$name:$name" "$user_unit_dir"
  say "rendered systemd units for $name in $user_unit_dir"
}

_systemctl_user() {
  local name="$1"
  shift
  local uid
  uid="$(id -u "$name")"
  sudo -u "$name" XDG_RUNTIME_DIR="/run/user/$uid" systemctl --user "$@"
}

start_tenant_systemd() {
  local name="$1"
  _systemctl_user "$name" daemon-reload
  _systemctl_user "$name" start "lunarwing-${name}.service"
  sleep 2
  if _systemctl_user "$name" is-active --quiet "lunarwing-${name}.service"; then
    say "lunarwing-${name}.service is active"
  else
    say "WARNING: lunarwing-${name}.service failed to start" >&2
    _systemctl_user "$name" status "lunarwing-${name}.service" --no-pager >&2 || true
    return 1
  fi
}

stop_tenant_systemd() {
  local name="$1"
  local uid
  uid="$(id -u "$name" 2>/dev/null)" || return 0

  for svc in "lunarwing-${name}.service" "xmpp-bridge-${name}.service" "lunarwing-proxy-${name}.service"; do
    if _systemctl_user "$name" is-active --quiet "$svc" 2>/dev/null; then
      _systemctl_user "$name" stop "$svc"
      say "stopped $svc"
    fi
  done
}

uninstall_tenant_systemd() {
  local name="$1"
  local user_unit_dir
  user_unit_dir="$(tenant_home "$name")/.config/systemd/user"

  for svc in "lunarwing-${name}.service" "xmpp-bridge-${name}.service" "lunarwing-proxy-${name}.service"; do
    rm -f "$user_unit_dir/$svc"
  done

  _systemctl_user "$name" daemon-reload 2>/dev/null || true
  say "uninstalled systemd units for $name"
}

# ── OpenRC service units ─────────────────────────────────────────────────────

render_tenant_openrc_units() {
  local name="$1"
  local repo env_dir state_dir log_dir run_dir
  repo="$(tenant_repo "$name")"
  env_dir="$(tenant_env_dir "$name")"
  state_dir="$(tenant_state_dir "$name")"
  log_dir="$(tenant_log_dir "$name")"
  run_dir="$(tenant_run_dir "$name")"

  local proxy_port bridge_port
  proxy_port="$(ports_get "$name" proxy)"
  bridge_port="$(ports_get "$name" bridge)"

  local proxy_bin
  proxy_bin="$SOURCE_REPO/tensorzero-proxy-configurations/lunarwing-proxy.py"

  # ── Main daemon init script ──
  cat >"/etc/init.d/lunarwing-${name}" <<INITEOF
#!/sbin/openrc-run

description="LunarWing AI assistant ($name)"

: "\${lunarwing_command:=$repo/target/${PROFILE}/lunarwing}"
: "\${lunarwing_args:=--no-onboard run}"
: "\${lunarwing_user:=$name}"
: "\${lunarwing_group:=$name}"
: "\${lunarwing_workdir:=$repo}"
: "\${lunarwing_pidfile:=$run_dir/lunarwing.pid}"
: "\${lunarwing_state_dir:=$state_dir}"
: "\${lunarwing_runtime_dir:=$run_dir}"
: "\${lunarwing_log_dir:=$log_dir}"
: "\${lunarwing_output_log:=\${lunarwing_log_dir}/lunarwing.log}"
: "\${lunarwing_error_log:=\${lunarwing_log_dir}/lunarwing.err}"
: "\${lunarwing_env_file:=$env_dir/lunarwing.env}"
: "\${lunarwing_umask:=0077}"
: "\${lunarwing_respawn_delay:=5}"
: "\${lunarwing_respawn_max:=5}"
: "\${lunarwing_respawn_period:=60}"
: "\${lunarwing_retry:=SIGTERM/30/KILL/5}"

command="\${lunarwing_command}"
command_args="\${lunarwing_args}"
command_user="\${lunarwing_user}:\${lunarwing_group}"
directory="\${lunarwing_workdir}"
pidfile="\${lunarwing_pidfile}"
supervisor="supervise-daemon"
retry="\${lunarwing_retry}"
respawn_delay="\${lunarwing_respawn_delay}"
respawn_max="\${lunarwing_respawn_max}"
respawn_period="\${lunarwing_respawn_period}"
output_log="\${lunarwing_output_log}"
error_log="\${lunarwing_error_log}"
required_files="\${command}"

depend() {
    need net localmount
    use dns logger
    after firewall xmpp-bridge-${name} lunarwing-proxy-${name}
}

load_env() {
    if [ -n "\${lunarwing_env_file}" ] && [ -r "\${lunarwing_env_file}" ]; then
        set -a
        . "\${lunarwing_env_file}"
        set +a
    fi
}

start_pre() {
    checkpath -d -m 0750 -o "\${lunarwing_user}:\${lunarwing_group}" "\${lunarwing_state_dir}"
    checkpath -d -m 0750 -o "\${lunarwing_user}:\${lunarwing_group}" "\${lunarwing_log_dir}"
    checkpath -d -m 0750 -o "\${lunarwing_user}:\${lunarwing_group}" "\${lunarwing_runtime_dir}"
    checkpath -f -m 0640 -o "\${lunarwing_user}:\${lunarwing_group}" "\${output_log}"
    checkpath -f -m 0640 -o "\${lunarwing_user}:\${lunarwing_group}" "\${error_log}"
    load_env || return 1
    umask "\${lunarwing_umask}"
}
INITEOF
  chmod 0755 "/etc/init.d/lunarwing-${name}"

  # ── XMPP bridge init script ──
  cat >"/etc/init.d/xmpp-bridge-${name}" <<INITEOF
#!/sbin/openrc-run

description="LunarWing XMPP bridge ($name)"

: "\${xmpp_bridge_command:=$repo/bridges/xmpp-bridge/target/${PROFILE}/xmpp-bridge}"
: "\${xmpp_bridge_user:=$name}"
: "\${xmpp_bridge_group:=$name}"
: "\${xmpp_bridge_workdir:=$repo/bridges/xmpp-bridge}"
: "\${xmpp_bridge_pidfile:=$run_dir/xmpp-bridge.pid}"
: "\${xmpp_bridge_state_dir:=$state_dir}"
: "\${xmpp_bridge_runtime_dir:=$run_dir}"
: "\${xmpp_bridge_log_dir:=$log_dir}"
: "\${xmpp_bridge_output_log:=\${xmpp_bridge_log_dir}/xmpp-bridge.log}"
: "\${xmpp_bridge_error_log:=\${xmpp_bridge_log_dir}/xmpp-bridge.err}"
: "\${xmpp_bridge_env_file:=$env_dir/xmpp-bridge.env}"
: "\${xmpp_bridge_umask:=0077}"
: "\${xmpp_bridge_respawn_delay:=5}"
: "\${xmpp_bridge_respawn_max:=5}"
: "\${xmpp_bridge_respawn_period:=60}"
: "\${xmpp_bridge_retry:=SIGTERM/30/KILL/5}"

command="\${xmpp_bridge_command}"
command_user="\${xmpp_bridge_user}:\${xmpp_bridge_group}"
directory="\${xmpp_bridge_workdir}"
pidfile="\${xmpp_bridge_pidfile}"
supervisor="supervise-daemon"
retry="\${xmpp_bridge_retry}"
respawn_delay="\${xmpp_bridge_respawn_delay}"
respawn_max="\${xmpp_bridge_respawn_max}"
respawn_period="\${xmpp_bridge_respawn_period}"
output_log="\${xmpp_bridge_output_log}"
error_log="\${xmpp_bridge_error_log}"
required_files="\${command}"

depend() {
    need net localmount
    use dns logger
    after firewall
    before lunarwing-${name}
}

load_env() {
    if [ -n "\${xmpp_bridge_env_file}" ] && [ -r "\${xmpp_bridge_env_file}" ]; then
        set -a
        . "\${xmpp_bridge_env_file}"
        set +a
    fi
}

start_pre() {
    checkpath -d -m 0750 -o "\${xmpp_bridge_user}:\${xmpp_bridge_group}" "\${xmpp_bridge_state_dir}"
    checkpath -d -m 0750 -o "\${xmpp_bridge_user}:\${xmpp_bridge_group}" "\${xmpp_bridge_log_dir}"
    checkpath -d -m 0750 -o "\${xmpp_bridge_user}:\${xmpp_bridge_group}" "\${xmpp_bridge_runtime_dir}"
    checkpath -f -m 0640 -o "\${xmpp_bridge_user}:\${xmpp_bridge_group}" "\${output_log}"
    checkpath -f -m 0640 -o "\${xmpp_bridge_user}:\${xmpp_bridge_group}" "\${error_log}"
    load_env || return 1
    umask "\${xmpp_bridge_umask}"
}
INITEOF
  chmod 0755 "/etc/init.d/xmpp-bridge-${name}"

  # ── TensorZero proxy init script ──
  cat >"/etc/init.d/lunarwing-proxy-${name}" <<INITEOF
#!/sbin/openrc-run

description="LunarWing TensorZero proxy ($name)"

: "\${proxy_command:=$(command -v python3)}"
: "\${proxy_args:=$proxy_bin --port $proxy_port --bind 127.0.0.1 --tensorzero $DEFAULT_TENSORZERO_URL}"
: "\${proxy_user:=$name}"
: "\${proxy_group:=$name}"
: "\${proxy_pidfile:=$run_dir/proxy.pid}"
: "\${proxy_runtime_dir:=$run_dir}"
: "\${proxy_log_dir:=$log_dir}"
: "\${proxy_output_log:=\${proxy_log_dir}/proxy.log}"
: "\${proxy_error_log:=\${proxy_log_dir}/proxy.err}"
: "\${proxy_env_file:=$env_dir/proxy.env}"
: "\${proxy_umask:=0077}"
: "\${proxy_respawn_delay:=5}"
: "\${proxy_respawn_max:=5}"
: "\${proxy_respawn_period:=60}"
: "\${proxy_retry:=SIGTERM/30/KILL/5}"

command="\${proxy_command}"
command_args="\${proxy_args}"
command_user="\${proxy_user}:\${proxy_group}"
pidfile="\${proxy_pidfile}"
supervisor="supervise-daemon"
retry="\${proxy_retry}"
respawn_delay="\${proxy_respawn_delay}"
respawn_max="\${proxy_respawn_max}"
respawn_period="\${proxy_respawn_period}"
output_log="\${proxy_output_log}"
error_log="\${proxy_error_log}"

depend() {
    need net
    use dns
    after firewall
    before lunarwing-${name}
}

load_env() {
    if [ -n "\${proxy_env_file}" ] && [ -r "\${proxy_env_file}" ]; then
        set -a
        . "\${proxy_env_file}"
        set +a
    fi
}

start_pre() {
    checkpath -d -m 0750 -o "\${proxy_user}:\${proxy_group}" "\${proxy_runtime_dir}"
    checkpath -d -m 0750 -o "\${proxy_user}:\${proxy_group}" "\${proxy_log_dir}"
    checkpath -f -m 0640 -o "\${proxy_user}:\${proxy_group}" "\${output_log}"
    checkpath -f -m 0640 -o "\${proxy_user}:\${proxy_group}" "\${error_log}"
    load_env || return 1
    umask "\${proxy_umask}"
}
INITEOF
  chmod 0755 "/etc/init.d/lunarwing-proxy-${name}"

  # ── Conf.d files ──
  cat >"/etc/conf.d/lunarwing-${name}" <<CONFD
# Auto-generated by lunarwing-mt-admin.sh for tenant: $name
lunarwing_rc_need="xmpp-bridge-${name} lunarwing-proxy-${name}"
CONFD

  cat >"/etc/conf.d/xmpp-bridge-${name}" <<CONFD
# Auto-generated by lunarwing-mt-admin.sh for tenant: $name
xmpp_bridge_rc_before="lunarwing-${name}"
CONFD

  cat >"/etc/conf.d/lunarwing-proxy-${name}" <<CONFD
# Auto-generated by lunarwing-mt-admin.sh for tenant: $name
CONFD

  say "rendered OpenRC init scripts and conf.d for $name"
}

start_tenant_openrc() {
  local name="$1"
  rc-service "lunarwing-proxy-${name}" start
  rc-service "xmpp-bridge-${name}" start
  rc-service "lunarwing-${name}" start
  say "OpenRC services started for $name"
}

stop_tenant_openrc() {
  local name="$1"
  rc-service "lunarwing-${name}" stop 2>/dev/null || true
  rc-service "xmpp-bridge-${name}" stop 2>/dev/null || true
  rc-service "lunarwing-proxy-${name}" stop 2>/dev/null || true
  say "OpenRC services stopped for $name"
}

uninstall_tenant_openrc() {
  local name="$1"
  for svc in "lunarwing-${name}" "xmpp-bridge-${name}" "lunarwing-proxy-${name}"; do
    rc-update del "$svc" default 2>/dev/null || true
    rm -f "/etc/init.d/$svc" "/etc/conf.d/$svc"
  done
  say "uninstalled OpenRC services for $name"
}

# ── Compound commands ────────────────────────────────────────────────────────

add_tenant() {
  local name="$1"
  local docker_group="${2:-false}"
  local xmpp_jid="${3:-$name@xmpp.localhost}"
  local xmpp_password="${4:-}"
  local tensorzero_url="${5:-$DEFAULT_TENSORZERO_URL}"

  name="$(sanitize_name "$name")"
  [[ -n "$name" ]] || die "invalid tenant name"

  say "=== Adding tenant: $name ==="
  say ""

  ports_registry_init
  local base_port
  base_port="$(ports_allocate "$name")"
  say ""

  create_tenant_user "$name" "$docker_group"
  say ""

  clone_tenant_repo "$name"
  say ""

  say "--- Generating environment files ---"
  write_tenant_lunarwing_env "$name" "$xmpp_jid" "$xmpp_password" "$tensorzero_url"
  write_tenant_bridge_env "$name" "$xmpp_jid" "$xmpp_password"
  write_tenant_proxy_env "$name" "$tensorzero_url"
  say ""

  say "--- Starting PostgreSQL ---"
  start_tenant_postgres "$name"
  say ""

  ensure_init_system
  say "--- Rendering $INIT_SYSTEM services ---"
  if [[ "$INIT_SYSTEM" == "systemd" ]]; then
    render_tenant_systemd_units "$name"
  else
    render_tenant_openrc_units "$name"
  fi
  say ""

  say "=== Tenant '$name' added ==="
  say ""
  say "Port block: $base_port-$((base_port + PORT_BLOCK_SIZE - 1))"
  say "  gateway:  $(ports_get "$name" gateway)"
  say "  http:     $(ports_get "$name" http)"
  say "  bridge:   $(ports_get "$name" bridge)"
  say "  postgres: $(ports_get "$name" postgres)"
  say "  proxy:    $(ports_get "$name" proxy)"
  say "  weechat:  $(ports_get "$name" weechat)"
  say ""
  say "Next steps:"
  say "  sudo $0 build-tenant $name"
  say "  sudo $0 start-tenant $name"
}

add_tenants() {
  local names_csv="$1"
  shift

  local IFS=','
  local names_array
  read -ra names_array <<< "$names_csv"

  for raw_name in "${names_array[@]}"; do
    local name
    name="$(sanitize_name "$(echo "$raw_name" | xargs)")"
    [[ -n "$name" ]] || continue
    say ""
    add_tenant "$name" "$@"
  done
}

remove_tenant() {
  local name="$1"
  local purge="${2:-false}"

  name="$(sanitize_name "$name")"
  say "=== Removing tenant: $name ==="
  say ""

  ensure_init_system
  if [[ "$INIT_SYSTEM" == "systemd" ]]; then
    stop_tenant_systemd "$name"
    uninstall_tenant_systemd "$name"
  else
    stop_tenant_openrc "$name"
    uninstall_tenant_openrc "$name"
  fi
  say ""

  stop_tenant_postgres "$name"
  if [[ "$purge" == "true" ]]; then
    reset_tenant_postgres "$name"
  fi
  say ""

  ports_deallocate "$name"
  say ""

  remove_tenant_user "$name" "$purge"
  say ""

  say "=== Tenant '$name' removed ==="
}

start_tenant() {
  local name="$1"
  name="$(sanitize_name "$name")"
  tenant_exists_in_registry "$name" || die "tenant '$name' not found in registry"

  say "=== Starting tenant: $name ==="

  start_tenant_postgres "$name"

  ensure_init_system
  if [[ "$INIT_SYSTEM" == "systemd" ]]; then
    start_tenant_systemd "$name"
  else
    start_tenant_openrc "$name"
  fi
}

stop_tenant() {
  local name="$1"
  name="$(sanitize_name "$name")"

  say "=== Stopping tenant: $name ==="

  ensure_init_system
  if [[ "$INIT_SYSTEM" == "systemd" ]]; then
    stop_tenant_systemd "$name"
  else
    stop_tenant_openrc "$name"
  fi

  stop_tenant_postgres "$name"
}

restart_tenant() {
  local name="$1"
  stop_tenant "$name"
  start_tenant "$name"
}

status_tenant() {
  local name="$1"
  name="$(sanitize_name "$name")"

  if ! tenant_exists_in_registry "$name"; then
    say "tenant '$name' not found in registry"
    return 1
  fi

  say "=== Tenant: $name ==="
  say ""
  say "Ports:"
  say "  gateway:  $(ports_get "$name" gateway)"
  say "  http:     $(ports_get "$name" http)"
  say "  bridge:   $(ports_get "$name" bridge)"
  say "  postgres: $(ports_get "$name" postgres)"
  say "  proxy:    $(ports_get "$name" proxy)"
  say "  weechat:  $(ports_get "$name" weechat)"
  say ""

  ensure_container_runtime
  local container_name="lunarwing-pg-$name"
  if $CONTAINER_RT inspect -f '{{.State.Running}}' "$container_name" 2>/dev/null | grep -q true; then
    say "PostgreSQL: running ($container_name)"
  else
    say "PostgreSQL: stopped ($container_name)"
  fi

  ensure_init_system
  say ""
  say "Services ($INIT_SYSTEM):"
  if [[ "$INIT_SYSTEM" == "systemd" ]]; then
    for svc in "lunarwing-${name}" "xmpp-bridge-${name}" "lunarwing-proxy-${name}"; do
      local state
      state="$(_systemctl_user "$name" is-active "${svc}.service" 2>/dev/null || echo "inactive")"
      say "  ${svc}.service: $state"
    done
  else
    for svc in "lunarwing-${name}" "xmpp-bridge-${name}" "lunarwing-proxy-${name}"; do
      local state
      state="$(rc-service "$svc" status 2>/dev/null | grep -oE 'started|stopped|crashed' || echo "unknown")"
      say "  $svc: $state"
    done
  fi
}

list_tenants() {
  ports_registry_init
  say "=== Registered tenants ==="
  say ""

  local names
  names="$(all_tenant_names)"
  if [[ -z "$names" ]]; then
    say "no tenants registered"
    return 0
  fi

  printf '%-15s %-8s %-8s %-8s %-8s %-8s %-8s\n' \
    "TENANT" "GATEWAY" "HTTP" "BRIDGE" "PG" "PROXY" "WEECHAT"
  printf '%-15s %-8s %-8s %-8s %-8s %-8s %-8s\n' \
    "------" "-------" "----" "------" "--" "-----" "-------"

  while IFS= read -r name; do
    printf '%-15s %-8s %-8s %-8s %-8s %-8s %-8s\n' \
      "$name" \
      "$(ports_get "$name" gateway)" \
      "$(ports_get "$name" http)" \
      "$(ports_get "$name" bridge)" \
      "$(ports_get "$name" postgres)" \
      "$(ports_get "$name" proxy)" \
      "$(ports_get "$name" weechat)"
  done <<< "$names"
}

show_tokens() {
  local filter="${1:-}"

  say "=== Gateway auth tokens ==="
  say ""

  local names
  if [[ -n "$filter" ]]; then
    names="$(sanitize_name "$filter")"
  else
    names="$(all_tenant_names)"
  fi

  if [[ -z "$names" ]]; then
    say "no tenants found"
    return 0
  fi

  while IFS= read -r name; do
    local env_path gateway_port token
    env_path="$(tenant_env_dir "$name")/lunarwing.env"
    gateway_port="$(ports_get "$name" gateway)"
    token="$(grep -s '^GATEWAY_AUTH_TOKEN=' "$env_path" | cut -d= -f2-)"
    say "$name (port $gateway_port): ${token:-<not set>}"
  done <<< "$names"
}

doctor() {
  say "=== Multi-tenant doctor ==="
  say ""

  local pass=0 fail=0
  _check() {
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then
      printf '[PASS] %s\n' "$label"
      pass=$((pass + 1))
    else
      printf '[FAIL] %s\n' "$label"
      fail=$((fail + 1))
    fi
  }

  _check "running as root" test "${EUID}" -eq 0
  _check "jq installed" command -v jq
  _check "git installed" command -v git
  _check "python3 installed" command -v python3
  _check "cargo installed" command -v cargo
  _check "rustup installed" command -v rustup

  if command -v docker >/dev/null 2>&1; then
    _check "docker available" docker info
  fi
  if command -v podman >/dev/null 2>&1; then
    _check "podman available" podman info
  fi

  ensure_init_system
  _check "init system detected ($INIT_SYSTEM)" true

  if [[ "$INIT_SYSTEM" == "systemd" ]]; then
    _check "loginctl available" command -v loginctl
  else
    _check "rc-service available" command -v rc-service
    _check "rc-update available" command -v rc-update
  fi

  _check "port registry exists" test -f "$PORTS_REGISTRY"
  _check "source repo exists" test -d "$SOURCE_REPO/ic"
  _check "proxy script exists" test -f "$SOURCE_REPO/tensorzero-proxy-configurations/lunarwing-proxy.py"

  say ""
  say "passed: $pass, failed: $fail"
  [[ $fail -eq 0 ]]
}

# ── Main dispatcher ──────────────────────────────────────────────────────────

main() {
  local command_name="${1:-}"
  if [[ -z "$command_name" ]]; then
    usage
    exit 1
  fi
  shift || true

  case "$command_name" in
    add-tenant)
      require_root
      local name="" docker_group="false" xmpp_jid="" xmpp_password="" tz_url="$DEFAULT_TENSORZERO_URL"
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --docker-group)    docker_group="true"; shift ;;
          --xmpp-jid)        xmpp_jid="$2"; shift 2 ;;
          --xmpp-password)   xmpp_password="$2"; shift 2 ;;
          --tensorzero-url)  tz_url="$2"; shift 2 ;;
          -*)                die "unknown flag: $1" ;;
          *)
            if [[ -z "$name" ]]; then name="$1"; shift
            else die "unexpected argument: $1"
            fi
            ;;
        esac
      done
      [[ -n "$name" ]] || die "usage: add-tenant <name> [--docker-group] [--xmpp-jid <jid>]"
      [[ -n "$xmpp_jid" ]] || xmpp_jid="$(sanitize_name "$name")@xmpp.localhost"
      add_tenant "$name" "$docker_group" "$xmpp_jid" "$xmpp_password" "$tz_url"
      ;;

    add-tenants)
      require_root
      local names_csv="" docker_group="false" xmpp_domain="xmpp.localhost" tz_url="$DEFAULT_TENSORZERO_URL"
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --docker-group)    docker_group="true"; shift ;;
          --xmpp-domain)     xmpp_domain="$2"; shift 2 ;;
          --tensorzero-url)  tz_url="$2"; shift 2 ;;
          -*)                die "unknown flag: $1" ;;
          *)
            if [[ -z "$names_csv" ]]; then names_csv="$1"; shift
            else die "unexpected argument: $1"
            fi
            ;;
        esac
      done
      [[ -n "$names_csv" ]] || die "usage: add-tenants <name1,name2,...> [--docker-group]"

      local IFS=','
      local names_array
      read -ra names_array <<< "$names_csv"
      for raw_name in "${names_array[@]}"; do
        local sname
        sname="$(sanitize_name "$(echo "$raw_name" | xargs)")"
        [[ -n "$sname" ]] || continue
        say ""
        add_tenant "$sname" "$docker_group" "${sname}@${xmpp_domain}" "" "$tz_url"
      done
      ;;

    remove-tenant)
      require_root
      local name="" purge="false"
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --purge) purge="true"; shift ;;
          -*)      die "unknown flag: $1" ;;
          *)
            if [[ -z "$name" ]]; then name="$1"; shift
            else die "unexpected argument: $1"
            fi
            ;;
        esac
      done
      [[ -n "$name" ]] || die "usage: remove-tenant <name> [--purge]"
      remove_tenant "$name" "$purge"
      ;;

    build-tenant)
      require_root
      local name="" with_wasm="false"
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --with-wasm) with_wasm="true"; shift ;;
          -*)          die "unknown flag: $1" ;;
          *)
            if [[ -z "$name" ]]; then name="$1"; shift
            else die "unexpected argument: $1"
            fi
            ;;
        esac
      done
      [[ -n "$name" ]] || die "usage: build-tenant <name> [--with-wasm]"
      build_tenant "$(sanitize_name "$name")" "$with_wasm"
      ;;

    build-all)
      require_root
      local with_wasm="false"
      [[ "${1:-}" == "--with-wasm" ]] && with_wasm="true"
      build_all "$with_wasm"
      ;;

    start-tenant)
      require_root
      [[ -n "${1:-}" ]] || die "usage: start-tenant <name>"
      start_tenant "$1"
      ;;

    stop-tenant)
      require_root
      [[ -n "${1:-}" ]] || die "usage: stop-tenant <name>"
      stop_tenant "$1"
      ;;

    restart-tenant)
      require_root
      [[ -n "${1:-}" ]] || die "usage: restart-tenant <name>"
      restart_tenant "$1"
      ;;

    list-tenants|list)
      ports_registry_init
      list_tenants
      ;;

    status)
      [[ -n "${1:-}" ]] || die "usage: status <name>"
      status_tenant "$1"
      ;;

    tokens)
      show_tokens "${1:-}"
      ;;

    doctor)
      doctor
      ;;

    help|--help|-h)
      usage
      ;;

    *)
      die "unknown command: $command_name (try: $0 help)"
      ;;
  esac
}

main "$@"
