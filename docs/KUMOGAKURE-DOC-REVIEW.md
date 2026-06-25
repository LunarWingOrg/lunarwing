# Post-v1.1.6 Documentation Improvement Plan

**Date:** 2026-06-25 (updated 2026-06-25)
**Author:** Kumogakure
**Branch:** `kumogakure-post-1.1.6-doc-review-3`
**Scope:** Full documentation improvement across the entire repo (docs/ and non-docs/)

## Context

This plan synthesizes three sources:
1. **KUMOGAKURE-POST-1.1.6-REVIEW** — code review of v1.1.6 (committed to this branch)
2. **docs/DOCS_AUDIT_GLM.md** — Zread-powered doc audit by sun (committed to this branch)
3. **Prior doc cleanup work** — non-docs staleness audit from June 23 (session 20260623).

The `docs/` tree was reorganized on June 19 (vendored nanocode archived, history
separated, index rebuilt). Sun applied Tier 1 fixes from the original plan in
PRs #84 + #85 (branches `kumogakure-post-1.1.6-doc-review-2` and staging).

---

## TIER 1: Fix Now (High visibility, low effort)

### 1A. README.md truncated sentences + typos
**Source:** DOCS_AUDIT_GLM.md items 8 and 9

- ~~Line 43: "Proprietary service centered channels... are int" — **truncated mid-word**~~
  **DONE** — sentence now reads correctly in full.
- ~~Line 67: "seperate repo" → "separate repo"~~ **DONE**
- ~~Line 72: "obselete" → "obsolete"~~ **DONE**
- ~~Line 72-73: "Re worked" → "Reworked" (remove space)~~ **DONE** — now reads "Reworked Built-in Worker - Debloated" / "Reworked Sandbox Worker - Debloated"
- ~~Line 102: "sponserships" → "sponsorships"~~ **DONE**
- ~~Line 32: Redundant bare `[LunarWing](https://lunarwing.org/)` link~~ **STILL PRESENT** — the bare link remains on line 32. Low priority cosmetic.

### 1B. README.md release notes range is stale
**Source:** DOCS_AUDIT_GLM.md item 1

- ~~Line 324: "v1.0.7 → v1.1.4"~~ **DONE** — now reads "v1.0.7 → v1.1.6"

### 1C. README.md worker count + codex deprecation
**Source:** DOCS_AUDIT_GLM.md items 3 and 4; v1.1.6 release notes

- ~~Line 89: "4+ worker types"~~ **PARTIALLY DONE** — now reads "all 4 worker types" (was "4+"). The number is accurate.
- **STILL OPEN** — Line 218: Worker test harness still has `python runner.py --worker codex   # single worker type` with codex as the example. Codex is deprecated (v1.1.6). Should use nanocode or pebble as the example instead.
- ~~Worker descriptions "Re worked" / "getting debloated"~~ **DONE** — cleaned up to "Reworked ... Debloated"

### 1D. docs/README.md index missing v1.1.5 and v1.1.6 releases
**Status:** **STILL OPEN** — The releases section in `docs/README.md` (lines 150-153) has no per-release table entries at all (the table was removed, replaced with a bare section header + description). The release files exist in `docs/releases/` (v1.0.7 through v1.1.6) but aren't individually indexed. This is acceptable as-is since the releases directory is self-discoverable, but the section could list them for completeness.

### 1E. docs/ops/ GOALS cleanup
**Status:** **DONE** — `GOALS_1.1.4.md`, `GOALS_1.1.5.md`, and `GOALS_1.1.6.md` all moved to `docs/ops/history/`. No GOALS files remain in `docs/ops/` root.

---

## TIER 2: IronClaw Rename Sweep (Medium effort, high correctness value)

### 2A. Finish the IronClaw → LunarWing rename outside docs/
**Source:** DOCS_AUDIT.md remaining items (M2, M3, M10, M12, M13, M22, L6, L9, L11, L13)
**Verified:** 30 files outside docs/ still contain "ironclaw" references (down from 47 at plan creation — some cleaned during the review-2 merge)

Per DOCS_AUDIT.md scope note: every remaining item except M13 is outside `docs/`. These are in `ic/`, root-level, and worker container dirs.

**Priority order (per DOCS_AUDIT fix order):**
1. **Runtime-injected prompts** — any IronClaw references that get injected into LLM context (system prompts, skill display names). These actively confuse the model.
2. **Code paths** — `ic/src/bootstrap.rs` fallback paths, any `~/.ironclaw` defaults (verify M21 was truly closed)
3. **User-facing docs** — `ic/FEATURE_PARITY.md`, `ic/CONTRIBUTING.md`, `tests/README.md`
4. **Worker container docs** — `codex4lunarwing/CLAUDE.md`, `lunarcode4lunarwing/CLAUDE.md`, etc.
5. **Internal/agent config** — `.claude/agents/*.md`, `AGENTS.md` files

**Note:** Some ironclaw references are intentional — directory names (`darkirc_channel_for_ironclaw/`, `git-ironclaw-unix-socket-client-repo/`), legacy path aliases (`IRONCLAW_BASE_DIR`), and historical references in release notes. These should be left alone but annotated.

**Effort:** 2-3 hours of careful grep + edit. Must verify each hit individually — blanket find-replace would break intentional references.

### 2B. Rename or annotate the ironclaw-named directories
**Verified:** Yes

Several directories still carry "ironclaw" in their path:
- `darkirc_channel_for_ironclaw/` — the DarkIRC WASM channel
- `git-ironclaw-unix-socket-client-repo/` — REPLv2 client
- `ic/openclaw-ports/` — already partially renamed (ironclaw → openclaw ports staging)

There's already a proposal: `docs/proposals/RENAME_IRONCLAW_WEECHAT_WS_CHANNEL_AND_ADAPTER`

**Recommendation:** Directory renames are high-risk (affect build paths, CI, import paths). Defer to a dedicated rename branch with full build verification. For now, add a `NOTE.md` in each directory explaining the legacy name.

**Effort:** 1 hour for annotations; 4+ hours for actual renames (separate PR).

### 2C. M13 — DarkIRC guide stale paths
**Source:** DOCS_AUDIT.md M13
**Status:** **DONE** — both `BUILD_INSTRUCTIONS.md` and `DARKIRC_BUILD_GUIDE.md` fully updated: all `~/ironclaw/` → `~/lunarwing/`, `ironclaw.db` → `lunarwing.db`, `target/release/ironclaw` → `target/release/lunarwing`, `ironclaw pairing` → `lunarwing pairing`, `ironclaw memory` → `lunarwing memory`, `ironclaw config` → `lunarwing config`, `ironclaw onboard` → `lunarwing onboard`. Zero ironclaw references remaining in either file.

**Note:** `DARKIRC_MT_ADAPTER.md` (third file in that directory) has 2 references to `darkirc_channel_for_ironclaw/` but those are the actual repo directory name — accurate, not stale. Left as-is until the directory itself is renamed (Tier 2B).

---

## TIER 3: Documentation Structure & Lifecycle (Higher effort)

### 3A. Add status labels to proposals
**Source:** DOCS_AUDIT_GLM.md item 4
**Verified:** ~35 active proposals in `docs/proposals/`, zero have status indicators.

**Approach:**
- Don't add YAML frontmatter (would require changing the rendering pipeline). Instead, add a `**Status:** draft | accepted | implemented | rejected` line at the top of each file.
- Move implemented/superseded proposals to `internal/history/proposals/` (some already moved during the reorg — verify which remain)

**Effort:** 1-2 hours. Must read each proposal to determine status.

### 3B. Tame docs/ops/ bloat
**Source:** DOCS_AUDIT_GLM.md item 3
**Verified:** GOALS cleanup is DONE. DarkFi analysis files still in `docs/ops/` (5 files: `darkfi_analysis_complete_summary.md`, `darkfi_detailed_technical_analysis.md`, `darkfi_message_throughput_analysis.md`, `darkfi_optimization_recommendations.md`, `darkfi_quick_reference.md`). These are technical analysis docs, not operational runbooks — better fit in `docs/reference/` or `docs/internal/`.

- Move 5 DarkFi analysis files → `docs/reference/` or `docs/internal/`
- Add a `README.md` to `docs/ops/` explaining categorization

**Effort:** 20 minutes.

### 3C. Fix hardcoded absolute user paths
**Source:** DOCS_AUDIT_GLM.md item 5; DOCS_AUDIT.md M15
**Verified:** **CONFIRMED** — 4 active files (excluding history/vendored) still have `/home/sun` or `/home/cmc` paths:
- `docs/ops/MULTITENANCY-PRODUCTION.md`
- `docs/ops/RELEASE-COMMANDS.md`
- `docs/releases/RELEASE-v1.1.0.md` (historical, may be acceptable)
- `docs/releases/RELEASE-v1.1.1.md` (historical, may be acceptable)

Replace with `$HOME`, relative paths, or `<user>` in the ops docs. Release notes are immutable historical records — leave those alone.

**Effort:** 15 minutes for the 2 ops files.

### 3D. Add "Prerequisites" and "Verification" sections to guides
**Source:** DOCS_AUDIT_GLM.md item 6
**Verified:** Yes — guides have content but inconsistent structure

Standardize each guide in `docs/guides/` to include:
- Prerequisites (version, dependencies)
- Steps (mostly present)
- Verification (how to confirm success)
- Rollback (what to do if it goes wrong)

**Effort:** 2-3 hours. Only apply to the ~12 active guides (skip vendored/history).

---

## TIER 4: Infrastructure & Process (Nice to have)

### 4A. Add documentation CI checks
**Source:** DOCS_AUDIT_GLM.md item 7
**Verified:** Not present

- **Forbidden-words check:** `grep -rn "ironclaw\|IronClaw" docs/ --include="*.md" | grep -v internal/history | grep -v vendored` as a CI gate (with an allowlist for intentional historical references in release notes, migration guides, etc.)
- **Link validity:** use `lychee` or `mlc` to check all markdown links
- **Frontmatter/schema validation:** if status labels are added (3A)

**Effort:** 1-2 hours for the CI config. Needs an allowlist for intentional ironclaw refs.

### 4B. README.md "Further Reading" should link to guided docs
**Source:** DOCS_AUDIT_GLM.md item 7
**Verified:** Yes — README links to docs/ subdirectories but not to the guided doc system (if one exists — the Zread guide system appears external)

**Effort:** 5 minutes if applicable.

### 4C. Commit message hygiene guidance
**Source:** My v1.1.6 code review (LOW-4)
**Verified:** Yes — v1.1.6 has commits like "d", "ud", "s", "ic10"

Add a note to `docs/guides/AI-CODE-CONTRIBUTION-POLICY.md` (or CONTRIBUTING.md) recommending conventional commit messages. Optionally add a commit-msg hook.

**Effort:** 15 minutes for guidance text.

---

## What's Already Done (from prior work + v1.1.6 + review-2 merge)

To avoid re-doing completed work:
- ✅ docs/ reorg (DOCS_REORG_CHECKLIST — all 10 areas complete)
- ✅ 70 vendored nanocode files archived to internal/vendored/
- ✅ docs/README.md rebuilt as accurate index
- ✅ DOCS_AUDIT items M1, M4-M9, M14, M17, M19-M21 closed
- ✅ DOCS_AUDIT items L1-L4, L8, L10, L12, L14 closed
- ✅ DarkIRC channel lib.rs IronClaw references in code are mostly historical/intentional
- ✅ docs/guides/ENABLING_DEV_TOOLS.md created (v1.1.6)
- ✅ docs/guides/AI-CODE-CONTRIBUTION-POLICY.md created (v1.1.6)
- ✅ Shellcheck quality gate for mt-admin (v1.1.6)
- ✅ DarkFi analyses moved from ic/ to docs/ops/ (v1.1.6)
- ✅ README.md truncated sentence (line 43) fixed
- ✅ README.md typos: "seperate" → "separate", "obselete" → "obsolete", "sponserships" → "sponsorships"
- ✅ README.md "Re worked" → "Reworked" worker descriptions cleaned up
- ✅ README.md release notes range updated to v1.0.7 → v1.1.6
- ✅ README.md worker count "4+" → "4"
- ✅ GOALS_1.1.4/1.1.5/1.1.6 archived to docs/ops/history/
- ✅ RELEASE-v1.1.6.md moved into docs/releases/

---

## Recommended Execution Order (remaining work)

1. **1A remaining + 1C remaining** — remove redundant bare LunarWing link on line 32; replace codex example in worker harness section with nanocode. ~5 minutes.
2. **2C** — DarkIRC guide stale paths (28 occurrences across 2 files). ~20 minutes.
3. **2A** — the ironclaw rename sweep outside docs/. Highest correctness-value work. ~2-3 hours.
4. **3A + 3B** — proposals status labels + DarkFi ops cleanup. ~2 hours.
5. **3C + 3D** — path fixes + guide standardization. Polish. ~3 hours.
6. **4** — CI checks and process. Future-proofing. ~2 hours.

Total remaining: ~8 hours of focused work. Each tier can be committed independently.
