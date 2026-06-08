# commands
# ── 0. Preflight: up-to-date staging with the release notes committed ──────────                                                                            
  git checkout staging                                                                                                                                         
  git pull --ff-only origin staging                                                                                                                            
  git status                       # should be clean before tagging                                                                                            
                                       
  # If RELEASE-v1.1.1.md (and create-tenant-summer.sh, etc.) are still uncommitted,
  # commit them to staging first so the tag captures them:                       
  git add RELEASE-v1.1.1.md
  git commit -m "Finalize release notes for v1.1.1"                                                                                   
  git push origin staging                                                                                                                                      
                                                                                                                                                               
  # ── 1. Create the release branch from staging (like release/v1.0.8, v1.0.9) ────
  git checkout -b release/v1.1.1 staging                                                                                                                       
  git push -u origin release/v1.1.1
    # ── 2. Create + push the annotated tag (like v1.0.9, v1.1.0) ───────────────────                                                                         
  git tag -a v1.1.1 -m "LunarWing v1.1.1 - Codename Freedom"
  git push origin v1.1.1
                                                                                                                                                               
  # ── 3. Create the GitHub release using the release notes file ──────────────────
  gh release create v1.1.1 \
    --title "v1.1.1 - Codename Freedom" \
    --notes-file RELEASE-v1.1.1.md \
    --latest

  # ── 4. Verify ─────────────────────────────────────────────────────────────────
  gh release view v1.1.1 --web
