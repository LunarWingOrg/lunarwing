# Documentation Audit — Medium Priority Items

**Date:** 2026-05-12
**Branch:** staging
**Context:** These items were identified during a full docs audit. They are stale but not immediately harmful — they cause confusion but don't directly break workflows or production deployments.

---

## M1. `ic/CONTRIBUTING.md` — Single "IronClaw" reference

**Line:** 56
**Current:** `IronClaw uses dual-backend persistence`
**Fix:** Change `IronClaw` → `LunarWing`

---

## M2. `ic/FEATURE_PARITY.md` — Title and paths reference IronClaw/OpenClaw

**What's wrong:**
- Title: `# IronClaw <-> OpenClaw Feature Parity Matrix`
- Lines 305, 334: `~/.ironclaw/` paths
- Lines 137, 476, 535: `ironclaw pairing` commands
- Last reviewed date: 2026-03-10

**Fix:**
- Rename title to `# LunarWing <-> OpenClaw Feature Parity Matrix`
- Update `~/.ironclaw/` → `~/.lunarwing/`
- Update `ironclaw pairing` → `lunarwing pairing`

---

## M3. `ic/COVERAGE_PLAN.md` — Entirely stale pre-fork document

**What's wrong:**
- Title: `# IronClaw Coverage Plan: 63.3% to 95%`
- Generated 2025-03-06 against `github.com/nearai/ironclaw`
- Coverage numbers, module sizes, and codecov URLs are all from the upstream project before the fork (February 2026)

**Fix:** Delete the file or add a prominent `STALE` banner at the top explaining it reflects upstream pre-fork state and should not be relied on.

---

## M4. `ic/fuzz/README.md` — Wrong title and crate path

**What's wrong:**
- Title: `# IronClaw Fuzz Targets`
- Line 4: references `crates/ironclaw_safety/fuzz/` — the actual crate is `crates/lunarwing_safety/fuzz/`

**Fix:**
- Title → `# LunarWing Fuzz Targets`
- `crates/ironclaw_safety/fuzz/` → `crates/lunarwing_safety/fuzz/`

---

## M5. `ic/crates/lunarwing_safety/fuzz/README.md` — Title says "ironclaw_safety"

**What's wrong:** Title is `# ironclaw_safety Fuzz Targets` but the crate is `lunarwing_safety`.

**Fix:** Title → `# lunarwing_safety Fuzz Targets`

---

## M6. `ic/skills/` — Multiple skills reference "IronClaw"

These are LLM-visible prompt extensions — wrong names affect agent behavior at runtime.

**Files and changes:**

| File | Issues |
|------|--------|
| `ic/skills/ironclaw-workflow-orchestrator/SKILL.md` | Name field, description, heading all say "IronClaw" → rename to LunarWing |
| `ic/skills/review-checklist/SKILL.md` | Line 21: "IronClaw PRs" → "LunarWing PRs" |
| `ic/skills/web-ui-test/SKILL.md` | 6 "IronClaw" references, `~/.ironclaw/installed_skills/` path, `ironclaw` log message |
| `ic/skills/local-test/SKILL.md` | 12+ `ironclaw-test` Docker image references, `ironclaw=debug` RUST_LOG, `ironclaw-test` container names |

---

## M7. `ic/.claude/` rules and commands — Pervasive "IronClaw" references

These are injected into agent prompts and directly affect how coding agents refer to the project.

**Files and changes:**

| File | Issues |
|------|--------|
| `ic/.claude/rules/skills.md` | `~/.ironclaw/skills/`, `~/.ironclaw/installed_skills/` |
| `ic/.claude/rules/tools.md` | `ironclaw tool install` |
| `ic/.claude/commands/add-tool.md` | "IronClaw" product name |
| `ic/.claude/commands/fix-issue.md` | "IronClaw" product name |
| `ic/.claude/commands/pr-shepherd.md` | "IronClaw" product name |
| `ic/.claude/commands/respond-pr.md` | "IronClaw" product name |
| `ic/.claude/commands/trace.md` | "IronClaw" product name |
| `ic/.claude/commands/add-sse-event.md` | "IronClaw" product name |
| `ic/.claude/commands/ship.md` | "IronClaw" product name |
| `ic/.claude/commands/review-pr.md` | "IronClaw" product name |
| `ic/.claude/commands/review-crate.md` | "IronClaw" product name |

**Fix:** Replace all `IronClaw` → `LunarWing`, `ironclaw` → `lunarwing` (for CLI commands/paths), `~/.ironclaw/` → `~/.lunarwing/` across all listed files.

---

## M8. `ic/src/tools/README.md` — Two "IronClaw" references

**Lines:** 109, 123
**Current:** "WASM Tools (IronClaw native)"
**Fix:** `IronClaw` → `LunarWing`

---

## M9. `ic/src/setup/README.md` — "IronClaw's onboarding"

**Line:** 3
**Current:** `This document is the authoritative specification for IronClaw's onboarding`
**Fix:** `IronClaw's` → `LunarWing's`
**Note:** Lines 91 (`IRONCLAW_BASE_DIR`) and 762 (`IRONCLAW_OAUTH_CALLBACK_URL`) are correctly documented as legacy aliases — leave those as-is.

---

## M10. `ic/channels-src/xmpp/README.md` — Stale absolute path and product name

**What's wrong:**
- Line 12: hardcoded path `/home/cmc/ironclaw/bridges/xmpp-bridge` (wrong absolute path)
- `~/.ironclaw/channels/` paths
- "IronClaw-facing adapter" description

**Fix:**
- Change absolute path to relative or `../bridges/xmpp-bridge`
- `~/.ironclaw/channels/` → `~/.lunarwing/channels/`
- `IronClaw` → `LunarWing`

---

## M11. `ic/channels-src/discord/README.md` — "Discord Channel for IronClaw"

**What's wrong:** Titled "Discord Channel for IronClaw" and references IronClaw setup. Discord is intentionally unsupported per the project philosophy, but the doc still exists.

**Fix:** Either delete the file or add a banner stating Discord is unsupported and the channel source is retained only for reference. Update product name regardless.

---

## M12. `ic/docs/XMPP_WASM_REFACTOR.md` — 9 stale IronClaw references

**What's wrong:** Uses `~/.ironclaw/channels/`, `~/.ironclaw/extensions/`, `~/.ironclaw/state/`, and "IronClaw" product name throughout.

**Fix:** Replace all `~/.ironclaw/` → `~/.lunarwing/` and `IronClaw` → `LunarWing`.

---

## M13. `docs/guides/darkirc_channel_for_ironclaw/BUILD_INSTRUCTIONS.md` — 20+ stale references

**What's wrong:** Uses `~/ironclaw/`, `~/.ironclaw/`, `ironclaw.db`, `target/release/ironclaw` throughout. Directory layout diagram shows entirely wrong paths.

**Fix:** Replace all `~/ironclaw/` → `~/lunarwing/`, `~/.ironclaw/` → `~/.lunarwing/`, `ironclaw.db` → `lunarwing.db`, `target/release/ironclaw` → `target/release/lunarwing`.

---

## M14. `AGENTS.md` — Wrong directory path and product name

**What's wrong:**
- Line 50: says `openclaw-ports/` exists at repo root, but actual path is `ic/openclaw-ports/`
- Says "core IronClaw files"

**Fix:**
- `openclaw-ports/` → `ic/openclaw-ports/`
- `IronClaw` → `LunarWing`

---

## M15. `ic/testing/lunarwing-xmpp/README.md` — Hardcoded user-specific paths

**Lines:** 222, 226
**Current:** `/home/sun/lw_workspace/lunarwing/replv2git/git-ironclaw-unix-socket-client-repo`
**Fix:** Replace with relative paths or use a placeholder like `$REPO_ROOT/replv2git/git-ironclaw-unix-socket-client-repo`.

---

## M16. `docs/README.md` — Incomplete index

**Missing entries:**
- `docs/ops/WORKER-CONTAINERS.md` from the ops table
- `docs/guides/MIGRATE_IRONCLAW_LIBSQL_TO_MT.md` and `docs/guides/MIGRATE_IRONCLAW_TO_MT.md` from guides
- `docs/proposals/` directory (contains `MULTICA_SUPPORT.md`)
- `docs/bugs/` directory (contains 6 bug documents)
- `docs/REORG.md`
- Several guide subdirectory README files (lunarcode4lunarwing, ic-infrastructure-health-check, ic_sm, replv2git)
- `docs/guides/ironclaw_weechat_wss/weechat_relay/TROUBLESHOOTING.md`

**Fix:** Add missing entries to the index under their appropriate sections.

---

## M17. `ic/docs/GOTIFY_ROUTINE_PROMPT.md` — Runtime prompt template says "IronClaw"

**What's wrong:** 5 "IronClaw" references including in the prompt template that gets injected into the LLM at runtime:
- "You are running as a scheduled IronClaw routine"
- Notification title: "IronClaw Morning Status"

**Fix:** Replace all `IronClaw` → `LunarWing` in the prompt template and surrounding text. This is particularly important because the text is sent to the LLM at runtime.

---

## M18. License mismatch between Cargo.toml and LICENSE file

**What's wrong:**
- `ic/Cargo.toml` (and all crate Cargo.tomls) declare `license = "MIT OR Apache-2.0"` (inherited from upstream)
- The actual `LICENSE` file at repo root is AGPLv3
- `README.md` states "The LunarWing project maintains the AGPLv3 license"
- `tools-src/slack/README.md` and `tools-src/github/README.md` also state MIT/Apache-2.0

**Fix:** Update `license` field in all Cargo.toml files to `AGPL-3.0-or-later` (or whichever SPDX identifier matches the LICENSE file). Update WASM tool READMEs to match.

---

## M19. `lunarcode4lunarwing/CLAUDE.md` — Says "IronClaw Nanocode Worker"

**What's wrong:** Uses "IronClaw" product name and `lunarwing-worker` Docker compose service name. The `lunarcode4lunarwing/` directory name is intentionally preserved per the rename table, but content descriptions should say LunarWing.

**Fix:** Replace product name `IronClaw` → `LunarWing` in descriptions. Docker service names should use `lunarwing-worker`.

---

## M20. `codex4ironclaw/CLAUDE.md` — Says "IronClaw Codex Worker"

**What's wrong:** Uses "IronClaw" product name and `ironclaw-codex-worker:latest` image name.

**Fix:** Replace product name `IronClaw` → `LunarWing` in descriptions. Leave Docker image names as-is if they match actual built images.

---

## M21. `ic/src/bootstrap.rs` — Default base dir is `.ironclaw` not `.lunarwing`

**What's wrong:**
- Line 62: `default_base_dir()` returns `home.join(".ironclaw")`
- Line 67: fallback also uses `.ironclaw`
- Line 16: static variable is named `IRONCLAW_BASE_DIR`
- Line 75: doc comment says "Defaults to `~/.lunarwing`" — contradicts the code

Multiple docs (root CLAUDE.md, root README.md) claim the default is `~/.lunarwing`, but the code uses `.ironclaw` in both cases. The actual `.env` file on disk lives at `/home/cmc/.ironclaw/.env`.

**Fix:** This is a code change, not just a docs fix. Either:
1. **Update the code** to default to `.lunarwing` (preferred — aligns with the rename), OR
2. **Update the docs** to say `.ironclaw` (matches current reality)

Option 1 is the correct long-term fix but requires verifying no scripts or services depend on the `.ironclaw` default path. The `IRONCLAW_BASE_DIR` env var is already accepted as a legacy alias, so existing deployments using that var would continue working. The risk is any deployment relying on the implicit `.ironclaw` default without setting either env var.

---

## M22. `ic/.env.example` — References `~/.ironclaw/session.json`

**Lines:** 41, 49
**Current:** `~/.ironclaw/session.json`
**Fix:** Update to `~/.lunarwing/session.json` (or leave as-is until M21 is resolved, since this path currently matches the code default).

---

## Suggested fix order

1. **M7 + M6 + M17** — Agent-injected prompts (highest runtime impact)
2. **M21** — Base directory code change (root cause of many path mismatches)
3. **M18** — License mismatch (legal)
4. **M14** — AGENTS.md wrong path
5. **M1, M4, M5, M8, M9** — Simple single-reference renames
6. **M2, M10, M12, M13, M19, M20, M22** — Multi-reference renames
7. **M16** — docs/README.md index update
8. **M15** — Hardcoded user paths
9. **M3** — Stale coverage plan (delete or banner)
10. **M11** — Discord README (delete or banner)

---
---

# Documentation Audit — Low Priority Items

**Context:** Cosmetic issues, internal notes, and historical docs. Not harmful but contribute to naming inconsistency across the repo.

---

## L1. `ic/crates/lunarwing_engine/MONTY.md` — Wrong crate name in test command

**Line:** 5
**Current:** `cargo test -p ironclaw_engine`
**Fix:** `cargo test -p lunarwing_engine`

---

## L2. `ic/crates/lunarwing_engine/prompts/mission_self_improvement.md` — "IronClaw engine"

**Lines:** 1, 33
**Current:** "self-improvement agent for the IronClaw engine", `cargo test -p ironclaw_engine`
**Fix:** `IronClaw` → `LunarWing`, `ironclaw_engine` → `lunarwing_engine`

---

## L3. `ic/crates/lunarwing_engine/prompts/mission_expected_behavior.md` — "IronClaw"

**Line:** 1
**Current:** "You investigate why IronClaw did not behave as the user expected."
**Fix:** `IronClaw` → `LunarWing`

---

## L4. `ic/deploy/workspace-template/SOUL.md` — "upstream Ironclaw"

**Line:** 4
**Current:** References "upstream Ironclaw"
**Note:** This is the workspace template deployed to new instances — new instances will get the stale name.
**Fix:** `Ironclaw` → `LunarWing`

---

## L5. `docs/internal/FORK_CONTEXT.md` — "IronClaw watchdog", stale secrets path

**Lines:** 47, 53, 80
**Current:** "IronClaw watchdog service/timer", "Main IronClaw daemon service", `/home/cmc/.ironclaw/.env`
**Fix:** `IronClaw` → `LunarWing`, update path to match current reality

---

## L6. `ic/tools-src/github/README.md` — All examples use `nearai/ironclaw`

**What's wrong:** Every JSON example uses `"owner": "nearai", "repo": "ironclaw"`. Also uses `ironclaw secret set` CLI command.
**Fix:** Update examples to use the LunarWing repo, `ironclaw secret set` → `lunarwing secret set`

---

## L7. `ic/tools-src/slack/README.md` — "IronClaw" throughout

**What's wrong:** Uses "IronClaw" product name, `~/.ironclaw/tools/` paths, `ironclaw tool install` / `ironclaw secret set` commands. Sends "Hello from IronClaw!" in examples.
**Note:** Slack is intentionally unsupported.
**Fix:** Rename or add unsupported banner (same treatment as Discord in M11).

---

## L8. `ic/docs/smart-routing-spec.md` — "Smart Model Routing for IronClaw"

**What's wrong:** Title and content use "IronClaw".
**Fix:** `IronClaw` → `LunarWing`

---

## L9. `ic/docs/plans/` — All 2026-02 planning docs reference IronClaw

**Files:**
- `2026-02-24-automated-qa.md`
- `2026-02-24-e2e-infrastructure-design.md`
- `2026-02-24-e2e-infrastructure.md`

**What's wrong:** Pre-fork planning documents reference `ironclaw` binary names, fixture names, and "IronClaw" product name. Include code snippets with `ironclaw_binary()`, `ironclaw_server`.
**Fix:** These are historical. Either leave as-is with a "historical, pre-fork" note at the top, or do a bulk rename.

---

## L10. `RELEASE-v1.0.6.md` — Placeholder content

**What's wrong:** Release date is `2026-??-??`, features are `Stuff`, fixes are `Thing 1`. References `lunarwing-worker-nanocode:latest` image name.
**Fix:** Fill in actual release content when ready, update image name.

---

## L11. `ic/claudecodetest.md` — Uses "Ironclaw" product name

**What's wrong:** Test results document uses "Ironclaw" product name and references `IronclawCustomTools` GitHub org.
**Fix:** `Ironclaw` → `LunarWing`. Consider whether this file should be deleted (appears to be a one-off test log).

---

## L12. `docs/internal/REPLv2_Client_and_Server.md` — Stub with typos

**What's wrong:** Contains only a stub with typo ("seperate" for "separate"). Root README.md references this as `REPLv2_Client_and_Server.md` without the `docs/internal/` prefix.
**Fix:** Either flesh out the content or delete the stub. Fix the reference path in root README.md.

---

## L13. `git-ironclaw-unix-socket-client-repo/AGENTS.md` — Wrong socket path

**What's wrong:** Build instructions reference `cargo run -- ~/.ironclaw/ironclaw.sock`. The socket file is now `lunarwing.sock` per the rename table.
**Note:** The directory name `git-ironclaw-unix-socket-client-repo/` is intentionally preserved.
**Fix:** `~/.ironclaw/ironclaw.sock` → `~/.ironclaw/lunarwing.sock` (socket renamed, base dir not yet)

---

## L14. `ic/scripts/dev-setup.sh` — Comment says "IronClaw"

**Line:** 2
**Current:** `# Developer setup script for IronClaw.`
**Fix:** `IronClaw` → `LunarWing`

---

## L15. Root-level stub files

**Files:** `LOREBOOKS.md`, `PROFILES.md`, `OLD_RESUME_NC.md`, `CHANGED_IN.md`
**What's wrong:** Personal notes/stubs that aren't documentation. They clutter the repository root.
**Fix:** Move to a `notes/` directory, delete, or add to `.gitignore` if they're local-only.
