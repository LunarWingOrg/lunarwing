use std::net::SocketAddr;
use std::sync::Arc;

use futures_util::{SinkExt, StreamExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{mpsc, oneshot};
use tokio_tungstenite::tungstenite::handshake::server::{Request, Response};
use tokio_tungstenite::tungstenite::http::StatusCode;
use tokio_tungstenite::tungstenite::protocol::Message;
use tokio_tungstenite::WebSocketStream;

use crate::executor::{self, ExecutorConfig, ExecutorEvent};
use crate::health::WorkerState;
use crate::protocol::{self, Envelope, TaskRequest};

pub struct BridgeConfig {
    pub bind_host: String,
    pub ws_port: u16,
    pub ws_path: String,
    pub health_port: u16,
    pub auth_token: Option<String>,
    pub worker_id: String,
    pub pebble_bin: String,
    pub model: String,
    pub permission_mode: String,
    pub workspace_root: String,
}

impl BridgeConfig {
    pub fn from_env() -> Self {
        Self {
            bind_host: env_or("WS_BIND_HOST", "0.0.0.0"),
            ws_port: env_or("WS_PORT", "9090").parse().unwrap_or(9090),
            ws_path: env_or("WS_PATH", "/ws/agent"),
            health_port: env_or("HEALTH_PORT", "8443").parse().unwrap_or(8443),
            auth_token: std::env::var("AGENT_AUTH_TOKEN")
                .ok()
                .filter(|t| !t.is_empty()),
            worker_id: env_or("LUNARWING_WORKER_ID", "worker-pebble-01"),
            pebble_bin: env_or("PEBBLE_BIN", "pebble"),
            model: env_or("PEBBLE_MODEL", "openai/gpt-5.2"),
            permission_mode: env_or("PEBBLE_PERMISSION_MODE", "danger-full-access"),
            workspace_root: env_or("WORKSPACE_ROOT", "/workspace"),
        }
    }
}

fn env_or(key: &str, default: &str) -> String {
    std::env::var(key).unwrap_or_else(|_| default.to_string())
}

pub async fn run(
    config: BridgeConfig,
    state: Arc<WorkerState>,
) -> Result<(), Box<dyn std::error::Error>> {
    let addr: SocketAddr = format!("{}:{}", config.bind_host, config.ws_port).parse()?;
    let listener = TcpListener::bind(addr).await?;
    state.set_ready(true);
    eprintln!("[bridge] listening on ws://{addr}{}", config.ws_path);

    let config = Arc::new(config);

    loop {
        let (stream, peer) = listener.accept().await?;
        eprintln!("[bridge] connection from {peer}");
        let config = Arc::clone(&config);
        let state = Arc::clone(&state);
        tokio::spawn(async move {
            if let Err(e) = handle_connection(stream, &config, &state).await {
                eprintln!("[bridge] connection error: {e}");
            }
            state.decrement_connections();
            eprintln!("[bridge] {peer} disconnected");
        });
    }
}

async fn handle_connection(
    stream: TcpStream,
    config: &BridgeConfig,
    state: &WorkerState,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let ws = upgrade_websocket(stream, &config.ws_path, config.auth_token.as_deref()).await?;
    state.increment_connections();
    let (mut write, mut read) = ws.split();

    let ready_json = serde_json::to_string(&protocol::ready_envelope(&config.worker_id))?;
    write.send(Message::Text(ready_json.into())).await?;
    eprintln!("[bridge] sent ready");

    let mut active_cancel: Option<oneshot::Sender<()>> = None;

    while let Some(Ok(msg)) = read.next().await {
        let text = match msg {
            Message::Text(t) => t.to_string(),
            Message::Ping(d) => {
                write.send(Message::Pong(d)).await?;
                continue;
            }
            Message::Close(_) => break,
            _ => continue,
        };

        let Ok(envelope) = serde_json::from_str::<Envelope>(&text) else {
            eprintln!("[bridge] invalid envelope");
            continue;
        };

        match envelope.msg_type.as_str() {
            "task_request" => {
                dispatch_task(envelope, config, &mut write, &mut active_cancel).await?;
            }
            "cancel" => {
                if let Some(tx) = active_cancel.take() {
                    let _ = tx.send(());
                    eprintln!("[bridge] cancel signal sent");
                }
            }
            "ping" => {
                let json = serde_json::to_string(&protocol::pong_envelope())?;
                write.send(Message::Text(json.into())).await?;
            }
            other => eprintln!("[bridge] unknown message type: {other}"),
        }
    }

    Ok(())
}

async fn upgrade_websocket(
    stream: TcpStream,
    expected_path: &str,
    auth_token: Option<&str>,
) -> Result<WebSocketStream<TcpStream>, tokio_tungstenite::tungstenite::Error> {
    let path = expected_path.to_string();
    let token = auth_token.map(String::from);

    #[allow(clippy::result_large_err)]
    tokio_tungstenite::accept_hdr_async(stream, move |req: &Request, mut response: Response| {
        if req.uri().path() != path {
            return Err(reject(StatusCode::NOT_FOUND));
        }
        if let Some(ref expected) = token {
            let bearer = req
                .headers()
                .get("authorization")
                .and_then(|v| v.to_str().ok())
                .unwrap_or("")
                .strip_prefix("Bearer ")
                .unwrap_or("");
            if bearer != expected.as_str() {
                return Err(reject(StatusCode::UNAUTHORIZED));
            }
        }
        let protocols = req
            .headers()
            .get("sec-websocket-protocol")
            .and_then(|v| v.to_str().ok())
            .unwrap_or("");
        let Some(matched) = negotiate_subprotocol(protocols) else {
            return Err(reject(StatusCode::BAD_REQUEST));
        };
        // Echo the negotiated subprotocol back: the orchestrator's client
        // rejects the handshake ("Server sent no subprotocol") unless the server
        // sets Sec-WebSocket-Protocol in the upgrade response — and the echoed
        // value must be one the client actually offered.
        response.headers_mut().insert(
            "sec-websocket-protocol",
            tokio_tungstenite::tungstenite::http::HeaderValue::from_static(matched),
        );
        Ok(response)
    })
    .await
}

/// Pick the subprotocol to echo from a comma-separated client offer.
/// Prefers the primary name; old daemons that only offer the legacy
/// `ironclaw-agent-v1` alias still connect and get that value echoed back.
fn negotiate_subprotocol(offer: &str) -> Option<&'static str> {
    let offered: Vec<&str> = offer.split(',').map(str::trim).collect();
    if offered.contains(&protocol::SUBPROTOCOL) {
        Some(protocol::SUBPROTOCOL)
    } else if offered.contains(&protocol::LEGACY_SUBPROTOCOL) {
        Some(protocol::LEGACY_SUBPROTOCOL)
    } else {
        None
    }
}

fn reject(status: StatusCode) -> http::Response<Option<String>> {
    http::Response::builder()
        .status(status)
        .body(None)
        .expect("response")
}

async fn dispatch_task<S>(
    envelope: Envelope,
    config: &BridgeConfig,
    write: &mut S,
    active_cancel: &mut Option<oneshot::Sender<()>>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>>
where
    S: futures_util::Sink<Message> + Unpin,
    <S as futures_util::Sink<Message>>::Error: std::error::Error + Send + Sync + 'static,
{
    let request: TaskRequest = serde_json::from_value(envelope.payload)?;
    eprintln!("[bridge] task {}: starting", request.task_id);

    let (event_tx, mut event_rx) = mpsc::unbounded_channel();
    let (cancel_tx, cancel_rx) = oneshot::channel();
    *active_cancel = Some(cancel_tx);

    let exec_config = ExecutorConfig {
        pebble_bin: config.pebble_bin.clone(),
        model: config.model.clone(),
        permission_mode: config.permission_mode.clone(),
        workspace_root: config.workspace_root.clone(),
    };

    tokio::spawn(async move {
        executor::run_task(&exec_config, &request, event_tx, cancel_rx).await;
    });

    while let Some(event) = event_rx.recv().await {
        let env = match &event {
            ExecutorEvent::Progress(e) | ExecutorEvent::Result(e) => e,
        };
        let json = serde_json::to_string(env).unwrap_or_default();
        if write.send(Message::Text(json.into())).await.is_err() {
            break;
        }
        if matches!(event, ExecutorEvent::Result(_)) {
            break;
        }
    }

    *active_cancel = None;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn negotiate_prefers_primary_when_both_offered() {
        assert_eq!(
            negotiate_subprotocol("lunarwing-agent-v1, ironclaw-agent-v1"),
            Some(protocol::SUBPROTOCOL)
        );
        assert_eq!(
            negotiate_subprotocol("ironclaw-agent-v1, lunarwing-agent-v1"),
            Some(protocol::SUBPROTOCOL)
        );
    }

    #[test]
    fn negotiate_accepts_primary_alone() {
        assert_eq!(
            negotiate_subprotocol("lunarwing-agent-v1"),
            Some(protocol::SUBPROTOCOL)
        );
    }

    #[test]
    fn negotiate_echoes_legacy_for_old_daemons() {
        assert_eq!(
            negotiate_subprotocol("ironclaw-agent-v1"),
            Some(protocol::LEGACY_SUBPROTOCOL)
        );
    }

    #[test]
    fn negotiate_rejects_unknown_offers() {
        assert_eq!(negotiate_subprotocol(""), None);
        assert_eq!(negotiate_subprotocol("some-other-proto"), None);
    }
}
