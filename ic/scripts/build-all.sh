#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

echo "Building LunarWing..."
cargo build --release

echo ""
echo "Done. Binary: target/release/lunarwing"
