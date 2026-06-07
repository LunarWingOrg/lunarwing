# XMPP known issues

Reconciled 2026-06-07.

- **OMEMO device trust** — the agent's OMEMO device may need to be trusted in a separate client
  before encrypted messages flow. This is XEP-0384 behavior, not a defect.
- **Inbound file uploads (OOB) — implemented, needs end-to-end testing.** As of v1.1.1 the channel
  parses `<x xmlns='jabber:x:oob'>` from incoming stanzas, downloads the file (30s timeout, 20 MB
  cap), and attaches it to the `IncomingMessage` (`extract_oob_attachments()`; see
  `docs/architecture/XMPP_FILE_TRANSFERS.md`). This pipeline has **not** been exercised end-to-end
  yet — the one real file-transfer caveat for the release.
  *(This section previously stated inbound OOB "isn't implemented"; that is now stale.)*
- **OMEMO MUC fallback spam / rare stuck processing loop** — historically observed; appear resolved
  (`docs/bugs/XMPP-OMEMO-BUG-TO-DO.md`). Reopen if they recur.
