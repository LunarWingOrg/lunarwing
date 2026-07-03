# BUG: ssh_git clone fails when bare repo HEAD points to non-existent branch (master/main mismatch)

**Severity:** Low
**Found:** 2026-07-03 during v1.1.8 SSH tool validation on tenant `starforce`
**Status:** Open
**Affects:** `ssh_git` built-in tool (`ic/src/tools/builtin/ssh_git.rs`) — indirectly affects any `git clone` against a bare repo whose HEAD symref doesn't match an existing branch

## Symptoms

1. A bare repo is initialized with `git init --bare` (default HEAD = `refs/heads/master`)
2. The seed commit is pushed to `main` (via `git branch -M main && git push origin main`)
3. Agent clones without `--branch` (relying on remote HEAD fallback)
4. Git falls back to the remote's HEAD symref, which points to `refs/heads/master`
5. No `master` branch exists → clone fails with `warning: remote HEAD refers to nonexistent ref`

## Reproduction

```bash
git init --bare test-repo.git
# HEAD now points at refs/heads/master (git default)
cd /tmp && git clone test-repo.git seed
cd seed
echo "test" > README.md
git add . && git commit -m "initial"
git branch -M main
git push origin main
# Clone without --branch fails:
git clone test-repo.git clone-test
# warning: remote HEAD refers to nonexistent ref 'refs/heads/master' and is unable to checkout
```

Then from the agent:
```
Use the ssh_git tool: operation=clone, host=127.0.0.1, repo=lunarwing/test-repo.git, path=test-clone
```

Clone succeeds but checkout is empty/broken because HEAD points at master which doesn't exist.

## Root Cause

`git init --bare` sets `HEAD` to `refs/heads/master` by default (the git compile-time default). When the actual branch is `main`, the bare repo's HEAD symref is wrong. Cloning without `--branch` makes git follow the remote HEAD, which resolves to a non-existent branch.

This is a git convention issue, not a LunarWing bug — but the `ssh_git` tool could help by warning the user when a clone succeeds but checkout fails due to a HEAD mismatch.

## Impact

- Clones of bare repos with mismatched HEAD produce confusing results (empty working tree, no checked-out branch)
- Users must know to either always pass `ref=main` or normalize bare repos with `git symbolic-ref HEAD refs/heads/main`

## Potential Fixes

1. **Tool-level:** After clone, detect if the checkout branch is empty/missing and warn with a helpful message suggesting `--branch <ref>`
2. **Doc-level:** Document the `git symbolic-ref HEAD refs/heads/main` normalization step in the SSH testing guide and worker setup docs
3. **No code change needed if `ref` is made required** (see `BUG-ssh-git-null-ref-serialization.md` — if ref is always passed, the HEAD fallback path is never hit)

## Workaround

Normalize bare repos at creation time:
```bash
git --git-dir=test-repo.git symbolic-ref HEAD refs/heads/main
```

Or always pass `ref` explicitly to `ssh_git` clone operations.
