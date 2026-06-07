# BUG: Unbounded mpsc recv() in spawned notification tasks

> **STATUS: OPEN (confirmed 2026-06-07)** — the two `ic/src/agent/agent_loop.rs` forwarders remain (now ~lines 613 and 741). The third site (`channels/relay/channel.rs`) no longer exists — the relay subsystem was removed in v1.1.1.

## Severity: MEDIUM

## Description

Several spawned background tasks use `while let Some(response) = notify_rx.recv().await` on mpsc channels with no timeout, exit condition, or poll ceiling. If the sending side is dropped without closing the channel cleanly, the receiving task hangs indefinitely, leaking a tokio task slot.

## Affected locations

### 1. Heartbeat notification forwarder
**File:** `ic/src/agent/agent_loop.rs` (~lines 602-629)

```rust
tokio::spawn(async move {
    while let Some(response) = notify_rx.recv().await {
        // broadcasts to channels...
    }
});
```

### 2. Routine engine notification forwarder
**File:** `ic/src/agent/agent_loop.rs` (~lines 689-717)

```rust
tokio::spawn(async move {
    while let Some(response) = notify_rx.recv().await {
        // broadcasts to channels...
    }
});
```

### 3. Relay channel webhook event reader
**File:** `ic/src/channels/relay/channel.rs` (~line 157)

```rust
tokio::spawn(async move {
    while let Some(event) = event_rx.recv().await {
        // process webhook events...
    }
});
```

## Impact

These are background tasks so they don't block the main agent loop directly. However:
- If senders are dropped without closing, the tasks hang forever consuming a tokio task slot
- Over time, if the agent loop restarts and re-spawns these, zombie tasks accumulate
- The relay channel task could hang if the external relay service drops the connection without closing the channel

## Proposed fix options

**Option A (simple):** Add a `tokio::select!` with a periodic liveness check — if no message arrives for N minutes, log and break.

**Option B (structural):** Use `tokio::sync::broadcast` instead of `mpsc` — broadcast channels return `RecvError::Closed` when all senders drop, guaranteeing the receiver exits.

**Option C (defensive):** Add a poll ceiling (e.g., max 100k iterations) as a safety valve, similar to what was done for scheduler cleanup loops.

## Filed

2026-05-08 by Ruffles
