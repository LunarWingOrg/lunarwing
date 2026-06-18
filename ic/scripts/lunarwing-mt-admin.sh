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
# Fleet-wide default for the daemon's LLM endpoint (LLM_BASE_URL). Empty = fall
# back to each tenant's local TensorZero proxy. Set this (or --llm-base-url per
# tenant) to point new tenants straight at a gateway as the proxy is phased out.
DEFAULT_LLM_BASE_URL="${LUNARWING_MT_LLM_BASE_URL:-}"
DEFAULT_GOTIFY_URL="${LUNARWING_MT_GOTIFY_URL:-}"
DEFAULT_GOTIFY_TITLE="${LUNARWING_MT_GOTIFY_TITLE:-}"

# ── Health-check / self-heal pipeline (host-global) ──────────────────────────
# The infra health-check + self-heal pipeline auto-discovers every tenant from
# /etc/init.d and the port registry, so ONE host-global scheduled run covers all
# current and future tenants. Enabled by default for new tenants on OpenRC; opt
# out per add-tenant with --no-health, or fleet-wide with
# LUNARWING_MT_HEALTH_ENABLED=false.
DEFAULT_HEALTH_ENABLED="${LUNARWING_MT_HEALTH_ENABLED:-true}"
HEALTH_INTERVAL_MIN="${LUNARWING_MT_HEALTH_INTERVAL_MIN:-15}"
HEALTH_BASE_DIR="${LUNARWING_MT_HEALTH_BASE_DIR:-/var/lib/lunarwing-health}"
HEALTH_SRC_DIR="$LUNARWING_ROOT/ic-infrastructure-health-check"
HEALTH_LIB_DIR="/usr/local/lib/lunarwing-health"
HEALTH_ENV_FILE="/etc/lunarwing/health.env"
HEALTH_LAUNCHER="/usr/local/sbin/lunarwing-mt-health"
# Gotify for self-heal escalations (token must NOT be committed — supply via env;
# it is written only to $HEALTH_ENV_FILE, mode 0600).
HEALTH_GOTIFY_URL="${LUNARWING_MT_GOTIFY_URL:-}"
HEALTH_GOTIFY_TOKEN="${LUNARWING_MT_GOTIFY_TOKEN:-}"
HEALTH_OPT_OUT=false   # set true by --no-health

# ── Per-tenant PostgreSQL image ──────────────────────────────────────────────
# Fully-qualified (registry host included) so rootless podman resolves it WITHOUT
# depending on the host's unqualified-search-registries: docker silently defaults
# short names to docker.io, but rootless podman errors ("short-name ... did not
# resolve to an alias and no unqualified-search registries are defined"). Override
# for a local mirror via LUNARWING_MT_PG_IMAGE.
PG_IMAGE="${LUNARWING_MT_PG_IMAGE:-docker.io/pgvector/pgvector:pg16}"

# ── Per-tenant PostgreSQL backups ────────────────────────────────────────────
# pg_dump each tenant's DB (custom -Fc format) to $BACKUP_DIR/<tenant>/. Keep the
# most recent $BACKUP_KEEP dumps per tenant (0 = keep all).
BACKUP_DIR="${LUNARWING_MT_BACKUP_DIR:-/var/lib/lunarwing-backups}"
BACKUP_KEEP="${LUNARWING_MT_BACKUP_KEEP:-7}"

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
tenant_quadlet_dir() { printf '%s/.config/containers/systemd' "$(tenant_home "$1")"; }
tenant_state_dir() { printf '%s/state' "$(tenant_lw_root "$1")"; }
tenant_log_dir() { printf '%s/logs' "$(tenant_lw_root "$1")"; }
tenant_run_dir() { printf '%s/run' "$(tenant_lw_root "$1")"; }

# Per-tenant PostgreSQL password. The source of truth is a 0600, tenant-owned
# secret file, generated once (hex → URL-safe inside DATABASE_URL) and reused so
# it stays STABLE across restarts/reconfigures — POSTGRES_PASSWORD only
# initialises an EMPTY datadir, so the value must not drift after first init.
# Migration-safe: if a tenant was already provisioned (its lunarwing.env carries a
# DATABASE_URL password), that value is preserved so an already-initialised DB
# keeps working; only brand-new tenants get a fresh random password. Use
# `rotate-pg-password` to deliberately move an existing tenant onto a random one.
# Never logged (repo rule).
tenant_pg_password() {
  local name="$1" f envf existing pw
  f="$(tenant_env_dir "$name")/pg.secret"
  if [[ -s "$f" ]]; then
    cat "$f"   # callers use $(...), which strips the trailing newline
    return 0
  fi
  envf="$(tenant_env_dir "$name")/lunarwing.env"
  if [[ -f "$envf" ]]; then
    existing="$(sed -n 's#^DATABASE_URL=postgres://lunarwing:\([^@]*\)@.*#\1#p' "$envf" | head -1)"
  fi
  if [[ -n "${existing:-}" ]]; then
    pw="$existing"                       # preserve an already-initialised DB's password
  else
    pw="$(generate_token | cut -c1-32)"  # fresh tenant → random 128-bit hex
  fi
  mkdir -p "$(dirname "$f")"
  ( umask 077; printf '%s\n' "$pw" > "$f" )
  chown "$name:$name" "$f" 2>/dev/null || true
  printf '%s\n' "$pw"
}

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
    --llm-base-url <url>           LLM endpoint the daemon dials (LLM_BASE_URL).
                                   Default: this tenant's local TensorZero proxy
    --tensorzero-url <url>         Upstream TensorZero URL
    --gotify-url <url>             Custom Gotify server URL (e.g. https://gotify.example.com)
    --no-health                    Don't enable the host-global health/self-heal pipeline

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
  render-units <name>             Re-render a tenant's service units from the current
                                  generator (no restart; applies init-script changes)
  rotate-pg-password <name>       Generate a new random PG password (ALTER ROLE + env update)

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

  backup-tenant <name>             pg_dump a tenant's DB (custom format) to
                                   $LUNARWING_MT_BACKUP_DIR/<name>/
  backup-all                       Back up every registered tenant
  list-backups [name]              List existing backups (all tenants or one)
  restore-tenant <name> <file>     Restore a tenant DB from a dump (DESTRUCTIVE)
    --yes                          Required: confirm the DROP+recreate restore
                                   (stop the tenant daemon first)

Environment:
  LUNARWING_SERVICE_MANAGER        Override: systemd or openrc
  LUNARWING_CONTAINER_RUNTIME      Override: docker or podman
  LUNARWING_MT_PROFILE             Build profile: release (default) or debug
  LUNARWING_MT_SOURCE_REPO         Path to source repo to clone from
  LUNARWING_MT_TENSORZERO_URL      Default upstream TensorZero URL
  LUNARWING_MT_LLM_BASE_URL        Fleet-wide default LLM_BASE_URL for new tenants
                                   (empty = each tenant's local TensorZero proxy)
  LUNARWING_MT_GOTIFY_URL          Default Gotify server URL for new tenants
  LUNARWING_MT_GOTIFY_TITLE        Default Gotify notification title for new tenants
  LUNARWING_MT_BACKUP_DIR          Backup directory (default /var/lib/lunarwing-backups)
  LUNARWING_MT_BACKUP_KEEP         Keep last N dumps per tenant (default 7; 0 = keep all)
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
MT_ROOTLESS=""
ensure_container_runtime() {
  [[ -n "$CONTAINER_RT" ]] || CONTAINER_RT="$(detect_container_runtime)"
  if [[ -z "$MT_ROOTLESS" ]]; then
    # Rootless-per-tenant is the default for podman (no daemon; each tenant owns
    # its containers under ~/.local/share/containers). Docker keeps the legacy
    # rootful-as-root model (it has a daemon). Override via LUNARWING_MT_ROOTLESS.
    if [[ -n "${LUNARWING_MT_ROOTLESS:-}" ]]; then
      MT_ROOTLESS="${LUNARWING_MT_ROOTLESS}"
    elif [[ "$CONTAINER_RT" == "podman" ]]; then
      MT_ROOTLESS="true"
    else
      MT_ROOTLESS="false"
    fi
  fi
}

# True if the active runtime is podman new enough for the Quadlet .container
# features we emit. Floor is >= 4.6: Quadlet itself shipped in 4.4, but the
# Health* keys render_pg_quadlet uses first exist in 4.5 (Quadlet hard-errors
# and skips the whole unit on an unknown key), and 4.6 is the conservative
# stable baseline. Gates the systemd rootless container-supervision path against
# the imperative `podman run` fallback. Result is memoised in QUADLET_OK.
QUADLET_OK=""
podman_supports_quadlet() {
  ensure_container_runtime
  [[ "$CONTAINER_RT" == "podman" ]] || return 1
  if [[ -z "$QUADLET_OK" ]]; then
    local ver major minor
    ver="$(podman version --format '{{.Client.Version}}' 2>/dev/null || true)"
    [[ -n "$ver" ]] || ver="$(podman --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1 || true)"
    major="${ver%%.*}"
    minor="${ver#*.}"; minor="${minor%%.*}"
    if [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]] \
       && { [[ "$major" -gt 4 ]] || { [[ "$major" -eq 4 ]] && [[ "$minor" -ge 6 ]]; }; }; then
      QUADLET_OK="yes"
    else
      QUADLET_OK="no"
    fi
  fi
  [[ "$QUADLET_OK" == "yes" ]]
}

# Run the container runtime for a TENANT's containers. When rootless (podman),
# execute as the tenant user against their rootless store + runtime dir; when
# rootful (docker), run as root unchanged. Every per-tenant pg/worker container
# operation MUST go through this so inspect/start/stop/exec/rm hit the SAME store
# that owns the container — root and rootless podman are separate universes.
_ctr() {
  local name="$1"; shift
  ensure_container_runtime
  if [[ "$MT_ROOTLESS" == "true" ]]; then
    local uid home
    uid="$(id -u "$name")" || die "cannot resolve uid for tenant '$name'"
    home="$(getent passwd "$name" | cut -d: -f6)"
    # Run from a tenant-traversable CWD (F10): `sudo -u` keeps the caller's cwd, so
    # when mt-admin runs from an admin dir the tenant can't enter (e.g. ~dame, 0700)
    # `sudo -u` aborts with "cannot chdir ... Permission denied" BEFORE the runtime
    # runs — which silently broke the rootless pg readiness gate (it always timed
    # out). `/` is always traversable; no _ctr call passes a cwd-relative path. exec
    # preserves the exit code and the stdin/stdout redirects used by exec/pg_dump.
    ( cd / && exec sudo -u "$name" env HOME="$home" XDG_RUNTIME_DIR="/run/user/$uid" "$CONTAINER_RT" "$@" )
  else
    "$CONTAINER_RT" "$@"
  fi
}

# Ensure a worker image is available to whoever will run the tenant's container.
# Rootful (docker): the shared root store already has it — just verify presence.
# Rootless (podman): the image lives in the tenant's OWN store; if absent, copy it
# from the admin (root) store via save|load (per-tenant, ~minutes for large images;
# a shared additionalimagestore would avoid the N copies but isn't wired yet).
# Returns non-zero if the image can't be made available (caller should skip).
_ensure_tenant_image() {
  local name="$1" image="$2"
  if _ctr "$name" image inspect "$image" &>/dev/null; then
    return 0
  fi
  if [[ "$MT_ROOTLESS" != "true" ]]; then
    return 1   # rootful + not built yet -> caller skips (build first)
  fi
  if ! "$CONTAINER_RT" image inspect "$image" &>/dev/null; then
    return 1   # rootless, but the admin store has no source image to copy
  fi
  say "distributing image $image into ${name}'s rootless store (save|load — minutes for large images) ..."
  if "$CONTAINER_RT" save "$image" | _ctr "$name" load >/dev/null 2>&1; then
    say "image $image available in ${name}'s store"
    return 0
  fi
  say "WARNING: failed to load $image into ${name}'s store"
  return 1
}

# Render a dedicated OpenRC unit for a tenant's external worker (nanocode/pebble),
# modeled on the lunarwing-pg-<t> unit. Health-aware status() checks the worker's
# /health endpoint (curl is present in both worker images) so the host self-heal
# pipeline — which auto-discovers /etc/init.d/lunarwing-* units — can detect and
# remediate a crashed OR hung worker, and so it survives reboot. OpenRC only.
render_worker_openrc_unit() {
  local name="$1" worker="$2" health_port="${3:-8443}"
  ensure_container_runtime
  local runtime_bin="" container="lunarwing-${worker}-${name}" uid home
  [[ -n "${CONTAINER_RT:-}" ]] && runtime_bin="$(command -v "$CONTAINER_RT" 2>/dev/null || true)"
  uid="$(id -u "$name" 2>/dev/null || echo "")"
  home="$(tenant_home "$name")"

  cat >"/etc/init.d/${container}" <<INITEOF
#!/sbin/openrc-run

description="LunarWing ${worker} worker ($name)"

: "\${wk_runtime:=$runtime_bin}"
: "\${wk_container:=$container}"
: "\${wk_rootless:=$MT_ROOTLESS}"
: "\${wk_user:=$name}"
: "\${wk_home:=$home}"
: "\${wk_uid:=$uid}"
: "\${wk_health_port:=$health_port}"
: "\${wk_wait:=60}"

depend() {
    need net localmount
    after firewall lunarwing-${name}
}

# Run the container runtime as the owning user (rootless) or root (rootful).
_wk() {
    if [ "\${wk_rootless}" = "true" ]; then
        sudo -u "\${wk_user}" env HOME="\${wk_home}" XDG_RUNTIME_DIR="/run/user/\${wk_uid}" "\${wk_runtime}" "\$@"
    else
        "\${wk_runtime}" "\$@"
    fi
}

# Healthy = container running AND its internal /health endpoint answers.
_wk_healthy() {
    [ "\$(_wk inspect -f '{{.State.Running}}' "\${wk_container}" 2>/dev/null)" = "true" ] || return 1
    _wk exec "\${wk_container}" curl -sf -o /dev/null --max-time 3 "http://127.0.0.1:\${wk_health_port}/health" 2>/dev/null
}

start() {
    [ -n "\${wk_runtime}" ] && [ -x "\${wk_runtime}" ] || { ewarn "no container runtime; skipping ${worker} for $name"; return 0; }
    ebegin "Starting ${worker} worker (\${wk_container})"
    if [ "\${wk_rootless}" = "true" ]; then
        checkpath -d -m 0700 -o "\${wk_user}:\${wk_user}" "/run/user/\${wk_uid}"
    fi
    _wk start "\${wk_container}" >/dev/null 2>&1 || { eend 1 "container start failed"; return 1; }
    _w=0
    while ! _wk_healthy; do
        _w=\$((_w + 1))
        [ "\$_w" -lt "\${wk_wait}" ] || { eend 1 "${worker} worker not healthy after \${wk_wait}s"; return 1; }
        sleep 1
    done
    eend 0
}

stop() {
    [ -n "\${wk_runtime}" ] && [ -x "\${wk_runtime}" ] || return 0
    ebegin "Stopping ${worker} worker (\${wk_container})"
    _wk stop --time 30 "\${wk_container}" >/dev/null 2>&1
    eend 0
}

status() {
    # Standard OpenRC started/stopped wording so health-openrc.sh classifies it.
    if _wk_healthy; then
        einfo "\${wk_container}: started"; return 0
    fi
    einfo "\${wk_container}: stopped"; return 3
}
INITEOF
  chmod 0755 "/etc/init.d/${container}"
}

# Promote a (rootless) worker container to a dedicated OpenRC unit so it is
# health-monitored, self-healed, and boot-persistent. No-op unless OpenRC.
_register_worker_unit() {
  local name="$1" worker="$2"
  ensure_init_system
  [[ "$INIT_SYSTEM" == "openrc" ]] || return 0
  render_worker_openrc_unit "$name" "$worker"
  rc-update add "lunarwing-${worker}-${name}" default >/dev/null 2>&1 || true
  rc-service "lunarwing-${worker}-${name}" start >/dev/null 2>&1 || true
  say "registered OpenRC unit lunarwing-${worker}-${name} (health-monitored, boot-persistent)"
}

# Tear down a worker's OpenRC unit (boot-disable + remove the init script).
_deregister_worker_unit() {
  local name="$1" worker="$2"
  ensure_init_system
  [[ "$INIT_SYSTEM" == "openrc" ]] || return 0
  [[ -f "/etc/init.d/lunarwing-${worker}-${name}" ]] || return 0
  rc-service "lunarwing-${worker}-${name}" stop >/dev/null 2>&1 || true
  rc-update del "lunarwing-${worker}-${name}" default >/dev/null 2>&1 || true
  rm -f "/etc/init.d/lunarwing-${worker}-${name}" "/etc/conf.d/lunarwing-${worker}-${name}"
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

  # Resumable (F4): if this tenant already has a block, reuse it (echo its
  # base_port) instead of dying — so re-running add-tenant after a mid-flow failure
  # resumes cleanly (clone/env/pg/render/pipeline are idempotent, and
  # tenant_pg_password is stable). Use `remove-tenant` to truly start over.
  local existing
  existing="$(jq -r ".tenants[\"$name\"].base_port // empty" "$PORTS_REGISTRY" 2>/dev/null || true)"
  if [[ -n "$existing" ]]; then
    say "tenant '$name' already has ports allocated (base $existing); reusing for resume" >&2
    printf '%s' "$existing"
    return 0
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

# Provision rootless-podman prerequisites for a tenant user. Idempotent: skips
# anything already present, never overlaps existing subordinate-id ranges.
ensure_rootless_prereqs() {
  local name="$1" uid home start
  ensure_container_runtime
  uid="$(id -u "$name")" || die "cannot resolve uid for tenant '$name'"
  home="$(getent passwd "$name" | cut -d: -f6)"

  # Subordinate uid/gid ranges for the user namespace. useradd may pre-allocate
  # these (via /etc/login.defs); only add when absent, and append AFTER the
  # current max so a new tenant never overlaps an existing range (or eris).
  if ! grep -q "^${name}:" /etc/subuid 2>/dev/null; then
    start="$(awk -F: 'BEGIN{m=100000}{e=$2+$3; if(e>m)m=e}END{print m}' /etc/subuid 2>/dev/null)"
    usermod --add-subuids "${start}-$((start + 65535))" "$name" \
      || die "failed to allocate subuid range for $name (shadow with subid support required)"
    say "allocated subuid range ${start}-$((start + 65535)) for $name"
  fi
  if ! grep -q "^${name}:" /etc/subgid 2>/dev/null; then
    start="$(awk -F: 'BEGIN{m=100000}{e=$2+$3; if(e>m)m=e}END{print m}' /etc/subgid 2>/dev/null)"
    usermod --add-subgids "${start}-$((start + 65535))" "$name" \
      || die "failed to allocate subgid range for $name"
    say "allocated subgid range ${start}-$((start + 65535)) for $name"
  fi

  # Runtime dir (XDG_RUNTIME_DIR). linger (enabled in create_tenant_user)
  # recreates it at boot; create it now for immediate use. tmpfs, 0700, owned.
  install -d -m 0700 -o "$name" -g "$name" "/run/user/$uid"

  # A freshly (re)created tenant may REUSE a uid whose previous holder left
  # rootless-podman runtime state behind in /run/user/$uid: that dir is created by
  # `install -d` above (not by a login session), so logind/elogind never reaps it
  # when the prior tenant is removed (see remove_tenant_user). A stale libpod
  # pause.pid then makes EVERY podman call — including the `system migrate` just
  # below, and the first pg container start in add-tenant — fail with
  # "cannot re-exec process to join the existing user namespace". Clear it so podman
  # spawns a fresh pause process — but KEEP it when it points to a live process
  # actually OWNED BY THIS tenant (its own running pause process on the "user
  # already exists" resume path, where ensure_rootless_prereqs re-runs from
  # create_tenant_user against a live tenant). Everything else is stale: an
  # empty/corrupt file, a dead pid, OR a pid since REUSED by another user's process
  # (host-ns owner != tenant uid) — a bare `kill -0` (we run as root) would read
  # that reused pid as "alive" and wrongly keep the stale file, leaving the O1 fault
  # unfixed. The tenant's pause process (catatonit) runs as the tenant uid in the
  # host ns, so /proc/<pid> ownership distinguishes it reliably.
  local pause_pid pause_owner
  pause_pid="/run/user/$uid/libpod/tmp/pause.pid"
  if [[ -f "$pause_pid" ]]; then
    pause_owner="$(cat "$pause_pid" 2>/dev/null || true)"
    if [[ -z "$pause_owner" ]] \
       || ! kill -0 "$pause_owner" 2>/dev/null \
       || [[ "$(stat -c %u "/proc/$pause_owner" 2>/dev/null || echo -1)" != "$uid" ]]; then
      rm -f "$pause_pid" 2>/dev/null || true
    fi
  fi

  # One-time rootless storage init (safe to re-run after subid changes).
  sudo -u "$name" env HOME="$home" XDG_RUNTIME_DIR="/run/user/$uid" \
    "$CONTAINER_RT" system migrate >/dev/null 2>&1 || true
  say "rootless prerequisites ready for $name (subuid/subgid, /run/user/$uid, storage)"
}

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

  # Rootless-podman prerequisites for the tenant (subuid/subgid, runtime dir,
  # storage). No-op when rootful (docker).
  ensure_container_runtime
  if [[ "$MT_ROOTLESS" == "true" ]]; then
    ensure_rootless_prereqs "$name"
  fi

  # Persist a per-user runtime manager so /run/user/<uid> survives reboot. Works
  # on both systemd-logind and elogind (OpenRC) — capability-gated, not
  # systemd-only, so rootless podman keeps a runtime dir across reboots.
  if command -v loginctl >/dev/null 2>&1; then
    if loginctl enable-linger "$name" 2>/dev/null; then
      say "enabled linger for $name"
    fi
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

  # Capture the uid BEFORE userdel removes the passwd entry — needed below to
  # reap the rootless runtime dir (/run/user/<uid>) once the account is gone.
  local _uid; _uid="$(id -u "$name" 2>/dev/null || true)"

  # Stop the per-user runtime manager so it doesn't keep/recreate /run/user/<uid>.
  # loginctl is provided by systemd-logind AND elogind (OpenRC), so gate on the
  # binary, not the init system — otherwise linger is never disabled on OpenRC.
  if command -v loginctl >/dev/null 2>&1; then
    loginctl disable-linger "$name" 2>/dev/null || true
  fi

  if [[ "$purge" == "true" ]]; then
    # Tear the user session down BEFORE userdel. Running userdel immediately after
    # disable-linger races the still-stopping user@<uid>.service and fails with
    # "user busy" (exit 8); previously that error was swallowed (2>/dev/null||true)
    # and "removed user" printed anyway, leaving orphaned accounts/home dirs.
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
      loginctl terminate-user "$name" 2>/dev/null || true
      if [[ -n "$_uid" ]]; then
        local _w=0
        while [[ -d "/run/user/$_uid" ]] && (( _w < 20 )); do sleep 0.5; _w=$((_w + 1)); done
      fi
    fi
    pkill -KILL -u "$name" 2>/dev/null || true
    # `userdel -r` prints a benign "mail spool not found" warning but still exits 0;
    # a real failure (user busy) exits nonzero — surface it instead of hiding it.
    if userdel -r "$name" 2>/dev/null; then
      say "removed user and home directory: $name"
    elif ! getent passwd "$name" >/dev/null 2>&1; then
      # Account gone but userdel exited nonzero (e.g. exit 12: home removal failed
      # on a busy mount / immutable file). Don't overclaim the home dir was removed.
      say "user '$name' account removed (userdel -r exited nonzero — home dir may persist; verify $(tenant_home "$name"))"
    else
      say "WARNING: failed to remove user '$name' (still present); remove manually: userdel -r $name"
    fi

    # O1 teardown half: /run/user/<uid> is created by `install -d` in
    # ensure_rootless_prereqs (not by a login session), so logind/elogind never
    # reaps it on disable-linger/terminate-user. Left behind, its stale libpod
    # pause.pid breaks the NEXT tenant that REUSES this uid. Remove it explicitly
    # once the account is gone. Guard on a real tenant uid (>=1000) so we never
    # touch root's or a system user's runtime dir.
    if [[ -n "$_uid" ]] && (( _uid >= 1000 )) \
       && ! getent passwd "$name" >/dev/null 2>&1 \
       && ! getent passwd "$_uid" >/dev/null 2>&1 \
       && [[ -d "/run/user/$_uid" ]]; then
      rm -rf "/run/user/$_uid" 2>/dev/null || true
      if [[ -d "/run/user/$_uid" ]]; then
        say "WARNING: could not fully remove rootless runtime dir /run/user/$_uid (busy mounts?); remove manually once released" >&2
      else
        say "reaped stale rootless runtime dir /run/user/$_uid"
      fi
    fi
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
    # --network=host (F8): rootless/rootful podman's default build network can't
    # reach the internet for RUN steps (apt) on hosts where the bridge/pasta path
    # is broken or IPv6 is preferred-but-unrouted; the host netns has working IPv4.
    # --format docker (O4): podman defaults to OCI, which drops the Dockerfile
    # HEALTHCHECK ("not supported for OCI image format"); build docker-format so the
    # baked healthcheck survives (harmless for the OpenRC init-unit probe, correct
    # if the image is ever run directly / under a healthcheck-honouring runtime).
    podman build $cache_flag --network=host --format docker -t lunarwing-worker-nanocode:latest "$nanocode_dir" \
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
    # --network=host (F8): see build_nanocode_worker — podman build's default network
    # can't reach the internet for RUN steps on this host; the host netns has IPv4.
    # --format docker (O4): preserve the Dockerfile HEALTHCHECK (podman OCI drops it).
    podman build $cache_flag --network=host --format docker -t lunarwing-worker-pebble:latest -f "$pebble_dir/Dockerfile" "$LUNARWING_ROOT" \
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

# Echo the existing VALUE of KEY from a tenant env file (empty if file/key absent).
# Used to PRESERVE secrets across re-runs so re-provisioning never rotates them.
_env_existing() {  # <env_file> <KEY>
  [[ -f "$1" ]] || return 0
  sed -n "s/^$2=//p" "$1" | head -1
}

write_tenant_lunarwing_env() {
  local name="$1"
  local xmpp_jid="${2:-$name@xmpp.localhost}"
  local xmpp_password="${3:-}"   # resolved below (preserve an existing one on re-run)
  local tensorzero_url="${4:-$DEFAULT_TENSORZERO_URL}"
  local llm_api_key="${5:-}"
  local llm_base_url="${6:-}"

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

  # Idempotent on re-run (F4-A/F4-B): PRESERVE existing secrets when lunarwing.env
  # already exists. Regenerating SECRETS_MASTER_KEY would permanently orphan the
  # tenant's encrypted DB secrets (it is the AES-256-GCM vault key); rotating the
  # tokens would break live clients/workers; minting a fresh XMPP_PASSWORD would
  # break the already-registered XMPP account. Generate fresh ONLY on first write.
  local gateway_token bridge_token relay_password secrets_key webhook_secret pg_password
  gateway_token="$(_env_existing "$path" GATEWAY_AUTH_TOKEN)";   gateway_token="${gateway_token:-$(generate_token)}"
  bridge_token="$(_env_existing "$path" XMPP_BRIDGE_TOKEN)";     bridge_token="${bridge_token:-$(generate_token | cut -c1-32)}"
  relay_password="$(_env_existing "$path" RELAY_PASSWORD)";      relay_password="${relay_password:-$(generate_token | cut -c1-32)}"
  secrets_key="$(_env_existing "$path" SECRETS_MASTER_KEY)";     secrets_key="${secrets_key:-$(generate_token)}"
  webhook_secret="$(_env_existing "$path" HTTP_WEBHOOK_SECRET)"; webhook_secret="${webhook_secret:-$(generate_token)}"
  # XMPP password: an explicit --xmpp-password wins; else preserve an existing one;
  # else mint a fresh one (first-time provision).
  [[ -n "$xmpp_password" ]] || { xmpp_password="$(_env_existing "$path" XMPP_PASSWORD)"; xmpp_password="${xmpp_password:-$(generate_token | cut -c1-32)}"; }
  # Stable + migration-safe; resolved before the heredoc so it can read an
  # existing DATABASE_URL (preserving an already-initialised DB's password).
  pg_password="$(tenant_pg_password "$name")"

  # LLM endpoint the daemon's OpenAI-compatible client dials. Defaults to this
  # tenant's local TensorZero proxy; an explicit value (from --llm-base-url or
  # LUNARWING_MT_LLM_BASE_URL) overrides it — e.g. to point straight at a shared
  # gateway or upstream OpenAI-compatible endpoint as the proxy is phased out.
  local llm_base_url_effective="${llm_base_url:-http://127.0.0.1:${proxy_port}/v1}"

  (
    umask 077
    cat >"$path" <<ENVEOF
LUNARWING_BASE_DIR=$state_dir
IRONCLAW_BASE_DIR=$state_dir
LUNARWING_SOCKET=$run_dir/lunarwing.sock
IRONCLAW_SOCKET=$run_dir/lunarwing.sock

# Database
DATABASE_BACKEND=postgres
DATABASE_URL=postgres://lunarwing:${pg_password}@127.0.0.1:${pg_port}/lunarwing
DATABASE_SSLMODE=disable
PGSSLMODE=disable

# LLM — OpenAI-compatible endpoint (defaults to the local TensorZero proxy)
LLM_BACKEND=openai_compatible
LLM_BASE_URL=${llm_base_url_effective}
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

# HTTP webhook (bound to localhost only; secret-protected)
HTTP_HOST=127.0.0.1
HTTP_PORT=$http_port
HTTP_WEBHOOK_SECRET=$webhook_secret

# Orchestrator (sandbox container callback)
ORCHESTRATOR_PORT=$orchestrator_port

# Nanocode worker (WebSocket port for agent communication)
NANOCODE_WSS_PORT=$nanocode_wss_port

# Pebble worker (WebSocket port for agent communication)
PEBBLE_WSS_PORT=$pebble_wss_port

# WeeChat relay + adapter
# RELAY_URL / WS_ADAPTER_URL are full URLs consumed by the in-process WASM
# channel (via the capabilities 'env' source). ADAPTER_PORT/WEECHAT_ADAPTER_PORT
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
  if _ctr "$name" inspect "$container_name" &>/dev/null 2>&1; then
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

  # Ensure the image is available to whoever runs the container (rootless: load it
  # into the tenant's store via save|load; rootful: must already be built in root).
  if ! _ensure_tenant_image "$name" lunarwing-worker-nanocode:latest; then
    say "nanocode worker image not available; run 'build-nanocode-worker' first (skipping)"
    return 0
  fi

  # systemd + rootless podman: Quadlet .container owns the lifecycle (the unit's
  # [Container] spec creates+runs it), so skip the imperative `_ctr run` below.
  ensure_init_system
  if [[ "$INIT_SYSTEM" == "systemd" && "$MT_ROOTLESS" == "true" ]] && podman_supports_quadlet; then
    _wait_user_manager "$name"
    render_worker_quadlet "$name" nanocode 8443
    _systemctl_user "$name" daemon-reload 2>/dev/null || true
    if _systemctl_user "$name" start "lunarwing-nanocode-${name}.service" >/dev/null 2>&1; then
      say "nanocode worker ready via quadlet (lunarwing-nanocode-${name}.service, WSS port $wss_port)"
    else
      say "WARNING: lunarwing-nanocode-${name}.service failed to start" >&2
      _systemctl_user "$name" status "lunarwing-nanocode-${name}.service" --no-pager >&2 || true
    fi
    return 0
  fi

  if _ctr "$name" inspect "$container_name" &>/dev/null; then
    if _ctr "$name" inspect -f '{{.State.Running}}' "$container_name" 2>/dev/null | grep -q true; then
      say "nanocode worker already running ($container_name, WSS port $wss_port)"
    else
      say "starting existing nanocode worker container $container_name"
      _ctr "$name" start "$container_name" >/dev/null
    fi
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

    # HEALTH_PORT=8443 matches the image's baked HEALTHCHECK (curl
    # 127.0.0.1:8443/health, served by health_server.py). The probe runs inside
    # the container's network namespace, so this needs no -p publish and never
    # conflicts across tenants; HEALTH_PORT=0 left the probe unreachable and the
    # container stuck "unhealthy" even though the WS bridge was fine.
    local -a restart_arg=()
    [[ "$MT_ROOTLESS" == "true" ]] || restart_arg=(--restart unless-stopped)
    _ctr "$name" run -d \
      --name "$container_name" \
      -e LUNARWING_WORKER_ID="worker-nanocode-${name}" \
      -e WS_PORT="$wss_port" \
      -e HEALTH_PORT="8443" \
      -e NANOCODE_MODE=websocket \
      -e WS_ROLE=server \
      -e WS_BIND_HOST=0.0.0.0 \
      -e WS_PATH=/ws/agent \
      "${env_flags[@]}" \
      -p "127.0.0.1:${wss_port}:${wss_port}" \
      -v "$workspace_dir:/workspace:z" \
      "${restart_arg[@]}" \
      lunarwing-worker-nanocode:latest \
      --mode websocket >/dev/null
  fi

  _register_worker_unit "$name" nanocode
  say "nanocode worker ready ($container_name, WSS port $wss_port)"
}

stop_tenant_nanocode() {
  local name="$1"
  ensure_container_runtime

  local container_name="lunarwing-nanocode-$name"
  ensure_init_system
  if [[ "$INIT_SYSTEM" == "openrc" && -f "/etc/init.d/${container_name}" ]]; then
    rc-service "$container_name" stop >/dev/null 2>&1 || true
    say "nanocode worker stopped ($container_name)"
  elif _ctr "$name" inspect "$container_name" &>/dev/null; then
    _ctr "$name" stop "$container_name" >/dev/null 2>&1 || true
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

  if ! _ensure_tenant_image "$name" lunarwing-worker-pebble:latest; then
    say "pebble worker image not available; run 'build-pebble-worker' first (skipping)"
    return 0
  fi

  # systemd + rootless podman: Quadlet .container owns the lifecycle (the unit's
  # [Container] spec creates+runs it), so skip the imperative `_ctr run` below.
  ensure_init_system
  if [[ "$INIT_SYSTEM" == "systemd" && "$MT_ROOTLESS" == "true" ]] && podman_supports_quadlet; then
    _wait_user_manager "$name"
    render_worker_quadlet "$name" pebble 8443
    _systemctl_user "$name" daemon-reload 2>/dev/null || true
    if _systemctl_user "$name" start "lunarwing-pebble-${name}.service" >/dev/null 2>&1; then
      say "pebble worker ready via quadlet (lunarwing-pebble-${name}.service, WSS port $wss_port)"
    else
      say "WARNING: lunarwing-pebble-${name}.service failed to start" >&2
      _systemctl_user "$name" status "lunarwing-pebble-${name}.service" --no-pager >&2 || true
    fi
    return 0
  fi

  if _ctr "$name" inspect "$container_name" &>/dev/null; then
    if _ctr "$name" inspect -f '{{.State.Running}}' "$container_name" 2>/dev/null | grep -q true; then
      say "pebble worker already running ($container_name, WSS port $wss_port)"
    else
      say "starting existing pebble worker container $container_name"
      _ctr "$name" start "$container_name" >/dev/null
    fi
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

    # HEALTH_PORT=8443 matches the image's baked HEALTHCHECK (curl
    # 127.0.0.1:8443/health, served by src/health.rs). The probe runs inside the
    # container's network namespace, so this needs no -p publish and never
    # conflicts across tenants; HEALTH_PORT=0 left the probe unreachable and the
    # container stuck "unhealthy" even though the WS bridge was fine.
    local -a restart_arg=()
    [[ "$MT_ROOTLESS" == "true" ]] || restart_arg=(--restart unless-stopped)
    _ctr "$name" run -d \
      --name "$container_name" \
      -e LUNARWING_WORKER_ID="worker-pebble-${name}" \
      -e WS_PORT="$wss_port" \
      -e HEALTH_PORT="8443" \
      -e PEBBLE_MODE=websocket \
      -e WS_BIND_HOST=0.0.0.0 \
      -e WS_PATH=/ws/agent \
      "${env_flags[@]}" \
      -p "127.0.0.1:${wss_port}:${wss_port}" \
      -v "$workspace_dir:/workspace:z" \
      "${restart_arg[@]}" \
      lunarwing-worker-pebble:latest >/dev/null
  fi

  _register_worker_unit "$name" pebble
  say "pebble worker ready ($container_name, WSS port $wss_port)"
}

stop_tenant_pebble() {
  local name="$1"
  ensure_container_runtime

  local container_name="lunarwing-pebble-$name"
  ensure_init_system
  if [[ "$INIT_SYSTEM" == "openrc" && -f "/etc/init.d/${container_name}" ]]; then
    rc-service "$container_name" stop >/dev/null 2>&1 || true
    say "pebble worker stopped ($container_name)"
  elif _ctr "$name" inspect "$container_name" &>/dev/null; then
    _ctr "$name" stop "$container_name" >/dev/null 2>&1 || true
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

  # systemd + rootless podman: a Quadlet .container owns the lifecycle (boot-
  # persistent, health-monitored, self-healable). Quadlet creates the container,
  # so skip the imperative `_ctr run` below; keep the pg_isready gate (via exec).
  ensure_init_system
  if [[ "$INIT_SYSTEM" == "systemd" && "$MT_ROOTLESS" == "true" ]] && podman_supports_quadlet; then
    _wait_user_manager "$name"
    render_pg_quadlet "$name"
    _systemctl_user "$name" daemon-reload 2>/dev/null || true
    if ! _systemctl_user "$name" start "lunarwing-pg-${name}.service" >/dev/null 2>&1; then
      say "WARNING: lunarwing-pg-${name}.service failed to start" >&2
      _systemctl_user "$name" status "lunarwing-pg-${name}.service" --no-pager >&2 || true
    fi
    # Gate on the container's own health (the Quadlet defines a pg_isready
    # HealthCmd) OR a direct pg_isready, rather than a bare `exec` loop: on a fresh
    # volume the initdb cycle (temp server up→down→restart) makes a single exec
    # probe flap, which previously exhausted the budget and `die`d — aborting the
    # WHOLE provision and leaving a half-baked tenant (F2). A slow first boot must
    # NOT strand the tenant: warn and continue (the unit has Restart=on-failure and
    # the host health pipeline/self-heal converge it), so add-tenant still renders
    # units and installs the pipeline.
    local q_attempts=0 q_ready=false q_health=""
    while (( q_attempts < 120 )); do
      q_health="$(_ctr "$name" inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$container_name" 2>/dev/null || true)"
      if [[ "$q_health" == healthy ]] || _ctr "$name" exec "$container_name" pg_isready -U lunarwing -q 2>/dev/null; then
        q_ready=true; break
      fi
      q_attempts=$((q_attempts + 1)); sleep 1
    done
    if [[ "$q_ready" == true ]]; then
      say "PostgreSQL ready via quadlet ($container_name, port $pg_port)"
    else
      say "WARNING: PostgreSQL for $name not confirmed ready after ${q_attempts}s (health=${q_health:-none}); continuing — pg has Restart=on-failure and the health pipeline will converge it." >&2
    fi
    return 0
  fi

  if _ctr "$name" inspect "$container_name" &>/dev/null; then
    if _ctr "$name" inspect -f '{{.State.Running}}' "$container_name" 2>/dev/null | grep -q true; then
      say "PostgreSQL already running ($container_name, port $pg_port)"
      return 0
    fi
    say "starting existing PostgreSQL container $container_name"
    if ! _ctr "$name" start "$container_name" >/dev/null; then
      say "WARNING: could not start existing PostgreSQL container $container_name for $name; continuing — re-run start-tenant or let the health pipeline converge it." >&2
      return 0
    fi
  else
    say "creating PostgreSQL container $container_name on port $pg_port"
    # Named volume (not anonymous) so the data has a stable, inspectable,
    # exportable identity for backups; rootless podman auto-chowns it inside the
    # tenant user namespace. --restart is a no-op under rootless podman (no
    # daemon — OpenRC owns lifecycle), so only set it for rootful docker.
    local -a restart_arg=()
    [[ "$MT_ROOTLESS" == "true" ]] || restart_arg=(--restart unless-stopped)
    # Pass POSTGRES_PASSWORD via a transient 0600 --env-file rather than `-e` so
    # the per-tenant secret never lands on the container-runtime argv (readable in
    # /proc/<pid>/cmdline by other local users). Removed right after creation; the
    # Quadlet path keeps it in its own 0600 unit file for the same reason.
    local pg_init_env
    pg_init_env="$(tenant_env_dir "$name")/.pg-init.env"
    ( umask 077; printf 'POSTGRES_PASSWORD=%s\n' "$(tenant_pg_password "$name")" >"$pg_init_env" )
    chown "$name:$name" "$pg_init_env" 2>/dev/null || true
    # O2: don't let a pg CREATE failure abort the whole provision (set -e). The F2
    # gate already downgrades a slow-readiness race to warn+continue; mirror that
    # for the create call (and the start above) so a transient runtime hiccup
    # doesn't strand the tenant half-baked (no units rendered, no health pipeline
    # installed). add-tenant is resumable (F4): fix the cause and re-run.
    if ! _ctr "$name" run -d \
      --name "$container_name" \
      -e POSTGRES_USER=lunarwing \
      --env-file "$pg_init_env" \
      -e POSTGRES_DB=lunarwing \
      -p "127.0.0.1:${pg_port}:5432" \
      -v "lunarwing-pg-${name}:/var/lib/postgresql/data" \
      "${restart_arg[@]}" \
      "$PG_IMAGE" >/dev/null; then
      rm -f "$pg_init_env"
      # Remove the partial/failed container so a resumed start-tenant re-creates it
      # cleanly, rather than taking the "start existing" branch on a broken shell.
      _ctr "$name" rm -f "$container_name" >/dev/null 2>&1 || true
      say "WARNING: PostgreSQL container create failed for $name; add-tenant still renders units + installs the health pipeline (so exit 0 does NOT imply pg is up). Fix the cause and re-run start-tenant." >&2
      return 0
    fi
    rm -f "$pg_init_env"
  fi

  local attempts=0
  while ! _ctr "$name" exec "$container_name" pg_isready -U lunarwing -q 2>/dev/null; do
    attempts=$((attempts + 1))
    if (( attempts >= 90 )); then
      say "WARNING: PostgreSQL for $name not confirmed ready after ${attempts}s; continuing — the host health pipeline/self-heal will converge it." >&2
      return 0
    fi
    sleep 1
  done
  say "PostgreSQL ready ($container_name, port $pg_port)"
}

stop_tenant_postgres() {
  local name="$1"
  ensure_container_runtime

  local container_name="lunarwing-pg-$name"
  if _ctr "$name" inspect "$container_name" &>/dev/null; then
    _ctr "$name" stop "$container_name" >/dev/null 2>&1 || true
    say "PostgreSQL stopped ($container_name)"
  fi
}

reset_tenant_postgres() {
  local name="$1"
  ensure_container_runtime

  local container_name="lunarwing-pg-$name"
  stop_tenant_postgres "$name"
  _ctr "$name" rm -f "$container_name" >/dev/null 2>&1 || true
  # Remove the named data volume too so a subsequent create starts fresh (matches
  # the pre-named-volume behaviour where the anonymous volume was orphaned on rm).
  _ctr "$name" volume rm "lunarwing-pg-${name}" >/dev/null 2>&1 || true
  say "PostgreSQL removed ($container_name, data volume cleared)"
}

# Rotate an existing tenant's PG password to a fresh random one. Unlike a new
# tenant (where POSTGRES_PASSWORD seeds an empty datadir), an initialised DB needs
# an in-place ALTER ROLE, then the persisted secret + DATABASE_URL updated, then a
# daemon restart so it reconnects with the new credential. The new password is hex
# (URL/SQL-safe) and is never echoed.
rotate_tenant_pg_password() {
  local name="$1"
  ensure_container_runtime
  name="$(sanitize_name "$name")"
  tenant_exists_in_registry "$name" || die "tenant '$name' not found in registry"

  local container_name="lunarwing-pg-$name"
  _ctr "$name" inspect -f '{{.State.Running}}' "$container_name" 2>/dev/null | grep -q true \
    || die "PostgreSQL container $container_name is not running; start the tenant first"

  local envf pg_port new_pw secret_file tmp
  envf="$(tenant_env_dir "$name")/lunarwing.env"
  [[ -f "$envf" ]] || die "tenant env not found: $envf"
  pg_port="$(ports_get "$name" postgres)"
  new_pw="$(generate_token | cut -c1-32)"

  # Change the live role password. psql connects over the container's local unix
  # socket (trust auth in the postgres image), and the new value is fed on stdin —
  # never on argv or in logs. A hex value carries no SQL-quoting hazard.
  if ! printf "ALTER ROLE lunarwing PASSWORD '%s';\n" "$new_pw" \
       | _ctr "$name" exec -i "$container_name" psql -v ON_ERROR_STOP=1 -U lunarwing -d lunarwing -q >/dev/null 2>&1; then
    die "failed to ALTER ROLE password inside $container_name (is the DB healthy?)"
  fi

  # Persist the new secret (source of truth) ...
  secret_file="$(tenant_env_dir "$name")/pg.secret"
  ( umask 077; printf '%s\n' "$new_pw" > "$secret_file" )
  chown "$name:$name" "$secret_file" 2>/dev/null || true

  # ... and rewrite DATABASE_URL in place (preserving the env file's owner/perms).
  # Temp lives beside the env file (0600), not in shared /tmp, so the cleartext
  # password isn't briefly exposed there — matching the convention used elsewhere.
  tmp="$(mktemp "$envf.tmp.XXXXXX")"
  sed "s#^DATABASE_URL=.*#DATABASE_URL=postgres://lunarwing:${new_pw}@127.0.0.1:${pg_port}/lunarwing#" "$envf" >"$tmp"
  cat "$tmp" >"$envf"
  rm -f "$tmp"

  say "Rotated PostgreSQL password for tenant '$name'."
  say "IMPORTANT: the running daemon still holds the old credential — restart to apply:"
  say "    lunarwing-mt-admin.sh restart-tenant $name"
}

# ── PostgreSQL backup / restore ──────────────────────────────────────────────

# pg_dump a tenant's database to a timestamped custom-format file under
# $BACKUP_DIR/<tenant>/. Runs pg_dump inside the tenant's pg container via _ctr,
# so it is init- and runtime-agnostic (rootless podman or rootful docker). Safe
# on a live database (MVCC snapshot). Prunes to the most recent $BACKUP_KEEP.
backup_tenant_postgres() {
  local name="$1"
  name="$(sanitize_name "$name")"
  tenant_exists_in_registry "$name" || die "tenant '$name' not found in registry"
  ensure_container_runtime
  local container_name="lunarwing-pg-$name"

  _ctr "$name" inspect -f '{{.State.Running}}' "$container_name" 2>/dev/null | grep -q true \
    || die "PostgreSQL not running for '$name' ($container_name) — start the tenant first"

  local dir ts dest tmp
  dir="$BACKUP_DIR/$name"
  mkdir -p "$dir"
  chmod 0700 "$BACKUP_DIR" "$dir" 2>/dev/null || true
  ts="$(date +%Y%m%d%H%M%S)"
  dest="$dir/${name}-${ts}.dump"
  tmp="$dest.partial"

  say "backing up '$name' -> $dest"
  # -Fc: compressed custom format (restore via pg_restore). umask 077 so the
  # .partial is never world-readable, even mid-dump; rename on success so an
  # interrupted dump never looks complete.
  if ( umask 077; _ctr "$name" exec "$container_name" pg_dump -U lunarwing -Fc lunarwing > "$tmp" ); then
    mv "$tmp" "$dest"
    say "backup complete: $dest ($(du -h "$dest" 2>/dev/null | cut -f1))"
  else
    rm -f "$tmp"
    die "pg_dump failed for '$name'"
  fi
  _prune_tenant_backups "$name"
}

# Keep only the most recent $BACKUP_KEEP dumps for a tenant (0/unset = keep all).
_prune_tenant_backups() {
  local name="$1" dir="$BACKUP_DIR/$1"
  [[ "${BACKUP_KEEP:-0}" =~ ^[0-9]+$ && "$BACKUP_KEEP" -gt 0 ]] || return 0
  local -a dumps=("$dir"/*.dump)
  [[ -e "${dumps[0]:-}" ]] || return 0          # glob did not match -> nothing to prune
  local n=${#dumps[@]} i
  (( n > BACKUP_KEEP )) || return 0
  for (( i=0; i < n - BACKUP_KEEP; i++ )); do   # glob is ascending (timestamp) = oldest first
    rm -f "${dumps[$i]}"
    say "pruned old backup: ${dumps[$i]}"
  done
}

# List existing backups for one tenant or all.
list_tenant_backups() {
  local filter="${1:-}" names
  if [[ -n "$filter" ]]; then names="$(sanitize_name "$filter")"; else names="$(all_tenant_names)"; fi
  [[ -n "$names" ]] || { say "no tenants"; return 0; }
  say "=== Backups (under $BACKUP_DIR) ==="
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    say ""
    say "$name:"
    if compgen -G "$BACKUP_DIR/$name/*.dump" >/dev/null 2>&1; then
      ls -1sh "$BACKUP_DIR/$name"/*.dump 2>/dev/null | sed 's/^/  /'
    else
      say "  (no backups)"
    fi
  done <<< "$names"
}

# Restore a tenant's database from a custom-format dump. DESTRUCTIVE: pg_restore
# --clean --if-exists DROPs and recreates objects. Requires the tenant daemon to
# be stopped (no concurrent writes) and an explicit --yes.
restore_tenant_postgres() {
  local name="$1" file="$2" confirmed="${3:-false}"
  name="$(sanitize_name "$name")"
  tenant_exists_in_registry "$name" || die "tenant '$name' not found in registry"
  [[ -f "$file" ]] || die "backup file not found: $file"
  # Reject anything that is not a custom-format archive before touching the DB
  # (custom-format pg_dump files begin with the magic "PGDMP").
  [[ "$(head -c5 "$file" 2>/dev/null)" == "PGDMP" ]] \
    || die "not a custom-format pg_dump archive (missing PGDMP header): $file"
  [[ "$confirmed" == "true" ]] || die "restore DROPs and recreates the database for '$name'. Re-run with --yes to confirm."
  ensure_container_runtime
  ensure_init_system
  local container_name="lunarwing-pg-$name"

  _ctr "$name" inspect -f '{{.State.Running}}' "$container_name" 2>/dev/null | grep -q true \
    || die "PostgreSQL not running for '$name' — start the tenant's pg container first"

  # Refuse unless we can POSITIVELY confirm the daemon is stopped (concurrent
  # writes corrupt a restore). Fail closed: if the service tool is missing or the
  # state is indeterminate, never assume "stopped".
  local daemon_state="unknown"
  if [[ "$INIT_SYSTEM" == "systemd" ]] && command -v systemctl >/dev/null 2>&1; then
    if _systemctl_user "$name" is-active --quiet "lunarwing-${name}.service" 2>/dev/null; then daemon_state="active"; else daemon_state="stopped"; fi
  elif [[ "$INIT_SYSTEM" == "openrc" ]] && command -v rc-service >/dev/null 2>&1; then
    if rc-service "lunarwing-${name}" status >/dev/null 2>&1; then daemon_state="active"; else daemon_state="stopped"; fi
  fi
  case "$daemon_state" in
    stopped) : ;;
    active)  die "stop the daemon first: $0 stop-tenant $name  (restart after restore)" ;;
    *)       die "cannot confirm the '$name' daemon is stopped (no $INIT_SYSTEM service tool?); stop it manually, then re-run" ;;
  esac

  say "restoring '$name' from $file (single transaction, DROP + recreate) ..."
  # --single-transaction: all-or-nothing. A mid-restore failure rolls the whole
  # DROP+recreate back, so a failed restore never leaves the DB half-dropped.
  if _ctr "$name" exec -i "$container_name" pg_restore -U lunarwing -d lunarwing --single-transaction --clean --if-exists < "$file"; then
    say "restore complete for '$name'. Restart the tenant: $0 start-tenant $name"
  else
    die "pg_restore failed for '$name' — rolled back (single transaction); the database is unchanged"
  fi
}

# ── Systemd service units ────────────────────────────────────────────────────

# Render a per-tenant Quadlet .container for the Postgres container. The podman
# user-generator turns this into lunarwing-pg-<t>.service at `systemctl --user
# daemon-reload`; [Install] makes the lingering user manager start it at boot.
# Quadlet owns creation (the imperative `_ctr run` is skipped on this path), so
# the named volume below preserves data across container replacement.
render_pg_quadlet() {
  local name="$1"
  local qdir pg_port pg_password
  qdir="$(tenant_quadlet_dir "$name")"
  pg_port="$(ports_get "$name" postgres)"
  pg_password="$(tenant_pg_password "$name")"   # inlined into the 0600 tenant-owned .container
  mkdir -p "$qdir"
  cat >"$qdir/lunarwing-pg-${name}.container" <<EOF
[Unit]
Description=LunarWing Postgres container ($name)
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=5

[Container]
ContainerName=lunarwing-pg-${name}
Image=${PG_IMAGE}
PublishPort=127.0.0.1:${pg_port}:5432
Volume=lunarwing-pg-${name}:/var/lib/postgresql/data
Environment=POSTGRES_USER=lunarwing
Environment=POSTGRES_PASSWORD=${pg_password}
Environment=POSTGRES_DB=lunarwing
HealthCmd=pg_isready -U lunarwing -q
HealthInterval=10s
HealthTimeout=3s
HealthRetries=5
HealthStartPeriod=30s

[Service]
Restart=on-failure
RestartSec=5
TimeoutStartSec=120

[Install]
WantedBy=default.target
EOF
  chmod 0600 "$qdir/lunarwing-pg-${name}.container"
  chown -R "$name:$name" "$(tenant_home "$name")/.config/containers"
}

# Render a per-tenant Quadlet .container for an external worker (nanocode/pebble).
# Mirrors the imperative env from start_tenant_<worker>: the GATEWAY_AUTH_TOKEN ->
# AGENT_AUTH_TOKEN and LLM_API_KEY -> TENSORZERO_API_KEY remap is resolved here and
# inlined as Environment= in a 0600 tenant-owned unit (no secret leaves the file).
# Returns early (no unit) when the worker has no allocated wss port.
render_worker_quadlet() {
  local name="$1" worker="$2" health_port="${3:-8443}"
  local qdir wss_port workspace_dir env_dir tenant_env_path worker_env_path
  qdir="$(tenant_quadlet_dir "$name")"
  wss_port="$(ports_get "$name" "${worker}_wss")"
  [[ -n "$wss_port" ]] || return 0
  env_dir="$(tenant_env_dir "$name")"
  tenant_env_path="$env_dir/lunarwing.env"
  worker_env_path="$env_dir/${worker}.env"
  workspace_dir="$(tenant_lw_root "$name")/${worker}-workspace"
  mkdir -p "$workspace_dir"; chown "$name:$name" "$workspace_dir"; chmod 777 "$workspace_dir"
  mkdir -p "$qdir"

  local agent_token tz_key
  agent_token="$(grep '^GATEWAY_AUTH_TOKEN=' "$tenant_env_path" 2>/dev/null | cut -d= -f2- || true)"
  tz_key="$(grep '^LLM_API_KEY=' "$tenant_env_path" 2>/dev/null | cut -d= -f2- || true)"
  # systemd treats % as a unit specifier; escape so a token containing % survives.
  agent_token="${agent_token//%/%%}"
  tz_key="${tz_key//%/%%}"

  {
    cat <<EOF
[Unit]
Description=LunarWing ${worker} worker ($name)
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=5

[Container]
ContainerName=lunarwing-${worker}-${name}
Image=lunarwing-worker-${worker}:latest
PublishPort=127.0.0.1:${wss_port}:${wss_port}
Volume=${workspace_dir}:/workspace:z
Environment=LUNARWING_WORKER_ID=worker-${worker}-${name}
Environment=WS_PORT=${wss_port}
Environment=HEALTH_PORT=${health_port}
Environment=WS_BIND_HOST=0.0.0.0
Environment=WS_PATH=/ws/agent
EOF
    if [[ "$worker" == "nanocode" ]]; then
      printf 'Environment=NANOCODE_MODE=websocket\n'
      printf 'Environment=WS_ROLE=server\n'
    elif [[ "$worker" == "pebble" ]]; then
      printf 'Environment=PEBBLE_MODE=websocket\n'
    fi
    [[ -n "$agent_token" ]] && printf 'Environment=AGENT_AUTH_TOKEN=%s\n' "$agent_token"
    [[ "$worker" == "nanocode" && -n "$tz_key" ]] && printf 'Environment=TENSORZERO_API_KEY=%s\n' "$tz_key"
    # Operator override file (optional). EnvironmentFile= has existed since the
    # Quadlet 4.4 debut, so it is safe at our >= 4.6 floor.
    [[ -f "$worker_env_path" ]] && printf 'EnvironmentFile=%s\n' "$worker_env_path"
    # nanocode takes a trailing CMD arg; pebble uses the image default.
    [[ "$worker" == "nanocode" ]] && printf 'Exec=--mode websocket\n'
    cat <<EOF
HealthCmd=curl -sf http://127.0.0.1:${health_port}/health || exit 1
HealthInterval=15s
HealthTimeout=5s
HealthRetries=3
HealthStartPeriod=30s

[Service]
Restart=on-failure
RestartSec=5
TimeoutStartSec=120

[Install]
WantedBy=default.target
EOF
  } >"$qdir/lunarwing-${worker}-${name}.container"
  chmod 0600 "$qdir/lunarwing-${worker}-${name}.container"
  chown -R "$name:$name" "$(tenant_home "$name")/.config/containers"
}

render_tenant_systemd_units() {
  local name="$1"
  ensure_container_runtime
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

  cat >"$user_unit_dir/lunarwing-weechat-${name}.service" <<EOF
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
After=network.target lunarwing-weechat-${name}.service
Requires=lunarwing-weechat-${name}.service
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

  # Postgres dependency — only when the pg Quadlet is rendered (systemd + rootless
  # podman with Quadlet support). Mirrors the OpenRC `need lunarwing-pg-<t>`.
  # Rootful docker has no pg unit (the container survives via --restart), so the
  # dependency is omitted there to avoid a Requires on a non-existent unit.
  local pg_dep_after="" pg_dep_requires=""
  if [[ "$MT_ROOTLESS" == "true" ]] && podman_supports_quadlet; then
    pg_dep_after="lunarwing-pg-${name}.service "
    pg_dep_requires="Requires=lunarwing-pg-${name}.service"
  fi

  # Main daemon unit
  cat >"$user_unit_dir/lunarwing-${name}.service" <<EOF
[Unit]
Description=LunarWing AI assistant ($name)
After=network.target ${pg_dep_after}xmpp-bridge-${name}.service lunarwing-proxy-${name}.service lunarwing-weechat-${name}.service lunarwing-weechat-adapter-${name}.service
Wants=xmpp-bridge-${name}.service lunarwing-proxy-${name}.service lunarwing-weechat-${name}.service lunarwing-weechat-adapter-${name}.service
${pg_dep_requires}

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

  # The pg + worker Quadlet .container units are rendered by the start functions
  # (start_tenant_postgres / start_tenant_<worker>), NOT here: those guard on
  # image availability, so a not-yet-built worker image never produces a unit
  # that would crash-loop at boot (Restart=always). The daemon's Requires= above
  # still resolves because start_tenant_postgres renders + starts pg first.

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

# Best-effort wait for the tenant's `systemd --user` manager + bus to be ready,
# so `systemctl --user` and the Quadlet generator work right after enable-linger
# (which can return before the user manager is fully up). Proceeds after ~10s.
_wait_user_manager() {
  local name="$1" uid i
  uid="$(id -u "$name" 2>/dev/null)" || return 0
  for i in $(seq 1 20); do
    [[ -S "/run/user/$uid/bus" ]] && return 0
    sleep 0.5
  done
  return 0
}

start_tenant_systemd() {
  local name="$1"
  _systemctl_user "$name" daemon-reload
  _systemctl_user "$name" enable \
    "lunarwing-${name}.service" \
    "xmpp-bridge-${name}.service" \
    "lunarwing-proxy-${name}.service" \
    "lunarwing-weechat-${name}.service" \
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

  for svc in "lunarwing-${name}.service" "xmpp-bridge-${name}.service" "lunarwing-proxy-${name}.service" "lunarwing-weechat-adapter-${name}.service" "lunarwing-weechat-${name}.service" "lunarwing-nanocode-${name}.service" "lunarwing-pebble-${name}.service" "lunarwing-pg-${name}.service"; do
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

  for svc in "lunarwing-${name}.service" "xmpp-bridge-${name}.service" "lunarwing-proxy-${name}.service" "lunarwing-weechat-adapter-${name}.service" "lunarwing-weechat-${name}.service"; do
    rm -f "$user_unit_dir/$svc"
  done

  # Quadlet .container units (rootless pg + workers). Remove the worker containers
  # (their workspace data is bind-mounted in the home); the pg container + named
  # volume are handled by stop_tenant_postgres / reset_tenant_postgres so non-purge
  # removals keep the data for a later re-add.
  local qdir; qdir="$(tenant_quadlet_dir "$name")"
  rm -f "$qdir/lunarwing-pg-${name}.container" \
        "$qdir/lunarwing-nanocode-${name}.container" \
        "$qdir/lunarwing-pebble-${name}.container"
  if id -u "$name" >/dev/null 2>&1; then
    for w in nanocode pebble; do
      _ctr "$name" rm -f "lunarwing-${w}-${name}" >/dev/null 2>&1 || true
    done
  fi

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

  # Resolve the container runtime path + tenant identity so the dedicated
  # Postgres init service can bring the container up (rootless: as the tenant
  # user; rootful docker: as root). Empty runtime -> the pg service no-ops.
  ensure_container_runtime
  local pg_runtime_bin="" pg_container="lunarwing-pg-$name"
  [[ -n "${CONTAINER_RT:-}" ]] && pg_runtime_bin="$(command -v "$CONTAINER_RT" 2>/dev/null || true)"
  local pg_uid pg_home
  pg_uid="$(id -u "$name" 2>/dev/null || echo "")"
  pg_home="$(tenant_home "$name")"

  # ── Postgres container init script (dedicated service; the daemon needs it) ──
  # A first-class unit (not a daemon start_pre side-effect) so the host self-heal
  # pipeline — which auto-discovers /etc/init.d units — can remediate a crashed
  # Postgres independently.
  cat >"/etc/init.d/lunarwing-pg-${name}" <<INITEOF
#!/sbin/openrc-run

description="LunarWing Postgres container ($name)"

: "\${pg_runtime:=$pg_runtime_bin}"
: "\${pg_container:=$pg_container}"
: "\${pg_rootless:=$MT_ROOTLESS}"
: "\${pg_user:=$name}"
: "\${pg_home:=$pg_home}"
: "\${pg_uid:=$pg_uid}"
: "\${pg_wait:=60}"

depend() {
    need net localmount
    after firewall
    before lunarwing-${name}
}

# Run the container runtime for this tenant's container: rootless -> as the
# tenant user with their runtime dir + HOME; rootful -> as root unchanged.
_pg() {
    if [ "\${pg_rootless}" = "true" ]; then
        sudo -u "\${pg_user}" env HOME="\${pg_home}" XDG_RUNTIME_DIR="/run/user/\${pg_uid}" "\${pg_runtime}" "\$@"
    else
        "\${pg_runtime}" "\$@"
    fi
}

start() {
    [ -n "\${pg_runtime}" ] && [ -x "\${pg_runtime}" ] || { ewarn "no container runtime; skipping Postgres for $name"; return 0; }
    ebegin "Starting Postgres container (\${pg_container})"
    if [ "\${pg_rootless}" = "true" ]; then
        checkpath -d -m 0700 -o "\${pg_user}:\${pg_user}" "/run/user/\${pg_uid}"
    fi
    _pg start "\${pg_container}" >/dev/null 2>&1 || { eend 1 "container start failed"; return 1; }
    _w=0
    while ! _pg exec "\${pg_container}" pg_isready -U lunarwing -q 2>/dev/null; do
        _w=\$((_w + 1))
        [ "\$_w" -lt "\${pg_wait}" ] || { eend 1 "Postgres not ready after \${pg_wait}s"; return 1; }
        sleep 1
    done
    eend 0
}

stop() {
    [ -n "\${pg_runtime}" ] && [ -x "\${pg_runtime}" ] || return 0
    ebegin "Stopping Postgres container (\${pg_container})"
    _pg stop --time 30 "\${pg_container}" >/dev/null 2>&1
    eend 0
}

status() {
    # Emit the standard OpenRC "started"/"stopped" wording (not "running") so the
    # health-check parser (grep started|stopped) and the mt-admin status display
    # classify the container correctly instead of relying on the rc_exit fallback.
    # "started" requires the container be running AND Postgres actually accept
    # connections (pg_isready) — a Running-but-wedged DB (crash recovery, disk
    # full, max_connections) otherwise reports healthy and is never remediated.
    # Mirrors the worker units' _wk_healthy and this unit's own start() gate.
    if [ "\$(_pg inspect -f '{{.State.Running}}' "\${pg_container}" 2>/dev/null)" = "true" ] \\
       && _pg exec "\${pg_container}" pg_isready -U lunarwing -q -t 3 2>/dev/null; then
        einfo "\${pg_container}: started"; return 0
    fi
    einfo "\${pg_container}: stopped"; return 3
}
INITEOF
  chmod 0755 "/etc/init.d/lunarwing-pg-${name}"

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
    need net localmount lunarwing-pg-${name}
    use dns logger
    after firewall lunarwing-pg-${name} xmpp-bridge-${name} lunarwing-proxy-${name} weechat-${name} lunarwing-weechat-adapter-${name}
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
    # Postgres is brought up by the dedicated lunarwing-pg-${name} service, which
    # this unit declares as a hard dependency (need), so the DB is already up.
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
  cat >"/etc/init.d/lunarwing-weechat-${name}" <<INITEOF
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
  chmod 0755 "/etc/init.d/lunarwing-weechat-${name}"

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
    need net lunarwing-weechat-${name}
    use dns
    after firewall lunarwing-weechat-${name}
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
lunarwing_rc_need="xmpp-bridge-${name} lunarwing-proxy-${name} lunarwing-weechat-${name} lunarwing-weechat-adapter-${name}"
CONFD

  cat >"/etc/conf.d/xmpp-bridge-${name}" <<CONFD
# Auto-generated by lunarwing-mt-admin.sh for tenant: $name
xmpp_bridge_rc_before="lunarwing-${name}"
CONFD

  cat >"/etc/conf.d/lunarwing-proxy-${name}" <<CONFD
# Auto-generated by lunarwing-mt-admin.sh for tenant: $name
CONFD

  cat >"/etc/conf.d/lunarwing-weechat-${name}" <<CONFD
# Auto-generated by lunarwing-mt-admin.sh for tenant: $name
CONFD

  cat >"/etc/conf.d/lunarwing-weechat-adapter-${name}" <<CONFD
# Auto-generated by lunarwing-mt-admin.sh for tenant: $name
CONFD

  say "rendered OpenRC init scripts and conf.d for $name"
}

start_tenant_openrc() {
  local name="$1"
  # Record operator intent UP FRONT: enabling the primary daemon in the default
  # runlevel marks this tenant as "started" (boot-persistent) regardless of whether
  # any unit's FIRST start succeeds. health-openrc.sh's started-gate
  # (tenant_started) keys on exactly this, so a daemon that crashes on its first
  # start is still reported `critical` (a real outage) and remediated — not masked
  # as `skipped`. The selective rc-update-add loop below additionally boot-enables
  # the optional units that actually came up. Idempotent.
  rc-update add "lunarwing-${name}" default >/dev/null 2>&1 || true

  # Postgres first: the daemon `need`s it (and it's idempotent if already up).
  rc-service "lunarwing-pg-${name}" start
  # Optional channels next, non-fatal: a missing weechat/aiohttp must not abort
  # the core stack (the main daemon does not depend on them).
  rc-service "lunarwing-weechat-${name}" start 2>/dev/null || say "  (lunarwing-weechat-${name} skipped — optional)"
  rc-service "lunarwing-weechat-adapter-${name}" start 2>/dev/null || say "  (lunarwing-weechat-adapter-${name} skipped — optional)"
  rc-service "lunarwing-proxy-${name}" start
  rc-service "xmpp-bridge-${name}" start
  rc-service "lunarwing-${name}" start
  say "OpenRC services started for $name"

  # Auto-enable on boot whatever is actually running (idempotent, OpenRC only).
  local svc
  for svc in "lunarwing-pg-${name}" "lunarwing-proxy-${name}" "xmpp-bridge-${name}" "lunarwing-${name}" \
             "lunarwing-weechat-${name}" "lunarwing-weechat-adapter-${name}"; do
    if rc-service "$svc" status >/dev/null 2>&1; then
      rc-update add "$svc" default >/dev/null 2>&1 || true
    fi
  done
  say "enabled boot persistence (default runlevel) for $name's running services"
}

stop_tenant_openrc() {
  local name="$1"
  rc-service "lunarwing-${name}" stop 2>/dev/null || true
  rc-service "xmpp-bridge-${name}" stop 2>/dev/null || true
  rc-service "lunarwing-proxy-${name}" stop 2>/dev/null || true
  rc-service "lunarwing-weechat-adapter-${name}" stop 2>/dev/null || true
  rc-service "lunarwing-weechat-${name}" stop 2>/dev/null || true
  # Postgres last: the daemon depends on it, so it stops after its consumers.
  rc-service "lunarwing-pg-${name}" stop 2>/dev/null || true
  say "OpenRC services stopped for $name"
}

uninstall_tenant_openrc() {
  local name="$1"
  for svc in "lunarwing-${name}" "xmpp-bridge-${name}" "lunarwing-proxy-${name}" "lunarwing-weechat-adapter-${name}" "lunarwing-weechat-${name}" "lunarwing-pg-${name}" "lunarwing-nanocode-${name}" "lunarwing-pebble-${name}"; do
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

# ── Host-global health-check / self-heal pipeline (OpenRC + systemd) ─────────

_ensure_cron_runlevel() {
  # Ensure a cron daemon is enabled at boot + running so the schedule fires.
  local want="${1:-}" cron
  for cron in ${want:+$want} fcron cronie dcron crond busybox-cron; do
    if [[ -x "/etc/init.d/$cron" ]]; then
      rc-update add "$cron" default >/dev/null 2>&1 || true
      rc-service "$cron" start >/dev/null 2>&1 || true
      say "cron daemon '$cron' enabled + running"
      return 0
    fi
  done
  say "WARNING: no cron daemon init script found; install fcron/cronie/dcron so the schedule runs"
}

_install_health_cron() {
  local sched="*/${HEALTH_INTERVAL_MIN} * * * * $HEALTH_LAUNCHER"
  local begin="# BEGIN lunarwing-mt-health managed block"
  local end="# END lunarwing-mt-health managed block"
  local cmd=""
  command -v fcrontab >/dev/null 2>&1 && cmd="fcrontab"
  [[ -z "$cmd" ]] && command -v crontab >/dev/null 2>&1 && cmd="crontab"
  if [[ -z "$cmd" ]]; then
    say "WARNING: no fcrontab/crontab found — cannot schedule the pipeline. Install a cron daemon or run $HEALTH_LAUNCHER periodically."
    return 0
  fi
  local tmp; tmp="$(mktemp)"
  "$cmd" -l 2>/dev/null | sed "/^${begin}$/,/^${end}$/d" > "$tmp" || true
  { printf '%s\n' "$begin" "$sched" "$end"; } >> "$tmp"
  if "$cmd" "$tmp" 2>/dev/null; then
    say "scheduled health pipeline via $cmd: every ${HEALTH_INTERVAL_MIN} min"
  else
    say "WARNING: failed to install $cmd schedule"
  fi
  rm -f "$tmp"
  _ensure_cron_runlevel "$([[ "$cmd" == "fcrontab" ]] && echo fcron)"
}

_install_health_systemd_timer() {
  # systemd hosts: a root, system-level oneshot service + timer. Persistent=true
  # provides the missed-run catch-up fcron gives on OpenRC; system-level (not
  # --user) because one run remediates many tenants' user units via sudo.
  local svc="/etc/systemd/system/lunarwing-mt-health.service"
  local tmr="/etc/systemd/system/lunarwing-mt-health.timer"
  if ! command -v systemctl >/dev/null 2>&1; then
    say "WARNING: systemctl not found — cannot schedule the pipeline on systemd."
    return 0
  fi
  cat >"$svc" <<UNITEOF
[Unit]
Description=LunarWing MT health-check + self-heal pipeline
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$HEALTH_LAUNCHER
UNITEOF
  cat >"$tmr" <<UNITEOF
[Unit]
Description=Schedule LunarWing MT health/self-heal pipeline (every ${HEALTH_INTERVAL_MIN} min)

[Timer]
OnBootSec=5min
OnCalendar=*:0/${HEALTH_INTERVAL_MIN}
Persistent=true
AccuracySec=30s
Unit=lunarwing-mt-health.service

[Install]
WantedBy=timers.target
UNITEOF
  systemctl daemon-reload >/dev/null 2>&1 || true
  if systemctl enable --now lunarwing-mt-health.timer >/dev/null 2>&1; then
    say "scheduled health pipeline via systemd timer: every ${HEALTH_INTERVAL_MIN} min"
  else
    say "WARNING: failed to enable lunarwing-mt-health.timer"
  fi
}

ensure_health_pipeline() {
  # Idempotently install + schedule the host-global health-check -> self-heal
  # pipeline. Auto-discovers all tenants, so one install covers every tenant.
  # Wired for OpenRC (fcron/cron) and systemd (timer); other inits are skipped.
  ensure_init_system
  case "$INIT_SYSTEM" in
    openrc|systemd) : ;;
    *) say "health pipeline: not wired for INIT_SYSTEM=$INIT_SYSTEM; skipping"; return 0 ;;
  esac
  [[ -d "$HEALTH_SRC_DIR" ]] || { say "WARNING: health source dir not found ($HEALTH_SRC_DIR); skipping"; return 0; }

  say "--- Ensuring host-global health/self-heal pipeline ---"

  # 1) Stable copy of the pipeline scripts (survives repo/worktree moves).
  mkdir -p "$HEALTH_LIB_DIR"
  cp -a "$HEALTH_SRC_DIR/." "$HEALTH_LIB_DIR/"
  chmod 0755 "$HEALTH_LIB_DIR"/*.sh 2>/dev/null || true
  say "synced pipeline scripts -> $HEALTH_LIB_DIR"

  # 2) Host-level report/state dir.
  mkdir -p "$HEALTH_BASE_DIR/workspace/reports/health"

  # 3) Config env file (write-if-absent so operator edits survive).
  mkdir -p /etc/lunarwing
  if [[ ! -f "$HEALTH_ENV_FILE" ]]; then
    ( umask 077
      cat >"$HEALTH_ENV_FILE" <<ENVEOF
# /etc/lunarwing/health.env — host-global health/self-heal pipeline config.
# Auto-generated by lunarwing-mt-admin.sh (write-if-absent; safe to edit).
LUNARWING_BASE_DIR=$HEALTH_BASE_DIR
LUNARWING_SERVICE_MANAGER=$INIT_SYSTEM
SELF_HEAL_TENANTS_FILE=$PORTS_REGISTRY

# MT hardening: remediate only auto-discovered per-tenant init units; disable
# checks that are N/A host-globally; page only on self-heal escalation (not on
# every non-healthy run); ignore stale reports.
SELF_HEAL_REMEDY_LOGICAL=false
HEALTH_XMPP_SERVER=
HEALTH_MODELS_ENABLED=false
HEALTH_OMEMO_ENABLED=false
HEALTHCHECK_NOTIFY=false
SELF_HEAL_MAX_REPORT_AGE=$(( HEALTH_INTERVAL_MIN * 60 * 4 ))

# Escalation notifications (fill in to enable Gotify pushes).
GOTIFY_URL=$HEALTH_GOTIFY_URL
GOTIFY_TOKEN=$HEALTH_GOTIFY_TOKEN
ENVEOF
    )
    chmod 0600 "$HEALTH_ENV_FILE"
    say "wrote $HEALTH_ENV_FILE (mode 0600)"
  else
    say "$HEALTH_ENV_FILE already exists (preserving)"
    # Reconcile only the service-manager line in case a prior run wrote a
    # different init system (self-heal honors LUNARWING_SERVICE_MANAGER ahead of
    # its own autodetection, so a stale value silently misroutes remediation).
    # Operator edits (e.g. Gotify tokens) are preserved — we rewrite one line.
    if ! grep -q "^LUNARWING_SERVICE_MANAGER=${INIT_SYSTEM}$" "$HEALTH_ENV_FILE"; then
      local _tmp; _tmp="$(mktemp)"
      if grep -q '^LUNARWING_SERVICE_MANAGER=' "$HEALTH_ENV_FILE"; then
        awk -v v="$INIT_SYSTEM" '/^LUNARWING_SERVICE_MANAGER=/{print "LUNARWING_SERVICE_MANAGER=" v; next} {print}' "$HEALTH_ENV_FILE" > "$_tmp"
      else
        cp "$HEALTH_ENV_FILE" "$_tmp"
        printf 'LUNARWING_SERVICE_MANAGER=%s\n' "$INIT_SYSTEM" >> "$_tmp"
      fi
      cat "$_tmp" > "$HEALTH_ENV_FILE"   # overwrite content, preserve mode/owner
      rm -f "$_tmp"
      say "reconciled LUNARWING_SERVICE_MANAGER=$INIT_SYSTEM in $HEALTH_ENV_FILE"
    fi
  fi

  # 4) Launcher: source env, then run the pipeline (health-check -> self-heal LIVE).
  cat >"$HEALTH_LAUNCHER" <<LAUNCHEOF
#!/bin/sh
# Auto-generated by lunarwing-mt-admin.sh. Host-global health/self-heal pipeline.
set -a
[ -r $HEALTH_ENV_FILE ] && . $HEALTH_ENV_FILE
set +a
exec $HEALTH_LIB_DIR/cron-wrapper.sh "\$@"
LAUNCHEOF
  chmod 0755 "$HEALTH_LAUNCHER"
  say "wrote $HEALTH_LAUNCHER"

  # 5) Schedule it (per init system).
  case "$INIT_SYSTEM" in
    openrc)  _install_health_cron ;;
    systemd) _install_health_systemd_timer ;;
  esac
  say "health pipeline ready (every ${HEALTH_INTERVAL_MIN} min; covers all tenants)"
}

remove_health_pipeline() {
  ensure_init_system
  local begin="# BEGIN lunarwing-mt-health managed block"
  local end="# END lunarwing-mt-health managed block"
  case "$INIT_SYSTEM" in
    openrc)
      command -v fcrontab >/dev/null 2>&1 && fcrontab -l 2>/dev/null | sed "/^${begin}$/,/^${end}$/d" | fcrontab - 2>/dev/null || true
      command -v crontab  >/dev/null 2>&1 && crontab  -l 2>/dev/null | sed "/^${begin}$/,/^${end}$/d" | crontab  - 2>/dev/null || true
      ;;
    systemd)
      if command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now lunarwing-mt-health.timer >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/lunarwing-mt-health.timer /etc/systemd/system/lunarwing-mt-health.service
        systemctl daemon-reload >/dev/null 2>&1 || true
      fi
      ;;
    *) return 0 ;;
  esac
  rm -f "$HEALTH_LAUNCHER"
  say "retired host-global health pipeline schedule (no tenants remain)"
  # $HEALTH_LIB_DIR + $HEALTH_ENV_FILE left in place (harmless; preserves config/state).
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
  local llm_base_url="${9:-$DEFAULT_LLM_BASE_URL}"

  name="$(sanitize_name "$name")"
  [[ -n "$name" ]] || die "invalid tenant name"
  # A tenant whose name begins with a reserved per-service prefix would make its
  # primary daemon unit (lunarwing-<name>) collide with another tenant's
  # per-service unit — e.g. tenant 'pebble-1' -> lunarwing-pebble-1, byte-identical
  # to tenant '1's pebble worker unit (lunarwing-pebble-1). That collision is
  # undisambiguatable downstream (health-openrc.sh's started-gate would mis-key the
  # unit and could mask a real outage as `skipped`), so forbid such names at the
  # source. (weechat-* also covers weechat-adapter-*.)
  case "$name" in
    pg-*|proxy-*|nanocode-*|pebble-*|weechat-*)
      die "tenant name '$name' collides with a reserved per-service unit prefix (pg-/proxy-/nanocode-/pebble-/weechat-/weechat-adapter-); choose another name" ;;
  esac

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
  write_tenant_lunarwing_env "$name" "$xmpp_jid" "$xmpp_password" "$tensorzero_url" "$llm_api_key" "$llm_base_url"
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

  # Host-global health-check + self-heal pipeline (auto-covers every tenant).
  if [[ "$DEFAULT_HEALTH_ENABLED" == "true" && "$HEALTH_OPT_OUT" != "true" ]]; then
    ensure_health_pipeline
  else
    say "health pipeline: disabled (enabled=$DEFAULT_HEALTH_ENABLED, opt-out=$HEALTH_OPT_OUT)"
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

  # If that was the last tenant, retire the host-global health pipeline schedule.
  if [[ -z "$(all_tenant_names)" ]]; then
    remove_health_pipeline
    say ""
  fi

  say "=== Tenant '$name' removed ==="
}

# Re-render a tenant's service units from the current generator WITHOUT touching
# secrets/env or restarting anything — for applying a generator change (e.g. an
# updated init-script status()) to an already-provisioned tenant. The systemd
# renderer daemon-reloads internally; OpenRC reads the script per invocation. A
# status()/health change takes effect immediately; a change to the run command
# needs a restart.
render_tenant_units() {
  local name="$1"
  name="$(sanitize_name "$name")"
  tenant_exists_in_registry "$name" || die "tenant '$name' not found in registry"
  ensure_init_system
  say "--- Re-rendering $INIT_SYSTEM units for $name ---"
  if [[ "$INIT_SYSTEM" == "systemd" ]]; then
    render_tenant_systemd_units "$name"
  else
    render_tenant_openrc_units "$name"
  fi
  say "units re-rendered for '$name' (services NOT restarted)."
  say "run-command changes need a restart to apply: $0 restart-tenant $name"
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
  if _ctr "$name" inspect -f '{{.State.Running}}' "$container_name" 2>/dev/null | grep -q true; then
    say "PostgreSQL: running ($container_name)"
  else
    say "PostgreSQL: stopped ($container_name)"
  fi

  local nanocode_container="lunarwing-nanocode-$name"
  if _ctr "$name" inspect -f '{{.State.Running}}' "$nanocode_container" 2>/dev/null | grep -q true; then
    say "Nanocode worker: running ($nanocode_container, WSS port $(ports_get "$name" nanocode_wss))"
  elif _ctr "$name" inspect "$nanocode_container" &>/dev/null; then
    say "Nanocode worker: stopped ($nanocode_container)"
  else
    say "Nanocode worker: not created"
  fi

  local pebble_container="lunarwing-pebble-$name"
  if _ctr "$name" inspect -f '{{.State.Running}}' "$pebble_container" 2>/dev/null | grep -q true; then
    say "Pebble worker: running ($pebble_container, WSS port $(ports_get "$name" pebble_wss))"
  elif _ctr "$name" inspect "$pebble_container" &>/dev/null; then
    say "Pebble worker: stopped ($pebble_container)"
  else
    say "Pebble worker: not created"
  fi

  ensure_init_system
  say ""
  say "Services ($INIT_SYSTEM):"
  if [[ "$INIT_SYSTEM" == "systemd" ]]; then
    local svcs=("lunarwing-${name}" "xmpp-bridge-${name}" "lunarwing-proxy-${name}" \
                "lunarwing-weechat-${name}" "lunarwing-weechat-adapter-${name}")
    # pg + workers are Quadlet units only on rootless podman; on rootful docker
    # they run as plain containers (shown above), not systemd units.
    if [[ "$MT_ROOTLESS" == "true" ]] && podman_supports_quadlet; then
      svcs+=("lunarwing-pg-${name}" "lunarwing-nanocode-${name}" "lunarwing-pebble-${name}")
    fi
    local svc state
    for svc in "${svcs[@]}"; do
      state="$(_systemctl_user "$name" is-active "${svc}.service" 2>/dev/null || echo "inactive")"
      say "  ${svc}.service: $state"
    done
  else
    local svc state
    for svc in "lunarwing-pg-${name}" "lunarwing-${name}" "xmpp-bridge-${name}" "lunarwing-proxy-${name}" \
               "lunarwing-weechat-${name}" "lunarwing-weechat-adapter-${name}" \
               "lunarwing-nanocode-${name}" "lunarwing-pebble-${name}"; do
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

  ensure_container_runtime
  if [[ "$MT_ROOTLESS" == "true" ]]; then
    _check "rootless: newuidmap setuid" bash -c '[ -u "$(command -v newuidmap 2>/dev/null)" ]'
    _check "rootless: newgidmap setuid" bash -c '[ -u "$(command -v newgidmap 2>/dev/null)" ]'
    _check "rootless: /etc/subuid populated" test -s /etc/subuid
    _check "rootless: /etc/subgid populated" test -s /etc/subgid
    # Every per-tenant container publishes 127.0.0.1:<port>:…, which under rootless
    # needs a userspace port-forwarder (pasta or slirp4netns).
    _check "rootless: pasta or slirp4netns (port-forward)" \
      bash -c 'command -v pasta >/dev/null 2>&1 || command -v slirp4netns >/dev/null 2>&1'
  fi

  ensure_init_system
  _check "init system detected ($INIT_SYSTEM)" true

  if [[ "$INIT_SYSTEM" == "systemd" ]]; then
    _check "loginctl available" command -v loginctl
    if [[ "$MT_ROOTLESS" == "true" ]]; then
      _check "podman >= 4.6 (Quadlet supervision)" podman_supports_quadlet
    fi
    # Per-tenant linger keeps /run/user/<uid> + the systemd --user manager alive
    # across reboot — boot-persistent Quadlet/user units depend on it. (Highest-
    # value rootless-on-systemd check.)
    local _dt _du _duid
    while IFS=$'\t' read -r _dt _du; do
      [[ -n "$_du" ]] || continue
      _duid="$(id -u "$_du" 2>/dev/null || echo "")"
      [[ -n "$_duid" ]] || continue
      _check "tenant $_dt: linger enabled" \
        bash -c "loginctl show-user '$_du' -p Linger --value 2>/dev/null | grep -qx yes"
      _check "tenant $_dt: /run/user/$_duid present" test -d "/run/user/$_duid"
    done < <(jq -r '.tenants // {} | to_entries[] | "\(.key)\t\(.value.user)"' "$PORTS_REGISTRY" 2>/dev/null || true)
  else
    _check "rc-service available" command -v rc-service
    _check "rc-update available" command -v rc-update
  fi

  _check "port registry exists" test -f "$PORTS_REGISTRY"
  _check "source repo exists" test -d "$SOURCE_REPO/ic"
  _check "proxy script exists" test -f "$SOURCE_REPO/tensorzero-proxy-configurations/lunarwing-proxy.py"
  _check "health-check orchestrator present" test -x "$HEALTH_SRC_DIR/infrastructure-health-check.sh"
  _check "self-heal script present" test -x "$HEALTH_SRC_DIR/lunarwing-self-heal.sh"
  _check "curl installed (self-heal/gotify)" command -v curl
  _check "flock installed (self-heal lock)" command -v flock
  if [[ "$DEFAULT_HEALTH_ENABLED" == "true" ]]; then
    _check "health pipeline scheduled" bash -c 'systemctl is-enabled lunarwing-mt-health.timer >/dev/null 2>&1 || crontab -l 2>/dev/null | grep -q lunarwing-mt-health || { command -v fcrontab >/dev/null 2>&1 && fcrontab -l 2>/dev/null | grep -q lunarwing-mt-health; }'
  fi
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
      local name="" docker_group="false" xmpp_jid="" xmpp_password="" tz_url="$DEFAULT_TENSORZERO_URL" gotify_url="$DEFAULT_GOTIFY_URL" gotify_title="$DEFAULT_GOTIFY_TITLE" llm_api_key="" llm_base_url="$DEFAULT_LLM_BASE_URL"
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --docker-group)    docker_group="true"; shift ;;
          --xmpp-jid)        xmpp_jid="$2"; shift 2 ;;
          --no-health)       HEALTH_OPT_OUT=true; shift ;;
          --xmpp-password)   xmpp_password="$2"; shift 2 ;;
          --llm-api-key)     llm_api_key="$2"; shift 2 ;;
          --llm-base-url)    llm_base_url="$2"; shift 2 ;;
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
      add_tenant "$name" "$docker_group" "$xmpp_jid" "$xmpp_password" "$tz_url" "$gotify_url" "$gotify_title" "$llm_api_key" "$llm_base_url"
      ;;

    add-tenants)
      require_root
      local names_csv="" docker_group="false" xmpp_domain="xmpp.localhost" tz_url="$DEFAULT_TENSORZERO_URL" gotify_url="$DEFAULT_GOTIFY_URL" gotify_title="$DEFAULT_GOTIFY_TITLE" llm_api_key="" llm_base_url="$DEFAULT_LLM_BASE_URL"
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --docker-group)    docker_group="true"; shift ;;
          --xmpp-domain)     xmpp_domain="$2"; shift 2 ;;
          --no-health)       HEALTH_OPT_OUT=true; shift ;;
          --llm-api-key)     llm_api_key="$2"; shift 2 ;;
          --llm-base-url)    llm_base_url="$2"; shift 2 ;;
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
        add_tenant "$sname" "$docker_group" "${sname}@${xmpp_domain}" "" "$tz_url" "$gotify_url" "$gotify_title" "$llm_api_key" "$llm_base_url"
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

    render-units)
      require_root
      [[ -n "${1:-}" ]] || die "usage: render-units <name>"
      ports_registry_init
      render_tenant_units "$1"
      ;;

    rotate-pg-password)
      require_root
      [[ -n "${1:-}" ]] || die "usage: rotate-pg-password <name>"
      rotate_tenant_pg_password "$1"
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

    backup-tenant)
      require_root
      local name="${1:-}"
      [[ -n "$name" ]] || die "usage: backup-tenant <name>"
      ports_registry_init
      backup_tenant_postgres "$name"
      ;;

    backup-all)
      require_root
      ports_registry_init
      local names
      names="$(all_tenant_names)"
      [[ -n "$names" ]] || { say "no tenants registered"; exit 0; }
      while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        # Subshell so a per-tenant die() doesn't abort the whole fleet backup.
        ( backup_tenant_postgres "$name" ) || say "WARNING: backup failed for $name (continuing)"
      done <<< "$names"
      ;;

    list-backups)
      ports_registry_init
      list_tenant_backups "${1:-}"
      ;;

    restore-tenant)
      require_root
      local name="" file="" confirmed=false
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --yes) confirmed=true; shift ;;
          -*)    die "unknown flag: $1" ;;
          *)
            if [[ -z "$name" ]]; then name="$1"; shift
            elif [[ -z "$file" ]]; then file="$1"; shift
            else die "unexpected argument: $1"
            fi
            ;;
        esac
      done
      [[ -n "$name" && -n "$file" ]] || die "usage: restore-tenant <name> <file> --yes"
      ports_registry_init
      restore_tenant_postgres "$name" "$file" "$confirmed"
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
