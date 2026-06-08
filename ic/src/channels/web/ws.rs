//! WebSocket handler for bidirectional client communication.
//!
//! Provides the same event stream as SSE but also accepts incoming messages
//! (chat, approvals) over a single persistent connection.
//!
//! ```text
//! Client ──── WS frame: {"type":"message","content":"hello"} ──► Agent Loop
//!        ◄─── WS frame: {"type":"event","event_type":"response","data":{...}} ── Broadcast
//!        ──── WS frame: {"type":"ping"} ──────────────────────────────────────►
//!        ◄─── WS frame: {"type":"pong"} ──────────────────────────────────────
//! ```

use std::collections::HashMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

use axum::extract::ws::{Message, WebSocket};
use futures::{SinkExt, StreamExt};
use tokio::sync::mpsc;
use uuid::Uuid;

use crate::agent::submission::Submission;
use crate::channels::IncomingMessage;
use crate::channels::web::server::GatewayState;
use crate::channels::web::types::{WsClientMessage, WsServerMessage};

/// Tracks active WebSocket connections with per-connection activity timestamps.
pub struct WsConnectionTracker {
    count: AtomicU64,
    connections: std::sync::RwLock<HashMap<Uuid, Instant>>,
}

impl WsConnectionTracker {
    pub fn new() -> Self {
        Self {
            count: AtomicU64::new(0),
            connections: std::sync::RwLock::new(HashMap::new()),
        }
    }

    pub fn connection_count(&self) -> u64 {
        self.count.load(Ordering::Relaxed)
    }

    /// Register a new connection. Returns the assigned connection ID.
    pub fn register_connection(&self) -> Uuid {
        let id = Uuid::new_v4();
        self.count.fetch_add(1, Ordering::Relaxed);
        let mut map = self.connections.write().unwrap_or_else(|e| e.into_inner());
        map.insert(id, Instant::now());
        id
    }

    /// Remove a connection from tracking.
    pub fn unregister_connection(&self, conn_id: &Uuid) {
        let mut map = self.connections.write().unwrap_or_else(|e| e.into_inner());
        if map.remove(conn_id).is_some() {
            self.count.fetch_sub(1, Ordering::Relaxed);
        }
    }

    /// Record activity for a connection (called on every received frame).
    pub fn update_activity(&self, conn_id: &Uuid) {
        let mut map = self.connections.write().unwrap_or_else(|e| e.into_inner());
        if let Some(instant) = map.get_mut(conn_id) {
            *instant = Instant::now();
        }
    }

    /// Remove tracker entries idle longer than `timeout`. Returns the number removed.
    ///
    /// This is a safety net for leaked entries — the per-connection idle timeout
    /// in `handle_ws_connection` is the primary disconnect mechanism.
    pub fn cleanup_stale(&self, timeout: Duration) -> usize {
        let cutoff = Instant::now() - timeout;
        let mut map = self.connections.write().unwrap_or_else(|e| e.into_inner());
        let before = map.len();
        map.retain(|_, last_activity| *last_activity > cutoff);
        let removed = before - map.len();
        if removed > 0 {
            self.count.fetch_sub(removed as u64, Ordering::Relaxed);
        }
        removed
    }
}

impl Default for WsConnectionTracker {
    fn default() -> Self {
        Self::new()
    }
}

/// Handle an upgraded WebSocket connection.
///
/// Spawns two tasks:
/// - **sender**: forwards broadcast events to the WebSocket client and sends
///   periodic protocol-level ping frames
/// - **receiver**: reads client frames and routes them to the agent, with an
///   idle timeout that closes silent connections
///
/// When either task ends (client disconnect or broadcast closed), both are
/// cleaned up.
pub async fn handle_ws_connection(
    socket: WebSocket,
    state: Arc<GatewayState>,
    user: crate::channels::web::auth::UserIdentity,
) {
    let (mut ws_sink, mut ws_stream) = socket.split();

    // Register connection with tracker
    let conn_id = state.ws_tracker.as_ref().map(|t| t.register_connection());

    // Subscribe to broadcast events (same source as SSE), scoped to this user.
    // Reject if we've hit the connection limit.
    let Some(raw_stream) = state.sse.subscribe_raw(Some(user.user_id.clone())) else {
        tracing::warn!("WebSocket rejected: too many connections");
        if let (Some(tracker), Some(id)) = (&state.ws_tracker, conn_id) {
            tracker.unregister_connection(&id);
        }
        return;
    };
    let mut event_stream = Box::pin(raw_stream);

    // Channel for the sender task to receive messages from both
    // the broadcast stream and any direct sends (like Pong)
    let (direct_tx, mut direct_rx) = mpsc::channel::<WsServerMessage>(64);

    let ping_interval_secs = state.ws_ping_interval_secs;

    // Sender task: forward broadcast events + direct messages to WS client,
    // and send periodic protocol-level pings to detect dead connections.
    let sender_handle = tokio::spawn(async move {
        let mut ping_interval =
            tokio::time::interval(Duration::from_secs(ping_interval_secs.max(1)));
        ping_interval.tick().await; // consume the immediate first tick
        loop {
            let ws_msg = tokio::select! {
                event = event_stream.next() => {
                    match event {
                        Some(sse_event) => {
                            let msg = WsServerMessage::from_sse_event(&sse_event);
                            match serde_json::to_string(&msg) {
                                Ok(json) => Message::Text(json.into()),
                                Err(_) => continue,
                            }
                        }
                        None => break,
                    }
                }
                direct = direct_rx.recv() => {
                    match direct {
                        Some(msg) => {
                            match serde_json::to_string(&msg) {
                                Ok(json) => Message::Text(json.into()),
                                Err(_) => continue,
                            }
                        }
                        None => break,
                    }
                }
                _ = ping_interval.tick() => {
                    Message::Ping(Vec::new().into())
                }
            };

            if ws_sink.send(ws_msg).await.is_err() {
                break; // Client disconnected
            }
        }
    });

    // Receiver task: read client frames and route to agent.
    // Uses tokio::time::timeout so connections idle longer than the configured
    // threshold are closed (the server-side pings trigger client pongs, so a
    // healthy client will always reset this timer).
    let user_id = user.user_id;
    let idle_timeout = Duration::from_secs(if state.ws_idle_timeout_secs > 0 {
        state.ws_idle_timeout_secs
    } else {
        86400 // 24h fallback if set to 0
    });

    loop {
        let frame = match tokio::time::timeout(idle_timeout, ws_stream.next()).await {
            Ok(Some(Ok(frame))) => frame,
            Ok(Some(Err(_))) | Ok(None) => break,
            Err(_) => {
                tracing::debug!("WebSocket idle timeout, closing connection");
                break;
            }
        };

        // Any received frame (including Pong responses) counts as activity.
        if let (Some(tracker), Some(id)) = (&state.ws_tracker, &conn_id) {
            tracker.update_activity(id);
        }

        match frame {
            Message::Text(text) => {
                let parsed: Result<WsClientMessage, _> = serde_json::from_str(&text);
                match parsed {
                    Ok(client_msg) => {
                        handle_client_message(client_msg, &state, &user_id, &direct_tx).await;
                    }
                    Err(e) => {
                        let _ = direct_tx
                            .send(WsServerMessage::Error {
                                message: format!("Invalid message: {}", e),
                            })
                            .await;
                    }
                }
            }
            Message::Close(_) => break,
            // Pong, Ping, Binary — activity already tracked above
            _ => {}
        }
    }

    // Clean up: abort sender, unregister from tracker
    sender_handle.abort();
    if let (Some(tracker), Some(id)) = (&state.ws_tracker, conn_id) {
        tracker.unregister_connection(&id);
    }
}

/// Route a parsed client message to the appropriate handler.
async fn handle_client_message(
    msg: WsClientMessage,
    state: &GatewayState,
    user_id: &str,
    direct_tx: &mpsc::Sender<WsServerMessage>,
) {
    match msg {
        WsClientMessage::Message {
            content,
            thread_id,
            timezone,
            images,
        } => {
            let mut incoming = IncomingMessage::new("gateway", user_id, &content);
            if let Some(ref tz) = timezone {
                incoming = incoming.with_timezone(tz);
            }
            if let Some(ref tid) = thread_id {
                incoming = incoming.with_thread(tid);
            }

            // Convert uploaded images to IncomingAttachments
            if !images.is_empty() {
                let attachments = crate::channels::web::server::images_to_attachments(&images);
                incoming = incoming.with_attachments(attachments);
            }

            // Clone sender to avoid holding RwLock read guard across send().await
            let tx = {
                let tx_guard = state.msg_tx.read().await;
                tx_guard.as_ref().cloned()
            };
            if let Some(tx) = tx {
                if tx.send(incoming).await.is_err() {
                    let _ = direct_tx
                        .send(WsServerMessage::Error {
                            message: "Channel closed".to_string(),
                        })
                        .await;
                }
            } else {
                let _ = direct_tx
                    .send(WsServerMessage::Error {
                        message: "Channel not started".to_string(),
                    })
                    .await;
            }
        }
        WsClientMessage::Approval {
            request_id,
            action,
            thread_id,
        } => {
            let (approved, always) = match action.as_str() {
                "approve" => (true, false),
                "always" => (true, true),
                "deny" => (false, false),
                other => {
                    let _ = direct_tx
                        .send(WsServerMessage::Error {
                            message: format!("Unknown approval action: {}", other),
                        })
                        .await;
                    return;
                }
            };

            let request_uuid = match Uuid::parse_str(&request_id) {
                Ok(id) => id,
                Err(_) => {
                    let _ = direct_tx
                        .send(WsServerMessage::Error {
                            message: "Invalid request_id (expected UUID)".to_string(),
                        })
                        .await;
                    return;
                }
            };

            let approval = Submission::ExecApproval {
                request_id: request_uuid,
                approved,
                always,
            };
            let content = match serde_json::to_string(&approval) {
                Ok(c) => c,
                Err(e) => {
                    let _ = direct_tx
                        .send(WsServerMessage::Error {
                            message: format!("Failed to serialize approval: {}", e),
                        })
                        .await;
                    return;
                }
            };

            let mut msg = IncomingMessage::new("gateway", user_id, content);
            if let Some(ref tid) = thread_id {
                msg = msg.with_thread(tid);
            }
            // Clone sender to avoid holding RwLock read guard across send().await
            let tx = {
                let tx_guard = state.msg_tx.read().await;
                tx_guard.as_ref().cloned()
            };
            if let Some(tx) = tx {
                let _ = tx.send(msg).await;
            }
        }
        WsClientMessage::AuthToken {
            extension_name,
            token,
        } => {
            if let Some(ref ext_mgr) = state.extension_manager {
                match ext_mgr
                    .configure_token(&extension_name, &token, user_id)
                    .await
                {
                    Ok(result) => {
                        if result.verification.is_some() {
                            state.sse.broadcast_for_user(
                                user_id,
                                crate::channels::web::types::SseEvent::AuthRequired {
                                    extension_name: extension_name.clone(),
                                    instructions: Some(result.message),
                                    auth_url: None,
                                    setup_url: None,
                                },
                            );
                        } else {
                            crate::channels::web::server::clear_auth_mode(state, user_id).await;
                            state.sse.broadcast_for_user(
                                user_id,
                                crate::channels::web::types::SseEvent::AuthCompleted {
                                    extension_name,
                                    success: true,
                                    message: result.message,
                                },
                            );
                        }
                    }
                    Err(e) => {
                        let msg = format!("Auth failed: {}", e);
                        if matches!(e, crate::extensions::ExtensionError::ValidationFailed(_)) {
                            state.sse.broadcast_for_user(
                                user_id,
                                crate::channels::web::types::SseEvent::AuthRequired {
                                    extension_name: extension_name.clone(),
                                    instructions: Some(msg.clone()),
                                    auth_url: None,
                                    setup_url: None,
                                },
                            );
                        }
                        let _ = direct_tx
                            .send(WsServerMessage::Error { message: msg })
                            .await;
                    }
                }
            } else {
                let _ = direct_tx
                    .send(WsServerMessage::Error {
                        message: "Extension manager not available".to_string(),
                    })
                    .await;
            }
        }
        WsClientMessage::AuthCancel { .. } => {
            crate::channels::web::server::clear_auth_mode(state, user_id).await;
        }
        WsClientMessage::Ping => {
            let _ = direct_tx.send(WsServerMessage::Pong).await;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // --- WsConnectionTracker tests ---

    #[test]
    fn test_tracker_register_unregister() {
        let tracker = WsConnectionTracker::new();
        assert_eq!(tracker.connection_count(), 0);

        let id1 = tracker.register_connection();
        assert_eq!(tracker.connection_count(), 1);

        let id2 = tracker.register_connection();
        assert_eq!(tracker.connection_count(), 2);

        tracker.unregister_connection(&id1);
        assert_eq!(tracker.connection_count(), 1);

        tracker.unregister_connection(&id2);
        assert_eq!(tracker.connection_count(), 0);
    }

    #[test]
    fn test_tracker_default() {
        let tracker = WsConnectionTracker::default();
        assert_eq!(tracker.connection_count(), 0);
    }

    #[test]
    fn test_tracker_unregister_idempotent() {
        let tracker = WsConnectionTracker::new();
        let id = tracker.register_connection();
        assert_eq!(tracker.connection_count(), 1);

        tracker.unregister_connection(&id);
        assert_eq!(tracker.connection_count(), 0);

        // Second unregister should be a no-op
        tracker.unregister_connection(&id);
        assert_eq!(tracker.connection_count(), 0);
    }

    #[test]
    fn test_tracker_update_activity() {
        let tracker = WsConnectionTracker::new();
        let id = tracker.register_connection();

        // update_activity should not affect count
        tracker.update_activity(&id);
        assert_eq!(tracker.connection_count(), 1);

        // update_activity with unknown ID should be a no-op
        let unknown = Uuid::new_v4();
        tracker.update_activity(&unknown);
        assert_eq!(tracker.connection_count(), 1);

        tracker.unregister_connection(&id);
        assert_eq!(tracker.connection_count(), 0);
    }

    #[test]
    fn test_tracker_cleanup_stale() {
        let tracker = WsConnectionTracker::new();
        let id1 = tracker.register_connection();
        let _id2 = tracker.register_connection();
        assert_eq!(tracker.connection_count(), 2);

        // Backdate id1's activity to make it stale
        {
            let mut map = tracker.connections.write().unwrap();
            map.insert(id1, Instant::now() - Duration::from_secs(200));
        }

        let removed = tracker.cleanup_stale(Duration::from_secs(120));
        assert_eq!(removed, 1);
        assert_eq!(tracker.connection_count(), 1);
    }

    #[test]
    fn test_tracker_cleanup_no_stale() {
        let tracker = WsConnectionTracker::new();
        let _id1 = tracker.register_connection();
        let _id2 = tracker.register_connection();

        let removed = tracker.cleanup_stale(Duration::from_secs(120));
        assert_eq!(removed, 0);
        assert_eq!(tracker.connection_count(), 2);
    }

    #[test]
    fn test_tracker_cleanup_mixed() {
        let tracker = WsConnectionTracker::new();
        let stale1 = tracker.register_connection();
        let _active = tracker.register_connection();
        let stale2 = tracker.register_connection();
        assert_eq!(tracker.connection_count(), 3);

        // Backdate two connections
        {
            let mut map = tracker.connections.write().unwrap();
            let old = Instant::now() - Duration::from_secs(300);
            map.insert(stale1, old);
            map.insert(stale2, old);
        }

        let removed = tracker.cleanup_stale(Duration::from_secs(120));
        assert_eq!(removed, 2);
        assert_eq!(tracker.connection_count(), 1);
    }

    // --- Message handler tests ---

    #[tokio::test]
    async fn test_handle_client_message_ping() {
        // Ping should produce a Pong on the direct channel
        let (direct_tx, mut direct_rx) = mpsc::channel(16);
        let state = make_test_state(None).await;

        handle_client_message(WsClientMessage::Ping, &state, "user1", &direct_tx).await;

        let response = direct_rx.recv().await.unwrap();
        assert!(matches!(response, WsServerMessage::Pong));
    }

    #[tokio::test]
    async fn test_handle_client_message_sends_to_agent() {
        // A Message should be forwarded to the agent's msg_tx
        let (agent_tx, mut agent_rx) = mpsc::channel(16);
        let state = make_test_state(Some(agent_tx)).await;
        let (direct_tx, _direct_rx) = mpsc::channel(16);

        handle_client_message(
            WsClientMessage::Message {
                content: "hello agent".to_string(),
                thread_id: Some("t1".to_string()),
                timezone: None,
                images: Vec::new(),
            },
            &state,
            "user1",
            &direct_tx,
        )
        .await;

        let incoming = agent_rx.recv().await.unwrap();
        assert_eq!(incoming.content, "hello agent");
        assert_eq!(incoming.thread_id.as_deref(), Some("t1"));
        assert_eq!(incoming.channel, "gateway");
        assert_eq!(incoming.user_id, "user1");
    }

    #[tokio::test]
    async fn test_handle_client_message_no_channel() {
        // When msg_tx is None, should send an error back
        let state = make_test_state(None).await;
        let (direct_tx, mut direct_rx) = mpsc::channel(16);

        handle_client_message(
            WsClientMessage::Message {
                content: "hello".to_string(),
                thread_id: None,
                timezone: None,
                images: Vec::new(),
            },
            &state,
            "user1",
            &direct_tx,
        )
        .await;

        let response = direct_rx.recv().await.unwrap();
        match response {
            WsServerMessage::Error { message } => {
                assert!(message.contains("not started"));
            }
            _ => panic!("Expected Error variant"),
        }
    }

    #[tokio::test]
    async fn test_handle_client_approval_approve() {
        let (agent_tx, mut agent_rx) = mpsc::channel(16);
        let state = make_test_state(Some(agent_tx)).await;
        let (direct_tx, _direct_rx) = mpsc::channel(16);

        let request_id = Uuid::new_v4();
        handle_client_message(
            WsClientMessage::Approval {
                request_id: request_id.to_string(),
                action: "approve".to_string(),
                thread_id: Some("thread-42".to_string()),
            },
            &state,
            "user1",
            &direct_tx,
        )
        .await;

        let incoming = agent_rx.recv().await.unwrap();
        // The content should be a serialized ExecApproval
        assert!(incoming.content.contains("ExecApproval"));
        // Thread should be forwarded onto the IncomingMessage.
        assert_eq!(incoming.thread_id.as_deref(), Some("thread-42"));
    }

    #[tokio::test]
    async fn test_handle_client_approval_invalid_action() {
        let state = make_test_state(None).await;
        let (direct_tx, mut direct_rx) = mpsc::channel(16);

        handle_client_message(
            WsClientMessage::Approval {
                request_id: Uuid::new_v4().to_string(),
                action: "maybe".to_string(),
                thread_id: None,
            },
            &state,
            "user1",
            &direct_tx,
        )
        .await;

        let response = direct_rx.recv().await.unwrap();
        match response {
            WsServerMessage::Error { message } => {
                assert!(message.contains("Unknown approval action"));
            }
            _ => panic!("Expected Error variant"),
        }
    }

    #[tokio::test]
    async fn test_handle_client_approval_invalid_uuid() {
        let state = make_test_state(None).await;
        let (direct_tx, mut direct_rx) = mpsc::channel(16);

        handle_client_message(
            WsClientMessage::Approval {
                request_id: "not-a-uuid".to_string(),
                action: "approve".to_string(),
                thread_id: None,
            },
            &state,
            "user1",
            &direct_tx,
        )
        .await;

        let response = direct_rx.recv().await.unwrap();
        match response {
            WsServerMessage::Error { message } => {
                assert!(message.contains("Invalid request_id"));
            }
            _ => panic!("Expected Error variant"),
        }
    }

    /// Helper to create a GatewayState for testing.
    async fn make_test_state(msg_tx: Option<mpsc::Sender<IncomingMessage>>) -> GatewayState {
        use crate::channels::web::sse::SseManager;

        GatewayState {
            msg_tx: tokio::sync::RwLock::new(msg_tx),
            sse: Arc::new(SseManager::new()),
            workspace: None,
            workspace_pool: None,
            session_manager: None,
            log_broadcaster: None,
            log_level_handle: None,
            extension_manager: None,
            tool_registry: None,
            store: None,
            job_manager: None,
            prompt_queue: None,
            scheduler: None,
            owner_id: "test".to_string(),
            default_sender_id: "test".to_string(),
            shutdown_tx: tokio::sync::RwLock::new(None),
            ws_tracker: Some(Arc::new(WsConnectionTracker::new())),
            llm_provider: None,
            skill_registry: None,
            skill_catalog: None,
            chat_rate_limiter: crate::channels::web::server::PerUserRateLimiter::new(30, 60),
            oauth_rate_limiter: crate::channels::web::server::RateLimiter::new(10, 60),
            webhook_rate_limiter: crate::channels::web::server::RateLimiter::new(10, 60),
            registry_entries: Vec::new(),
            cost_guard: None,
            routine_engine: Arc::new(tokio::sync::RwLock::new(None)),
            startup_time: std::time::Instant::now(),
            active_config: crate::channels::web::server::ActiveConfigSnapshot::default(),
            secrets_store: None,
            db_auth: None,
            channel_manager: None,
            ws_ping_interval_secs: 30,
            ws_idle_timeout_secs: 120,
        }
    }
}
