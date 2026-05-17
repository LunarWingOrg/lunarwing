# Branch Guide

# This guide is completely out of date. Needs a TOTAL REWRITE

## Branch Structure

| Branch | Purpose |
|--------|---------|
| `staging` | Integration branch — all feature branches merge here first |
| `1.0.6-*` | Feature branches for the v1.0.6 release cycle |
| `experimental-*` | Experimental features not yet targeted for a specific release |

## Branching Strategy

### Feature branches

Feature branches are created from `staging` and named with the release version prefix:

```
1.0.6-LunarVision       # Vision service feature
1.0.6-EmbeddedMemoryUpdate  # Embedding config changes
1.0.6-CleanupRound2     # Cleanup and removal work
```

When a feature is complete, it is merged into `staging` via pull request or direct merge.

### Agent branches

When AI agents make changes, they should checkout `staging` and create a new branch using the agent name with an incrementing number:

```
staging-baud-1
staging-baud-2
staging-ruffles-1
staging-kageho-1
staging-kageho-2
```

Agent branches are reviewed and merged into `staging` or the appropriate feature branch.

### Release flow

1. Feature branches merge into `staging`
2. `staging` is tested and validated
3. `staging` is tagged and released

## Active Feature Branches

See `FEATURE_BRANCHES_1.0.6.md` at the repo root for the current list of v1.0.6 feature branches and their status.
