Right, same answer, different language. Here goes.

---

I dug through the repo's documentation audit records and reorg checklists. Frankly, the room for improvement is larger than some people's code comments. Here are specific suggestions, ordered by priority:

### 1. 🔴 Finish the IronClaw → LunarWing Full Rename (Most Urgent)

Your [DOCS_AUDIT.md](docs/DOCS_AUDIT.md) already documents **11 unresolved items** (M2, M3, M10, M12, M13, M22, L6, L9, L11, L13, etc.). The core issue: after forking from IronClaw to LunarWing, tons of files still reference the old name. This isn't just confusing — **it directly affects runtime behavior**. For example, [M7](docs/DOCS_AUDIT.md#L103-L123) has agent-injected prompts and [M17](docs/DOCS_AUDIT.md#L217-L223) has routine prompt templates still saying "IronClaw," so the LLM literally thinks it's a project that no longer exists.

Follow the [fix order](docs/DOCS_AUDIT.md#L281-L292) laid out in the audit: hit runtime-injected prompts first (M7+M6+M17), then the default path in code (M21), then sweep the remaining references.

### 2. 🔴 Resolve the Code-vs-Docs Path Contradiction

[M21](docs/DOCS_AUDIT.md#L255-L269) points out that `ic/src/bootstrap.rs` has `default_base_dir()` returning `~/.ironclaw`, while the docs (CLAUDE.md, README.md) everywhere say `~/.lunarwing`. **Either the code is lying or the docs are.** This is a root-cause-level contradiction — no amount of doc fixes matter if the code defaults to the wrong path.

### 3. 🟡 Tame the `docs/ops/` Bloat

The `ops/` directory currently has **38 files** — active goals, darkfi analyses, Gentoo ops notes, and shipped historical goals all mixed together. Suggestion:
- Shipped `GOALS_*` continue moving into `ops/history/` (partially done)
- The 5 DarkFi analysis files → `internal/` or `reference/`
- Add a `README.md` to `ops/` explaining the categorization logic

### 4. 🟡 Add Lifecycle Management to `docs/proposals/`

32 active proposals, but no status labels. Suggestion:
- Add YAML frontmatter to each file: `status: draft | accepted | implemented | rejected`
- Implemented proposals → `internal/history/proposals/`
- New contributors can then instantly see what's current vs. historical

### 5. 🟡 Fix Hardcoded Absolute User Paths

[M15](docs/DOCS_AUDIT.md#L194-L198) flags paths like `/home/sun/...` and `/home/cmc/...` baked into documentation. These break the moment someone else reads them on a different machine. Replace with `$REPO_ROOT` or relative paths consistently.

### 6. 🟢 Add "Prerequisites" and "Verification Steps" to Guides

The migration and deployment guides in `docs/guides/` are solid on content but lack standardized structure. Every guide should include at minimum:
- **Prerequisites**: what version, what dependencies
- **Steps**: already present
- **Verification**: how to confirm success after following the steps
- **Rollback**: what to do when things go sideways

### 7. 🟢 Add Documentation CI Checks

Since rename slip-ups have happened repeatedly, add CI guards:
- `grep -r "IronClaw\|ironclaw" docs/` as a forbidden-words check
- Markdown link validity checking (`mlc` or `lychee`)
- Frontmatter schema validation

---

### Suggested Next Steps

Start where the blast radius is largest:

- [Architecture Overview](4-architecture-overview) — understand the full picture before editing docs
- [Instance Setup and Configuration](3-instance-setup-and-configuration) — the path contradiction is most visible here
- [Quick Start](2-quick-start) — the first page new users see; stale names hurt most here
