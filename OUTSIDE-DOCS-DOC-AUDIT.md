# Outside-Docs Documentation Audit

Audit of all `.md` and `.txt` files **outside** the `docs/` directory that contain
stale "ironclaw" references, deprecated worker names, hardcoded paths, or other
issues. Identified during post-v1.1.6 documentation review.

**Date:** 2026-06-25
**Last updated:** 2026-06-25
**Reviewer:** Kumogakure
**Branch:** `kumogakure-post-1.1.6-doc-review-3`

---

## Completed (10/15)

### 1. `ic/tools-src/github/README.md` — 21 hits — DONE
- Title: "GitHub Tool for IronClaw" → LunarWing
- All `ironclaw secret set` commands → `lunarwing secret set`
- All 16 JSON example `"repo": "ironclaw"` → `"repo": "lunarwing"`
- Error/troubleshooting strings updated
- Commit: `8aafe3cf`

### 2. `projects/ocr-sidecar/DOCUMENTATION.md` — 10 hits — DONE
- "via IronClaw" → "via LunarWing", "Register with IronClaw" → LunarWing
- WASM tool install commands, troubleshooting, license updated
- Commit: `3477fe5b`

### 3. `ic/FEATURE_PARITY.md` — 5 hits — DONE
- `ironclaw pairing` → `lunarwing pairing`, `~/.ironclaw/` → `~/.lunarwing/`
- State directory, workspace-relative install, DM pairing references
- Commit: `8aafe3cf`

### 4. `ic/channels-src/xmpp/README.md` — 6 hits — DONE
- "IronClaw-facing adapter" → "LunarWing-facing adapter"
- `~/.ironclaw/channels/` → `~/.lunarwing/channels/`
- Hardcoded `/home/cmc/ironclaw/bridges/xmpp-bridge` → relative `bridges/xmpp-bridge/`
- `ironclaw onboard` → `lunarwing onboard`
- Commit: `8aafe3cf`

### 5. `ic/testing/lunarwing-xmpp/README.md` — 7 hits — DONE
- 4x `/home/cmc/lunarwing/ic` → `$LUNARWING_ROOT/ic`
- 2x `/home/sun/lw_workspace/...` → `$LUNARWING_ROOT/replv2git/...`
- Intentional legacy aliases left intact: `IRONCLAW_SOCKET`, `IRONCLAW_BASE_DIR`,
  `tensorzero::function_name::ironclaw` (model name), `ironclaw-watchdog` (migration note)
- Commit: `8aafe3cf`

### 6. `tests/README.md` — 2 hits — DONE
- `codex4ironclaw/` → `codex4lunarwing/` (directory was already renamed, docs were stale)
- Codex worker marked as **deprecated** in table and CLI example
- Commit: `1c797603`

### 8. `ic/tests/e2e/CLAUDE.md` — 2 hits — DONE
- "Environment passed to ironclaw" → lunarwing
- "spawning the ironclaw binary" → lunarwing
- Commit: `3477fe5b`

### 9. `ic/tests/e2e/README.md` — 1 hit — DONE
- "the ironclaw gateway" → "the lunarwing gateway"
- Commit: `3477fe5b`

### 10. `tensorzero-proxy-configurations/AGENTS.md` — 3 hits — DONE
- `ironclaw-proxy.py` → `lunarwing-proxy.py` (file was already renamed, docs were stale)
- "IronClaw adapter" → "LunarWing adapter"
- Commit: `1c797603`

### 15. `ic/upgrade.txt` — 1 hit — DELETED
- Stale one-liner: "we need to upgrade from 0.19.0 to 0.24.0 for ironclaw"
- Deleted
- Commit: `1c797603`

---

## Remaining (4 files)

### 7. `ic/unix-socket-client/README.md` — AWAITING DECISION
- Orphaned v1 dead code. Confirmed not referenced by any code or documentation.
- Entire `ic/unix-socket-client/` directory (4 files) is safe to delete.
- **Action:** Delete the whole directory (pending user confirmation)

### 11. `git-ironclaw-unix-socket-client-repo/AGENTS.md` — 2 hits
- "Ironclaw Unix socket REPL", `~/.ironclaw/ironclaw.sock`
- **Action:** Rename to LunarWing; update socket path

### 12. `replv2git/git-ironclaw-unix-socket-client-repo/AGENTS.md` — 2 hits
- Duplicate of #11 in replv2git subtree
- **Action:** Same fixes as #11

### 13. `PEBBLE.md` — 3 hits
- `ironclaw-gotify-tool/`, `ironclaw_weechat_wss/`
- These may be actual directory names in the repo — verify before changing
- **Action:** Verify if these are real dir names; if so, leave; if not, rename

### 14. `fresh_run_notes.txt` — 7 hits
- Old dev scratch notes with hardcoded paths (`/home/cmc/ironclaw/`)
- **Action:** Delete entirely — throwaway dev notes

---

## Notes

- The `git-ironclaw-unix-socket-repl-server-repo/*.txt` and
  `replv2git/git-ironclaw-unix-socket-repl-server-repo/*.txt` files (10 total)
  are old code snippets stored as `.txt` and are candidates for deletion,
  but are not included in the 15 above since they contain no ironclaw
  references — just junk scratch files.

- Files with `IRONCLAW_BASE_DIR`, `IRONCLAW_RECORD_TRACE`, `IRONCLAW_SOCKET` etc.
  are intentional legacy environment variable aliases for backwards
  compatibility. These were verified against source code and left intact.

- The directory names themselves (`git-ironclaw-unix-socket-client-repo/`,
  `darkirc_channel_for_ironclaw/`) are not addressed here — directory renames
  have broader impact and should be tracked separately.

- The `codex` worker is deprecated (not yet removed). References to it should
  be marked deprecated, not removed, until full removal is completed.
