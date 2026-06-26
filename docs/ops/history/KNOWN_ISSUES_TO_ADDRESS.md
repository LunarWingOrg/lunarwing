# Known issues to address

> Canonical, reconciled lists live in `RELEASE-v1.1.1.md` (Known Issues) and
> `docs/bugs/README.md`. This file is just the short ops scratchpad.

Reconciled 2026-06-07:

- ~~weechat channel secret testing~~ — **DONE.** Channel-originated messages now resolve under the
  owner credential scope (`ic/src/channels/wasm/wrapper.rs` `resolve_message_scope`), so tools like
  `web_search` resolve secrets over WeeChat. See `docs/bugs/WEECHAT-NO-SECRET-ACCESS.md`.
- **Full extensive pre-release test still needed** — see `docs/ops/PRE-RELEASE-TESTING.md`.
- **Nanocode worker config not auto-generated** — `mt-admin` should emit `config.toml` + env with
  the WSS port and external-worker auth token. See `docs/bugs/MISSING-CONFIG-FOR-NANOCODE.md`.
