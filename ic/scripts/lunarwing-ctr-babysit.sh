#!/bin/sh
# lunarwing-ctr-babysit — podman wait babysitter for rootless container supervision
#
# This script is the foreground command supervised by OpenRC's supervise-daemon.
# It ensures the container is started, then blocks on `podman wait` until the
# container exits. When podman wait returns, this script exits, and supervise-daemon
# respawns it (which starts the container again).
#
# Usage: lunarwing-ctr-babysit <container-name>
#
# Environment required (provided by OpenRC start_pre):
#   HOME, XDG_RUNTIME_DIR — rootless podman environment

set -eu

ctr="${1:-}"
if [ -z "${ctr}" ]; then
    echo "usage: lunarwing-ctr-babysit <container-name>" >&2
    exit 1
fi

# Ensure container is started (idempotent; no-op if already running)
podman start "${ctr}" >/dev/null 2>&1 || true

# Block until container exits. `podman wait` exits 0 when the container stops
# (regardless of the container's own exit code), which supervise-daemon treats
# as the command exiting, so it respawns the babysitter and restarts the container.
exec podman wait "${ctr}"