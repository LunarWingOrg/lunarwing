# XMPP known issues

Reconciled 2026-06-07.

- **OMEMO device trust** — the agent's OMEMO device may need to be trusted in a separate client
  before encrypted messages flow. This is XEP-0384 behavior, not a defect.
- **Inbound file uploads — implemented (incl. encrypted media), live e2e validation pending.** The
  channel answers `disco#info` + advertises entity caps (so clients recognize the agent as a valid
  recipient), extracts OOB (`<x xmlns='jabber:x:oob'>`) and `aesgcm://` (XEP-0454) URLs — the latter
  also from decrypted OMEMO bodies — and downloads them with bounded concurrency, a per-stanza URL
  cap, and a streamed 20 MB size cap; `aesgcm://` media is AES-256-GCM-decrypted locally. This is
  unit-tested and the bridge builds, but the full pipeline has **not** yet been exercised end-to-end
  against a live server (Conversations/Gajim → agent). See `docs/architecture/XMPP_FILE_TRANSFERS.md`.
  *(Earlier notes said inbound OOB "isn't implemented" / "needs e2e testing"; the implementation is
  now in place — only the live e2e run remains.)*
- **Inbound downloads have no SSRF guard (deferred).** The bridge fetches sender-supplied OOB /
  `aesgcm://` URLs without blocking private/loopback/metadata IPs. Deployments rely on the network
  boundary and the `ALLOW_PRIVATE_IPS` model; a future phase can reuse
  `config/helpers.rs::validate_base_url`.
- **OMEMO MUC fallback spam / rare stuck processing loop** — historically observed; appear resolved
  (`docs/bugs/XMPP-OMEMO-BUG-TO-DO.md`). Reopen if they recur.
