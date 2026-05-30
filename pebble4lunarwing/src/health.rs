use std::convert::Infallible;
use std::net::SocketAddr;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Instant;

use http::Response;
use hyper::body::Bytes;
use hyper::service::service_fn;
use hyper::{Method, Request};
use hyper_util::rt::TokioIo;
use tokio::net::TcpListener;

use crate::protocol::WORKER_VERSION;

pub struct WorkerState {
    worker_id: String,
    ready: AtomicBool,
    connections: AtomicUsize,
    start_time: Instant,
}

impl WorkerState {
    pub fn new(worker_id: &str) -> Self {
        Self {
            worker_id: worker_id.to_string(),
            ready: AtomicBool::new(false),
            connections: AtomicUsize::new(0),
            start_time: Instant::now(),
        }
    }

    pub fn set_ready(&self, ready: bool) {
        self.ready.store(ready, Ordering::Relaxed);
    }

    pub fn increment_connections(&self) {
        self.connections.fetch_add(1, Ordering::Relaxed);
    }

    pub fn decrement_connections(&self) {
        self.connections.fetch_sub(1, Ordering::Relaxed);
    }
}

pub async fn serve(
    addr: SocketAddr,
    state: Arc<WorkerState>,
) -> Result<(), Box<dyn std::error::Error>> {
    let listener = TcpListener::bind(addr).await?;
    eprintln!("[health] listening on http://{addr}");

    loop {
        let (stream, _) = listener.accept().await?;
        let state = Arc::clone(&state);
        tokio::spawn(async move {
            let io = TokioIo::new(stream);
            let service = service_fn(move |req| {
                let state = Arc::clone(&state);
                async move { handle_request(req, &state) }
            });
            let _ = hyper::server::conn::http1::Builder::new()
                .serve_connection(io, service)
                .await;
        });
    }
}

#[allow(clippy::unnecessary_wraps, clippy::needless_pass_by_value)]
fn handle_request(
    req: Request<hyper::body::Incoming>,
    state: &WorkerState,
) -> Result<Response<http_body_util::Full<Bytes>>, Infallible> {
    if req.method() != Method::GET {
        return Ok(Response::builder()
            .status(405)
            .body(http_body_util::Full::new(Bytes::from_static(
                b"Method Not Allowed",
            )))
            .expect("response"));
    }

    match req.uri().path() {
        "/health" => {
            let body = serde_json::json!({
                "status": "ok",
                "uptime_seconds": state.start_time.elapsed().as_secs(),
                "worker_id": state.worker_id,
                "version": WORKER_VERSION,
                "mode": "websocket",
            });
            Ok(json_response(200, &body))
        }
        "/ready" => {
            let ready = state.ready.load(Ordering::Relaxed);
            let connections = state.connections.load(Ordering::Relaxed);
            let body = serde_json::json!({
                "ready": ready,
                "connections": connections,
            });
            let status = if ready { 200 } else { 503 };
            Ok(json_response(status, &body))
        }
        _ => Ok(Response::builder()
            .status(404)
            .body(http_body_util::Full::new(Bytes::from_static(b"Not Found")))
            .expect("response")),
    }
}

fn json_response(status: u16, body: &serde_json::Value) -> Response<http_body_util::Full<Bytes>> {
    let json = serde_json::to_string(body).unwrap_or_default();
    Response::builder()
        .status(status)
        .header("content-type", "application/json")
        .body(http_body_util::Full::new(Bytes::from(json)))
        .expect("response")
}
