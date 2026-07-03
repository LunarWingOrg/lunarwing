#!/usr/bin/env bash
set -euo pipefail

# ── Branch Test Loop ──────────────────────────────────────────────────────────
#
# Sequentially tests code changes across git branches by provisioning a fresh
# tenant per branch, running a test suite, capturing results, and tearing down.
#
# Designed for resource-constrained Gentoo/OpenRC hosts (6 threads, limited disk).
# One tenant at a time. Binary-only rebuild per branch (WASM + worker images are
# snapshotted from a base build and reused).
#
# Usage:
#   ic/scripts/branch-test-loop.sh snapshot                    # build base once
#   ic/scripts/branch-test-loop.sh run [branch1 branch2 ...]    # test branches
#   ic/scripts/branch-test-loop.sh results                      # print summary
#   ic/scripts/branch-test-loop.sh clean                       # remove snapshot
#
# Prerequisites:
#   - Root/sudo (mt-admin needs it)
#   - The base branch must already be built as a tenant (snapshot phase)
#   - taskset -c 0-5 for all cargo commands (enforced below)
#
# Test cases are defined in the TEST SUITE section below. Override by creating
# a test file at $TEST_FILE (default: ic/scripts/branch-tests/custom.sh).

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
LUNARWING_ROOT="$(cd -- "${REPO_ROOT}/.." && pwd)"
MT="${SCRIPT_DIR}/lunarwing-mt-admin.sh"

SNAPSHOT_DIR="${LUNARWING_ROOT}/.branch-test-snapshot"
RESULTS_DIR="${LUNARWING_ROOT}/.branch-test-results"
TEST_FILE="${SCRIPT_DIR}/branch-tests/custom.sh"

BASE_BRANCH="${BASE_BRANCH:-main}"
TENANT_PREFIX="btest"
THREADS="0-5"
JOBS=6

say()    { printf '%s\n' "$*"; }
die()    { printf 'error: %s\n' "$*" >&2; exit 1; }
banner() { printf '\n========== %s ==========\n' "$*"; }

require_root() { [[ "${EUID}" -eq 0 ]] || die "run as root (sudo)"; }

# ── Snapshot phase ────────────────────────────────────────────────────────────
#
# Builds a base tenant with full --with-wasm, then snapshots:
#   - WASM artifacts (state/channels/, state/tools/)
#   - PG dump
#   - Worker image reference (not the image itself — too large to snapshot)
#
# The snapshot is reused per-branch to skip WASM + worker rebuilds.

do_snapshot() {
  require_root
  banner "Snapshot phase — building base tenant on '${BASE_BRANCH}'"

  local base_tenant="${TENANT_PREFIX}-base"

  # Verify we're on the base branch
  local current
  current="$(cd "${REPO_ROOT}" && git branch --show-current)"
  [[ "$current" == "$BASE_BRANCH" ]] \
    || die "repo is on '${current}', must be on '${BASE_BRANCH}' to snapshot"

  # Provision base tenant if it doesn't exist
  if ! jq -e ".tenants[\"${base_tenant}\"]" /etc/lunarwing/ports.json >/dev/null 2>&1; then
    say "provisioning base tenant: ${base_tenant}"
    "$MT" add-tenant "$base_tenant" --no-health --no-ssh
    "$MT" build-tenant "$base_tenant" --with-wasm
    "$MT" install-wasm "$base_tenant"
  else
    say "base tenant already exists: ${base_tenant}"
  fi

  local home
  home="$(getent passwd "$base_tenant" | cut -d: -f6)"
  local lwroot="${home}/lunarwing"

  # Create snapshot dir
  rm -rf "$SNAPSHOT_DIR"
  mkdir -p "$SNAPSHOT_DIR/wasm-channels" "$SNAPSHOT_DIR/wasm-tools"

  # Snapshot WASM artifacts
  say "snapshotting WASM artifacts..."
  cp -a "$lwroot/state/channels/"*.wasm "$SNAPSHOT_DIR/wasm-channels/" 2>/dev/null || true
  cp -a "$lwroot/state/channels/"*.capabilities.json "$SNAPSHOT_DIR/wasm-channels/" 2>/dev/null || true
  cp -a "$lwroot/state/tools/"*.wasm "$SNAPSHOT_DIR/wasm-tools/" 2>/dev/null || true
  cp -a "$lwroot/state/tools/"*.capabilities.json "$SNAPSHOT_DIR/wasm-tools/" 2>/dev/null || true

  # Snapshot PG
  say "snapshotting PostgreSQL..."
  "$MT" backup-tenant "$base_tenant" 2>/dev/null || true
  local latest_backup
  latest_backup="$(ls -t /var/lib/lunarwing-backups/${base_tenant}/*.dump 2>/dev/null | head -1)"
  if [[ -n "$latest_backup" ]]; then
    cp "$latest_backup" "$SNAPSHOT_DIR/base.dump"
    say "PG snapshot: $SNAPSHOT_DIR/base.dump"
  else
    say "WARNING: no PG backup found (tests will start with empty DB)"
  fi

  # Snapshot the built binary (for sanity comparison)
  if [[ -f "$lwroot/ic/target/release/lunarwing" ]]; then
    cp "$lwroot/ic/target/release/lunarwing" "$SNAPSHOT_DIR/lunarwing-base"
    say "base binary snapshotted"
  fi

  # Record snapshot metadata
  cat >"$SNAPSHOT_DIR/meta.txt" <<EOF
base_branch=${BASE_BRANCH}
base_tenant=${base_tenant}
created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
wasm_channels=$(ls "$SNAPSHOT_DIR/wasm-channels/"*.wasm 2>/dev/null | wc -l)
wasm_tools=$(ls "$SNAPSHOT_DIR/wasm-tools/"*.wasm 2>/dev/null | wc -l)
EOF

  banner "Snapshot complete"
  cat "$SNAPSHOT_DIR/meta.txt"
  say ""
  say "Ready for: sudo $0 run [branch1 branch2 ...]"
}

# ── Per-branch test cycle ────────────────────────────────────────────────────

run_branch() {
  local branch="$1"
  local tenant="${TENANT_PREFIX}-${branch//\//-}"

  banner "Testing branch: ${branch} (tenant: ${tenant})"

  # Cleanup any leftover tenant from a prior failed run
  if jq -e ".tenants[\"${tenant}\"]" /etc/lunarwing/ports.json >/dev/null 2>&1; then
    say "cleaning up leftover tenant: ${tenant}"
    "$MT" stop-tenant "$tenant" 2>/dev/null || true
    "$MT" remove-tenant "$tenant" --purge 2>/dev/null || true
  fi

  # 1. Provision tenant (no health, no SSH — keep it lean)
  say "1/6 provisioning tenant..."
  "$MT" add-tenant "$tenant" --no-health --no-ssh 2>&1 | tail -3

  local home
  home="$(getent passwd "$tenant" | cut -d: -f6)"
  local lwroot="${home}/lunarwing"
  local repo="${lwroot}/ic"

  # 2. Checkout the branch in the tenant's clone
  say "2/6 checking out branch ${branch}..."
  sudo -u "$tenant" bash -c "cd '${repo}' && git fetch origin && git checkout '${branch}'" 2>&1 | tail -3

  # 3. Binary-only build (skip WASM — use snapshot)
  say "3/6 building binary (binary-only, ${JOBS} jobs)..."
  tmux new-session -d -s "btest-${tenant}" \
    "sudo -u ${tenant} bash -c 'cd ${repo} && taskset -c ${THREADS} cargo build --release --bin lunarwing -j${JOBS} 2>&1' | tee /tmp/btest-${tenant}.log"

  # Wait for build to finish
  local build_wait=0
  while tmux has-session -t "btest-${tenant}" 2>/dev/null; do
    sleep 10
    build_wait=$((build_wait + 10))
    [[ $build_wait -gt 1800 ]] && { say "BUILD TIMEOUT (30min)"; break; }
  done

  # Check build result
  if [[ ! -f "${repo}/target/release/lunarwing" ]]; then
    say "BUILD FAILED — skipping tests for ${branch}"
    write_result "$branch" "FAIL" "build failed" "{}"
    "$MT" remove-tenant "$tenant" --purge 2>/dev/null || true
    return 1
  fi
  say "build OK"

  # 4. Restore WASM artifacts from snapshot (skip WASM build)
  say "4/6 installing WASM from snapshot..."
  mkdir -p "${lwroot}/state/channels" "${lwroot}/state/tools"
  cp -a "$SNAPSHOT_DIR/wasm-channels/"* "${lwroot}/state/channels/" 2>/dev/null || true
  cp -a "$SNAPSHOT_DIR/wasm-tools/"* "${lwroot}/state/tools/" 2>/dev/null || true
  chown -R "${tenant}:${tenant}" "${lwroot}/state"

  # 5. Start tenant and run tests
  say "5/6 starting tenant..."
  "$MT" start-tenant "$tenant" 2>&1 | tail -5

  # Wait for gateway to be ready
  local gateway_port
  gateway_port="$(jq -r ".tenants[\"${tenant}\"].ports.gateway" /etc/lunarwing/ports.json)"
  local ready=0
  for i in $(seq 1 30); do
    curl -sf "http://127.0.0.1:${gateway_port}/healthz" >/dev/null 2>&1 && { ready=1; break; }
    sleep 2
  done
  [[ $ready -eq 1 ]] || { say "GATEWAY NOT READY — skipping tests"; write_result "$branch" "FAIL" "gateway not ready" "{}"; "$MT" remove-tenant "$tenant" --purge 2>/dev/null || true; return 1; }

  # Get auth token
  local token
  token="$("$MT" tokens "$tenant" 2>/dev/null | grep -oE '[a-f0-9]{64}' | head -1)"

  say "6/6 running test suite..."
  local http_port
  http_port="$(jq -r ".tenants[\"${tenant}\"].ports.http" /etc/lunarwing/ports.json)"
  run_tests "$branch" "$gateway_port" "$http_port" "$token"

  # Teardown
  say "tearing down..."
  "$MT" stop-tenant "$tenant" 2>/dev/null || true
  "$MT" remove-tenant "$tenant" --purge 2>/dev/null || true

  # Clean build artifacts + podman to reclaim disk
  say "cleaning disk..."
  # Already purged the home dir, just prune containers
  podman system prune -f 2>/dev/null || true

  say "branch ${branch} complete"
}

# ── Test suite ───────────────────────────────────────────────────────────────
#
# Each test writes a JSON result to $RESULTS_DIR/<branch>.json.
# Override by sourcing $TEST_FILE if it exists.

run_tests() {
  local branch="$1" gateway="$2" http_port="$3" token="$4"
  local results_file="${RESULTS_DIR}/${branch//\//-}.json"
  local pass_count=0 fail_count=0
  local -a results=()

  mkdir -p "$RESULTS_DIR"

  # Source custom tests if available
  if [[ -f "$TEST_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$TEST_FILE"
    if declare -f custom_tests >/dev/null 2>&1; then
      custom_tests "$branch" "$gateway" "$http_port" "$token" "$results_file"
      return
    fi
  fi

  # Default test suite
  test_gateway_health() {
    local resp
    resp="$(curl -sf "http://127.0.0.1:${gateway}/healthz" 2>/dev/null)" || return 1
    [[ -n "$resp" ]]
  }

  test_agent_status() {
    local resp
    resp="$(curl -sf "http://127.0.0.1:${http_port}/agent/status" 2>/dev/null)" || return 1
    echo "$resp" | grep -q '"running":true' || return 1
  }

  test_ssh_tool() {
    # Send a chat message asking the agent to use the ssh tool
    # This is async — we poll for the response via SSE
    local resp http_code
    resp="$(curl -s -w '\n%{http_code}' \
      -X POST "http://127.0.0.1:${gateway}/api/chat/send" \
      -H "Authorization: Bearer ${token}" \
      -H "Content-Type: application/json" \
      -d '{"message":"Use the ssh tool to connect to 127.0.0.1 as user '"${tenant}"' and run \"hostname\". Show me the output."}')" || return 1
    http_code="$(echo "$resp" | tail -1)"
    [[ "$http_code" == "200" || "$http_code" == "202" ]]
  }

  # Run each test
  for test_fn in test_gateway_health test_agent_status test_ssh_tool; do
    local test_name="$test_fn"
    local result="PASS"
    if $test_fn 2>/dev/null; then
      pass_count=$((pass_count + 1))
    else
      result="FAIL"
      fail_count=$((fail_count + 1))
    fi
    results+=("{\"test\":\"${test_name}\",\"result\":\"${result}\"}")
    say "  ${result} ${test_name}"
  done

  # Write results JSON
  local json_results
  json_results="$(printf '%s\n' "${results[@]}" | paste -sd,)"
  cat >"$results_file" <<EOF
{
  "branch": "${branch}",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "passed": ${pass_count},
  "failed": ${fail_count},
  "overall": "$([[ $fail_count -eq 0 ]] && echo PASS || echo FAIL)",
  "tests": [${json_results}]
}
EOF

  say "results: ${results_file} (${pass_count} passed, ${fail_count} failed)"
}

write_result() {
  local branch="$1" overall="$2" detail="$3" tests_json="${4:-{}}"
  local results_file="${RESULTS_DIR}/${branch//\//-}.json"
  mkdir -p "$RESULTS_DIR"
  cat >"$results_file" <<EOF
{
  "branch": "${branch}",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "overall": "${overall}",
  "detail": "${detail}",
  "tests": ${tests_json}
}
EOF
}

# ── Results summary ────────────────────────────────────────────────────────

do_results() {
  banner "Branch Test Results"
  printf '%-40s %-8s %-8s %-8s %s\n' "BRANCH" "PASS" "FAIL" "OVERALL" "TIMESTAMP"
  printf '%s\n' "------------------------------------------------------------"

  for f in "$RESULTS_DIR"/*.json; do
    [[ -f "$f" ]] || continue
    local branch passed failed overall ts
    branch="$(jq -r '.branch' "$f")"
    passed="$(jq -r '.passed // 0' "$f")"
    failed="$(jq -r '.failed // 0' "$f")"
    overall="$(jq -r '.overall' "$f")"
    ts="$(jq -r '.timestamp' "$f")"
    printf '%-40s %-8s %-8s %-8s %s\n' "$branch" "$passed" "$failed" "$overall" "$ts"
  done
  say ""
}

# ── Clean ───────────────────────────────────────────────────────────────────

do_clean() {
  require_root
  banner "Cleaning snapshot + results"
  # Remove the base tenant
  local base_tenant="${TENANT_PREFIX}-base"
  if jq -e ".tenants[\"${base_tenant}\"]" /etc/lunarwing/ports.json >/dev/null 2>&1; then
    "$MT" stop-tenant "$base_tenant" 2>/dev/null || true
    "$MT" remove-tenant "$base_tenant" --purge 2>/dev/null || true
  fi
  rm -rf "$SNAPSHOT_DIR" "$RESULTS_DIR"
  podman system prune -f 2>/dev/null || true
  say "cleaned snapshot, results, and base tenant"
}

# ── Main ────────────────────────────────────────────────────────────────────

usage() {
  cat <<EOF
Usage: sudo $0 <command> [args]

Commands:
  snapshot                    Build the base snapshot (run once on ${BASE_BRANCH})
  run [branch1 branch2 ...]   Test specific branches (defaults to all local branches)
  results                     Print results summary table
  clean                       Remove snapshot, results, and base tenant

Environment:
  BASE_BRANCH                 Base branch for snapshot (default: main)
  TENANT_PREFIX               Tenant name prefix (default: btest)
  TEST_FILE                   Custom test file to source (default: branch-tests/custom.sh)

Workflow:
  1. git checkout main && sudo $0 snapshot
  2. sudo $0 run feature-a feature-b fix-ssh-git
  3. sudo $0 results
  4. sudo $0 clean
EOF
}

[[ $# -eq 0 ]] && { usage; exit 0; }

case "$1" in
  snapshot)  shift; do_snapshot "$@" ;;
  run)      shift; do_run "$@" ;;
  results)  do_results ;;
  clean)    do_clean ;;
  *)        usage; exit 1 ;;
esac

# ── Run loop ─────────────────────────────────────────────────────────────────

do_run() {
  require_root
  banner "Branch test loop"

  # Verify snapshot exists
  [[ -d "$SNAPSHOT_DIR" ]] || die "no snapshot found — run 'snapshot' first"
  [[ -f "$SNAPSHOT_DIR/meta.txt" ]] || die "snapshot incomplete (missing meta.txt)"

  say "snapshot: $(cat "$SNAPSHOT_DIR/meta.txt" | tr '\n' ' ')"

  # Determine branches to test
  local -a branches
  if [[ $# -gt 0 ]]; then
    branches=("$@")
  else
    say "no branches specified — using all local branches except main"
    mapfile -t branches < <(cd "$REPO_ROOT" && git branch --format='%(refname:short)' | grep -v "^${BASE_BRANCH}$")
  fi

  [[ ${#branches[@]} -gt 0 ]] || die "no branches to test"

  say "branches: ${branches[*]}"
  say "tenant prefix: ${TENANT_PREFIX}"
  say ""

  local total=${#branches[@]}
  local current=0

  for branch in "${branches[@]}"; do
    current=$((current + 1))
    say ""
    say ">>> [$current/$total] Branch: ${branch}"
    run_branch "$branch" || say ">>> branch ${branch} failed (continuing)"
    say ""
    say "disk: $(df -h / | tail -1 | awk '{print $4 " free"}')"
  done

  banner "All branches tested"
  do_results
}