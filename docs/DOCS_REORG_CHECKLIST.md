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
| `docs/guides/nanocode-config/` | 19 | ✅ moved to `internal/vendored/` (2 LW config docs kept) |
| `docs/internal/nanocode-config/` | 48 | ✅ folded into `internal/vendored/` (2 LW notes kept) |
| **Total** | **70** | ✅ all vendored consolidated under `internal/vendored/` |

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
- [x] ✅ **`guides/`** — 56 → 23 files. Archived 19 vendored nanocode files; moved 6
      deprecated/divergent component docs to `internal/history/guides/`; deleted 8
      stubs/junk/duplicates; kept 23 real guides + canonical component docs.
- [x] ✅ **`internal/`** — folded 48 vendored nanocode files into `internal/vendored/`;
      archived 23 stub/notes to `internal/history/internal/` (no hard deletes, per request);
      kept 5 substantial docs. Active `internal/` is now 5 files + the two archives.
- [x] ✅ **`ops/`** — light pass. `ops/` is mostly current/authoritative + active MT work.
      Archived 3 shipped `GOALS_*` to the existing `ops/history/`; kept everything else
      (incl. `GOALS_1.1.4`/`1.1.5` and `XMPP_TRANSFERS.md`). No deletions.
- [x] ✅ **`proposals/`** — 61 → 32 files. Archived 29 shipped/superseded/historical
      proposals to `internal/history/proposals/`; kept 32 active/forward-looking ones
      (incl. `OLDPROJECT_PORT_ANALYSES/`). No deletions (per request).
- [x] ✅ **`releases/`** — all 7 kept (immutable historical records). Audited via a
      7-agent workflow for broken in-repo links; no file changes. Catalog in work log.
- [x] ✅ **`DOCS_AUDIT.md`** — reconciled against current reality via a 17-agent verify
      workflow. Closed 6 more items; 11 remain (all but M13/M16 are rename fixes outside
      `docs/`, out of scope). No out-of-`docs/` files modified.
- [ ] ⬜ **`README.md`** — the `docs/` index. Currently self-declared "out of date."
      Rebuild as the accurate table of contents once the tree is reorganized. (Do last.)

---

## Follow-ups / revisit

- **`internal/` may have over-archived (2026-06-19):** the `internal/` pass moved 23 stub/notes
  to `internal/history/internal/`. Nothing was deleted. Some may still be relevant — revisit and
  un-move docs back into active `docs/internal/` as needed.

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

### `guides/` (done)

56 → 23 files.

- **Archived → `internal/vendored/nanocode-config/` (19)** — the vendored `nanocode/` (18) +
  `nanocode.nvim/` (1) upstream subtrees, merged with the `reference/`-pass copy. Kept the 2
  genuine LunarWing files (`nanocode-config/README.md`, `SETUP_NANOCODE_FOR_TENSORZERO.md`).
- **Archived → `internal/history/guides/` (6)** — deprecated/divergent component docs:
  `codex4ironclaw/{README, HOW_TO_CONNECT_LUNARWING, KAGEHO_INTEGRATION_GUIDE}.md` (deprecated
  worker), `nanocode4ironclaw/README.md` (deprecated), `ic-infrastructure-health-check/README.md`
  (divergent stale snapshot of the live root copy), `git-ironclaw-systemd/README.md` (unfilled
  GitLab template).
- **Deleted (8)** — stubs/junk/duplicates: `QUICK_BUILD.md`, `REFLEX_COMPILER_TESTING.md`,
  `codex4ironclaw/INTEGRATION.md`, `darkirc_channel_for_ironclaw/{BUILD_REQUIREMENTS,README}.md`,
  `git-ironclaw-unix-socket-client-repo/README.md`, and the redundant `replv2git/` nesting (2 exact
  duplicates of the flat copies).
- **Kept (23)** — 12 top-level guides + canonical component docs (`darkirc` 2 build guides,
  `ironclaw_weechat_wss` 3, `gotify-wasm`, `ic_sm`, `tensorzero-proxy-configurations`,
  `git-ironclaw-unix-socket-repl-server-repo`) + `nanocode-config/{README, SETUP…}`.
- **Links:** removed 5 dead rows from `docs/README.md`'s guides table. Left stale (out of scope):
  `RELEASE-v1.1.4.md` → `QUICK_BUILD.md`.

### `internal/` (done)

`internal/` is the designated drafts/notes area; this pass folded its vendored bulk and archived
the abandoned stub scaffold, keeping only the substantial working docs.

- **Folded → `internal/vendored/nanocode-config/` (48)** — the `nanocode/` (46) + `nanocode.nvim/`
  (2) upstream subtrees (incl. the 384 KB `nanogpt.md`), merged with the prior passes' copies (0
  collisions). `internal/vendored/` is now the single consolidated upstream archive (71 files).
- **Archived → `internal/history/internal/` (23)** — per request, the stub scaffold was *archived,
  not deleted*: the 8 `custom_*` source-repo URL bookmarks, the deprecated-codex notes (5), and
  assorted empty/placeholder stubs (`REMAKE`, `GRANT_PROPOSAL_FRAMEWORK`, `TEST`, `EXAMPLES`,
  `APPROACH_TO_DOCS`, `BRANCHES`, `REPLv2_Client_and_Server`, `NOTES`, `KEEP`, `CONTRIBUTING`, …),
  preserving their original subpaths.
- **Kept in `internal/` (5)** — `FORK_CONTEXT.md` (CLAUDE.md-linked), `.github/pull_request_template.md`,
  the ic-health-check analysis draft, and `nanocode-config/{KAGEHO_QUESTIONS, NextSteps}.md`.
- **No hard deletes this pass** — everything is preserved under `vendored/` or `history/`.
- Rewrote `docs/README.md`'s `internal/` index to the 5 kept docs + pointers to the archives.

Note: `docs/DOCS_AUDIT.md` references a couple of now-archived stubs (e.g. L12
`REPLv2_Client_and_Server.md`) — reconcile in the `DOCS_AUDIT.md` pass (L12's "flesh out or delete"
is effectively resolved by archiving).

### `releases/` (done)

Audited all 7 files via a 7-agent workflow (one verifier per note, each checking every in-repo
link against the current tree). **Disposition: keep all 7** — release notes are immutable
historical records, so no moves/deletes/edits. `docs/README.md`'s releases table already lists all
7 correctly. `CHANGELOG-AGENTS.md` and `RELEASE-v1.0.7.md` have zero broken links.

Broken in-repo links found (left as-is per the immutability rule):

*Stale due to our reorg moves (already logged in earlier passes):*
- `RELEASE-v1.1.0` → `architecture/MULTICA-SEC.md`
- `RELEASE-v1.1.1` → `architecture/{FIXED_NON_UUID_SCOPE_LEAKAGE, SECURITY_ENHANCEMENTS, WEBSOCKET_KEEPALIVE_IMPLEMENTATION}.md`
  (all now under `internal/history/architecture/`)
- `RELEASE-v1.1.4` → `guides/QUICK_BUILD.md` (deleted stub)

*Pre-existing broken/inaccurate links (NOT caused by this reorg):*
- `RELEASE-v1.1.1/1.1.2/1.1.3` self-reference `docs/ops/RELEASE-v1.1.x.md` — release notes were
  moved to `docs/releases/` back in v1.1.3, but the notes still cite the old `ops/` path.
- `RELEASE-v1.1.0` → `GOALS_1.1.0.md` (in `ops/history/`), `ic/deploy/workspace-template/BOOTSTRAP.md`
  (intentionally deleted — a removal record).
- `RELEASE-v1.1.1` → `ops/STATUS_OF_REMOVAL_OF_PROPRIETARY_CHANNELS.md` (in `ops/history/`),
  `proposals/SELF_HEALING_IMPROVEMENTS_1.md` (only `_2` exists).
- `RELEASE-v1.1.4` → `reference/TENANT-CONFIGURATION.md` (always lived at `ops/TENANT-CONFIGURATION.md`).

### `proposals/` (done)

61 → 32 files. **No deletions** (per request) — everything was moved or kept.

- **Classification:** 44 substantive proposals were classified by a 44-agent workflow (each
  verifying shipped-status against the code + release notes); the 17 others (tiny stubs + the port
  analyses) were handled directly.
- **Archived → `internal/history/proposals/` (29)** — shipped features (CHAOS test plan,
  `MT_SYSTEMD_PARITY`, `PER_TENANT_RANDOM_PG_PASSWORDS`, `reflex-compiler`, `ROOTLESS_WORKER_OPENRC_UNITS`,
  `SYSTEMD_QUADLET_IMPROVEMENTS`, `WEBSOCKET_KEEPALIVE_IMPLEMENTATION`, several WEECHAT/WORKER fixes,
  `MULTICA_RAW`, `PEBBLE`, and the **entire `VisionProject/`** — OCR/vision service shipped),
  superseded designs (`MULTICA_POSSIBLE_CONSIDERATIONS`, `ROOTLESS_DEFAULT_INIT_GATING`,
  `KAGEHO_BUILD_PLAN`), historical records (`MULTICA_SERVER_COMPATIBILITY_CONFIRMED`,
  `SELF_HEALING_IMPROVEMENTS_2`, `OLDRELNOTES`), and two done/personal notes
  (`LAST_THREE_FEATURES_FOR_8`, `House`).
- **Kept (32)** — active roadmaps/work, conservatively-kept low-confidence/partial items, forward
  idea stubs, and **`OLDPROJECT_PORT_ANALYSES/`** (kept in place per request).
- **`docs/README.md`:** trimmed the proposals table — removed 3 dead links (`GITHUB_ACCS`,
  `VisionProject/KAGEHO_LOG`, `NANOCODE_WORKER_SECRETS`; never existed) plus the archived rows, and
  added a pointer to the history archive.

### `ops/` (done)

Light pass — `ops/` is mostly current, well-maintained operational docs (many `CLAUDE.md`-pinned)
plus active MT work, so almost everything stayed.

- **Archived → `ops/history/` (3)** — shipped release checklists `GOALS_1.1.2.md`,
  `GOALS_1.1.2_INFRA_HEALTH_CHECK.md`, `GOALS_1.1.3.md`, extending the existing `ops/history/`
  convention (which already held `GOALS_1.0.6`–`1.1.0`). Repointed their internal cross-links to
  the new location and refreshed `ops/history/README.md`.
- **Kept (~30)** — all current ops docs, active MT notes (Gentoo/machine-migration in progress),
  forward planning (`ROADMAP_2026`, `FUTURE_RELEASE_ITEMS`, `PENDING_CLEANUP`), `XMPP_TRANSFERS.md`
  (current v1.1.5 quick-ref), and small notes.
- **Deliberately kept (per discussion):** `GOALS_1.1.4.md` (shipped but still referenced by the
  active MT-1.1.0→1.1.4 upgrade proposal + the MT-1.1.4 bug logs) and `GOALS_1.1.5.md` (current).
  The two `*-MT-1.1.4-ISSUES.md` logs stay in `bugs/` (already indexed there; not relocated).
- **`docs/README.md`:** swapped the two archived `GOALS_1.1.2*` rows for current `GOALS_1.1.5` /
  `GOALS_1.1.4` rows. Release-note links to the archived GOALS left stale (immutable).

### `DOCS_AUDIT.md` (done)

Re-verified all 17 still-"Remaining" items against the current tree via a 17-agent workflow
(status-only — the actual fixes mostly live outside `docs/` and are out of scope).

- **Newly closed (6):** M11 (Discord README — source removed), M20 (`codex4ironclaw/CLAUDE.md` —
  dir removed, superseded by `codex4lunarwing/`), L7 (Slack README — source removed), L10
  (`RELEASE-v1.0.6` placeholder — gone; releases start at v1.0.7), L12 (`REPLv2_Client_and_Server` —
  archived by this reorg), L5 (`FORK_CONTEXT.md` — stale refs already fixed).
- **Still open (11):** M2 (partial), M3, M10, M12, M13, M16, M22, L6, L9, L11, L13. All but M13 and
  M16 are IronClaw→LunarWing rename fixes in files **outside `docs/`** (out of scope here). M16
  (the README index) closes with the final rebuild; **M13**
  (`darkirc_channel_for_ironclaw/BUILD_INSTRUCTIONS.md`) is the one doc under `docs/` still carrying
  stale `~/ironclaw/` paths — flagged for an optional follow-up content rename.
- Updated the audit header: added a 2026-06-19 "Also closed" block, slimmed "Remaining", added a
  scope note. No files outside `docs/` were modified.
