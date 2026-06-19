# Documentation Reorg & Consolidation — Progress Checklist

**Started:** 2026-06-19
**Branch:** `1.1.5-docs-update-reorg`
**Goal:** Re-organize and consolidate scattered/outdated documentation. Make `docs/`
a clean, current, navigable tree.

## Scope rule (important)

**We only alter documentation under `docs/`.** The repo contains many other
`README.md`, `CLAUDE.md`, and `AGENTS.md` files (repo root, `ic/`, `projects/`,
worker container dirs, etc.). Those are **out of scope** and stay where they are.
The existing [`DOCS_AUDIT.md`](DOCS_AUDIT.md) tracks the cross-repo IronClaw→LunarWing
rename items that live outside `docs/`; this checklist does **not** duplicate that
work — it covers reorganizing and consolidating the `docs/` tree itself.

## Cross-cutting theme: vendored upstream noise

A bulk commit (`4ed60748 "Re-organized Documentation"`) swept an entire copy of the
upstream **nanocode / opencode** project's own docs into `docs/`. These are not
LunarWing-authored and don't belong in our documentation tree.

**Disposition (decided 2026-06-19):** archive the whole vendored tree under
`docs/internal/vendored/` (reconstructing the upstream layout), preserving git
history via `git mv`. **Stale LunarWing-authored docs** (not vendored) go to
`docs/internal/history/`; only pure stubs/junk get deleted outright.

| Location | Vendored nanocode files | Status |
|----------|------------------------:|--------|
| `docs/reference/nanocode-config/` | 3 | ✅ moved to `internal/vendored/` |
| `docs/guides/nanocode-config/` | 18 | ⬜ pending (guides pass) |
| `docs/internal/nanocode-config/` | 46 | ⬜ pending (internal pass) |
| **Total** | **67** | |

Includes a 384 KB `nanogpt.md`, 17-language UI glossaries, per-package READMEs, and
test fixtures. See [`internal/vendored/README.md`](internal/vendored/README.md).

---

## Checklist

> One box per area. All paths are under `docs/`. Status legend:
> ⬜ not started · 🔄 in progress · ✅ done

- [x] ✅ **`reference/`** — Kept `custom_bridges/XMPP.md` (current, accurate). Moved
      vendored `nanocode-config/` subtree (3 orphaned files) to `internal/vendored/`.
      `reference/` now contains only genuine LunarWing references.
- [x] ✅ **`architecture/`** — 19 → 6 files. Kept the 6 genuine specs/design notes;
      archived 8 raw session-logs/fix-notes to `internal/history/architecture/`;
      deleted 5 empty/scratch stubs. See work log.
- [x] ✅ **`bugs/`** — kept all 18 bug docs (deliberate Open/Fixed tracker; fixed bugs
      stay). Reconciled the index: added 4 previously-untracked docs, upgraded a 315 B
      transcript stub into a proper bug doc, new section for the 1.1.4 MT issue logs.
- [ ] ⬜ **`guides/`** — 56 files. Includes 18 vendored nanocode files + many
      worker/channel subdir READMEs swept in from source repos. Heavy consolidation.
- [ ] ⬜ **`internal/`** — 76 files. Includes 46 vendored nanocode files. Drafts,
      historical notes, vendored content. Largest cleanup target.
- [ ] ⬜ **`ops/`** — 38 files. Many `GOALS_*` per-release checklists; `history/`
      already exists for archiving. Consolidate stale ops scratchpads.
- [ ] ⬜ **`proposals/`** — 61 files. Many superseded/implemented proposals and
      one-line stubs; archive shipped ones, drop dead stubs.
- [ ] ⬜ **`releases/`** — 7 files. Release notes v1.0.7–v1.1.4 + changelog. Mostly
      keep; verify completeness and index.
- [ ] ⬜ **`DOCS_AUDIT.md`** — reconcile against current reality (many M/L items are
      done or now out-of-scope since they touch files outside `docs/`).
- [ ] ⬜ **`README.md`** — the `docs/` index. Currently self-declared "out of date."
      Rebuild as the accurate table of contents once the tree is reorganized. (Do last.)

---

## Work log

### `reference/` (in progress)

Findings:
- `custom_bridges/XMPP.md` — accurate, current LunarWing reference. **Keep.**
- `nanocode-config/nanocode/packages/opencode/BUN_SHELL_MIGRATION_PLAN.md` — vendored
  upstream opencode planning doc. Orphaned. **Remove.**
- `nanocode-config/.../test/fixture/skills/agents-sdk/SKILL.md` — vendored upstream
  test fixture. Orphaned. **Remove.**
- `nanocode-config/.../test/fixture/skills/cloudflare/SKILL.md` — vendored upstream
  test fixture. Orphaned. **Remove.**

Result: `reference/` becomes a clean directory containing only genuine LunarWing
protocol/contract references (currently just the XMPP custom bridge).

### `architecture/` (done)

19 → 6 files.

**Kept (6)** — genuine specs / design notes:
`ENGINE-V2.md`, `SEMANTIC-MEMORY-SEARCH.md`, `WEECHAT-CHANNEL-ARCHITECTURE.md`,
`XMPP_FILE_TRANSFERS.md`, `SELF_HEAL_DEPLOYMENT_WIRING.md`,
`ATOMICBOOL_DEEPER_PROPAGATION.md`.

**Archived → `internal/history/architecture/` (8)** — raw session logs / resolved fix notes:
`HANDLE_MESSAGE_FIX.md`, `RESPONSE_SUPPRESSION_IMPLEMENTATION.md`,
`WEBSOCKET_KEEPALIVE_IMPLEMENTATION.md`, `FIXED_NON_UUID_SCOPE_LEAKAGE.md`,
`SECURITY_ENHANCEMENTS.md` (misnamed — actually a compile-fix log),
`MULTICA-PT1PT2.md`, `MULTICA-SEC.md`, `MULTICA-WILDCARD.md`.

**Deleted (5)** — empty/scratch stubs: `REBORN.md`, `WEECHAT-DOUBLE-REPLY-FIX.MD`,
`PORT_REGISTRY_V5.md`, `DATABASE_MIGRATIONS.md`, `WEECHAT.md` (superseded redirect).

**Links repointed (in-scope):** `docs/README.md` (dropped 2 archived rows),
`architecture/ATOMICBOOL_DEEPER_PROPAGATION.md` (`Related:` line),
`bugs/XMPP-OMEMO-BUG-TO-DO.md`.

**Stale links left intentionally (release notes kept immutable, per decision):**
- `releases/RELEASE-v1.1.0.md` → `MULTICA-SEC.md`
- `releases/RELEASE-v1.1.1.md` → `FIXED_NON_UUID_SCOPE_LEAKAGE.md`, `SECURITY_ENHANCEMENTS.md`,
  `WEBSOCKET_KEEPALIVE_IMPLEMENTATION.md`

These four now point at `architecture/…` paths that have moved to
`internal/history/architecture/…`. Re-evaluate during the `releases/` pass.

**Note for the `proposals/` pass:** `WEBSOCKET_KEEPALIVE_IMPLEMENTATION.md` is duplicated
in `proposals/` (larger copy, 5.7 KB) — reconcile then.

### `bugs/` (done)

No files moved or deleted — `bugs/` is a deliberate Open/Fixed tracker (its `README.md` keeps
fixed bugs "retained for history with a status banner"), so this pass was index reconciliation,
not relocation.

- The directory had **18 bug docs but the index listed only 14**. Added the 4 missing:
  - `BUG-FIXED-wasm-tools-not-found-on-build.md` → **Fixed** (MT wasm-tools PATH fix, v1.1.3).
  - `BUG-WEECHAT-WARNINGS.md` → **Open (Low)** — rewrote the 315 B transcript snippet into a
    proper bug doc after **verifying** the flagged `rand_check` latent bug is still live
    (`ironclaw_weechat_wss/weechat_relay/src/lib.rs:1766` ignores `probability`, always returns
    `false`).
  - `SYSTEMD-MT-1.1.4-ISSUES.md` + `OPENRC-MT-1.1.4-ISSUES.md` → new **"1.1.4 MT pre-release
    issue logs"** section (multi-issue logs, not single bugs; all fixed except F7 = telegram).
- Updated the index header (2026-06-19 note) and the top-level `docs/README.md` bug count (→ 18).
- **Flagged for `ops/` pass:** the two 1.1.4 MT issue logs are operational records
  cross-referenced from `ops/GOALS_1.1.4.md`; decide then whether they belong in `ops/`.
