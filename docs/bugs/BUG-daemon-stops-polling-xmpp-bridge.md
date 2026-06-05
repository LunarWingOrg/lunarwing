# BUG: Daemon stops polling XMPP bridge for messages

**Severity:** High
**Found:** 2026-05-08 during v1.0.2 pre-release testing
**Status:** Open
**Affects:** Multi-tenant deployments with XMPP/OMEMO

## Symptoms

1. XMPP bridge is running and healthy (OMEMO enabled, bundle published, prekeys available)
2. Messages from user arrive at bridge and are queued (`queued_messages` > 0, `current_cursor` advances)
3. Main daemon process is alive (PID exists, process running)
4. Daemon never consumes queued messages — no responses sent back via XMPP
5. Restarting the daemon restores message consumption

## Reproduction

1. Deploy two tenants (noko, ono) via `lunarwing-mt-admin.sh`
2. Start both tenants — XMPP/OMEMO works initially
3. After some time or after a service restart, the daemon stops polling the bridge
4. Bridge `/v1/status` shows `queued_messages` accumulating
5. Bridge `/v1/messages?cursor=0` shows messages sitting undelivered
6. Both tenants affected independently — not caused by subagent/worker container usage (ono never ran a worker container)

## Evidence

**noko bridge status** (healthy):
```json
{
  "configured": true,
  "running": true,
  "current_cursor": 6,
  "queued_messages": 6,
  "omemo_enabled": true,
  "bundle_published": true,
  "prekeys_available": 99,
  "last_omemo_error": null
}
```

**ono bridge status** (healthy, same issue):
```json
{
  "configured": true,
  "running": true,
  "current_cursor": 5,
  "queued_messages": 5,
  "omemo_enabled": true,
  "bundle_published": true,
  "prekeys_available": 99,
  "last_omemo_error": null
}
```

Both daemons alive (`ps aux` confirmed), both bridges alive, zero messages consumed.

## Additional Observation: OMEMO Warmup After Restart

First 3 messages after bridge restart show OMEMO decryption failure (fallback plaintext: "I sent you an OMEMO encrypted message but your client doesn't seem to support that"). Subsequent messages decrypted fine. This is separate from the polling bug but compounds the issue — restarting the daemon to fix polling also restarts the bridge, which then requires OMEMO warmup again.

## Likely Cause

The XMPP WASM channel inside the daemon has a polling loop that fetches messages from the bridge via `GET /v1/messages?cursor=N`. This loop is either:

1. **Crashed silently** — the polling task panicked or errored without restarting
2. **Blocked on something** — the polling task is awaiting something that will never resolve (e.g., a channel send to a full/closed channel)
3. **Never started** — the WASM channel failed to initialize after a restart but the daemon continued without it

Key areas to investigate:
- `ic/channels-src/xmpp/` — WASM channel polling loop
- `ic/src/channels/wasm/runtime.rs` — WASM channel execution runtime
- `ic/src/channels/wasm/wrapper.rs` — Channel trait wrapper, message forwarding
- `ic/src/channels/manager.rs` — ChannelManager stream merging — does it detect a dead channel?

## Proposed Fix

1. **Add health monitoring to WASM channel polling** — if the XMPP channel hasn't produced a message or heartbeat in N seconds, log a warning and restart the polling loop
2. **Expose channel health in gateway status endpoint** — include per-channel last-poll timestamp so operators can detect stalled channels
3. **Auto-recover dead polling loops** — if the WASM channel task exits, the ChannelManager should detect it and respawn

## Why the Existing Watchdog Doesn't Help

The systemd watchdog (`scripts/lunarwing-watchdog.sh`) only checks `systemctl is-active` — it restarts the process if it crashes. In this bug, the daemon process is alive and running; only the XMPP polling loop inside it has stalled. The watchdog sees "active" and does nothing.

## Proposed Fix

### Option A: Extend external watchdog (quick win)
Add a bridge queue depth check to the watchdog script. Poll the bridge's `/v1/status` endpoint and compare `queued_messages` across two consecutive runs. If the queue is growing and the daemon isn't consuming, restart the service. This can be deployed without code changes to the daemon.

### Option B: Internal WASM channel supervision (proper fix)
Add supervision to the WASM channel polling task inside the daemon. If the XMPP channel's polling loop exits or hasn't produced a message/heartbeat in N seconds, the ChannelManager should detect it and respawn the task automatically. Key files:
- `ic/channels-src/xmpp/` — WASM channel polling loop
- `ic/src/channels/wasm/runtime.rs` — WASM channel execution runtime
- `ic/src/channels/manager.rs` — ChannelManager stream merging

### Option C: Expose channel health in gateway (observability)
Add per-channel last-poll timestamp to the gateway status endpoint so operators and monitoring tools can detect stalled channels before users notice.

All three options are complementary and should ideally all be implemented.

## Workaround

Restart the affected tenant:

```bash
sudo env PATH="$PATH" scripts/lunarwing-mt-admin.sh restart-tenant <name>
```

Note: this also restarts the bridge, triggering OMEMO warmup (first 3-5 messages may fail to decrypt).
