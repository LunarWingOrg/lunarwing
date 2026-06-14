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
DEFAULT_TENSORZERO_URL="${LUNARWING_MT_TENSORZERO_URL:-http://192.168.1.157:3000/openai/v1}"
DEFAULT_GOTIFY_URL="${LUNARWING_MT_GOTIFY_URL:-}"
DEFAULT_GOTIFY_TITLE="${LUNARWING_MT_GOTIFY_TITLE:-}"

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
    --llm-api-key <key>            API key for the LLM backend provider
    --tensorzero-url <url>         Upstream TensorZero URL
    --gotify-url <url>             Custom Gotify server URL (e.g. https://gotify.example.com)

  add-tenants <names> [options]    Comma-separated list (e.g. "Ruffles,Miyuki")
    (same options as add-tenant apply to all)

  remove-tenant <name>             Stop services, deallocate ports
    --purge                        Also delete OS user and home directory

  build-tenant <name>             Build binaries for one tenant (OOM-safe flock)
    --with-wasm                    Also build WASM extensions
    --with-nanocode                Also build the nanocode worker Docker image
    --with-pebble                  Also build the pebble worker Docker image

  build-all                        Build each tenant sequentially
    --with-wasm                    Also build WASM extensions
    --with-nanocode                Also build the nanocode worker Docker image
    --with-pebble                  Also build the pebble worker Docker image

  build-nanocode-worker            Build the nanocode worker Docker image
    --no-cache                     Force a full rebuild without Docker cache

  build-pebble-worker             Build the pebble worker Docker image
    --no-cache                     Force a full rebuild without Docker cache

  install-wasm <name>             Install built WASM tools/channels into tenant state dir
  install-wasm-all                Install WASM for all tenants

  start-tenant <name>             Start all services for a tenant
  stop-tenant <name>              Stop all services for a tenant
  restart-tenant <name>           Stop then start

  configure-gotify <name> <url>    Set custom Gotify URL for a tenant
                                   (updates workspace config + capabilities)

  configure-pebble <name>          Configure pebble worker for a tenant
    --nanogpt-api-key <key>        NanoGPT API key
    --model <model>                Pebble model (default: openai/gpt-5.2)

  patch-env <name>                 Add missing env vars (e.g. ORCHESTRATOR_PORT)
  patch-env-all                    Patch env for all registered tenants

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
  LUNARWING_MT_GOTIFY_URL          Default Gotify server URL for new tenants
  LUNARWING_MT_GOTIFY_TITLE        Default Gotify notification title for new tenants
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
  "version": 3,
  "range": { "start": 10000, "end": 19999 },
  "block_size": 10,
  "tenants": {}
}
ENDJSON
    chmod 0644 "$tmp"
    mv "$tmp" "$PORTS_REGISTRY"
    say "initialized port registry: $PORTS_REGISTRY"
  fi

  ports_migrate
}

ports_migrate() {
  [[ -f "$PORTS_REGISTRY" ]] || return 0
  require_cmd jq

  local current_version
  current_version="$(jq -r '.version // 0' "$PORTS_REGISTRY")"

  if [[ "$current_version" -lt 2 ]]; then
    say "migrating port registry v${current_version} -> v2 (reserved_0 -> orchestrator) ..."
    local tmp
    tmp="$(mktemp "$PORTS_REGISTRY.tmp.XXXXXX")"
    jq '
      .version = 2 |
      .tenants |= with_entries(
        .value.ports |= (
          if .reserved_0 then
            .orchestrator = .reserved_0 | del(.reserved_0)
          else
            .
          end
        )
      )
    ' "$PORTS_REGISTRY" >"$tmp"
    chmod 0644 "$tmp"
    mv "$tmp" "$PORTS_REGISTRY"
    say "port registry migrated to v2"
    current_version=2
  fi

  if [[ "$current_version" -lt 3 ]]; then
    say "migrating port registry v2 -> v3 (reserved_1 -> nanocode_wss) ..."
    local tmp
    tmp="$(mktemp "$PORTS_REGISTRY.tmp.XXXXXX")"
    jq '
      .version = 3 |
      .tenants |= with_entries(
        .value.ports |= (
          if .reserved_1 then
            .nanocode_wss = .reserved_1 | del(.reserved_1)
          else
            . + { nanocode_wss: (.orchestrator + 1) }
          end
        )
      )
    ' "$PORTS_REGISTRY" >"$tmp"
    chmod 0644 "$tmp"
    mv "$tmp" "$PORTS_REGISTRY"
    say "port registry migrated to v3"
    current_version=3
  fi

  if [[ "$current_version" -lt 4 ]]; then
    say "migrating port registry v3 -> v4 (reserved_2 -> pebble_wss) ..."
    local tmp
    tmp="$(mktemp "$PORTS_REGISTRY.tmp.XXXXXX")"
    jq '
      .version = 4 |
      .tenants |= with_entries(
        .value.ports |= (
          if .reserved_2 then
            .pebble_wss = .reserved_2 | del(.reserved_2)
          else
            . + { pebble_wss: (.orchestrator + 2) }
          end
        )
      )
    ' "$PORTS_REGISTRY" >"$tmp"
    chmod 0644 "$tmp"
    mv "$tmp" "$PORTS_REGISTRY"
    say "port registry migrated to v4"
  fi

  if [[ "$current_version" -lt 5 ]]; then
    say "migrating port registry v4 -> v5 (reserved_3 -> weechat_adapter) ..."
    local tmp
    tmp="$(mktemp "$PORTS_REGISTRY.tmp.XXXXXX")"
    jq '
      .version = 5 |
      .tenants |= with_entries(
        .value.ports |= (
          if .reserved_3 then
            .weechat_adapter = .reserved_3 | del(.reserved_3)
          else
            . + { weechat_adapter: (.orchestrator + 3) }
          end
        )
      )
    ' "$PORTS_REGISTRY" >"$tmp"
    chmod 0644 "$tmp"
    mv "$tmp" "$PORTS_REGISTRY"
    say "port registry migrated to v5"
  fi

  if [[ "$current_version" -lt 6 ]]; then
    say "migrating port registry v${current_version} -> v6 (add extended port range for overflow services) ..."
    local tmp
    tmp="$(mktemp "$PORTS_REGISTRY.tmp.XXXXXX")"
    # v6 expands per-tenant capacity *without moving any existing port*. Each
    # tenant's existing block (base_port + .ports) is left untouched; a parallel
    # block is mirrored into a second range (extended_base = base_port - range
    # start + extended_range start) holding fresh reserved_N slots for future
    # services. Mirroring preserves the >= block_size spacing, so extended blocks
    # never overlap each other or the original range.
    jq '
      .version = 6
      | .extended_range = { "start": 20000, "end": 29999 }
      | .extended_block_size = (.block_size // 10)
      | ( .range.start // 10000 ) as $rstart
      | ( .extended_range.start ) as $estart
      | ( .extended_block_size ) as $bs
      | .tenants |= with_entries(
          .value |= (
            if .base_port then
              ( .base_port - $rstart + $estart ) as $eb
              | .extended_base = $eb
              | .extended_ports = (
                  reduce range(0; $bs) as $i ({}; . + { ("reserved_\($i)"): ($eb + $i) })
                )
            else . end
          )
        )
    ' "$PORTS_REGISTRY" >"$tmp"
    chmod 0644 "$tmp"
    mv "$tmp" "$PORTS_REGISTRY"
    say "port registry migrated to v6"
    current_version=6
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
    ( .range.start // 10000 ) as $rstart
    | ( .extended_range.start // 20000 ) as $estart
    | ( .extended_block_size // 10 ) as $ebs
    | ( $base - $rstart + $estart ) as $ebase
    | .tenants[$name] = {
        base_port: $base,
        user: $name,
        created_at: $ts,
        ports: {
          gateway:          ($base + 0),
          http:             ($base + 1),
          bridge:           ($base + 2),
          postgres:         ($base + 3),
          proxy:            ($base + 4),
          weechat:          ($base + 5),
          orchestrator:     ($base + 6),
          nanocode_wss:     ($base + 7),
          pebble_wss:       ($base + 8),
          weechat_adapter:  ($base + 9)
        },
        extended_base: $ebase,
        extended_ports: (
          reduce range(0; $ebs) as $i ({}; . + { ("reserved_\($i)"): ($ebase + $i) })
        )
      }
  ' "$PORTS_REGISTRY" >"$tmp"
  chmod 0644 "$tmp"
  mv "$tmp" "$PORTS_REGISTRY"

  say "allocated port block $base-$((base + PORT_BLOCK_SIZE - 1)) for tenant '$name'" >&2
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
  jq -r '.tenants | to_entries[] | "\(.key)\t\(.value.ports.gateway)\t\(.value.ports.http)\t\(.value.ports.bridge)\t\(.value.ports.postgres)\t\(.value.ports.proxy)\t\(.value.ports.weechat)\t\(.value.ports.weechat_adapter // "-")\t\(.value.ports.orchestrator)\t\(.value.ports.nanocode_wss // "-")\t\(.value.ports.pebble_wss // "-")"' "$PORTS_REGISTRY" \
    | column -t -N "TENANT,GATEWAY,HTTP,BRIDGE,PG,PROXY,WEECHAT,WS_ADPT,ORCH,NANOCODE,PEBBLE"
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
    useradd --create-home --shell /bin/bash --comment "LunarWing tenant $name" "$name"
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

  # Install rustup for tenant user if not already present
  local cargo_src='if [ -f "$HOME/.cargo/env" ]; then . "$HOME/.cargo/env"; else export PATH="$HOME/.cargo/bin:$PATH"; fi;'
  if ! sudo -u "$name" bash -c "${cargo_src} command -v rustup" &>/dev/null; then
    say "installing rustup for $name ..."
    sudo -u "$name" bash -c 'curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y' \
      || die "rustup installation failed for $name"
    say "rustup installed for $name"
  else
    say "rustup already available for $name"
  fi

  # Ensure a default toolchain is set (rustup install may leave none configured)
  if ! sudo -u "$name" bash -c "${cargo_src} rustup show active-toolchain" &>/dev/null; then
    say "setting default toolchain to stable for $name ..."
    sudo -u "$name" bash -c "${cargo_src} rustup default stable" \
      || die "failed to set default toolchain for $name"
  fi

  # Ensure WASM targets and cargo-component are installed
  say "ensuring WASM toolchain for $name ..."
  sudo -u "$name" bash -c "${cargo_src} rustup target add wasm32-wasip1 wasm32-wasip2 2>&1" || true
  if ! sudo -u "$name" bash -c "${cargo_src} command -v cargo-component" &>/dev/null; then
    say "installing cargo-component and wasm-tools for $name ..."
    sudo -u "$name" bash -c "${cargo_src} cargo install cargo-component wasm-tools --locked 2>&1" || true
  fi
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

  if [[ -d "$dest/.git" ]] && [[ -d "$dest/ic" ]]; then
    say "repo already cloned at $dest"
    return 0
  fi
  # Clean up incomplete clone (has .git but missing content)
  if [[ -d "$dest/.git" ]] && [[ ! -d "$dest/ic" ]]; then
    say "incomplete clone detected, removing .git and re-cloning ..."
    rm -rf "$dest/.git"
  fi

  say "cloning repo from $SOURCE_REPO to $dest ..."
  local -a safedir=(-c "safe.directory=$dest" -c "safe.directory=$SOURCE_REPO")
  if [[ -d "$dest" ]] && [[ -n "$(ls -A "$dest")" ]]; then
    # Directory already has content (env/, state/, etc.) — init in place
    git "${safedir[@]}" init "$dest" >/dev/null
    git "${safedir[@]}" -C "$dest" remote add origin "$SOURCE_REPO"
    git "${safedir[@]}" -C "$dest" fetch origin --quiet
    local branch
    branch="$(git "${safedir[@]}" -C "$SOURCE_REPO" symbolic-ref --short HEAD 2>/dev/null || echo staging)"
    git "${safedir[@]}" -C "$dest" checkout -b "$branch" "origin/$branch" 2>&1 | tail -1
  else
    git "${safedir[@]}" clone --single-branch "$SOURCE_REPO" "$dest" 2>&1 | tail -1
  fi
  chown -R "$name:$name" "$dest"
  say "repo cloned for $name"
}

# ── Build management ─────────────────────────────────────────────────────────

build_tenant() {
  local name="$1"
  local with_wasm="${2:-false}"
  local with_nanocode="${3:-false}"
  local with_pebble="${4:-false}"
  local repo
  repo="$(tenant_repo "$name")"

  [[ -d "$repo" ]] || die "repo not found at $repo; run add-tenant first"

  say "acquiring build lock (only one tenant builds at a time) ..."
  (
    flock -x 200

    local cargo_env="if [ -f \"\$HOME/.cargo/env\" ]; then . \"\$HOME/.cargo/env\"; else export PATH=\"\$HOME/.cargo/bin:\$PATH\"; fi;"

    say "building lunarwing for $name ..."
    sudo -u "$name" bash -c "$cargo_env cd '$repo' && cargo build --profile $PROFILE --bin lunarwing" \
      || die "lunarwing build failed for $name"

    say "building xmpp-bridge for $name ..."
    sudo -u "$name" bash -c "$cargo_env cd '$repo/bridges/xmpp-bridge' && cargo build --profile $PROFILE" \
      || die "xmpp-bridge build failed for $name"

    if [[ "$with_wasm" == "true" ]]; then
      say "building WASM extensions for $name ..."
      sudo -u "$name" bash -c "$cargo_env cd '$repo' && bash scripts/build-wasm-extensions.sh" || true

      say "installing WASM extensions for $name ..."
      install_wasm_tenant "$name"
    fi

    say "build complete for $name"
    say ""
    say "Reminder: set your LLM provider API key (if applicable to your backend) in $(tenant_env_dir "$name")/lunarwing.env"
    say "  e.g.  LLM_API_KEY=sk-..."
  ) 200>"$BUILD_LOCK"

  if [[ "$with_nanocode" == "true" ]]; then
    build_nanocode_worker "false"
  fi

  if [[ "$with_pebble" == "true" ]]; then
    build_pebble_worker "false"
  fi
}

build_all() {
  local with_wasm="${1:-false}"
  local with_nanocode="${2:-false}"
  local with_pebble="${3:-false}"
  local names
  names="$(all_tenant_names)"

  if [[ -z "$names" ]]; then
    say "no tenants registered"
    return 0
  fi

  # Build worker images once (shared across tenants)
  if [[ "$with_nanocode" == "true" ]]; then
    say ""
    say "=== Building nanocode worker image ==="
    build_nanocode_worker "false"
  fi

  if [[ "$with_pebble" == "true" ]]; then
    say ""
    say "=== Building pebble worker image ==="
    build_pebble_worker "false"
  fi

  while IFS= read -r name; do
    say ""
    say "=== Building tenant: $name ==="
    build_tenant "$name" "$with_wasm" "false" "false"
  done <<< "$names"
}

# ── Nanocode worker Docker image build ────────────────────────────────────────

build_nanocode_worker() {
  local no_cache="${1:-false}"
  local nanocode_dir="${LUNARWING_ROOT}/lunarcode4lunarwing"
  local nanocode_src="${LUNARWING_ROOT}/nanocode-config/nanocode"

  [[ -d "$nanocode_dir" ]] || die "nanocode worker dir not found at $nanocode_dir"

  ensure_container_runtime

  # Ensure nanocode source is available in the build context.
  # Docker COPY cannot follow symlinks outside the build context, so we
  # must copy the directory rather than symlinking it.
  if [[ ! -d "$nanocode_dir/nanocode" ]] || [[ -L "$nanocode_dir/nanocode" ]]; then
    if [[ -d "$nanocode_src" ]]; then
      # Remove stale symlink if present
      rm -f "$nanocode_dir/nanocode" 2>/dev/null || true
      say "copying nanocode source into build context ..."
      cp -rL "$nanocode_src" "$nanocode_dir/nanocode"
    else
      die "nanocode source not found at $nanocode_src; cannot build worker image"
    fi
  fi

  say "building nanocode worker Docker image ..."
  local cache_flag=""
  [[ "$no_cache" == "true" ]] && cache_flag="--no-cache"

  if [[ "$CONTAINER_RT" == "podman" ]]; then
    podman build $cache_flag -t lunarwing-worker-nanocode:latest "$nanocode_dir" \
      || die "nanocode worker image build failed"
  else
    docker build $cache_flag -t lunarwing-worker-nanocode:latest "$nanocode_dir" \
      || die "nanocode worker image build failed"
  fi

  say "nanocode worker image built: lunarwing-worker-nanocode:latest"
}

build_pebble_worker() {
  local no_cache="${1:-false}"
  local pebble_dir="${LUNARWING_ROOT}/pebble4lunarwing"

  [[ -d "$pebble_dir" ]] || die "pebble worker dir not found at $pebble_dir"

  ensure_container_runtime

  say "building pebble worker Docker image ..."
  local cache_flag=""
  [[ "$no_cache" == "true" ]] && cache_flag="--no-cache"

  if [[ "$CONTAINER_RT" == "podman" ]]; then
    podman build $cache_flag -t lunarwing-worker-pebble:latest -f "$pebble_dir/Dockerfile" "$LUNARWING_ROOT" \
      || die "pebble worker image build failed"
  else
    docker build $cache_flag -t lunarwing-worker-pebble:latest -f "$pebble_dir/Dockerfile" "$LUNARWING_ROOT" \
      || die "pebble worker image build failed"
  fi

  say "pebble worker image built: lunarwing-worker-pebble:latest"
}

# ── WASM install ─────────────────────────────────────────────────────────────

channel_crate_name() {
  case "$1" in
    weechat) printf 'weechat_relay_channel' ;;
    *)       printf '%s_channel' "$1" ;;
  esac
}

tool_binary_name() {
  printf '%s_tool' "$(printf '%s' "$1" | tr '-' '_')"
}

install_wasm_tenant() {
  local name="$1"
  name="$(sanitize_name "$name")"
  tenant_exists_in_registry "$name" || die "tenant '$name' not found in registry"

  local repo state_dir
  repo="$(tenant_repo "$name")"
  state_dir="$(tenant_state_dir "$name")"

  local channels_dir="$state_dir/channels"
  local tools_dir="$state_dir/tools"

  mkdir -p "$channels_dir" "$tools_dir"

  # Resolve wasm-tools. add-tenant installs it for the *tenant* user under
  # ~/.cargo/bin; this function runs as root/admin, so prefer the tenant's copy
  # (otherwise we'd miss it and warn spuriously) before falling back to the
  # admin PATH. Output is chowned to the tenant at the end either way.
  local wasm_tools="" tenant_wasm_tools
  tenant_wasm_tools="$(tenant_home "$name")/.cargo/bin/wasm-tools"
  if [[ -x "$tenant_wasm_tools" ]]; then
    wasm_tools="$tenant_wasm_tools"
  elif command -v wasm-tools >/dev/null 2>&1; then
    wasm_tools="wasm-tools"
  fi

  local has_wasm_tools=true
  if [[ -z "$wasm_tools" ]]; then
    say "note: wasm-tools not installed — installing raw WASM components (works fine; skipping optional debug-info strip)"
    has_wasm_tools=false
  fi

  local installed=0 skipped=0

  say "installing WASM channels to $channels_dir..."
  for dir in "$repo/channels-src"/*/; do
    [[ -d "$dir" ]] || continue
    local ch_name crate_name src_wasm dest_wasm caps_src caps_dest
    ch_name="$(basename "$dir")"
    crate_name="$(channel_crate_name "$ch_name")"
    src_wasm="$dir/target/wasm32-wasip2/release/${crate_name}.wasm"
    dest_wasm="$channels_dir/${ch_name}.wasm"
    caps_src="$dir/${ch_name}.capabilities.json"
    caps_dest="$channels_dir/${ch_name}.capabilities.json"

    if [[ ! -f "$src_wasm" ]]; then
      skipped=$((skipped + 1))
      continue
    fi

    if [[ "$has_wasm_tools" == "true" ]]; then
      "$wasm_tools" component new "$src_wasm" -o "$dest_wasm" 2>/dev/null \
        || cp "$src_wasm" "$dest_wasm"
      "$wasm_tools" strip "$dest_wasm" -o "$dest_wasm" 2>/dev/null || true
    else
      cp "$src_wasm" "$dest_wasm"
    fi

    if [[ -f "$caps_src" ]]; then
      cp "$caps_src" "$caps_dest"
    fi
    say "  installed channel: $ch_name"
    installed=$((installed + 1))
  done

  say "installing WASM tools to $tools_dir..."
  for dir in "$repo/tools-src"/*/; do
    [[ -d "$dir" ]] || continue
    local t_name bin_name install_name src_wasm dest_wasm caps_src caps_dest
    t_name="$(basename "$dir")"
    bin_name="$(tool_binary_name "$t_name")"
    install_name="${t_name}-tool"
    src_wasm="$dir/target/wasm32-wasip2/release/${bin_name}.wasm"
    dest_wasm="$tools_dir/${install_name}.wasm"
    caps_dest="$tools_dir/${install_name}.capabilities.json"

    if [[ ! -f "$src_wasm" ]]; then
      skipped=$((skipped + 1))
      continue
    fi

    if [[ "$has_wasm_tools" == "true" ]]; then
      "$wasm_tools" component new "$src_wasm" -o "$dest_wasm" 2>/dev/null \
        || cp "$src_wasm" "$dest_wasm"
      "$wasm_tools" strip "$dest_wasm" -o "$dest_wasm" 2>/dev/null || true
    else
      cp "$src_wasm" "$dest_wasm"
    fi

    caps_src="$dir/${install_name}.capabilities.json"
    if [[ ! -f "$caps_src" ]]; then
      caps_src="$dir/${t_name}.capabilities.json"
    fi
    if [[ -f "$caps_src" ]]; then
      cp "$caps_src" "$caps_dest"
    fi
    say "  installed tool: $install_name"
    installed=$((installed + 1))
  done

  chown -R "$name:$name" "$channels_dir" "$tools_dir"

  local gotify_config="$state_dir/workspace/config/gotify.json"
  if [[ -f "$gotify_config" ]] && [[ -f "$tools_dir/gotify-tool.capabilities.json" ]]; then
    local gotify_url
    gotify_url="$(jq -r '.url // empty' "$gotify_config" 2>/dev/null)"
    if [[ -n "$gotify_url" ]]; then
      configure_gotify_capabilities "$name" "$gotify_url"
    fi
  fi

  say "WASM install for $name: $installed installed, $skipped skipped (not built)"
}

install_wasm_all() {
  local names
  names="$(all_tenant_names)"

  if [[ -z "$names" ]]; then
    say "no tenants registered"
    return 0
  fi

  while IFS= read -r name; do
    say ""
    say "=== Installing WASM for tenant: $name ==="
    install_wasm_tenant "$name"
  done <<< "$names"
}

# ── Environment file generation ──────────────────────────────────────────────

write_tenant_lunarwing_env() {
  local name="$1"
  local xmpp_jid="${2:-$name@xmpp.localhost}"
  local xmpp_password="${3:-$(generate_token | cut -c1-32)}"
  local tensorzero_url="${4:-$DEFAULT_TENSORZERO_URL}"
  local llm_api_key="${5:-}"

  local path gateway_port http_port bridge_port pg_port proxy_port weechat_port weechat_adapter_port orchestrator_port nanocode_wss_port pebble_wss_port
  path="$(tenant_env_dir "$name")/lunarwing.env"
  gateway_port="$(ports_get "$name" gateway)"
  http_port="$(ports_get "$name" http)"
  bridge_port="$(ports_get "$name" bridge)"
  pg_port="$(ports_get "$name" postgres)"
  proxy_port="$(ports_get "$name" proxy)"
  weechat_port="$(ports_get "$name" weechat)"
  weechat_adapter_port="$(ports_get "$name" weechat_adapter)"
  orchestrator_port="$(ports_get "$name" orchestrator)"
  nanocode_wss_port="$(ports_get "$name" nanocode_wss)"
  pebble_wss_port="$(ports_get "$name" pebble_wss)"

  local state_dir run_dir repo_dir
  state_dir="$(tenant_state_dir "$name")"
  run_dir="$(tenant_run_dir "$name")"
  repo_dir="$(tenant_repo "$name")"

  local gateway_token bridge_token relay_password secrets_key
  gateway_token="$(generate_token)"
  bridge_token="$(generate_token | cut -c1-32)"
  relay_password="$(generate_token | cut -c1-32)"
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
LLM_API_KEY=${llm_api_key:-token-${name}}
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

# Orchestrator (sandbox container callback)
ORCHESTRATOR_PORT=$orchestrator_port

# Nanocode worker (WebSocket port for agent communication)
NANOCODE_WSS_PORT=$nanocode_wss_port

# Pebble worker (WebSocket port for agent communication)
PEBBLE_WSS_PORT=$pebble_wss_port

# WeeChat relay + adapter
# RELAY_URL / WS_ADAPTER_URL are full URLs consumed by the in-process WASM
# channel (via the capabilities `env` source). ADAPTER_PORT/WEECHAT_ADAPTER_PORT
# are the bare port consumed by the standalone ws_adapter.py process.
RELAY_URL=http://127.0.0.1:${weechat_port}
RELAY_PASSWORD=$relay_password
ADAPTER_PORT=$weechat_adapter_port
WEECHAT_ADAPTER_PORT=$weechat_adapter_port
WS_ADAPTER_URL=http://127.0.0.1:${weechat_adapter_port}

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

# ── External-worker config.toml generation ────────────────────────────────────
#
# External workers (nanocode, pebble, …) speak the ironclaw-agent-v1 WebSocket
# protocol and are routed by the agent's `create_job(mode: "<worker>")` tool.
# The daemon discovers them from `[[sandbox.external_workers]]` blocks in
# `config.toml` under the tenant's LUNARWING_BASE_DIR (the state dir). Without
# this block the agent has nothing to route `create_job(mode: "<worker>")` to
# and never logs `External workers configured: <worker>` on startup.
#
# The worker container binds 127.0.0.1:<wss_port> (path /ws/agent) and is
# launched with AGENT_AUTH_TOKEN set to the tenant's GATEWAY_AUTH_TOKEN (see
# start_tenant_nanocode), so the daemon side must present that same token as the
# WebSocket bearer — hence auth_token mirrors GATEWAY_AUTH_TOKEN here.
#
# Idempotent: a tenant entry is written once and skipped on re-runs. The block
# survives the daemon's own config.toml writers (e.g. `/model`), which
# load-modify-save the whole settings struct.
ensure_external_worker_config() {
  local name="$1"      # tenant name
  local worker="$2"    # logical worker name, matches create_job mode (e.g. "nanocode")
  local port_key="$3"  # ports-registry key for its WSS port (e.g. "nanocode_wss")

  local state_dir env_path config_path wss_port auth_token
  state_dir="$(tenant_state_dir "$name")"
  env_path="$(tenant_env_dir "$name")/lunarwing.env"
  config_path="$state_dir/config.toml"

  wss_port="$(ports_get "$name" "$port_key")"
  if [[ -z "$wss_port" ]]; then
    say "no $port_key port allocated for $name (skipping $worker external-worker config)"
    return 0
  fi

  # Already configured? Skip so re-runs / patch-env are idempotent. The daemon's
  # TOML writer emits `name = "<worker>"` identically, so this also matches a
  # file that has been load-modify-saved by `/model`.
  if [[ -f "$config_path" ]] && grep -q "name = \"$worker\"" "$config_path" 2>/dev/null; then
    say "external worker '$worker' already configured in $config_path (skipping)"
    return 0
  fi

  auth_token="$(grep -s '^GATEWAY_AUTH_TOKEN=' "$env_path" | cut -d= -f2-)"

  # add-tenant runs before the daemon ever starts, so config.toml usually does
  # not exist yet — create it with a header. Appending a fresh
  # `[[sandbox.external_workers]]` array-of-tables to an existing file is valid
  # TOML because we only ever append when no entry for this array exists yet.
  if [[ ! -f "$config_path" ]]; then
    sudo -u "$name" mkdir -p "$state_dir"
    (
      umask 077
      cat >"$config_path" <<'HDR'
# LunarWing tenant configuration (auto-generated by lunarwing-mt-admin.sh).
#
# Priority: env var > this file > database settings > defaults.
# The external-worker blocks below wire create_job(mode: "<name>") to the
# per-tenant worker containers. Hand edits outside these blocks are preserved.
HDR
    )
  fi

  {
    printf '\n# External worker: %s — create_job(mode: "%s")\n' "$worker" "$worker"
    printf '[[sandbox.external_workers]]\n'
    printf 'name = "%s"\n' "$worker"
    printf 'url = "ws://127.0.0.1:%s/ws/agent"\n' "$wss_port"
    if [[ -n "$auth_token" ]]; then
      printf 'auth_token = "%s"\n' "$auth_token"
    fi
    printf 'timeout_ms = 300000\n'
  } >>"$config_path"

  if [[ -z "$auth_token" ]]; then
    say "WARNING: GATEWAY_AUTH_TOKEN not found in $env_path;" \
        "'$worker' worker config written WITHOUT auth_token (connections will fail until set)"
  fi

  chown "$name:$name" "$config_path"
  chmod 600 "$config_path"
  say "wrote $worker external-worker config to $config_path (ws://127.0.0.1:$wss_port/ws/agent)"
}

patch_tenant_env() {
  local name="$1"
  name="$(sanitize_name "$name")"
  tenant_exists_in_registry "$name" || die "tenant '$name' not found in registry"

  local env_path
  env_path="$(tenant_env_dir "$name")/lunarwing.env"
  [[ -f "$env_path" ]] || die "env file not found: $env_path"

  local orchestrator_port
  orchestrator_port="$(ports_get "$name" orchestrator)"

  if grep -q '^ORCHESTRATOR_PORT=' "$env_path"; then
    say "ORCHESTRATOR_PORT already set in $env_path (skipping)"
  else
    printf '\n# Orchestrator (sandbox container callback)\nORCHESTRATOR_PORT=%s\n' "$orchestrator_port" >>"$env_path"
    say "added ORCHESTRATOR_PORT=$orchestrator_port to $env_path"
  fi

  local nanocode_wss_port
  nanocode_wss_port="$(ports_get "$name" nanocode_wss)"
  if [[ -n "$nanocode_wss_port" ]]; then
    if grep -q '^NANOCODE_WSS_PORT=' "$env_path"; then
      say "NANOCODE_WSS_PORT already set in $env_path (skipping)"
    else
      printf '\n# Nanocode worker (WebSocket port for agent communication)\nNANOCODE_WSS_PORT=%s\n' "$nanocode_wss_port" >>"$env_path"
      say "added NANOCODE_WSS_PORT=$nanocode_wss_port to $env_path"
    fi
  fi

  local pebble_wss_port
  pebble_wss_port="$(ports_get "$name" pebble_wss)"
  if [[ -n "$pebble_wss_port" ]]; then
    if grep -q '^PEBBLE_WSS_PORT=' "$env_path"; then
      say "PEBBLE_WSS_PORT already set in $env_path (skipping)"
    else
      printf '\n# Pebble worker (WebSocket port for agent communication)\nPEBBLE_WSS_PORT=%s\n' "$pebble_wss_port" >>"$env_path"
      say "added PEBBLE_WSS_PORT=$pebble_wss_port to $env_path"
    fi
  fi

  local weechat_adapter_port
  weechat_adapter_port="$(ports_get "$name" weechat_adapter)"
  if [[ -n "$weechat_adapter_port" ]]; then
    if grep -q '^WEECHAT_ADAPTER_PORT=' "$env_path"; then
      say "WEECHAT_ADAPTER_PORT already set in $env_path (skipping)"
    else
      printf '\n# WeeChat adapter (local HTTP adapter bridging WeeChat WS relay to WASM)\nWEECHAT_ADAPTER_PORT=%s\n' "$weechat_adapter_port" >>"$env_path"
      say "added WEECHAT_ADAPTER_PORT=$weechat_adapter_port to $env_path"
    fi
    # WS_ADAPTER_URL is the full adapter URL consumed by the in-process WASM
    # channel (via the capabilities `env` source). Without it the channel
    # falls back to the hardcoded :6681 default and silently fails.
    if grep -q '^WS_ADAPTER_URL=' "$env_path"; then
      say "WS_ADAPTER_URL already set in $env_path (skipping)"
    else
      printf 'WS_ADAPTER_URL=http://127.0.0.1:%s\n' "$weechat_adapter_port" >>"$env_path"
      say "added WS_ADAPTER_URL=http://127.0.0.1:$weechat_adapter_port to $env_path"
    fi
  fi

  local weechat_port
  weechat_port="$(ports_get "$name" weechat)"
  if [[ -n "$weechat_port" ]]; then
    if grep -q '^RELAY_URL=' "$env_path"; then
      say "RELAY_URL already set in $env_path (skipping)"
    else
      printf '\n# WeeChat relay URL consumed by the in-process WASM channel\nRELAY_URL=http://127.0.0.1:%s\n' "$weechat_port" >>"$env_path"
      say "added RELAY_URL=http://127.0.0.1:$weechat_port to $env_path"
    fi
  fi

  # Wire the nanocode external worker into config.toml so existing tenants get
  # create_job(mode: "nanocode") routing without a hand-edited config file.
  ensure_external_worker_config "$name" "nanocode" "nanocode_wss"
  ensure_external_worker_config "$name" "pebble" "pebble_wss"
}

extract_host_from_url() {
  printf '%s' "$1" | sed -E 's|^https?://||; s|[:/].*||'
}

write_tenant_gotify_config() {
  local name="$1"
  local gotify_url="${2:-}"
  local gotify_title="${3:-}"

  [[ -n "$gotify_url" ]] || return 0

  local state_dir config_dir config_path
  state_dir="$(tenant_state_dir "$name")"
  config_dir="$state_dir/workspace/config"
  config_path="$config_dir/gotify.json"

  sudo -u "$name" mkdir -p "$config_dir"
  gotify_url="$(printf '%s' "$gotify_url" | sed 's|/$||')"
  if [[ -n "$gotify_title" ]]; then
    printf '{"url": "%s", "title": "%s"}\n' "$gotify_url" "$gotify_title" >"$config_path"
  else
    printf '{"url": "%s"}\n' "$gotify_url" >"$config_path"
  fi
  chown "$name:$name" "$config_path"
  say "wrote: $config_path"
}

configure_gotify_capabilities() {
  local name="$1"
  local gotify_url="${2:-}"

  [[ -n "$gotify_url" ]] || return 0
  require_cmd jq

  local tools_dir caps_path host
  tools_dir="$(tenant_state_dir "$name")/tools"
  caps_path="$tools_dir/gotify-tool.capabilities.json"

  [[ -f "$caps_path" ]] || return 0

  host="$(extract_host_from_url "$gotify_url")"
  [[ -n "$host" ]] || return 0

  local tmp
  tmp="$(mktemp "$caps_path.tmp.XXXXXX")"
  jq --arg host "$host" '
    .capabilities.http.allowlist[0].host = $host |
    .capabilities.http.credentials.gotify.host_patterns = [$host]
  ' "$caps_path" >"$tmp"
  mv "$tmp" "$caps_path"
  chown "$name:$name" "$caps_path"
  say "  configured gotify capabilities for host: $host"
}

# ── Pebble worker configuration ──────────────────────────────────────────────

configure_pebble() {
  local name="$1"
  local nanogpt_api_key="$2"
  local model="$3"

  name="$(sanitize_name "$name")"
  tenant_exists_in_registry "$name" || die "tenant '$name' not found in registry"

  local env_dir env_path
  env_dir="$(tenant_env_dir "$name")"
  env_path="$env_dir/pebble.env"

  mkdir -p "$env_dir"

  : >"$env_path"

  if [[ -n "$nanogpt_api_key" ]]; then
    printf 'NANOGPT_API_KEY=%s\n' "$nanogpt_api_key" >>"$env_path"
  fi

  if [[ -n "$model" ]]; then
    printf 'PEBBLE_MODEL=%s\n' "$model" >>"$env_path"
  fi

  chown "$name:$name" "$env_path"
  chmod 600 "$env_path"
  say "pebble configured for tenant '$name' at $env_path"

  local container_name="lunarwing-pebble-$name"
  if $CONTAINER_RT inspect "$container_name" &>/dev/null 2>&1; then
    say "note: restart the pebble worker to pick up new config:"
    say "  sudo $0 stop-tenant $name && sudo $0 start-tenant $name"
  fi
}

# ── Nanocode worker container ─────────────────────────────────────────────────

start_tenant_nanocode() {
  local name="$1"
  ensure_container_runtime

  local wss_port container_name nanocode_dir
  wss_port="$(ports_get "$name" nanocode_wss)"
  container_name="lunarwing-nanocode-$name"
  nanocode_dir="${LUNARWING_ROOT}/lunarcode4lunarwing"

  if [[ -z "$wss_port" ]]; then
    say "no nanocode_wss port allocated for $name (skipping nanocode worker)"
    return 0
  fi

  # Check if the image exists
  if ! $CONTAINER_RT image inspect lunarwing-worker-nanocode:latest &>/dev/null; then
    say "nanocode worker image not found; run 'build-nanocode-worker' first (skipping)"
    return 0
  fi

  if $CONTAINER_RT inspect "$container_name" &>/dev/null; then
    if $CONTAINER_RT inspect -f '{{.State.Running}}' "$container_name" 2>/dev/null | grep -q true; then
      say "nanocode worker already running ($container_name, WSS port $wss_port)"
      return 0
    fi
    say "starting existing nanocode worker container $container_name"
    $CONTAINER_RT start "$container_name" >/dev/null
  else
    say "creating nanocode worker container $container_name on WSS port $wss_port"

    # Read tenant env for secrets to pass through
    local tenant_env_path
    tenant_env_path="$(tenant_env_dir "$name")/lunarwing.env"

    # Read nanocode-specific env if it exists
    local nanocode_env_path
    nanocode_env_path="$(tenant_env_dir "$name")/nanocode.env"

    local env_flags=()
    # Core env vars from tenant lunarwing.env
    if [[ -f "$tenant_env_path" ]]; then
      local gateway_token
      gateway_token="$(grep '^GATEWAY_AUTH_TOKEN=' "$tenant_env_path" | cut -d= -f2- || true)"
      [[ -n "$gateway_token" ]] && env_flags+=(-e "AGENT_AUTH_TOKEN=$gateway_token")

      local llm_api_key
      llm_api_key="$(grep '^LLM_API_KEY=' "$tenant_env_path" | cut -d= -f2- || true)"
      [[ -n "$llm_api_key" ]] && env_flags+=(-e "TENSORZERO_API_KEY=$llm_api_key")
    fi

    # Override with nanocode-specific env file if present
    if [[ -f "$nanocode_env_path" ]]; then
      env_flags+=(--env-file "$nanocode_env_path")
    fi

    local workspace_dir
    workspace_dir="$(tenant_lw_root "$name")/nanocode-workspace"
    mkdir -p "$workspace_dir"
    chown "$name:$name" "$workspace_dir"
    chmod 777 "$workspace_dir"

    $CONTAINER_RT run -d \
      --name "$container_name" \
      -e LUNARWING_WORKER_ID="worker-nanocode-${name}" \
      -e WS_PORT="$wss_port" \
      -e HEALTH_PORT="0" \
      -e NANOCODE_MODE=websocket \
      -e WS_ROLE=server \
      -e WS_BIND_HOST=0.0.0.0 \
      -e WS_PATH=/ws/agent \
      "${env_flags[@]}" \
      -p "127.0.0.1:${wss_port}:${wss_port}" \
      -v "$workspace_dir:/workspace:z" \
      --restart unless-stopped \
      lunarwing-worker-nanocode:latest \
      --mode websocket >/dev/null
  fi

  say "nanocode worker ready ($container_name, WSS port $wss_port)"
}

stop_tenant_nanocode() {
  local name="$1"
  ensure_container_runtime

  local container_name="lunarwing-nanocode-$name"
  if $CONTAINER_RT inspect "$container_name" &>/dev/null; then
    $CONTAINER_RT stop "$container_name" >/dev/null 2>&1 || true
    say "nanocode worker stopped ($container_name)"
  fi
}

# ── Pebble worker container ──────────────────────────────────────────────────

start_tenant_pebble() {
  local name="$1"
  ensure_container_runtime

  local wss_port container_name
  wss_port="$(ports_get "$name" pebble_wss)"
  container_name="lunarwing-pebble-$name"

  if [[ -z "$wss_port" ]]; then
    say "no pebble_wss port allocated for $name (skipping pebble worker)"
    return 0
  fi

  if ! $CONTAINER_RT image inspect lunarwing-worker-pebble:latest &>/dev/null; then
    say "pebble worker image not found; run 'build-pebble-worker' first (skipping)"
    return 0
  fi

  if $CONTAINER_RT inspect "$container_name" &>/dev/null; then
    if $CONTAINER_RT inspect -f '{{.State.Running}}' "$container_name" 2>/dev/null | grep -q true; then
      say "pebble worker already running ($container_name, WSS port $wss_port)"
      return 0
    fi
    say "starting existing pebble worker container $container_name"
    $CONTAINER_RT start "$container_name" >/dev/null
  else
    say "creating pebble worker container $container_name on WSS port $wss_port"

    local tenant_env_path
    tenant_env_path="$(tenant_env_dir "$name")/lunarwing.env"

    local pebble_env_path
    pebble_env_path="$(tenant_env_dir "$name")/pebble.env"

    local env_flags=()
    if [[ -f "$tenant_env_path" ]]; then
      local gateway_token
      gateway_token="$(grep '^GATEWAY_AUTH_TOKEN=' "$tenant_env_path" | cut -d= -f2- || true)"
      [[ -n "$gateway_token" ]] && env_flags+=(-e "AGENT_AUTH_TOKEN=$gateway_token")
    fi

    if [[ -f "$pebble_env_path" ]]; then
      env_flags+=(--env-file "$pebble_env_path")
    fi

    local workspace_dir
    workspace_dir="$(tenant_lw_root "$name")/pebble-workspace"
    mkdir -p "$workspace_dir"
    chown "$name:$name" "$workspace_dir"
    chmod 777 "$workspace_dir"

    $CONTAINER_RT run -d \
      --name "$container_name" \
      -e LUNARWING_WORKER_ID="worker-pebble-${name}" \
      -e WS_PORT="$wss_port" \
      -e HEALTH_PORT="0" \
      -e PEBBLE_MODE=websocket \
      -e WS_BIND_HOST=0.0.0.0 \
      -e WS_PATH=/ws/agent \
      "${env_flags[@]}" \
      -p "127.0.0.1:${wss_port}:${wss_port}" \
      -v "$workspace_dir:/workspace:z" \
      --restart unless-stopped \
      lunarwing-worker-pebble:latest >/dev/null
  fi

  say "pebble worker ready ($container_name, WSS port $wss_port)"
}

stop_tenant_pebble() {
  local name="$1"
  ensure_container_runtime

  local container_name="lunarwing-pebble-$name"
  if $CONTAINER_RT inspect "$container_name" &>/dev/null; then
    $CONTAINER_RT stop "$container_name" >/dev/null 2>&1 || true
    say "pebble worker stopped ($container_name)"
  fi
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
    [[ $attempts -lt 90 ]] || die "PostgreSQL for $name did not become ready"
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

  local repo env_dir state_dir proxy_port bridge_port weechat_port
  repo="$(tenant_repo "$name")"
  env_dir="$(tenant_env_dir "$name")"
  state_dir="$(tenant_state_dir "$name")"
  proxy_port="$(ports_get "$name" proxy)"
  bridge_port="$(ports_get "$name" bridge)"
  weechat_port="$(ports_get "$name" weechat)"

  local proxy_bin
  # Run from the tenant's own clone (in their home), not the admin's source repo,
  # so a tenant's services aren't coupled to another user's home directory.
  proxy_bin="$(tenant_lw_root "$name")/tensorzero-proxy-configurations/lunarwing-proxy.py"

  local ws_adapter_path
  ws_adapter_path="$(tenant_lw_root "$name")/ironclaw_weechat_wss/weechat_relay/ws_adapter.py"

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

  # WeeChat unit (runs in tmux so you can attach: tmux -L weechat-${name} attach)
  local weechat_home
  weechat_home="$(tenant_home "$name")/.config/weechat"
  mkdir -p "$weechat_home"
  chown "$name:$name" "$weechat_home"

  cat >"$user_unit_dir/weechat-${name}.service" <<EOF
[Unit]
Description=WeeChat IRC client ($name)
After=network.target

[Service]
Type=forking
ExecStart=$(command -v tmux) -L weechat-${name} new-session -d -s weechat '$(command -v weechat) --dir ${weechat_home}'
ExecStop=$(command -v tmux) -L weechat-${name} kill-session -t weechat
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF

  # WeeChat WS adapter unit
  cat >"$user_unit_dir/lunarwing-weechat-adapter-${name}.service" <<EOF
[Unit]
Description=LunarWing WeeChat WS adapter ($name)
After=network.target weechat-${name}.service
Requires=weechat-${name}.service
PartOf=lunarwing-${name}.service

[Service]
Type=simple
WorkingDirectory=$(dirname "$ws_adapter_path")
EnvironmentFile=$env_dir/lunarwing.env
ExecStart=$(command -v python3) $ws_adapter_path
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
After=network.target xmpp-bridge-${name}.service lunarwing-proxy-${name}.service weechat-${name}.service lunarwing-weechat-adapter-${name}.service
Wants=xmpp-bridge-${name}.service lunarwing-proxy-${name}.service weechat-${name}.service lunarwing-weechat-adapter-${name}.service

[Service]
Type=simple
WorkingDirectory=$repo
EnvironmentFile=$env_dir/lunarwing.env
Environment=PATH=/usr/local/bin:/usr/bin:/bin:/home/${name}/.cargo/bin
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
  _systemctl_user "$name" enable \
    "lunarwing-${name}.service" \
    "xmpp-bridge-${name}.service" \
    "lunarwing-proxy-${name}.service" \
    "weechat-${name}.service" \
    "lunarwing-weechat-adapter-${name}.service"
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

  for svc in "lunarwing-${name}.service" "xmpp-bridge-${name}.service" "lunarwing-proxy-${name}.service" "lunarwing-weechat-adapter-${name}.service" "weechat-${name}.service"; do
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

  for svc in "lunarwing-${name}.service" "xmpp-bridge-${name}.service" "lunarwing-proxy-${name}.service" "lunarwing-weechat-adapter-${name}.service" "weechat-${name}.service"; do
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

  local proxy_port bridge_port weechat_port
  proxy_port="$(ports_get "$name" proxy)"
  bridge_port="$(ports_get "$name" bridge)"
  weechat_port="$(ports_get "$name" weechat)"

  local proxy_bin
  # Run from the tenant's own clone (in their home), not the admin's source repo,
  # so a tenant's services aren't coupled to another user's home directory.
  proxy_bin="$(tenant_lw_root "$name")/tensorzero-proxy-configurations/lunarwing-proxy.py"

  local ws_adapter_path
  ws_adapter_path="$(tenant_lw_root "$name")/ironclaw_weechat_wss/weechat_relay/ws_adapter.py"
  local ws_adapter_dir
  ws_adapter_dir="$(dirname "$ws_adapter_path")"

  local weechat_home
  weechat_home="$(tenant_home "$name")/.config/weechat"

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
    after firewall xmpp-bridge-${name} lunarwing-proxy-${name} weechat-${name} lunarwing-weechat-adapter-${name}
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

  # ── WeeChat init script (tmux-based) ──
  cat >"/etc/init.d/weechat-${name}" <<INITEOF
#!/sbin/openrc-run

description="WeeChat IRC client ($name)"

: "\${weechat_user:=$name}"
: "\${weechat_group:=$name}"
: "\${weechat_home:=$weechat_home}"
: "\${weechat_pidfile:=$run_dir/weechat.pid}"
: "\${weechat_runtime_dir:=$run_dir}"
: "\${weechat_log_dir:=$log_dir}"
: "\${weechat_output_log:=\${weechat_log_dir}/weechat.log}"
: "\${weechat_error_log:=\${weechat_log_dir}/weechat.err}"
: "\${weechat_retry:=SIGTERM/30/KILL/5}"

command="$(command -v tmux)"
command_args="-L weechat-${name} new-session -d -s weechat '$(command -v weechat) --dir \${weechat_home}'"
command_user="\${weechat_user}:\${weechat_group}"

depend() {
    need net
    use dns
    after firewall
    before lunarwing-weechat-adapter-${name} lunarwing-${name}
}

start() {
    ebegin "Starting WeeChat ($name)"
    checkpath -d -m 0750 -o "\${weechat_user}:\${weechat_group}" "\${weechat_home}"
    checkpath -d -m 0750 -o "\${weechat_user}:\${weechat_group}" "\${weechat_runtime_dir}"
    start-stop-daemon --start --user "\${weechat_user}" \\
        --exec $(command -v tmux) -- -L weechat-${name} new-session -d -s weechat "$(command -v weechat) --dir \${weechat_home}"
    eend \$?
}

stop() {
    ebegin "Stopping WeeChat ($name)"
    su -s /bin/sh "\${weechat_user}" -c "$(command -v tmux) -L weechat-${name} kill-session -t weechat 2>/dev/null" || true
    eend 0
}
INITEOF
  chmod 0755 "/etc/init.d/weechat-${name}"

  # WeeChat WS adapter init script
  cat >"/etc/init.d/lunarwing-weechat-adapter-${name}" <<INITEOF
#!/sbin/openrc-run

description="LunarWing WeeChat WS adapter ($name)"

: "\${adapter_command:=$(command -v python3)}"
: "\${adapter_args:=$ws_adapter_path}"
: "\${adapter_user:=$name}"
: "\${adapter_group:=$name}"
: "\${adapter_pidfile:=$run_dir/weechat-adapter.pid}"
: "\${adapter_runtime_dir:=$run_dir}"
: "\${adapter_log_dir:=$log_dir}"
: "\${adapter_output_log:=\${adapter_log_dir}/weechat-adapter.log}"
: "\${adapter_error_log:=\${adapter_log_dir}/weechat-adapter.err}"
: "\${adapter_env_file:=$env_dir/lunarwing.env}"
: "\${adapter_umask:=0077}"
: "\${adapter_respawn_delay:=5}"
: "\${adapter_respawn_max:=5}"
: "\${adapter_respawn_period:=60}"
: "\${adapter_retry:=SIGTERM/30/KILL/5}"

command="\${adapter_command}"
command_args="\${adapter_args}"
command_user="\${adapter_user}:\${adapter_group}"
directory="$ws_adapter_dir"
pidfile="\${adapter_pidfile}"
supervisor="supervise-daemon"
retry="\${adapter_retry}"
respawn_delay="\${adapter_respawn_delay}"
respawn_max="\${adapter_respawn_max}"
respawn_period="\${adapter_respawn_period}"
output_log="\${adapter_output_log}"
error_log="\${adapter_error_log}"

depend() {
    need net weechat-${name}
    use dns
    after firewall weechat-${name}
    before lunarwing-${name}
}

load_env() {
    if [ -n "\${adapter_env_file}" ] && [ -r "\${adapter_env_file}" ]; then
        set -a
        . "\${adapter_env_file}"
        set +a
    fi
}

start_pre() {
    checkpath -d -m 0750 -o "\${adapter_user}:\${adapter_group}" "\${adapter_runtime_dir}"
    checkpath -d -m 0750 -o "\${adapter_user}:\${adapter_group}" "\${adapter_log_dir}"
    checkpath -f -m 0640 -o "\${adapter_user}:\${adapter_group}" "\${output_log}"
    checkpath -f -m 0640 -o "\${adapter_user}:\${adapter_group}" "\${error_log}"
    load_env || return 1
    umask "\${adapter_umask}"
}
INITEOF
  chmod 0755 "/etc/init.d/lunarwing-weechat-adapter-${name}"

  # ── Conf.d files ──
  cat >"/etc/conf.d/lunarwing-${name}" <<CONFD
# Auto-generated by lunarwing-mt-admin.sh for tenant: $name
lunarwing_rc_need="xmpp-bridge-${name} lunarwing-proxy-${name} weechat-${name} lunarwing-weechat-adapter-${name}"
CONFD

  cat >"/etc/conf.d/xmpp-bridge-${name}" <<CONFD
# Auto-generated by lunarwing-mt-admin.sh for tenant: $name
xmpp_bridge_rc_before="lunarwing-${name}"
CONFD

  cat >"/etc/conf.d/lunarwing-proxy-${name}" <<CONFD
# Auto-generated by lunarwing-mt-admin.sh for tenant: $name
CONFD

  cat >"/etc/conf.d/weechat-${name}" <<CONFD
# Auto-generated by lunarwing-mt-admin.sh for tenant: $name
CONFD

  cat >"/etc/conf.d/lunarwing-weechat-adapter-${name}" <<CONFD
# Auto-generated by lunarwing-mt-admin.sh for tenant: $name
CONFD

  say "rendered OpenRC init scripts and conf.d for $name"
}

start_tenant_openrc() {
  local name="$1"
  rc-service "weechat-${name}" start
  rc-service "lunarwing-weechat-adapter-${name}" start
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
  rc-service "lunarwing-weechat-adapter-${name}" stop 2>/dev/null || true
  rc-service "weechat-${name}" stop 2>/dev/null || true
  say "OpenRC services stopped for $name"
}

uninstall_tenant_openrc() {
  local name="$1"
  for svc in "lunarwing-${name}" "xmpp-bridge-${name}" "lunarwing-proxy-${name}" "lunarwing-weechat-adapter-${name}" "weechat-${name}"; do
    rc-update del "$svc" default 2>/dev/null || true
    rm -f "/etc/init.d/$svc" "/etc/conf.d/$svc"
  done
  say "uninstalled OpenRC services for $name"
}

# ── Compound commands ────────────────────────────────────────────────────────

# WeeChat's ws_adapter.py needs the `aiohttp` Python package importable by the
# TENANT user's python3 (system-wide, or in that user's ~/.local — an --user
# install for a different account, e.g. the admin, is NOT visible). Non-fatal:
# the adapter is optional, so we only warn with how to fix it.
warn_if_adapter_deps_missing() {
  local name="$1"
  if ! command -v python3 >/dev/null 2>&1; then
    say "WARNING: python3 not found — the WeeChat adapter cannot run."
    return 0
  fi
  if sudo -u "$name" python3 -c 'import aiohttp' >/dev/null 2>&1; then
    return 0
  fi
  say ""
  say "WARNING: Python package 'aiohttp' is not importable by user '$name'."
  say "         lunarwing-weechat-adapter-${name} will exit on start until it is installed:"
  say "           system-wide (preferred): sudo pacman -S python-aiohttp"
  say "             (Debian: sudo apt install python3-aiohttp  ·  Fedora: sudo dnf install python3-aiohttp)"
  say "           per-tenant fallback:     sudo -u ${name} pip install --user --break-system-packages aiohttp"
  say ""
}

add_tenant() {
  local name="$1"
  local docker_group="${2:-false}"
  local xmpp_jid="${3:-$name@xmpp.localhost}"
  local xmpp_password="${4:-}"
  local tensorzero_url="${5:-$DEFAULT_TENSORZERO_URL}"
  local gotify_url="${6:-$DEFAULT_GOTIFY_URL}"
  local gotify_title="${7:-$DEFAULT_GOTIFY_TITLE}"
  local llm_api_key="${8:-}"

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

  warn_if_adapter_deps_missing "$name"

  clone_tenant_repo "$name"
  say ""

  say "--- Generating environment files ---"
  write_tenant_lunarwing_env "$name" "$xmpp_jid" "$xmpp_password" "$tensorzero_url" "$llm_api_key"
  write_tenant_bridge_env "$name" "$xmpp_jid" "$xmpp_password"
  write_tenant_proxy_env "$name" "$tensorzero_url"
  write_tenant_gotify_config "$name" "$gotify_url" "$gotify_title"
  ensure_external_worker_config "$name" "nanocode" "nanocode_wss"
  ensure_external_worker_config "$name" "pebble" "pebble_wss"
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
  say "  gateway:          $(ports_get "$name" gateway)"
  say "  http:             $(ports_get "$name" http)"
  say "  bridge:           $(ports_get "$name" bridge)"
  say "  postgres:         $(ports_get "$name" postgres)"
  say "  proxy:            $(ports_get "$name" proxy)"
  say "  weechat:          $(ports_get "$name" weechat)"
  say "  orchestrator:     $(ports_get "$name" orchestrator)"
  say "  nanocode_wss:     $(ports_get "$name" nanocode_wss)"
  say "  pebble_wss:       $(ports_get "$name" pebble_wss)"
  say "  weechat_adapter:  $(ports_get "$name" weechat_adapter)"
  say ""
  say "Next steps:"
  say "  sudo $0 build-tenant $name --with-wasm --with-nanocode"
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
  start_tenant_nanocode "$name"
  start_tenant_pebble "$name"

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

  stop_tenant_pebble "$name"
  stop_tenant_nanocode "$name"
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
  say "  gateway:          $(ports_get "$name" gateway)"
  say "  http:             $(ports_get "$name" http)"
  say "  bridge:           $(ports_get "$name" bridge)"
  say "  postgres:         $(ports_get "$name" postgres)"
  say "  proxy:            $(ports_get "$name" proxy)"
  say "  weechat:          $(ports_get "$name" weechat)"
  say "  orchestrator:     $(ports_get "$name" orchestrator)"
  say "  nanocode_wss:     $(ports_get "$name" nanocode_wss)"
  say "  pebble_wss:       $(ports_get "$name" pebble_wss)"
  say "  weechat_adapter:  $(ports_get "$name" weechat_adapter)"
  say ""

  ensure_container_runtime
  local container_name="lunarwing-pg-$name"
  if $CONTAINER_RT inspect -f '{{.State.Running}}' "$container_name" 2>/dev/null | grep -q true; then
    say "PostgreSQL: running ($container_name)"
  else
    say "PostgreSQL: stopped ($container_name)"
  fi

  local nanocode_container="lunarwing-nanocode-$name"
  if $CONTAINER_RT inspect -f '{{.State.Running}}' "$nanocode_container" 2>/dev/null | grep -q true; then
    say "Nanocode worker: running ($nanocode_container, WSS port $(ports_get "$name" nanocode_wss))"
  elif $CONTAINER_RT inspect "$nanocode_container" &>/dev/null; then
    say "Nanocode worker: stopped ($nanocode_container)"
  else
    say "Nanocode worker: not created"
  fi

  local pebble_container="lunarwing-pebble-$name"
  if $CONTAINER_RT inspect -f '{{.State.Running}}' "$pebble_container" 2>/dev/null | grep -q true; then
    say "Pebble worker: running ($pebble_container, WSS port $(ports_get "$name" pebble_wss))"
  elif $CONTAINER_RT inspect "$pebble_container" &>/dev/null; then
    say "Pebble worker: stopped ($pebble_container)"
  else
    say "Pebble worker: not created"
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

  printf '%-15s %-8s %-8s %-8s %-8s %-8s %-8s %-8s %-8s %-8s %-8s\n' \
    "TENANT" "GATEWAY" "HTTP" "BRIDGE" "PG" "PROXY" "WEECHAT" "WS_ADPT" "ORCH" "NANOCODE" "PEBBLE"
  printf '%-15s %-8s %-8s %-8s %-8s %-8s %-8s %-8s %-8s %-8s %-8s\n' \
    "------" "-------" "----" "------" "--" "-----" "-------" "-------" "----" "--------" "------"

  while IFS= read -r name; do
    printf '%-15s %-8s %-8s %-8s %-8s %-8s %-8s %-8s %-8s %-8s %-8s\n' \
      "$name" \
      "$(ports_get "$name" gateway)" \
      "$(ports_get "$name" http)" \
      "$(ports_get "$name" bridge)" \
      "$(ports_get "$name" postgres)" \
      "$(ports_get "$name" proxy)" \
      "$(ports_get "$name" weechat)" \
      "$(ports_get "$name" weechat_adapter)" \
      "$(ports_get "$name" orchestrator)" \
      "$(ports_get "$name" nanocode_wss)" \
      "$(ports_get "$name" pebble_wss)"
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
  _check "nanocode worker dir exists" test -d "$LUNARWING_ROOT/lunarcode4lunarwing"
  _check "nanocode worker Dockerfile exists" test -f "$LUNARWING_ROOT/lunarcode4lunarwing/Dockerfile"
  _check "pebble worker dir exists" test -d "$LUNARWING_ROOT/pebble4lunarwing"
  _check "pebble worker Dockerfile exists" test -f "$LUNARWING_ROOT/pebble4lunarwing/Dockerfile"

  # Check if worker images are built
  if command -v docker >/dev/null 2>&1; then
    _check "nanocode worker image exists" docker image inspect lunarwing-worker-nanocode:latest
    _check "pebble worker image exists" docker image inspect lunarwing-worker-pebble:latest
  elif command -v podman >/dev/null 2>&1; then
    _check "nanocode worker image exists" podman image inspect lunarwing-worker-nanocode:latest
    _check "pebble worker image exists" podman image inspect lunarwing-worker-pebble:latest
  fi

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
      local name="" docker_group="false" xmpp_jid="" xmpp_password="" tz_url="$DEFAULT_TENSORZERO_URL" gotify_url="$DEFAULT_GOTIFY_URL" gotify_title="$DEFAULT_GOTIFY_TITLE" llm_api_key=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --docker-group)    docker_group="true"; shift ;;
          --xmpp-jid)        xmpp_jid="$2"; shift 2 ;;
          --xmpp-password)   xmpp_password="$2"; shift 2 ;;
          --llm-api-key)     llm_api_key="$2"; shift 2 ;;
          --tensorzero-url)  tz_url="$2"; shift 2 ;;
          --gotify-url)      gotify_url="$2"; shift 2 ;;
          --gotify-title)    gotify_title="$2"; shift 2 ;;
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
      add_tenant "$name" "$docker_group" "$xmpp_jid" "$xmpp_password" "$tz_url" "$gotify_url" "$gotify_title" "$llm_api_key"
      ;;

    add-tenants)
      require_root
      local names_csv="" docker_group="false" xmpp_domain="xmpp.localhost" tz_url="$DEFAULT_TENSORZERO_URL" gotify_url="$DEFAULT_GOTIFY_URL" gotify_title="$DEFAULT_GOTIFY_TITLE" llm_api_key=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --docker-group)    docker_group="true"; shift ;;
          --xmpp-domain)     xmpp_domain="$2"; shift 2 ;;
          --llm-api-key)     llm_api_key="$2"; shift 2 ;;
          --tensorzero-url)  tz_url="$2"; shift 2 ;;
          --gotify-url)      gotify_url="$2"; shift 2 ;;
          --gotify-title)    gotify_title="$2"; shift 2 ;;
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
        add_tenant "$sname" "$docker_group" "${sname}@${xmpp_domain}" "" "$tz_url" "$gotify_url" "$gotify_title" "$llm_api_key"
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
      local name="" with_wasm="false" with_nanocode="false" with_pebble="false"
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --with-wasm)     with_wasm="true"; shift ;;
          --with-nanocode) with_nanocode="true"; shift ;;
          --with-pebble)   with_pebble="true"; shift ;;
          -*)              die "unknown flag: $1" ;;
          *)
            if [[ -z "$name" ]]; then name="$1"; shift
            else die "unexpected argument: $1"
            fi
            ;;
        esac
      done
      [[ -n "$name" ]] || die "usage: build-tenant <name> [--with-wasm] [--with-nanocode] [--with-pebble]"
      build_tenant "$(sanitize_name "$name")" "$with_wasm" "$with_nanocode" "$with_pebble"
      ;;

    build-all)
      require_root
      local with_wasm="false" with_nanocode="false" with_pebble="false"
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --with-wasm)     with_wasm="true"; shift ;;
          --with-nanocode) with_nanocode="true"; shift ;;
          --with-pebble)   with_pebble="true"; shift ;;
          -*)              die "unknown flag: $1" ;;
          *)               die "unexpected argument: $1" ;;
        esac
      done
      build_all "$with_wasm" "$with_nanocode" "$with_pebble"
      ;;

    build-nanocode-worker)
      require_root
      local no_cache="false"
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --no-cache) no_cache="true"; shift ;;
          -*)         die "unknown flag: $1" ;;
          *)          die "unexpected argument: $1" ;;
        esac
      done
      build_nanocode_worker "$no_cache"
      ;;

    build-pebble-worker)
      require_root
      local no_cache="false"
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --no-cache) no_cache="true"; shift ;;
          -*)         die "unknown flag: $1" ;;
          *)          die "unexpected argument: $1" ;;
        esac
      done
      build_pebble_worker "$no_cache"
      ;;

    install-wasm)
      require_root
      [[ -n "${1:-}" ]] || die "usage: install-wasm <name>"
      install_wasm_tenant "$1"
      ;;

    install-wasm-all)
      require_root
      install_wasm_all
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

    configure-gotify)
      require_root
      local name="${1:-}" gotify_url="${2:-}" gotify_title="${3:-}"
      [[ -n "$name" && -n "$gotify_url" ]] || die "usage: configure-gotify <name> <url> [title]"
      name="$(sanitize_name "$name")"
      tenant_exists_in_registry "$name" || die "tenant '$name' not found in registry"
      write_tenant_gotify_config "$name" "$gotify_url" "$gotify_title"
      configure_gotify_capabilities "$name" "$gotify_url"
      say "Gotify configured for tenant '$name': $gotify_url"
      ;;

    configure-pebble)
      require_root
      local name="" nanogpt_key="" pebble_model=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --nanogpt-api-key) nanogpt_key="$2"; shift 2 ;;
          --model)           pebble_model="$2"; shift 2 ;;
          -*)                die "unknown flag: $1" ;;
          *)
            if [[ -z "$name" ]]; then name="$1"; shift
            else die "unexpected argument: $1"
            fi
            ;;
        esac
      done
      [[ -n "$name" ]] || die "usage: configure-pebble <name> --nanogpt-api-key <key> [--model <model>]"
      [[ -n "$nanogpt_key" ]] || die "configure-pebble requires --nanogpt-api-key"
      ports_registry_init
      configure_pebble "$(sanitize_name "$name")" "$nanogpt_key" "$pebble_model"
      ;;

    patch-env)
      require_root
      local name="${1:-}"
      [[ -n "$name" ]] || die "usage: patch-env <name>"
      ports_registry_init
      patch_tenant_env "$name"
      ;;

    patch-env-all)
      require_root
      ports_registry_init
      local names
      names="$(all_tenant_names)"
      [[ -n "$names" ]] || { say "no tenants registered"; exit 0; }
      while IFS= read -r name; do
        patch_tenant_env "$name"
      done <<< "$names"
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

# Only dispatch when executed directly; allows sourcing for tests/inspection.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
