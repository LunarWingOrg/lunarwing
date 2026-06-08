#!/usr/bin/env bash

#Written by Starforce Nebula to re-organize documentation

set -euo pipefail
cd /tmp/lunarwing-github   # <-- adjust if repo lives elsewhere

# ----------------------------------------------------------------------
# 1️⃣  Create target folders (add more if you want finer granularity)
# ----------------------------------------------------------------------
mkdir -p docs/{architecture,guides,ops,reference,internal}

# ----------------------------------------------------------------------
# 2️⃣  Helper: move a file with `git mv` (preserves history)
# ----------------------------------------------------------------------
move_file() {
    src=$1
    dst=$2
    # create destination directory if needed
    mkdir -p "$(dirname "$dst")"
    git mv "$src" "$dst"
    echo "Moved $src → $dst"
}

# ----------------------------------------------------------------------
# 3️⃣  Find all *.md files that are NOT excluded
# ----------------------------------------------------------------------
find . -type f -name '*.md' \
    ! -path './README.md' \
    ! -path './ic/*' \
    ! -path '*/.claude/*' \
    ! -name 'CLAUDE.md' \
    ! -name 'AGENTS.md' \
    ! -name 'CODEX.md' \
    -print0 |
while IFS= read -r -d '' file; do
    # Strip leading "./"
    rel="${file#./}"
    # --------------------------------------------------------------
    # Decide target sub‑folder based on simple heuristics
    # --------------------------------------------------------------
    case "$rel" in
        # Architecture / design
        DESIGN.md|NETWORK_SECURITY.md|IRONCLAW_PORT_VERIFICATION.md)
            target="docs/architecture/$rel"
            ;;

        # Guides – building, setup, channel‑specific, etc.
        *BUILD*|*SETUP*|*GUIDE*|*HOW_TO*|*INTEGRATION*|*README.md|*INSTALL.md)
            target="docs/guides/$rel"
            ;;

        # Ops – deployment, harnesses, multitenancy, health‑checks
        *HARNESS*|*MULTITENANCY*|*DEPLOY*|*HEALTH*|*OPS*|*PRODUCTION*)
            target="docs/ops/$rel"
            ;;

        # Reference – contracts, skill SKILL.md, channel docs, etc.
        *XMPP.md|*GOTIFY.md|*SECRET_MANAGER.md|*SKILL.md|*CONTRACT*|*PROVIDERS*|*PLAN*|*SCHEMA*)
            target="docs/reference/$rel"
            ;;

        # Anything else falls into internal (you can later tidy)
        *)
            target="docs/internal/$rel" 
            ;;
    esac

    # --------------------------------------------------------------
    # Perform the move (git‑aware)
    # --------------------------------------------------------------
    move_file "$rel" "$target"
done

# ----------------------------------------------------------------------
# 4️⃣  Clean up empty directories left behind
# ----------------------------------------------------------------------
find . -type d -empty -delete

echo "=== REORG COMPLETE ==="
echo "All moved files are now under /docs/."
echo "Review `git status` and amend any link updates before committing."
