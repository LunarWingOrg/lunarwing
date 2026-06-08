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
