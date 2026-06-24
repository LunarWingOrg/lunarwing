#!/usr/bin/env bash
# ============================================================
# build-lunarwing.sh — LunarWing native build script for a Pi 5
# ============================================================
#
# Builds the LunarWing (ic) crate natively on aarch64.
# Designed for Raspberry Pi 5 or similar low-resource ARM systems.
#
# Usage:
#   ./scripts/build-lunarwing.sh [OPTIONS]
#
# Options:
#   -c, --clean       Run cargo clean before building
#   -j, --jobs N      Number of parallel jobs (default: 2)
#   -t, --target DIR  Override CARGO_TARGET_DIR
#   -r, --repo DIR    Override repo root path
#   --profile MODE    Build profile: release (default) or debug   PRO TIP DONT USE DEBUG LOL
#   --wasm            Also build Telegram WASM channel (separate target dir)
#   --no-kill         Don't kill stale cargo/rustc processes
#   -v, --verbose     Show cargo output in real-time
#   -h, --help        Show this help message
#
# Environment variables (override flags):
#   CARGO_TARGET_DIR  Build artifacts directory
#   LUNARWING_REPO   Repo root path
#   BUILD_JOBS        Number of parallel jobs
#
# Examples:
#   ./scripts/build-lunarwing.sh                    # Default: release, -j2
#   ./scripts/build-lunarwing.sh -c                 # Clean + build
#   ./scripts/build-lunarwing.sh -j 4 --profile debug  # Debug build, 4 jobs
#   ./scripts/build-lunarwing.sh --wasm             # Also build WASM channels

set -euo pipefail

# ── Defaults ───────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${LUNARWING_REPO:-$(cd "$SCRIPT_DIR/.." && pwd)}"
IC_DIR="$REPO_ROOT/ic"
TARGET_DIR="${CARGO_TARGET_DIR:-$HOME/.cargo-target}"
WASM_TARGET_DIR="${TARGET_DIR}-wasm"
JOBS="${BUILD_JOBS:-1}"
PROFILE="release"
DO_CLEAN=false
DO_WASM=false
DO_KILL=true
VERBOSE=false

# ── Colors ─────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ── Helpers ────────────────────────────────────────────────

log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

usage() {
    sed -n '2,/^# Examples:/p' "$0" | sed 's/^# *//' | sed 's/^#//'
    exit 0
}

check_cargo() {
    if ! command -v cargo &>/dev/null; then
        if [ -x "$HOME/.cargo/bin/cargo" ]; then
            export PATH="$HOME/.cargo/bin:$PATH"
        else
            log_error "cargo not found. Run install_rust_debian.sh first."
            exit 1
        fi
    fi
    log_ok "cargo $(cargo --version | awk '{print $2}')"
    log_ok "rustc $(rustc --version | awk '{print $2}')"
}

check_repo() {
    if [ ! -f "$IC_DIR/Cargo.toml" ]; then
        log_error "Cargo.toml not found at $IC_DIR/Cargo.toml"
        log_error "Is LUNARWING_REPO set correctly? (current: $REPO_ROOT)"
        exit 1
    fi
    log_ok "Repo: $REPO_ROOT"
}

check_target_dir() {
    # Warn if target dir is on tmpfs (will run out of space)
    local mount_point
    mount_point=$(df "$TARGET_DIR" 2>/dev/null | tail -1 | awk '{print $1}')
    if [[ "$mount_point" == *"tmpfs"* ]] || [[ "$mount_point" == *"tmp"* ]]; then
        log_warn "Target directory is on tmpfs — builds may fail due to space limits"
        log_warn "Consider: export CARGO_TARGET_DIR=/home/\$USER/.cargo-target"
    fi
    log_ok "Target: $TARGET_DIR"

    # Memory check — Pi 5 with 4GB RAM struggles with -j2 release builds
    local mem_total_kb
    mem_total_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null)
    local mem_total_mb=$((mem_total_kb / 1024))
    if [ "$mem_total_mb" -lt 6144 ] && [ "$JOBS" -gt 1 ]; then
        log_warn "System has ${mem_total_mb}MB RAM with -j${JOBS} — OOM kills are likely"
        log_warn "Consider: -j 1  (or add more swap)"
    fi
    log_ok "Memory: ${mem_total_mb}MB total, $(awk '/MemAvailable/ {printf "%.0f", $2/1024}' /proc/meminfo)MB available"
}

kill_stale_processes() {
    if [ "$DO_KILL" = false ]; then
        return
    fi

    local found=false
    if pgrep -f "cargo build.*--release" &>/dev/null || \
       pgrep -f "cargo build.*wasm32" &>/dev/null; then
        found=true
    fi

    if [ "$found" = true ]; then
        log_info "Killing stale cargo/rustc processes..."
        pkill -9 -f "cargo build" 2>/dev/null || true
        pkill -9 -f "rustc.*lunarwing" 2>/dev/null || true
        sleep 2

        # Verify they're dead
        if pgrep -f "cargo build" &>/dev/null; then
            log_warn "Some cargo processes survived — forcing kill"
            pkill -9 cargo 2>/dev/null || true
            pkill -9 rustc 2>/dev/null || true
            sleep 1
        fi
        log_ok "Stale processes killed"
    else
        log_ok "No stale cargo/rustc processes found"
    fi
}

clear_locks() {
    local lock_count=0
    while IFS= read -r lockfile; do
        rm -f "$lockfile"
        lock_count=$((lock_count + 1))
    done < <(find "$TARGET_DIR" -type f \( -name ".cargo-lock" -o -name ".cargo-build-lock" -o -name ".cargo-artifact-lock" \) 2>/dev/null)

    while IFS= read -r lockfile; do
        rm -f "$lockfile"
        lock_count=$((lock_count + 1))
    done < <(find "$WASM_TARGET_DIR" -type f \( -name ".cargo-lock" -o -name ".cargo-build-lock" -o -name ".cargo-artifact-lock" \) 2>/dev/null)

    # Also clear stale locks in the global cargo home
    for f in "$HOME/.cargo/.package-cache" "$HOME/.cargo/.package-cache-mutate"; do
        if [ -f "$f" ]; then
            rm -f "$f"
            lock_count=$((lock_count + 1))
        fi
    done

    if [ "$lock_count" -gt 0 ]; then
        log_ok "Cleared $lock_count stale lock file(s)"
    else
        log_ok "No stale lock files found"
    fi
}

run_clean() {
    if [ "$DO_CLEAN" = true ]; then
        log_info "Running cargo clean..."
        (cd "$IC_DIR" && cargo clean) 2>&1
        log_ok "Clean complete"
    fi
}

run_build() {
    local profile_flag=""
    local profile_name="$PROFILE"
    if [ "$PROFILE" = "release" ]; then
        profile_flag="--release"
    fi

    local log_file="/tmp/cargo_build_$(date +%Y%m%d_%H%M%S).log"

    echo ""
    echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║         LunarWing Build — $profile_name profile           ║${NC}"
    echo -e "${BOLD}${CYAN}╠══════════════════════════════════════════════════╣${NC}"
    echo -e "${BOLD}${CYAN}║${NC}  Jobs:     ${BOLD}$JOBS${NC}                                  ${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}║${NC}  Target:   ${BOLD}$TARGET_DIR${NC}  ${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}║${NC}  Repo:     ${BOLD}$REPO_ROOT${NC}  ${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}║${NC}  Log:      ${BOLD}$log_file${NC}  ${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════╝${NC}"
    echo ""

    local start_time
    start_time=$(date +%s)

    local cargo_cmd="cargo build -j $JOBS $profile_flag"
    local exit_code=0

    if [ "$VERBOSE" = true ]; then
        log_info "Running: $cargo_cmd (verbose)"
        set +e
        (cd "$IC_DIR" && eval "$cargo_cmd" 2>&1 | tee "$log_file")
        exit_code=${PIPESTATUS[0]}
        set -e
    else
        log_info "Running: $cargo_cmd"
        log_info "Log: $log_file"
        set +e
        (cd "$IC_DIR" && eval "$cargo_cmd" > "$log_file" 2>&1)
        exit_code=$?
        set -e
    fi
    local end_time
    end_time=$(date +%s)
    local elapsed=$((end_time - start_time))
    local minutes=$((elapsed / 60))
    local seconds=$((elapsed % 60))

    echo ""
    if [ "$exit_code" -eq 0 ]; then
        local crate_count
        crate_count=$(grep -c "Compiling" "$log_file" 2>/dev/null || echo "?")
        local target_size
        target_size=$(du -sh "$TARGET_DIR" 2>/dev/null | awk '{print $1}')

        echo -e "${GREEN}${BOLD}✓ Build succeeded!${NC}"
        echo -e "  Crates compiled: ${BOLD}$crate_count${NC}"
        echo -e "  Time:            ${BOLD}${minutes}m ${seconds}s${NC}"
        echo -e "  Target size:     ${BOLD}$target_size${NC}"
        echo -e "  Log:             ${BOLD}$log_file${NC}"

        # Show binary location
        local binary
        binary=$(find "$TARGET_DIR/$PROFILE" -maxdepth 1 -type f -executable -name "lunarwing*" 2>/dev/null | head -1)
        if [ -n "$binary" ]; then
            echo -e "  Binary:          ${BOLD}$binary${NC}"
        fi
    else
        echo -e "${RED}${BOLD}✗ Build failed!${NC}"
        echo -e "  Exit code: ${BOLD}$exit_code${NC}"
        echo -e "  Log:       ${BOLD}$log_file${NC}"
        echo ""
        echo -e "${YELLOW}Last 20 lines of build output:${NC}"
        tail -20 "$log_file" 2>/dev/null
        exit "$exit_code"
    fi
}

run_wasm_build() {
    if [ "$DO_WASM" = false ]; then
        return
    fi

    local wasm_cargo_toml="$IC_DIR/channels-src/telegram/Cargo.toml"
    if [ ! -f "$wasm_cargo_toml" ]; then
        log_warn "WASM channel Cargo.toml not found at $wasm_cargo_toml — skipping WASM build"
        return
    fi

    local log_file="/tmp/cargo_wasm_build_$(date +%Y%m%d_%H%M%S).log"
    local start_time
    start_time=$(date +%s)

    echo ""
    log_info "Building Telegram WASM channel (separate target: $WASM_TARGET_DIR)"

    set +e
    (cd "$IC_DIR" && CARGO_TARGET_DIR="$WASM_TARGET_DIR" \
        cargo build -j "$JOBS" --release --target wasm32-wasip2 \
        --manifest-path "$wasm_cargo_toml" > "$log_file" 2>&1)
    local exit_code=$?
    set -e
    local end_time
    end_time=$(date +%s)
    local elapsed=$((end_time - start_time))

    if [ "$exit_code" -eq 0 ]; then
        log_ok "WASM build succeeded (${elapsed}s)"
    else
        log_warn "WASM build failed — main build is still usable"
        log_warn "Log: $log_file"
    fi
}

# ── Parse arguments ────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--clean)    DO_CLEAN=true; shift ;;
        -j|--jobs)     JOBS="$2"; shift 2 ;;
        -t|--target)   TARGET_DIR="$2"; shift 2 ;;
        -r|--repo)     REPO_ROOT="$2"; IC_DIR="$REPO_ROOT/ic"; shift 2 ;;
        --profile)     PROFILE="$2"; shift 2 ;;
        --wasm)        DO_WASM=true; shift ;;
        --no-kill)     DO_KILL=false; shift ;;
        -v|--verbose)  VERBOSE=true; shift ;;
        -h|--help)     usage ;;
        *)
            log_error "Unknown option: $1"
            usage
            ;;
    esac
done

# Export CARGO_TARGET_DIR so cargo actually uses it
export CARGO_TARGET_DIR="$TARGET_DIR"

# ── Main ───────────────────────────────────────────────────

echo ""
echo -e "${BOLD}🦅 LunarWing Build Script${NC}"
echo -e "   $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

check_cargo
check_repo
check_target_dir

echo ""
log_info "Phase 1: Cleanup"
kill_stale_processes
clear_locks

echo ""
log_info "Phase 2: Prepare"
run_clean

echo ""
log_info "Phase 3: Build"
run_build

echo ""
log_info "Phase 4: WASM (optional)"
run_wasm_build

echo ""
echo -e "${BOLD}${GREEN}🦅 All done.${NC}"
echo ""
