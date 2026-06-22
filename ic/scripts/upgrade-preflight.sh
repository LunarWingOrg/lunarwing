#!/usr/bin/env bash
#
# upgrade-preflight.sh — READ-ONLY readiness assessor for an in-place
# v1.1.0 -> v1.1.4 ("Phoenix") multi-tenant upgrade on systemd + Podman.
#
# It inspects the host and each tenant and prints a per-tenant verdict:
#     GO       — ready for the upgrade-tenant.sh migration
#     CAUTION  — proceed, but be aware of the noted items
#     STOP     — do not upgrade this tenant until the blocker is resolved
#
# The single most important thing it checks is the Podman rootful->rootless
# data-orphan hazard: v1.1.0 ran each tenant's Postgres ROOTFUL (root's container
# store, NO named volume); v1.1.4 defaults MT_ROOTLESS=true (rootless, tenant
# store, named volume). A naive start under v1.1.4 boots the tenant against an
# EMPTY database. This script detects whether the old root-store PG still holds
# the live data so you migrate it (dump -> restore) instead of orphaning it.
#
# It makes no DESTRUCTIVE changes: only `inspect`/`ps`/`rev-parse`/`grep`/
# `pg_isready`/`is-enabled`/`show-user` reads. (One benign side effect: probing
# rootless podman as a tenant initializes that tenant's empty container-store
# directory under its $HOME — harmless, and a no-op for tenants already running
# rootless podman.) Safe to run on a live production fleet at any time.
#
# Usage (run as root — it reads root's container store and tenants' files):
#   sudo ic/scripts/upgrade-preflight.sh <tenant>
#   sudo ic/scripts/upgrade-preflight.sh --all
#   sudo ic/scripts/upgrade-preflight.sh --all --keep-rootful   # assess Runbook B
#
# Exit code: 0 if every assessed tenant is GO/CAUTION; 1 if any tenant is STOP
# (or a host-level prerequisite fails).
set -euo pipefail

TARGET_REF="${UPGRADE_TARGET_REF:-v1.1.4}"
PORTS_REGISTRY="${LUNARWING_PORTS_REGISTRY:-/etc/lunarwing/ports.json}"

KEEP_ROOTFUL=false
TENANT_ARG=""
ALL=false
for a in "$@"; do
  case "$a" in
    --all)          ALL=true ;;
    --keep-rootful) KEEP_ROOTFUL=true ;;
    --target=*)     TARGET_REF="${a#*=}" ;;
    -*)             printf 'unknown arg: %s\n' "$a" >&2; exit 2 ;;
    *)              TENANT_ARG="$a" ;;
  esac
done

WARN_COUNT=0
say()    { printf '%s\n' "$*"; }
warn()   { WARN_COUNT=$((WARN_COUNT + 1)); printf '  CAUTION: %s\n' "$*"; }
stop()   { printf '  STOP:    %s\n' "$*"; }
ok()     { printf '  ok:      %s\n' "$*"; }
note()   { printf '  note:    %s\n' "$*"; }
banner() { printf '\n========== %s ==========\n' "$*"; }
die()    { printf 'error: %s\n' "$*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || die "run as root (sudo): reads root's container store and tenants' files"
command -v jq >/dev/null 2>&1 || die "jq is required"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MT="$SCRIPT_DIR/lunarwing-mt-admin.sh"

# ---- run an external probe without aborting the script (set -e safe) ----------
probe() { local out rc; set +e; out="$("$@" 2>/dev/null)"; rc=$?; set -e; printf '%s' "$out"; return $rc; }

# host counters
HOST_STOP=0

# tenant-level tallies (set by assess_tenant, read by the summary)
declare -A VERDICT

# ---- container runtime detection (mirrors mt-admin's detect_container_runtime) -
# Same precedence as mt-admin (docker-first when both are installed) and same
# override validation, so the verdict reflects what mt-admin will actually drive.
detect_runtime() {
  local o="${LUNARWING_CONTAINER_RUNTIME:-}"
  if [[ -n "$o" ]]; then
    case "${o,,}" in docker|podman) echo "${o,,}"; return ;;
      *) die "unsupported LUNARWING_CONTAINER_RUNTIME='$o' (use docker or podman)" ;; esac
  fi
  if command -v docker >/dev/null 2>&1; then echo docker; return; fi
  if command -v podman >/dev/null 2>&1; then echo podman; return; fi
  echo none
}

podman_ge_46() {
  local v; v="$(probe podman --version | awk '{print $3}')" || return 1
  [[ -n "$v" ]] || return 1
  local maj min; maj="${v%%.*}"; min="${v#*.}"; min="${min%%.*}"
  min="${min//[!0-9]/}"; min="${min:-0}"   # tolerate '4.6.0-rc1' / odd suffixes
  maj="${maj//[!0-9]/}"; maj="${maj:-0}"
  (( maj > 4 || (maj == 4 && min >= 6) ))
}

RUNTIME="$(detect_runtime)"

# tenant rootless podman wrapper (read-only inspect/ps as the tenant user)
_tctr() {
  local name="$1"; shift
  local uid home
  uid="$(id -u "$name" 2>/dev/null)" || return 1
  home="$(getent passwd "$name" | cut -d: -f6)"
  ( cd / && exec sudo -u "$name" env HOME="$home" XDG_RUNTIME_DIR="/run/user/$uid" "$RUNTIME" "$@" )
}

# ============================ HOST CHECKS =====================================
host_checks() {
  banner "Host prerequisites"

  case "$RUNTIME" in
    podman) ok "container runtime: podman" ;;
    docker) note "container runtime: docker — the rootful->rootless flip does NOT apply; use --keep-rootful semantics (no data migration needed)" ;;
    none)   stop "no container runtime (podman/docker) found"; HOST_STOP=1 ;;
  esac

  if [[ "$RUNTIME" == podman ]]; then
    if podman_ge_46; then
      ok "podman >= 4.6 (Quadlet supervision available)"
    else
      warn "podman < 4.6 — rootless Quadlet supervision unavailable; rootless PG would run unsupervised with NO boot persistence. Upgrade podman or use --keep-rootful."
    fi
  fi

  if [[ -f "$PORTS_REGISTRY" ]]; then
    local pv; pv="$(jq -r '.version // 0' "$PORTS_REGISTRY" 2>/dev/null || echo 0)"
    if [[ "$pv" -ge 7 ]]; then ok "ports.json present (schema v$pv, darkirc ports ready)"
    elif [[ "$pv" -ge 6 ]]; then warn "ports.json at schema v$pv (< 7) — darkirc_irc/darkirc_rpc may be missing; run migrate-ports-v7.sh (backs up + validates) at your convenience"
    else warn "ports.json at schema v$pv (< 6) — additive, non-breaking; run migrate-ports-v6.sh (backs up + validates), then migrate-ports-v6.1.sh and migrate-ports-v7.sh, at your convenience"; fi
  else
    stop "ports registry not found: $PORTS_REGISTRY"; HOST_STOP=1
  fi

  if [[ -x "$MT" ]]; then
    if grep -q 'MT_ROOTLESS' "$MT" && grep -qE '^\s*restore-tenant\)' "$MT"; then
      ok "mt-admin is v1.1.4-class (MT_ROOTLESS + restore-tenant present)"
    else
      stop "mt-admin at $MT looks older than v1.1.4 (no MT_ROOTLESS/restore-tenant) — re-running add-tenant with it can DESTROY tenant secrets. Update the repo first."; HOST_STOP=1
    fi
  else
    stop "mt-admin not found/executable at $MT"; HOST_STOP=1
  fi

  command -v pg_isready >/dev/null 2>&1 || note "pg_isready not on PATH (DB-reachability probe runs inside the container instead)"
}

# ============================ TENANT CHECKS ===================================
assess_tenant() {
  local name="$1"
  local verdict="GO"
  local w0=$WARN_COUNT          # snapshot warn count; any tenant-scope warn -> CAUTION
  banner "Tenant: $name"

  if ! jq -e ".tenants[\"$name\"]" "$PORTS_REGISTRY" >/dev/null 2>&1; then
    stop "not in ports registry $PORTS_REGISTRY"; VERDICT[$name]="STOP"; return
  fi

  local uid home lwroot envf
  if ! uid="$(id -u "$name" 2>/dev/null)"; then
    stop "OS user '$name' does not exist"; VERDICT[$name]="STOP"; return
  fi
  home="$(getent passwd "$name" | cut -d: -f6)"
  lwroot="$home/lunarwing"
  envf="$lwroot/env/lunarwing.env"
  ok "user uid=$uid home=$home"

  # --- tenant clone present + git rev vs target ---
  if [[ -d "$lwroot/.git" ]]; then
    local rev desc
    rev="$(probe sudo -u "$name" git -C "$lwroot" rev-parse --short HEAD || true)"
    desc="$(probe sudo -u "$name" git -C "$lwroot" describe --tags --always || true)"
    note "clone at ${rev:-?} (${desc:-?})"
    # is the target ref reachable / already checked out?
    if sudo -u "$name" git -C "$lwroot" rev-parse --verify -q "$TARGET_REF" >/dev/null 2>&1; then
      if sudo -u "$name" git -C "$lwroot" merge-base --is-ancestor "$TARGET_REF" HEAD 2>/dev/null; then
        ok "clone already contains $TARGET_REF"
      else
        warn "clone is BEHIND $TARGET_REF — upgrade-tenant.sh will fetch+checkout+rebuild"
      fi
    else
      warn "$TARGET_REF not present locally — a 'git fetch --tags' is needed before checkout"
    fi
    if [[ -n "$(probe sudo -u "$name" git -C "$lwroot" status --porcelain || true)" ]]; then
      warn "tenant clone has uncommitted changes — checkout may need --yes (stash) in upgrade-tenant.sh"
    fi
  else
    stop "tenant clone $lwroot is not a git repo — cannot update/rebuild the daemon"; verdict="STOP"
  fi

  # --- env: secrets must be preservable ---
  if [[ -f "$envf" ]]; then
    if grep -q '^SECRETS_MASTER_KEY=' "$envf"; then ok "SECRETS_MASTER_KEY present (preserved on re-add)"
    else warn "SECRETS_MASTER_KEY not in $envf — encrypted DB secrets may be unrecoverable; locate it before upgrading"; fi
    grep -q '^HTTP_HOST=' "$envf"          || warn "HTTP_HOST missing — webhook binds 0.0.0.0; the add-tenant re-run back-fills HTTP_HOST=127.0.0.1"
    grep -q '^HTTP_WEBHOOK_SECRET=' "$envf" || note "HTTP_WEBHOOK_SECRET missing — back-filled by the add-tenant re-run"
  else
    stop "tenant env not found: $envf"; verdict="STOP"
  fi

  # --- THE critical check: where does the live PG data live? ---
  local pg="lunarwing-pg-$name"
  local root_state rootless_state
  root_state="$(probe podman inspect -f '{{.State.Running}}' "$pg" || true)"   # root store
  rootless_state="$(probe _tctr "$name" inspect -f '{{.State.Running}}' "$pg" || true)"

  if [[ "$RUNTIME" == podman && "$KEEP_ROOTFUL" == false ]]; then
    if [[ -n "$root_state" ]]; then
      note "ROOT-store PG container exists (Running=$root_state) — this holds the v1.1.0 data"
      if [[ "$root_state" == true ]]; then
        # confirm reachable so backup-tenant can dump it
        if probe podman exec "$pg" pg_isready -U lunarwing -q; then
          local sz
          sz="$(probe podman exec "$pg" psql -U lunarwing -tAc "SELECT pg_size_pretty(pg_database_size('lunarwing'))" || true)"
          ok "root-store PG reachable (db size ${sz:-unknown}) — MIGRATION REQUIRED: dump from root store -> restore into rootless"
        else
          stop "root-store PG container present but pg_isready failed — start it before backup, or investigate"; verdict="STOP"
        fi
      else
        warn "root-store PG is STOPPED — start it (LUNARWING_MT_ROOTLESS=false start-tenant) so backup-tenant can dump the live data before migrating"
      fi
      [[ -n "$rootless_state" ]] && warn "a ROOTLESS PG container ALSO exists (Running=$rootless_state) — a prior partial start may have created an empty rootless DB; verify before restore"
    elif [[ -n "$rootless_state" ]]; then
      # No root-store PG, only a rootless one: either already-migrated (has data)
      # or the empty post-flip orphan. Probe DATA ROWS (not table existence — the
      # daemon's migrations create the schema regardless of any restore) to tell
      # them apart, gating on reachability first so "unreachable" != "empty".
      if [[ "$rootless_state" == true ]]; then
        if probe _tctr "$name" exec "$pg" pg_isready -U lunarwing -q; then
          local rows
          rows="$(probe _tctr "$name" exec "$pg" psql -U lunarwing -tAc "SELECT (SELECT count(*) FROM conversations)+(SELECT count(*) FROM conversation_messages)" | tr -cd '0-9' || true)"
          if [[ "${rows:-0}" -gt 0 ]]; then
            ok "rootless PG holds $rows conversation rows — already migrated; no action needed"
          else
            stop "rootless PG is reachable but has 0 conversation rows — looks like the EMPTY post-flip DB and no root-store copy remains. Restore from a backup before proceeding."; verdict="STOP"
          fi
        else
          warn "a rootless PG exists and is Running but pg_isready failed — can't tell whether it holds data; recheck it before proceeding (do NOT assume empty)"
        fi
      else
        warn "a rootless PG exists but is STOPPED and there's no root-store PG — start it and re-check whether it holds data before proceeding"
      fi
    else
      stop "no PG container found in EITHER store for $name — cannot locate the tenant's data; investigate before upgrading"; verdict="STOP"
    fi
  else
    # keep-rootful (or docker): the existing container is reused in place
    if [[ -n "$root_state" ]]; then ok "PG container present (Running=$root_state) — reused in place (no flip)"
    else warn "no PG container found for $name — verify the tenant's DB location"; fi
  fi

  # --- rootless prereqs (only needed when adopting rootless) ---
  if [[ "$RUNTIME" == podman && "$KEEP_ROOTFUL" == false ]]; then
    grep -q "^${name}:" /etc/subuid 2>/dev/null && grep -q "^${name}:" /etc/subgid 2>/dev/null \
      && ok "subuid/subgid allocated" \
      || note "subuid/subgid not yet allocated — the add-tenant re-run (ensure_rootless_prereqs) provisions them"
    [[ -d "/run/user/$uid" ]] && ok "/run/user/$uid present" \
      || note "/run/user/$uid absent — provisioned by ensure_rootless_prereqs (linger recreates at boot)"
    local linger; linger="$(probe loginctl show-user "$name" -p Linger --value || true)"
    [[ "$linger" == yes ]] && ok "linger enabled (user manager survives logout/reboot)" \
      || warn "linger not enabled for $name — Quadlet PG won't survive reboot until enabled (loginctl enable-linger $name)"
  fi

  # --- orphaned old weechat unit (rename weechat-<t> -> lunarwing-weechat-<t>) ---
  if [[ -f "$home/.config/systemd/user/weechat-$name.service" ]]; then
    warn "stale old-name unit weechat-$name.service present — disable+remove after upgrade (replaced by lunarwing-weechat-$name.service)"
  fi

  # --- passwordless sudo -n root->tenant (needed by _ctr + self-heal) ---
  probe sudo -n -u "$name" true && ok "passwordless sudo -n root->$name works" \
    || warn "sudo -n -u $name failed — rootless container ops and self-heal restarts need passwordless root->tenant sudo"

  # finalize three-state: STOP wins; otherwise any tenant-scope CAUTION -> CAUTION
  if [[ "$verdict" != "STOP" && $WARN_COUNT -gt $w0 ]]; then verdict="CAUTION"; fi
  case "$verdict" in
    STOP)    stop "tenant '$name' is NOT ready (see STOP items above)" ;;
    CAUTION) say "  => CAUTION: tenant '$name' can proceed, but review the CAUTION items above" ;;
    GO)      ok "tenant '$name' is ready (GO)" ;;
  esac
  VERDICT[$name]="$verdict"
}

# ================================ MAIN ========================================
host_checks
HOST_WARN=$WARN_COUNT          # host-scope CAUTIONs (podman<4.6, ports.json<6, ...)

declare -a TENANTS=()
if [[ "$ALL" == true ]]; then
  mapfile -t TENANTS < <(jq -r '.tenants | keys[]' "$PORTS_REGISTRY" 2>/dev/null || true)
  [[ ${#TENANTS[@]} -gt 0 ]] || die "no tenants in $PORTS_REGISTRY"
elif [[ -n "$TENANT_ARG" ]]; then
  TENANTS=("$TENANT_ARG")
else
  die "usage: $0 <tenant> | --all  [--keep-rootful] [--target=<rev>]"
fi

for t in "${TENANTS[@]}"; do
  [[ -n "$t" ]] && assess_tenant "$t"
done

banner "Summary"
if [[ $HOST_STOP -ne 0 ]]; then say "Host: STOP (prerequisite failed)"
elif [[ $HOST_WARN -gt 0 ]]; then say "Host: CAUTION ($HOST_WARN item(s) — see host checks above)"
else say "Host: OK"; fi
exit_code=$HOST_STOP
for t in "${TENANTS[@]}"; do
  [[ -n "$t" ]] || continue
  printf '  %-24s %s\n' "$t" "${VERDICT[$t]:-?}"
  [[ "${VERDICT[$t]:-}" == "STOP" ]] && exit_code=1
done
say ""
say "Legend: GO = ready · CAUTION = proceed with awareness · STOP = resolve first"
exit "$exit_code"
