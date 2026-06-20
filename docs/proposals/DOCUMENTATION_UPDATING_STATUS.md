# An incomplete description of where things stand (this document itself needs to be corrected before it can be taken seriously)

* The main docs/ reorganization is complete and the internal/ archive has been revisited.
* docs/README.md is an accurate fully-linked index, and DOCS_AUDIT.md reflects current eality.

## Possible next steps

1. Fix M13 (in-scope). docs/guides/darkirc_channel_for_ironclaw/BUILD_INSTRUCTIONS.md is the one doc still under docs/ carrying stale ~/ironclaw / ironclaw.db / target/release/ironclaw paths (~22 lines). It's small, in-scope, and would zero out the docs/-internal audit debt. Could fold into this branch before the PR.
2. Separate task — the out-of-docs/ rename sweep. DOCS_AUDIT.md still tracks 9 IronClaw→LunarWing fixes in code/root files (ic/FEATURE_PARITY, ic/COVERAGE_PLAN [delete-or-banner], ic/channels-src/xmpp/README, ic/docs/XMPP_WASM_REFACTOR, ic/.env.example, ic/tools-src/github/README, ic/docs/plans/, ic/claudecodetest.md, the unix-socket-client AGENTS.md). We have exact files + line numbers from the audit workflow, so this is a well-scoped follow-up branch — but it edits ic/, so it's deliberately out of this docs branch.
