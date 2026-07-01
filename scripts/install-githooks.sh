#!/usr/bin/env bash
# Install LunarWing git hooks by pointing core.hooksPath at the committed .githooks/ dir.
#
# This is the durable install path: core.hooksPath survives git operations (unlike
# copying into .git/hooks/, which is per-clone and lost on some operations).
#
# Usage:
#   ./scripts/install-githooks.sh          # install
#   ./scripts/install-githooks.sh --status  # show current state
#   ./scripts/install-githooks.sh --remove  # unset core.hooksPath
#
# After install, the hooks in .githooks/ run automatically on commit/push.
# Bypass any hook with `git commit --no-verify` / `git push --no-verify`.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "error: not inside a git repository" >&2
  exit 1
}
cd "$REPO_ROOT"

HOOK_DIR=".githooks"

show_status() {
  local current
  current="$(git config core.hooksPath || echo '(unset)')"
  echo "core.hooksPath = $current"
  if [ "$current" = "$HOOK_DIR" ]; then
    echo "status: hooks ACTIVE (.githooks/ will run on commit/push)"
  elif [ "$current" = "(unset)" ]; then
    echo "status: hooks INACTIVE (git uses default .git/hooks/)"
  else
    echo "status: core.hooksPath points elsewhere — .githooks/ is NOT active"
  fi
}

case "${1:-install}" in
  --status|-s)
    show_status
    exit 0
    ;;
  --remove|-r)
    git config --unset core.hooksPath 2>/dev/null || true
    echo "Removed core.hooksPath (.githooks/ no longer active)."
    show_status
    exit 0
    ;;
  install|--install)
    : # fall through
    ;;
  *)
    echo "usage: $0 [--status|--remove|install]" >&2
    exit 2
    ;;
esac

# Sanity: the hook dir must exist and be committed (not just a local dir).
if [ ! -d "$HOOK_DIR" ]; then
  echo "error: $HOOK_DIR/ not found at repo root" >&2
  exit 1
fi

# Ensure all hooks are executable (core.hooksPath requires +x).
chmod +x "$HOOK_DIR"/* 2>/dev/null || true

git config core.hooksPath "$HOOK_DIR"

echo "Installed LunarWing git hooks (core.hooksPath=$HOOK_DIR)."
echo ""
echo "Active hooks:"
for h in "$HOOK_DIR"/*; do
  [ -e "$h" ] || continue
  name="$(basename "$h")"
  case "$name" in
    pre-commit)  echo "  $name   — secret scan + version-bump check (fast, no cargo)" ;;
    commit-msg)  echo "  $name   — require regression tests for fix: commits" ;;
    pre-push)    echo "  $name   — non-blocking reminder (set IRONCLAW_STRICT_PREPUSH=1 to enforce cargo gate)" ;;
    *)           echo "  $name" ;;
  esac
done
echo ""
echo "Bypass any hook with: git commit --no-verify  /  git push --no-verify"
echo "Check state anytime:  $0 --status"
