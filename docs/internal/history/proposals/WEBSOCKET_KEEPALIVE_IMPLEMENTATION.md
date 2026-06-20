# WebSocket Keepalive Implementation Plan

## Status

| Item | Status |
|------|--------|
| Settings (`ws_ping_interval_secs`, `ws_idle_timeout_secs`) | **Done** — `settings.rs` + `GatewayConfig` + `GatewayState` |
| Proposal document | **Done** — this file |
| `WsConnectionTracker` enhancement | **Done** — per-connection activity tracking via `register/unregister/update_activity/cleanup_stale` |
| Server-side ping | **Done** — sender task sends `Message::Ping` at configurable interval |
| Receiver loop idle timeout | **Done** — `tokio::time::timeout` closes idle connections |
| Background cleanup task | **Done** — 60s sweeper in `start_server()` removes leaked tracker entries |
| Unit tests for stale detection | **Done** — 7 tracker tests + 6 message handler tests |

## Problem
Current WebSocket implementation relies entirely on client-initiated ping/pong. If a client goes silent (network partition, browser tab suspended, mobile app backgrounded), the server holds onto dead connections indefinitely, consuming resources and potentially hitting connection limits.

## Current State (Actual Code)

### ws.rs
- **`WsConnectionTracker`**: Simple `AtomicU64` counter with `increment()`, `decrement()`, `connection_count()`. No per-connection tracking.
- **`handle_ws_connection`**: Uses `tokio::select!` with a sender task (forwards broadcast events + direct messages) and a receiver loop (reads client frames). Splits socket into sender/receiver halves.
- **`handle_client_message`**: Takes `(msg, state, user_id, direct_tx)` — routes Ping, Message, Approval, Chat messages.
- **Existing tests**: Cover tracker increment/decrement, Ping/Pong round-trip, message routing, approval handling.

### sse.rs
- Has `KeepAlive` with 30-second interval for SSE connections — good reference pattern.

### settings.rs
- `ws_ping_interval_secs` (default: 30) — **added, not yet consumed**
- `ws_idle_timeout_secs` (default: 120) — **added, not yet consumed**
- `session_idle_timeout_secs` (default: 7 days) — existing, unrelated

### server.rs
- `GatewayState` holds `ws_tracker: Option<WsConnectionTracker>` — currently just a counter
- `start_server` spawns the axum server but no background cleanup task

## Solution

### 1. Enhance WsConnectionTracker (remaining)
**File**: `ic/src/channels/web/ws.rs`

Add per-connection activity tracking alongside the existing counter:
```rust
pub struct WsConnectionTracker {
    count: AtomicU64,
    // NEW: per-connection last-activity timestamps
    connections: Arc<RwLock<HashMap<Uuid, Instant>>>,
}
```

New methods:
- `register_connection() -> Uuid` — increments counter + inserts into map
- `update_activity(conn_id: Uuid)` — updates Instant::now()
- `unregister_connection(conn_id: Uuid)` — decrements counter + removes from map
- `cleanup_stale_connections(timeout: Duration) -> Vec<Uuid>` — removes entries older than timeout

Existing `increment()`/`decrement()`/`connection_count()` should be preserved or aliased for backward compatibility.

### 2. Add Idle Timeout to Receiver Loop (remaining)
**File**: `ic/src/channels/web/ws.rs`

The current `handle_ws_connection` uses `tokio::select!` with a sender and receiver. The receiver loop needs:
- Track `last_activity: Instant` updated on every received frame
- Add a `tokio::time::sleep(idle_timeout)` branch to the `select!` that closes the connection
- Register/unregister with the enhanced tracker

### 3. Server-Side Ping (remaining)
**File**: `ic/src/channels/web/ws.rs`

The sender task currently forwards broadcast events and direct messages. Add:
- A `tokio::time::interval(ping_interval)` branch that sends `Message::Ping` frames
- This is simpler than the original proposal's separate keepalive task

### 4. Background Cleanup Task (remaining)
**File**: `ic/src/channels/web/server.rs`

In `start_server`, after spawning the axum server, spawn a cleanup loop:
```rust
tokio::spawn(async move {
    let mut interval = tokio::time::interval(Duration::from_secs(60));
    loop {
        interval.tick().await;
        let stale = tracker.cleanup_stale_connections(idle_timeout).await;
        if !stale.is_empty() {
            tracing::info!(count = stale.len(), "Cleaned up stale WebSocket connections");
        }
    }
});
```

### 5. Unit Tests (remaining)
**File**: `ic/src/channels/web/ws.rs`

Add to the existing `#[cfg(test)] mod tests`:
- `test_tracker_register_unregister` — register returns Uuid, count increments/decrements
- `test_tracker_update_activity` — activity updates don't affect count
- `test_tracker_cleanup_stale` — connections idle > timeout are removed
- `test_tracker_no_cleanup_active` — recently active connections survive cleanup
- `test_tracker_multiple_connections` — mixed stale/active cleanup

## Configuration

```toml
[settings]
ws_ping_interval_secs = 30    # already in settings.rs
ws_idle_timeout_secs = 120    # already in settings.rs
```

## Migration Notes
- Default values maintain backward compatibility
- Existing clients that don't respond to pings will be disconnected after `idle_timeout`
- This is the desired behavior to prevent resource exhaustion
- The existing `increment()`/`decrement()` API must remain functional during transition

## Build Requirements
- Requires a machine with `cargo` and the full Rust toolchain
- This machine (Kestrel's perch) does not have `cargo` installed
- Recommended: build on Pebble or Nanocode instance
- Target branch: `1.1.1-111-oof-june5staging-improvements-kestrel-local-1`

## Future Enhancements
- Expose connection metrics via `/api/metrics` endpoint
- Add graceful shutdown with close frames
- Implement connection pooling for reconnection scenarios
