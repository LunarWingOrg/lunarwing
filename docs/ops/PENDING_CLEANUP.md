# Pending Cleanup

> **Reconciled 2026-06-08.** Forward-looking cleanup list; the version targets below come from
> the deferred-items roadmap in `RELEASE-v1.1.1.md`. Slack/Discord/WhatsApp/Feishu channels and
> the gmail/google-calendar tool sources are already removed.

## Proprietary channels

| Channel | Status |
|---------|--------|
| Slack | Removed |
| Discord | Removed |
| WhatsApp | Removed |
| Feishu | Removed |
| Telegram | Present — removal targeted **v1.1.9** (still in `channels-src/` + `tools-src/`) |

## Proprietary extensions (Google) — targeted v1.1.2

The `gmail` and `google-calendar` **tool sources are removed** (no `tools-src/` dirs, no registry
catalog entries under `ic/registry/`). The remaining cleanup is residual google references in the
codebase:

- Google OAuth/provider plumbing (`ic/src/config/oauth.rs`, `ic/src/bridge/auth_manager.rs`)
- Web UI OAuth elements (`ic/src/channels/web/`)
- A `google` bundle in registry test fixtures (`ic/src/registry/manifest.rs` `test_parse_bundles`)

## Remove unused dir

- `customic` — done.

## Rename ironclaw references in nanocode bridge

> **Conflict (2026-06-07):** root `CLAUDE.md` lists the `ironclaw-agent-v1` WebSocket subprotocol
> as **intentionally NOT renamed** (shared external protocol). Reconcile project intent before
> acting — a rename is a coordinated breaking change across the bridge
> (`lunarcode4lunarwing/scripts/`) and `ic/src/orchestrator/external_worker.rs` (which expects the
> subprotocol string to match), and `CLAUDE.md` must be updated to match.

## Other source renames

- `ironclaw_weechat_wss` → `lunarwing_weechat_wss` (channel + adapter source) — targeted **v1.1.7**
  (`docs/proposals/RENAME_IRONCLAW_WEECHAT_WS_CHANNEL_AND_ADAPTER`).
- `ironclaw-gotify-tool` → `lunarwing_gotify_tool` if needed (low priority).

## Notes

- The GitHub tool can stay for now; a removal decision is targeted **v1.1.9**, and it may be
  replaced by the custom Git WASM tool (targeted v1.1.8).
