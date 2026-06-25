# Outside-Docs Documentation Audit

Audit of all `.md` and `.txt` files **outside** the `docs/` directory that contain
stale "ironclaw" references, deprecated worker names, hardcoded paths, or other
issues. Identified during post-v1.1.6 documentation review.

**Date:** 2026-06-25
**Reviewer:** Kumogakure
**Branch:** `kumogakure-post-1.1.6-doc-review-3`

---

## Files to Fix (15)

### 1. `ic/tools-src/github/README.md` — 21 hits
- Entire doc uses "IronClaw" as product name
- Command examples: `ironclaw secret set`, `ironclaw tool run`
- Repo path references: "ironclaw"
- **Action:** Rename all product references to LunarWing; update command examples

### 2. `projects/ocr-sidecar/DOCUMENTATION.md` — 10 hits
- "via IronClaw", "Register with IronClaw"
- **Action:** Rename product references to LunarWing

### 3. `ic/FEATURE_PARITY.md` — 5 hits
- `ironclaw pairing`, `~/.ironclaw/`, `~/.ironclaw/tools/`
- **Action:** Update paths to `~/.lunarwing/`; rename commands

### 4. `ic/channels-src/xmpp/README.md` — 6 hits
- "IronClaw-facing adapter"
- `~/.ironclaw/channels/`
- Hardcoded path: `/home/cmc/ironclaw/`
- **Action:** Rename product references; fix paths to `~/.lunarwing/`; remove hardcoded home dir

### 5. `ic/testing/lunarwing-xmpp/README.md` — 7 hits
- `IRONCLAW_SOCKET` env var (may be intentional legacy alias — verify)
- Hardcoded path: `/home/sun/lw_workspace/`
- **Action:** Fix hardcoded paths; verify if IRONCLAW_SOCKET is still a valid env var

### 6. `tests/README.md` — 2 hits
- `codex4ironclaw/` directory reference
- `codex` worker (deprecated in v1.1.6)
- **Action:** Update directory name; replace `codex` with `nanocode` or `pebble`

### 7. `ic/unix-socket-client/README.md` — 1 hit
- Hardcoded path: `/home/cmc/ironclaw/`
- **Action:** Remove hardcoded home dir; use generic path

### 8. `ic/tests/e2e/CLAUDE.md` — 2 hits
- "ironclaw in tests"
- **Action:** Rename to LunarWing

### 9. `ic/tests/e2e/README.md` — 1 hit
- "ironclaw gateway"
- **Action:** Rename to LunarWing gateway

### 10. `tensorzero-proxy-configurations/AGENTS.md` — 3 hits
- `ironclaw-proxy.py`
- "IronClaw adapter"
- **Action:** Rename script reference and product name

### 11. `git-ironclaw-unix-socket-client-repo/AGENTS.md` — 2 hits
- "Ironclaw Unix socket REPL"
- `~/.ironclaw/ironclaw.sock`
- **Action:** Rename to LunarWing; update socket path

### 12. `replv2git/git-ironclaw-unix-socket-client-repo/AGENTS.md` — 2 hits
- Duplicate of #11 (same content in replv2git subtree)
- **Action:** Same fixes as #11

### 13. `PEBBLE.md` — 3 hits
- `ironclaw-gotify-tool/`, `ironclaw_weechat_wss/`
- These may be actual directory names in the repo — verify before changing
- **Action:** Verify if these are real dir names; if so, leave; if not, rename

### 14. `fresh_run_notes.txt` — 7 hits
- Old dev scratch notes with hardcoded paths (`/home/cmc/ironclaw/`)
- **Action:** Likely delete entirely — appears to be throwaway dev notes

### 15. `ic/upgrade.txt` — 1 hit
- One-liner: "we need to upgrade from 0.19.0 to 0.24.0 for ironclaw"
- **Action:** Likely delete — stale upgrade note, no longer relevant

---

## Notes

- The `git-ironclaw-unix-socket-repl-server-repo/*.txt` and
  `replv2git/git-ironclaw-unix-socket-repl-server-repo/*.txt` files (10 total)
  are old code snippets stored as `.txt` and are candidates for deletion,
  but are not included in the 15 above since they contain no ironclaw
  references — just junk scratch files.

- Files with `IRONCLAW_BASE_DIR`, `IRONCLAW_RECORD_TRACE`, `IRONCLAW_SOCKET` etc.
  may be intentional legacy environment variable aliases for backwards
  compatibility. Verify against source code before renaming.

- The directory names themselves (`git-ironclaw-unix-socket-client-repo/`,
  `codex4ironclaw/`, `darkirc_channel_for_ironclaw/`) are not addressed here —
  directory renames have broader impact and should be tracked separately.
