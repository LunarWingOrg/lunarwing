//! Integration tests for the external-worker (EWE) WebSocket path.
//!
//! These tests stand up a mock worker speaking the `ironclaw-agent-v1` protocol
//! on an ephemeral loopback port and drive the real
//! [`ExternalWorkerManager::execute_task`] against it. They close the largest
//! pre-existing test gap (T1 in SESSION-AUDIT-MT-DARKIRC-EWE-2026-06-23.md):
//! `connect_and_handshake`, `run_external_task`, and `execute_task` were
//! previously never exercised end-to-end.
//!
//! Coverage:
//! - happy path (task_progress + task_result success), with output accumulation
//! - failed result
//! - task timeout (worker hangs) -> `ExternalWorkerTimeout`
//! - cancel an in-flight task -> `ExternalTaskStatus::Cancelled`
//! - connection failure (unreachable endpoint) -> `ExternalWorkerConnectionFailed`
//! - protocol error (connection closed before `ready`) -> `ExternalWorkerProtocolError`
//! - connection-pool reuse across two sequential successful tasks
//!
//! No PostgreSQL / Docker / external services required; pure loopback WS.

use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use futures::{SinkExt, StreamExt};
use tokio::net::TcpListener;
use tokio::time::timeout;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::handshake::server::{ErrorResponse, Request, Response};
use uuid::Uuid;

use lunarwing::config::{ExternalWorkerConfig, LoadBalanceStrategy, WorkerEndpoint};
use lunarwing::error::OrchestratorError;
use lunarwing::orchestrator::ExternalWorkerManager;
use lunarwing::orchestrator::external_worker::{ExternalTaskStatus, TaskContext};

/// How long we wait for any single test assertion before declaring the test
/// hung. The protocol path under test should resolve in well under this.
const TEST_BOUND: Duration = Duration::from_secs(15);

// ── Mock worker ─────────────────────────────────────────────────────

/// Scripted behaviour for a mock worker connection.
#[derive(Clone)]
enum MockBehavior {
    /// Send `ready`, then on each `task_request`: stream the given progress
    /// chunks, then a success result. Loops so the connection can be pooled and
    /// reused for subsequent tasks.
    Success {
        progress: Vec<String>,
        output: String,
    },
    /// Send `ready`, then on `task_request`: a single failed result.
    Failed { error: String },
    /// Send `ready`, read `task_request`, then never reply (drives a timeout).
    Hang,
    /// Complete the WebSocket upgrade but close without sending `ready`
    /// (drives a protocol error).
    CloseBeforeReady,
}

/// Build a protocol envelope as a JSON string. The id/timestamp are opaque to
/// the client; hardcoded values are fine.
fn envelope(msg_type: &str, payload: serde_json::Value) -> String {
    serde_json::json!({
        "id": "mock-msg-id",
        "type": msg_type,
        "timestamp": "2026-01-01T00:00:00Z",
        "payload": payload,
    })
    .to_string()
}

/// Spawn a mock worker bound to an ephemeral loopback port, running on the
/// current tokio runtime. Returns its `ws://` URL and a shared counter of
/// accepted TCP connections (used to assert pool reuse: a reused connection
/// does not trigger a new accept).
async fn spawn_mock_worker_async(behavior: MockBehavior) -> (String, Arc<AtomicUsize>) {
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind mock listener");
    let addr = listener.local_addr().expect("local_addr");
    let url = format!("ws://{addr}");
    let conn_count = Arc::new(AtomicUsize::new(0));

    tokio::spawn(run_accept_loop(listener, behavior, conn_count.clone()));

    (url, conn_count)
}

/// Accept loop: each accepted connection is handed to a per-connection handler.
async fn run_accept_loop(
    listener: TcpListener,
    behavior: MockBehavior,
    conn_count: Arc<AtomicUsize>,
) {
    loop {
        let (stream, _peer) = match listener.accept().await {
            Ok(s) => s,
            Err(_) => break,
        };
        conn_count.fetch_add(1, Ordering::SeqCst);
        let b = behavior.clone();
        tokio::spawn(async move {
            let _ = handle_connection(stream, b).await;
        });
    }
}

/// Server-handshake callback that echoes the `ironclaw-agent-v1` subprotocol the
/// orchestrator requests (`connect_and_handshake` always sends it). The client's
/// tungstenite rejects the handshake if the server sends no subprotocol, so this
/// mirrors what real worker containers must do.
#[allow(clippy::result_large_err)] // Err type is fixed by tungstenite's Callback trait
fn echo_subprotocol(req: &Request, mut resp: Response) -> Result<Response, ErrorResponse> {
    if req.headers().contains_key("sec-websocket-protocol") {
        resp.headers_mut().insert(
            "sec-websocket-protocol",
            "ironclaw-agent-v1".parse().expect("valid header value"),
        );
    }
    Ok(resp)
}

/// Per-connection protocol handler. Implements the server side of
/// `ironclaw-agent-v1` for the scripted behavior.
async fn handle_connection(stream: tokio::net::TcpStream, behavior: MockBehavior) {
    // For CloseBeforeReady we want the upgrade to complete (so the client treats
    // it as a protocol problem, not a connection problem) then close.
    let mut ws = match tokio_tungstenite::accept_hdr_async(stream, echo_subprotocol).await {
        Ok(ws) => ws,
        Err(_) => return,
    };

    if matches!(behavior, MockBehavior::CloseBeforeReady) {
        let _ = ws.close(None).await;
        return;
    }

    // Send `ready`.
    let ready = envelope(
        "ready",
        serde_json::json!({ "worker_id": "mock-1", "version": "test", "mode": "job" }),
    );
    if ws.send(Message::Text(ready.into())).await.is_err() {
        return;
    }

    loop {
        // Wait for a `task_request` from the client.
        let req = match ws.next().await {
            Some(Ok(m)) if !m.is_close() => m,
            _ => break, // client closed / errored
        };
        // Acknowledge that we consumed the request (don't need to parse it).
        let _ = req.to_text();

        match behavior {
            MockBehavior::Success {
                ref progress,
                ref output,
            } => {
                for delta in progress {
                    let p = envelope(
                        "task_progress",
                        serde_json::json!({ "task_id": "t", "delta": delta, "done": false }),
                    );
                    if ws.send(Message::Text(p.into())).await.is_err() {
                        return;
                    }
                }
                let r = envelope(
                    "task_result",
                    serde_json::json!({
                        "task_id": "t",
                        "status": "success",
                        "output": output,
                        "error": null,
                        "duration_ms": 5,
                    }),
                );
                if ws.send(Message::Text(r.into())).await.is_err() {
                    return;
                }
                // Loop: the connection may be returned to the pool and reused.
            }
            MockBehavior::Failed { ref error } => {
                let r = envelope(
                    "task_result",
                    serde_json::json!({
                        "task_id": "t",
                        "status": "failed",
                        "output": "",
                        "error": error,
                        "duration_ms": 3,
                    }),
                );
                let _ = ws.send(Message::Text(r.into())).await;
                return; // failed tasks are not pooled
            }
            MockBehavior::Hang => {
                // Never reply; the client will time out or be cancelled. Hold
                // the connection open (bounded) so the read side stays pending.
                tokio::time::sleep(Duration::from_secs(30)).await;
                return;
            }
            MockBehavior::CloseBeforeReady => unreachable!("handled above"),
        }
    }
}

// ── Helpers ──────────────────────────────────────────────────────────

fn config_for(url: &str) -> ExternalWorkerConfig {
    ExternalWorkerConfig {
        name: "mock".to_string(),
        url: url.to_string(),
        auth_token: None,
        timeout_ms: 30_000,
        endpoints: vec![WorkerEndpoint {
            url: url.to_string(),
            auth_token: None,
            weight: None,
        }],
        load_balance: LoadBalanceStrategy::RoundRobin,
    }
}

/// Bind and immediately drop a listener to obtain a guaranteed-closed port.
async fn closed_port_url() -> String {
    let l = TcpListener::bind("127.0.0.1:0").await.expect("bind");
    let addr = l.local_addr().expect("addr");
    drop(l);
    format!("ws://{addr}")
}

// ── Tests ────────────────────────────────────────────────────────────

#[tokio::test]
async fn happy_path_success_with_progress() {
    let (url, _count) = spawn_mock_worker_async(MockBehavior::Success {
        progress: vec!["Hello ".to_string(), "world".to_string()],
        output: "Hello world".to_string(),
    })
    .await;
    let mgr = ExternalWorkerManager::new(vec![config_for(&url)]);

    let res = timeout(
        TEST_BOUND,
        mgr.execute_task(
            Uuid::new_v4(),
            "mock",
            "do the thing",
            Some(5_000),
            true,
            TaskContext::default(),
        ),
    )
    .await
    .expect("test timed out")
    .expect("execute_task errored")
    .expect("expected a result for wait=true");

    assert_eq!(res.status, ExternalTaskStatus::Success);
    // `task_result.output` is non-empty, so it takes precedence over the
    // accumulated progress deltas.
    assert_eq!(res.output, "Hello world");
    assert!(res.error.is_none());
}

#[tokio::test]
async fn happy_path_uses_accumulated_progress_when_output_empty() {
    // When the result's `output` is empty, the client falls back to the
    // concatenated progress deltas.
    let (url, _count) = spawn_mock_worker_async(MockBehavior::Success {
        progress: vec!["alpha ".to_string(), "beta".to_string()],
        output: String::new(),
    })
    .await;
    let mgr = ExternalWorkerManager::new(vec![config_for(&url)]);

    let res = timeout(
        TEST_BOUND,
        mgr.execute_task(
            Uuid::new_v4(),
            "mock",
            "task",
            Some(5_000),
            true,
            TaskContext::default(),
        ),
    )
    .await
    .expect("test timed out")
    .expect("execute_task errored")
    .expect("expected result");

    assert_eq!(res.status, ExternalTaskStatus::Success);
    assert_eq!(res.output, "alpha beta");
}

#[tokio::test]
async fn failed_result_status() {
    let (url, _count) = spawn_mock_worker_async(MockBehavior::Failed {
        error: "boom".to_string(),
    })
    .await;
    let mgr = ExternalWorkerManager::new(vec![config_for(&url)]);

    let res = timeout(
        TEST_BOUND,
        mgr.execute_task(
            Uuid::new_v4(),
            "mock",
            "task",
            Some(5_000),
            true,
            TaskContext::default(),
        ),
    )
    .await
    .expect("test timed out")
    .expect("execute_task errored")
    .expect("expected result");

    assert_eq!(res.status, ExternalTaskStatus::Failed);
    assert_eq!(res.error.as_deref(), Some("boom"));
}

#[tokio::test]
async fn task_timeout_when_worker_hangs() {
    let (url, _count) = spawn_mock_worker_async(MockBehavior::Hang).await;
    let mgr = ExternalWorkerManager::new(vec![config_for(&url)]);

    // Short task timeout (covers only the response-read phase, which starts
    // after connect+handshake+send, all local and fast).
    let err = timeout(
        TEST_BOUND,
        mgr.execute_task(
            Uuid::new_v4(),
            "mock",
            "task",
            Some(300),
            true,
            TaskContext::default(),
        ),
    )
    .await
    .expect("test timed out")
    .expect_err("expected ExternalWorkerTimeout");

    assert!(
        matches!(err, OrchestratorError::ExternalWorkerTimeout { .. }),
        "got {err:?}"
    );
}

#[tokio::test]
async fn cancel_in_flight_task() {
    let (url, _count) = spawn_mock_worker_async(MockBehavior::Hang).await;
    let mgr = Arc::new(ExternalWorkerManager::new(vec![config_for(&url)]));
    let job_id = Uuid::new_v4();

    // Cancel shortly after dispatch from a sibling task.
    let mgr_c = mgr.clone();
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(150)).await;
        mgr_c.cancel_task(job_id).await;
    });

    let res = timeout(
        TEST_BOUND,
        mgr.execute_task(
            job_id,
            "mock",
            "task",
            Some(10_000),
            true,
            TaskContext::default(),
        ),
    )
    .await
    .expect("test timed out")
    .expect("execute_task errored")
    .expect("expected result");

    assert_eq!(res.status, ExternalTaskStatus::Cancelled);
}

#[tokio::test]
async fn connection_failure_unreachable_endpoint() {
    let url = closed_port_url().await;
    let mgr = ExternalWorkerManager::new(vec![config_for(&url)]);

    let err = timeout(
        TEST_BOUND,
        mgr.execute_task(
            Uuid::new_v4(),
            "mock",
            "task",
            Some(5_000),
            true,
            TaskContext::default(),
        ),
    )
    .await
    .expect("test timed out")
    .expect_err("expected connection failure");

    assert!(
        matches!(
            err,
            OrchestratorError::ExternalWorkerConnectionFailed { .. }
        ),
        "got {err:?}"
    );
}

#[tokio::test]
async fn protocol_error_closed_before_ready() {
    let (url, _count) = spawn_mock_worker_async(MockBehavior::CloseBeforeReady).await;
    let mgr = ExternalWorkerManager::new(vec![config_for(&url)]);

    let err = timeout(
        TEST_BOUND,
        mgr.execute_task(
            Uuid::new_v4(),
            "mock",
            "task",
            Some(5_000),
            true,
            TaskContext::default(),
        ),
    )
    .await
    .expect("test timed out")
    .expect_err("expected protocol error");

    assert!(
        matches!(err, OrchestratorError::ExternalWorkerProtocolError { .. }),
        "got {err:?}"
    );
}

#[tokio::test]
async fn connection_pool_reuse_across_sequential_tasks() {
    // A successful task returns its connection to the pool; a second task to
    // the same endpoint should reuse it (no new TCP accept).
    let (url, conn_count) = spawn_mock_worker_async(MockBehavior::Success {
        progress: vec![],
        output: "ok".to_string(),
    })
    .await;
    let mgr = ExternalWorkerManager::new(vec![config_for(&url)]);

    let first = timeout(
        TEST_BOUND,
        mgr.execute_task(
            Uuid::new_v4(),
            "mock",
            "first",
            Some(5_000),
            true,
            TaskContext::default(),
        ),
    )
    .await
    .expect("first timed out")
    .expect("first errored")
    .expect("first result");
    assert_eq!(first.status, ExternalTaskStatus::Success);

    let second = timeout(
        TEST_BOUND,
        mgr.execute_task(
            Uuid::new_v4(),
            "mock",
            "second",
            Some(5_000),
            true,
            TaskContext::default(),
        ),
    )
    .await
    .expect("second timed out")
    .expect("second errored")
    .expect("second result");
    assert_eq!(second.status, ExternalTaskStatus::Success);

    // Exactly one TCP connection accepted: the second task reused the pooled one.
    assert_eq!(
        conn_count.load(Ordering::SeqCst),
        1,
        "expected pool reuse (1 connection), got {}",
        conn_count.load(Ordering::SeqCst)
    );
}
