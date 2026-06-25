Conversation From ZREAD:

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

---

For README.md specifically:

---

Here's what screams "outdated" in the root [README.md](README.md), beyond the test harness you already know about:

---

### 1. 🔴 Release Notes Range is Stale (Line 324)

```markdown
- **Release notes:** [docs/releases/](docs/releases/) — v1.0.7 → v1.1.4
```

The `docs/releases/` directory now contains releases up through **v1.1.5** (and a `CHANGELOG-AGENTS.md`). The README stops at v1.1.4. Minor, but it tells a reader the docs aren't being maintained in lockstep with releases.

### 2. 🔴 Worker Test Harness Section (Lines 209–221) — You Already Know

The whole `### Worker Test Harness` block references `tests/README.md`, which itself still says "Codex" worker sources from `codex4ironclaw/` (line 9 of [tests/README.md](tests/README.md)) and lists only 4 worker types. If the harness has diverged significantly from reality, this section is actively misleading anyone trying to run tests.

### 3. 🟡 "4+ Worker Types" Claim (Line 89)

```markdown
* Worker test harness for all 4+ worker types with Docker Compose isolation (`tests/`)
```

The "4+" is vague and the README elsewhere lists exactly 4 (Nanocode, Pebble, Built-in, Sandbox). If Pebble is now a real tested worker type, say 5. If Codex is deprecated, say 4. "4+" reads like a placeholder that never got resolved.

### 4. 🟡 Missing Pebble Worker in Feature List (Lines 69–73)

The Worker Containers section lists Nanocode, Pebble, Built-in, and Sandbox — but the descriptions for Built-in and Sandbox both say **"Debloated"** and "Re worked" with awkward phrasing:

> * **Re worked Built-in Worker - Debloated** — Native worker running inside the LunarWing daemon getting debloated, rip out obselete worker modes...
> * **Re worked Sandbox Worker - Debloated** — Docker-isolated execution sandbox, debloated

"Re worked" with a space, "obselete" misspelled, "getting debloated" in present tense — this reads like draft notes, not a polished README. Either the debloating is done (past tense) or it's still in progress (say so clearly).

### 5. 🟡 E2E Tests Reference May Be Stale (Lines 197–207)

```markdown
### E2E Tests (Python/Playwright)

Browser-based E2E tests against a live instance with a mock LLM. See [ic/tests/e2e/CLAUDE.md](ic/tests/e2e/CLAUDE.md).
```

Let me check if that path even exists — but given the project's trajectory, if E2E testing has moved or changed framework, this is a dead link. Worth verifying.

### 6. 🟡 Integration Test Harness References (Lines 223–229)

```markdown
`ic/scripts/lunarwing-xmpp-test-env.sh` is the full-stack test harness...
- Full single-tenant reference: [ic/testing/lunarwing-xmpp/README.md](ic/testing/lunarwing-xmpp/README.md)
```

The `ic/testing/lunarwing-xmpp/` directory still exists but only contains a README and two `.env.example` files. If the harness has evolved, this may undersell or misrepresent what's actually there.

### 7. 🟡 "Further Reading" Doesn't Link to the Guide You're Reading Right Now

The README's "Further Reading" section (line 315+) links to `docs/README.md` and various subdirectories, but **doesn't mention the guided documentation** (this guide system with 31 pages). That's a significant omission — the guide is the most approachable entry point for new users.

### 8. 🟡 Typos & Awkward Phrasing

- Line 43: "Proprietary service centered channels... are int" — sentence appears **truncated** (cuts off mid-word)
- Line 67: "seperate repo" → should be "separate repo"
- Line 72: "obselete" → "obsolete"
- Line 96: "open protoc" — also **truncated** (same sentence continues in the features section but cuts off here)
- Line 102: "sponserships" → "sponsorships"

### 9. 🟢 Redundant "LunarWing" Link (Line 32)

```markdown
[LunarWing](https://lunarwing.org/)
```

This appears right after the Quick Links section with no context. It's a bare markdown link duplicating the website link from line 27. Looks like a leftover.

---

### Summary: Priority Fix Order

| Priority | Issue | Lines |
|----------|-------|-------|
| 🔴 | Truncated sentences (2 occurrences) | 43, 96 |
| 🔴 | Release notes range stops at v1.1.4 | 324 |
| 🔴 | Test harness section outdated | 89, 209–221 |
| 🟡 | Typos: "seperate", "obselete", "sponserships" | 67, 72, 102 |
| 🟡 | "Debloated" worker descriptions read like draft notes | 72–73 |
| 🟡 | No link to the guided documentation system | 315+ |
| 🟡 | "4+" worker types is vague | 89 |
| 🟢 | Redundant bare link | 32 |

The truncated sentences are the most embarrassing — they look like a copy-paste artifact that nobody caught. Fix those first, then the test harness section.

### Suggested Next Steps

- [Quick Start](2-quick-start) — cross-reference to make sure it's consistent with the README's setup instructions
- [Architecture Overview](4-architecture-overview) — useful context for rewriting the worker descriptions accurately
- [Test Harness and E2E Testing](31-test-harness-and-e2e-testing) — the guide page that should align with whatever you update in the README's testing section

---


