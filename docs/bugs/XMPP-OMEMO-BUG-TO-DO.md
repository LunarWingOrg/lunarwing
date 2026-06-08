# BUG: OMEMO MUC fallback-spam + stuck processing loop

> **STATUS: FIXED / not reproducing (as of 2026-06-07)** — reopen with logs if it recurs.

**Severity:** Medium (when active) — affected OMEMO group chat (MUC) only.

## Symptoms

Two symptoms that showed up together in OMEMO group chats:

1. **Fallback-spam** — the agent repeatedly sent the plaintext fallback *"I sent you an OMEMO
   encrypted message but your client doesn't seem to support that"* instead of decrypting,
   typically right after a bridge/daemon restart.
2. **Stuck processing loop** — the agent appeared wedged ("Message queued — will be processed
   after the current turn") and stopped producing replies.

## Status / resolution

Neither symptom currently reproduces. They are consistent with two known, since-addressed
behaviors rather than a distinct unfixed bug:

- **OMEMO warmup after restart** is expected: encrypted MUC can take several messages after a
  restart before decrypting reliably (see `CLAUDE.md` → "XMPP / OMEMO Known Behavior"). The
  early fallback messages are the warmup window, not a loop.
- **Stuck `Processing` threads** were addressed by the `handle_message` timeout/recovery work
  and stuck-run recovery (see `docs/architecture/HANDLE_MESSAGE_FIX.md` and the Routine System
  notes in `CLAUDE.md`).

This note was previously a placeholder ("document the OMEMO MUC bug + stuck loop"); it is kept
as a thin Fixed record. If the spam or stuck loop returns, reopen with bridge `/v1/status`
output and `RUST_LOG=lunarwing=debug` daemon logs around the affected messages.
