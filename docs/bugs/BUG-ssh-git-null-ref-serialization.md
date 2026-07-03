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

The Rust tool code (`ssh_git.rs:132`) handles absent/null `ref` correctly:
```rust
let git_ref = params.get("ref").and_then(|v| v.as_str());
```
`as_str()` returns `None` for JSON null, and `build_argv` only adds `--branch` when `git_ref` is `Some`. So the Rust tool itself is correct.

The issue is in the LLM serialization layer: when the agent omits `ref`, the tool-call JSON may serialize the absent value as the literal string `"null"` before it reaches the Rust tool's parameter parsing. Git then receives `--branch null` and fails with `fatal: Remote branch null not found`.

The tool should either:
1. Make `ref` required in the schema to force the agent to always pass an explicit value
2. Or the serialization layer should omit absent fields entirely rather than converting them to string `"null"`

## Impact

- Clone/push may fail when `ref` is omitted or set to null
- Agent must know to always pass an explicit `ref` value

## Potential Fix

Either:
1. Make `ref` required in the tool's `parameters_schema()` to eliminate the null/absent ambiguity entirely
2. Trace the serialization layer to find where `None`/absent becomes the string `"null"` and fix it there

Option 1 is simpler and avoids the agent guessing behavior.

## Workaround

Always pass `ref` explicitly in `ssh_git` calls (e.g. `ref: main`).
