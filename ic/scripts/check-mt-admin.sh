#!/usr/bin/env bash
#
# Shellcheck gate for lunarwing-mt-admin.sh (T7).
# Fails if any warning-or-above issue is found. Run manually, in CI, or as a
# pre-commit hook. Install shellcheck separately (e.g. `pacman -S shellcheck`).
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$SCRIPT_DIR/lunarwing-mt-admin.sh"

command -v shellcheck >/dev/null 2>&1 || {
  echo "error: shellcheck is required (install: pacman -S shellcheck / apt install shellcheck)" >&2
  exit 2
}

if shellcheck -S warning "$TARGET"; then
  echo "✓ shellcheck clean: $TARGET"
  exit 0
else
  echo "✗ shellcheck issues found in $TARGET (fix or document in .shellcheckrc)" >&2
  exit 1
fi
