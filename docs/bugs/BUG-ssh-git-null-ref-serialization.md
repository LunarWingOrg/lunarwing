# BUG: ssh_git tool serializes null ref as literal string "null"

**Severity:** Low
**Found:** 2026-07-03 during v1.1.8 SSH tool validation on tenant `starforce`
**Status:** Open
**Affects:** `ssh_git` built-in tool (`ic/src/tools/builtin/ssh_git.rs`)

## Symptoms

1. Agent calls `ssh_git` with `ref` omitted (or set to null in the JSON parameters)
2. The tool serializes the null value as the literal string `"null"`
3. Git interprets `"null"` as a branch/tag name
4. Clone/push fails or operates on the wrong ref

## Reproduction

```
Use the ssh_git tool to clone a repo. Parameters: operation=clone, host=127.0.0.1, repo=lunarwing/test-repo.git, path=test-clone
```

The agent omits `ref` (it's optional in the schema). The tool passes `null` as the refspec to git.

## Root Cause

In `ssh_git.rs` (line 132):
```rust
let git_ref = params.get("ref").and_then(|v| v.as_str());
```

When `ref` is absent, `git_ref` is `None` and the `--branch` flag is correctly omitted for clone. However, the agent sometimes explicitly passes `"ref": null` in the JSON, which `as_str()` converts to `None` correctly — but the tool description and schema don't make it clear that omitting `ref` entirely is the correct approach, leading the agent to pass `"null"` as a string in some code paths.

The workaround is to always pass `ref` explicitly (e.g. `ref: main`).

## Impact

- Clone/push may fail when `ref` is omitted or set to null
- Agent must know to always pass an explicit `ref` value

## Potential Fix

Ensure the tool handles absent/null `ref` consistently — `None` should mean "no `--branch` flag", never the string `"null"`. The `as_str()` check already returns `None` for JSON null, so the issue may be in how the agent serializes parameters rather than in the Rust code itself. Consider making `ref` required in the schema to eliminate ambiguity.

## Workaround

Always pass `ref` explicitly in `ssh_git` calls (e.g. `ref: main`).
