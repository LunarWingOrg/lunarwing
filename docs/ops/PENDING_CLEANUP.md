# cleanup

> **Reconciled 2026-06-07.** Forward-looking cleanup list; most items are version-targeted in
> `RELEASE-v1.1.1.md` (Telegram → v1.1.6; Google/Gmail → v1.1.4; WeeChat/gotify renames → v1.1.5).
> Slack/Discord/WhatsApp/Feishu channels are already removed.

## Proprietary channels

* Telegram
* Slack (Removed)
* Discord (Removed)
* WhatsApp (Removed)
* Feishu (Removed)
  
## Proprietary Extensions

* gmail
* google stuff

## Remove unused dir:

* customic (done)

## Rename ironclaw references in nanocode bridge:

> **Conflict (2026-06-07):** root `CLAUDE.md` currently lists the `ironclaw-agent-v1` WebSocket
> subprotocol as **intentionally NOT renamed** (shared external protocol). Reconcile project intent
> before acting — if the rename is wanted it's a coordinated breaking change across the bridge and
> `ic/src/orchestrator/external_worker.rs`, and CLAUDE.md must be updated to match.

* WebSocket subprotocol still logs `ironclaw-agent-v1` — rename to `lunarwing-agent-v1`
* Bridge scripts in `lunarcode4lunarwing/scripts/` reference the old subprotocol name
* Coordinate with `ic/src/orchestrator/external_worker.rs` which expects the subprotocol string to match
* **Note:** The subprotocol rename needs to happen on both sides simultaneously — the bridge (`lunarcode4lunarwing/scripts/`) and the daemon (`ic/src/orchestrator/external_worker.rs`) must agree on the string, so it's a coordinated change

## Rename ironclaw_weechat_ws to lunarwing_weechat_ws

## Rename ironclaw-gotify-tool to lunarwing_gotify_tool if necessary

##### Notes:

1. can keep github for now but its not a great extension tbh. can eventually replace with my custom git tool that should be an added feature in 1.0.8+
