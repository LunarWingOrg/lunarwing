# An incomplete description of where things stand (this document itself needs to be corrected before it can be taken seriously)

* The docs/ reorganization is complete and the internal/ archive has been revisited — 13 commits on 1.1.5-docs-update-reorg, all verified, nothing lost. The tree is clean, the README is an accurate fully-linked index, and DOCS_AUDIT.md reflects current reality.

## Suggested next steps

### Grounded in what we covered tonight, roughly in priority order:

1. Open the PR into staging. The branch is done and self-contained (docs-only, no code touched). This is the natural close-out — and the v1.1.5 release notes should call out the reorg when written. I can draft the PR description from the checklist/commit series whenever you want.

2. Quick win — fix M13 (in-scope). docs/guides/darkirc_channel_for_ironclaw/BUILD_INSTRUCTIONS.md is the one doc still under docs/ carrying stale ~/ironclaw / ironclaw.db / target/release/ironclaw paths (~22 lines). It's small, in-scope, and would zero out the docs/-internal audit debt. Could fold into this branch before the PR.
3.
4. 3. Separate task — the out-of-docs/ rename sweep. DOCS_AUDIT.md still tracks 9 IronClaw→LunarWing fixes in code/root files (ic/FEATURE_PARITY, ic/COVERAGE_PLAN [delete-or-banner], ic/channels-src/xmpp/README, ic/docs/XMPP_WASM_REFACTOR, ic/.env.example, ic/tools-src/github/README, ic/docs/plans/, ic/claudecodetest.md, the unix-socket-client AGENTS.md). We have exact files + line numbers from the audit workflow, so this is a well-scoped follow-up branch — but it edits ic/, so it's deliberately out of this docs branch.
5. Minor — refresh root CLAUDE.md. Its "Repo Structure" list still names the now-removed codex4ironclaw/ (audit M20 flagged this). A small, separate cleanup.

* My recommendation: #1 + #2 now (close out the docs work cleanly), then #3 as its own branch when you want to tackle the code-side rename debt. Happy to start any of these — just point me at one.
