# Post-v1.1.6 Documentation Improvement Plan

**Date:** 2026-06-25
**Author:** Kumogakure
**Branch:** `kumogakure-post-1.1.6-doc-review-1`
**Scope:** Full documentation improvement across the entire repo (docs/ and non-docs/)

## Context

This plan synthesizes three sources:
1. **KUMOGAKURE-POST-1.1.6-REVIEW** — code review of v1.1.6 (committed to this branch)
2. **docs/DOCS_AUDIT_GLM.md** — Zread-powered doc audit by sun (committed to this branch)
3. **Prior doc cleanup work** — my non-docs staleness audit from June 23 (session 20260623). **Caveat:** much of that may already be done — the `docs/` reorg (DOCS_REORG_CHECKLIST.md) was marked complete June 19, and several DOCS_AUDIT items were closed. Each item below must be verified against current file state before acting.

The `docs/` tree was reorganized on June 19 (vendored nanocode archived, history separated, index rebuilt). That work was solid. This plan focuses on what remains.

---

## TIER 1: Fix Now (High visibility, low effort)

### 1A. README.md truncated sentences + typos
**Source:** DOCS_AUDIT_GLM.md items 8 and 9
**Verified:** Yes — confirmed in current README.md

- Line 43: "Proprietary service centered channels... are int" — **truncated mid-word**
- Line 67: "seperate repo" → "separate repo"
- Line 72: "obselete" → "obsolete"
- Line 72-73: "Re worked" → "Reworked" (remove space), "getting debloated" — rewrite to past tense or mark as WIP
- Line 102: "sponserships" → "sponsorships"
- Line 32: Redundant bare `[LunarWing](https://lunarwing.org/)` link — remove

**Effort:** 10 minutes. Pure text fixes.

### 1B. README.md release notes range is stale
**Source:** DOCS_AUDIT_GLM.md item 1
**Verified:** Yes — line 324 says "v1.0.7 → v1.1.4", but v1.1.5 and v1.1.6 now exist

- Update to "v1.0.7 → v1.1.6"
- Also add `RELEASE-v1.1.5.md` and `RELEASE-v1.1.6.md` to the releases index in `docs/README.md` (currently stops at v1.1.4 in that index too)

**Effort:** 5 minutes.

### 1C. README.md worker count + codex deprecation
**Source:** DOCS_AUDIT_GLM.md items 3 and 4; v1.1.6 release notes
**Verified:** Yes

- Line 89: "4+ worker types" — v1.1.6 deprecated codex. Current supported: Nanocode, Pebble, Built-in, Sandbox = 4. Say "4" or "3 external + built-in/sandbox"
- Line 209-221: Worker test harness section references `tests/README.md` which still says "Codex" and `codex4ironclaw/` — update or note codex as deprecated
- Worker descriptions (lines 69-73): rewrite the "Re worked Built-in Worker - Debloated" / "Re worked Sandbox Worker - Debloated" entries into clean past-tense descriptions

**Effort:** 20 minutes. Needs accuracy check against current worker state.

### 1D. docs/README.md index missing v1.1.5 and v1.1.6 releases
**Verified:** Yes — the releases table in docs/README.md stops at `RELEASE-v1.1.4.md`

- Add entries for v1.1.5 (Kawarimi) and v1.1.6 (Reversible Extinction)

**Effort:** 5 minutes.

### 1E. docs/ops/ missing v1.1.6 GOALS and shipped GOALS cleanup
**Verified:** Yes

- `docs/ops/GOALS_1.1.6.md` exists but is NOT listed in docs/README.md ops section
- `GOALS_1.1.4.md` and `GOALS_1.1.5.md` should be archived to `ops/history/` (shipped releases)
- GOALS_1.1.6 should be listed in the index

**Effort:** 10 minutes.

---

## TIER 2: IronClaw Rename Sweep (Medium effort, high correctness value)

### 2A. Finish the IronClaw → LunarWing rename outside docs/
**Source:** DOCS_AUDIT.md remaining items (M2, M3, M10, M12, M13, M22, L6, L9, L11, L13)
**Verified:** Yes — 47 files outside docs/ still contain "ironclaw" references

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
**Verified:** Needs verification

`docs/guides/darkirc_channel_for_ironclaw/BUILD_INSTRUCTIONS.md` reportedly still has `~/ironclaw/`, `ironclaw.db`, `target/release/ironclaw` paths. This is the one remaining doc *inside* docs/ with stale paths.

**Effort:** 15 minutes if confirmed.

---

## TIER 3: Documentation Structure & Lifecycle (Higher effort)

### 3A. Add status labels to proposals
**Source:** DOCS_AUDIT_GLM.md item 4
**Verified:** Yes — ~35 active proposals in docs/proposals/, no status indicators

**Approach:**
- Don't add YAML frontmatter (would require changing the rendering pipeline). Instead, add a `**Status:** draft | accepted | implemented | rejected` line at the top of each file.
- Move implemented/superseded proposals to `internal/history/proposals/` (some already moved during the reorg — verify which remain)

**Effort:** 1-2 hours. Must read each proposal to determine status.

### 3B. Tame docs/ops/ bloat
**Source:** DOCS_AUDIT_GLM.md item 3
**Verified:** Partially — the reorg moved DarkFi analyses to docs/ops/ (from ic/), but they're analysis docs not ops docs

- 5 DarkFi analysis files → better fit in `docs/reference/` or `docs/internal/`
- Shipped GOALS_1.1.4, GOALS_1.1.5 → `ops/history/` (already has a history/ subdir)
- Add a `README.md` to `docs/ops/` explaining categorization (active ops vs shipped checklists vs analysis)

**Effort:** 30 minutes.

### 3C. Fix hardcoded absolute user paths
**Source:** DOCS_AUDIT_GLM.md item 5; DOCS_AUDIT.md M15
**Verified:** Needs re-verification — M15 was partially closed

Paths like `/home/sun/...` and `/home/cmc/...` in docs. Replace with `$HOME`, relative paths, or `<user>`.

**Effort:** 30 minutes of grep + fix.

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

## What's Already Done (from prior work + v1.1.6)

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

---

## Recommended Execution Order

1. **TIER 1 (all)** — quick wins, fix the embarrassing stuff first (truncated sentences, typos, stale release range). ~50 minutes total.
2. **TIER 2A** — the ironclaw rename sweep outside docs/. This is the highest correctness-value work. ~2-3 hours.
3. **TIER 2C** — M13 DarkIRC guide paths. Quick if confirmed.
4. **TIER 3A+3B** — proposals status labels + ops cleanup. Structural improvements. ~2 hours.
5. **TIER 3C+3D** — path fixes + guide standardization. Polish. ~3 hours.
6. **TIER 4** — CI checks and process. Future-proofing. ~2 hours.

Total estimated: ~10 hours of focused work. Can be split across multiple sessions or delegated.

Each tier can be committed independently. TIER 1 is safe to do immediately with zero risk.
