#!/usr/bin/env bash
set -euo pipefail

echo "==> fmt check"
cargo fmt --all -- --check

echo "==> clippy (correctness)"
cargo clippy --locked --all-targets -- -D clippy::correctness

# LUNARWING_PREPUSH_TEST is primary; IRONCLAW_PREPUSH_TEST is a legacy alias.
if [ "${LUNARWING_PREPUSH_TEST:-${IRONCLAW_PREPUSH_TEST:-1}}" = "1" ]; then
    echo "==> tests (skip with LUNARWING_PREPUSH_TEST=0)"
    cargo test --locked --lib
fi
