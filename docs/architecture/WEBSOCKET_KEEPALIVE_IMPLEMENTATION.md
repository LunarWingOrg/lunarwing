● Here's a summary of everything implemented:

  Settings layer (settings.rs, config/channels.rs):
  - Added default_ws_ping_interval() (30s) and default_ws_idle_timeout() (120s) functions
  - Wired them through GatewayConfig → GatewayState, configurable via env vars WS_PING_INTERVAL_SECS and WS_IDLE_TIMEOUT_SECS

  Enhanced WsConnectionTracker (ws.rs):
  - Replaced simple AtomicU64 counter with per-connection HashMap<Uuid, Instant> tracking
  - New API: register_connection(), unregister_connection(), update_activity(), cleanup_stale()
  - Lock-poison-safe via unwrap_or_else(|e| e.into_inner())

  Server-side ping (ws.rs sender task):
  - Added tokio::time::interval branch to the sender's select! loop
  - Sends Message::Ping at ws_ping_interval_secs intervals
  - Browsers auto-respond with Pong, keeping the idle timer alive

  Idle timeout (ws.rs receiver loop):
  - Wrapped ws_stream.next() in tokio::time::timeout(idle_timeout, ...)
  - Any received frame (including Pong) resets the timer via update_activity()
  - Dead connections are closed after ws_idle_timeout_secs of silence

  Background cleanup (server.rs):
  - 60-second sweeper task spawned in start_server()
  - Removes leaked tracker entries older than ws_idle_timeout_secs — safety net for panicked handlers

  Tests: 13 tests passing (7 new tracker tests + 6 existing handler tests). Zero clippy warnings. All 177 web module tests pass.
