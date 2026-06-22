# Release Commands

Step-by-step git/GitHub commands to cut a release. Replace `<version>` (e.g. `1.1.2`) and
`<codename>` with the target release's values. The branching strategy (`staging` →
`release/v<version>`) is documented in the root `CLAUDE.md`.

```bash
# ── 0. Preflight: up-to-date staging with the release notes committed ──────────
git checkout staging
git pull --ff-only origin staging
git status                       # should be clean before tagging

# If RELEASE-v<version>.md (and any create-tenant-*.sh, etc.) are still uncommitted,
# commit them to staging first so the tag captures them:
git add RELEASE-v<version>.md
git commit -m "Finalize release notes for v<version>"
git push origin staging

# ── 1. Create the release branch from staging ──────────────────────────────────
git checkout -b release/v<version> staging
git push -u origin release/v<version>

# ── 2. Create + push the annotated tag ─────────────────────────────────────────
git tag -a v<version> -m "LunarWing v<version> - Codename <codename>"
git push origin v<version>

# ── 3. Create the GitHub release using the release notes file ──────────────────
gh release create v<version> \
  --title "v<version> - Codename <codename>" \
  --notes-file RELEASE-v<version>.md \
  --latest

# ── 4. Verify ─────────────────────────────────────────────────────────────────
gh release view v<version> --web
```

> Release notes are drafted at the repo root as `RELEASE-v<version>.md` (so the tag captures
> them) and archived to `docs/ops/RELEASE-v<version>.md` after the release.

tl;dr
# Create the release branch

  cd /home/sun/lw_new_workspace/lunarwing
  git checkout staging
  git pull --ff-only origin staging      # ensure local staging == remote (no-op if already current)
  git checkout -b release/v1.1.5         # convention: release/v<version>
  git push -u origin release/v1.1.5

# Create the GitHub release (tag + notes)

  cd /home/sun/lw_new_workspace/lunarwing
  gh release create v1.1.5 \
    --target release/v1.1.5 \
    --title "v1.1.5 - Codename Kawarimi" \
    --notes-file RELEASE-v1.1.5.md \
    --latest
  This creates the v1.1.5 tag at the tip of release/v1.1.5 (pushed in step 10), attaches RELEASE-v1.1.5.md as the body, titles it like the others, and marks it
  Latest. Matches v1.1.4 (not a prerelease, so no --prerelease).

  Verify (optional)

  git fetch --tags origin
  gh release view v1.1.5            # confirm tag, title, notes, target


also:
gh repo set-default LunarWingOrg/lunarwing


