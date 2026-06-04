# cleanup

## Remove cruft

### dont need these:

* Telegram
* Slack
* Discord (Removed)
* WhatsApp (Removed)
* Feishu (Removed)
  
### dont need these:

* gmail
* google stuff

### Remove unused dir:

* customic (done)

### Rename ironclaw references in nanocode bridge:

* WebSocket subprotocol still logs `ironclaw-agent-v1` — rename to `lunarwing-agent-v1`
* Bridge scripts in `lunarcode4lunarwing/scripts/` reference the old subprotocol name
* Coordinate with `ic/src/orchestrator/external_worker.rs` which expects the subprotocol string to match
* **Note:** The subprotocol rename needs to happen on both sides simultaneously — the bridge (`lunarcode4lunarwing/scripts/`) and the daemon (`ic/src/orchestrator/external_worker.rs`) must agree on the string, so it's a coordinated change

##### Notes:

1. can keep github for now but its not a great extension tbh. can eventually replace with my custom git tool that should be an added feature in 1.0.8+
