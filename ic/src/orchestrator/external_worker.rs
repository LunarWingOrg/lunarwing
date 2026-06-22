//! WebSocket client for external workers speaking the `ironclaw-agent-v1` protocol.
//!
//! External workers are persistent containers (nanocode, codex, etc.) that the
//! orchestrator connects to on demand rather than creating per-job.

use std::collections::HashMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use chrono::Utc;
use futures::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use tokio::sync::{Mutex, RwLock, broadcast, oneshot};
use uuid::Uuid;

use crate::channels::web::types::SseEvent;
use crate::config::ExternalWorkerConfig;
use crate::context::{ContextManager, JobState};
use crate::db::Database;
use crate::error::OrchestratorError;

// ── Protocol types ──────────────────────────────────────────────────

#[derive(Debug, Serialize, Deserialize)]
struct Envelope {
    id: String,
    #[serde(rename = "type")]
    msg_type: String,
    timestamp: String,
    payload: serde_json::Value,
}

impl Envelope {
    fn new(msg_type: &str, payload: serde_json::Value) -> Self {
        Self {
            id: Uuid::new_v4().to_string(),
            msg_type: msg_type.to_string(),
            timestamp: Utc::now().to_rfc3339(),
            payload,
        }
    }
}

#[derive(Debug, Deserialize)]
struct ReadyPayload {
    worker_id: String,
    #[allow(dead_code)]
    version: String,
    #[allow(dead_code)]
    mode: String,
}

#[derive(Debug, Deserialize)]
struct TaskProgressPayload {
    #[allow(dead_code)]
    task_id: String,
    delta: String,
    #[allow(dead_code)]
    done: bool,
}

/// A single message in conversation history.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConversationMessage {
    pub role: String,
    pub content: String,
}

/// Context passed to external workers with task requests.
///
/// All fields are optional with serde defaults for backward compatibility —
/// older workers that don't understand these fields will still work.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct TaskContext {
    /// Workspace/project directory path.
    pub project_dir: Option<String>,
    /// Recent conversation messages for context.
    pub conversation_history: Vec<ConversationMessage>,
    /// Environment variables to inject into the worker process.
    pub environment: HashMap<String, String>,
    /// User ID who initiated the task.
    pub user_id: String,
    /// Arbitrary metadata key-value pairs.
    pub metadata: HashMap<String, String>,
}

pub fn build_task_context(
    user_id: &str,
    project_dir: Option<&str>,
    environment: HashMap<String, String>,
    conversation_history: Vec<ConversationMessage>,
    metadata: HashMap<String, String>,
) -> TaskContext {
    TaskContext {
        user_id: user_id.to_string(),
        project_dir: project_dir.map(String::from),
        environment,
        conversation_history,
        metadata,
    }
}

#[derive(Debug, Deserialize)]
struct TaskResultPayload {
    #[allow(dead_code)]
    task_id: String,
    status: String,
    output: String,
    error: Option<String>,
    duration_ms: u64,
}

// ── External job handle ─────────────────────────────────────────────

/// Handle to a running external worker task.
pub struct ExternalJobHandle {
    pub job_id: Uuid,
    pub worker_name: String,
    cancel_tx: Option<oneshot::Sender<()>>,
}

impl ExternalJobHandle {
    pub fn cancel(mut self) {
        if let Some(tx) = self.cancel_tx.take() {
            let _ = tx.send(());
        }
    }
}

// ── Manager ─────────────────────────────────────────────────────────

/// Manages connections to external worker endpoints.
pub struct ExternalWorkerManager {
    workers: HashMap<String, ExternalWorkerConfig>,
    load_balancers: HashMap<String, LoadBalancer>,
    pool: Arc<WorkerConnectionPool>,
    job_event_tx: Option<broadcast::Sender<(Uuid, String, SseEvent)>>,
    context_manager: Option<Arc<ContextManager>>,
    store: Option<Arc<dyn Database>>,
    active_handles: Arc<RwLock<HashMap<Uuid, Arc<Mutex<ExternalJobHandle>>>>>,
}

impl ExternalWorkerManager {
    pub fn new(configs: Vec<ExternalWorkerConfig>) -> Self {
        let mut load_balancers = HashMap::new();
        for config in &configs {
            let endpoints = config.endpoints();
            load_balancers.insert(config.name.clone(), LoadBalancer::new(endpoints));
        }

        let workers: HashMap<String, ExternalWorkerConfig> =
            configs.into_iter().map(|c| (c.name.clone(), c)).collect();

        if !workers.is_empty() {
            tracing::info!(
                "External workers configured: {}",
                workers.keys().cloned().collect::<Vec<_>>().join(", ")
            );
        }

        Self {
            workers,
            load_balancers,
            pool: Arc::new(WorkerConnectionPool::new(2, Duration::from_secs(300))),
            job_event_tx: None,
            context_manager: None,
            store: None,
            active_handles: Arc::new(RwLock::new(HashMap::new())),
        }
    }

    pub fn with_event_deps(
        mut self,
        event_tx: broadcast::Sender<(Uuid, String, SseEvent)>,
        context_manager: Arc<ContextManager>,
    ) -> Self {
        self.job_event_tx = Some(event_tx);
        self.context_manager = Some(context_manager);
        self
    }

    pub fn with_store(mut self, store: Arc<dyn Database>) -> Self {
        self.store = Some(store);
        self
    }

    pub fn get_worker(&self, name: &str) -> Option<&ExternalWorkerConfig> {
        self.workers.get(name)
    }

    pub fn worker_names(&self) -> Vec<&str> {
        self.workers.keys().map(|s| s.as_str()).collect()
    }

    pub fn is_empty(&self) -> bool {
        self.workers.is_empty()
    }

    /// Execute a task on a named external worker.
    ///
    /// Connects via WebSocket, sends the task, streams progress as job events,
    /// and returns the final result. If `wait` is true, blocks until completion.
    /// If false, spawns a background task and returns immediately.
    pub async fn execute_task(
        &self,
        job_id: Uuid,
        worker_name: &str,
        task: &str,
        timeout_ms: Option<u64>,
        wait: bool,
        context: TaskContext,
    ) -> Result<Option<ExternalTaskResult>, OrchestratorError> {
        self.pool.evict_stale().await;

        let config = self.workers.get(worker_name).ok_or_else(|| {
            OrchestratorError::ExternalWorkerNotFound {
                worker_name: worker_name.to_string(),
            }
        })?;

        let timeout = timeout_ms.unwrap_or(config.timeout_ms);

        // Use load balancer to select endpoint
        let endpoint = self
            .load_balancers
            .get(worker_name)
            .map(|lb| lb.next_endpoint().clone())
            .unwrap_or_else(|| WorkerEndpoint {
                url: config.url.clone(),
                auth_token: config.auth_token.clone(),
                weight: None,
            });

        let url = endpoint.url.clone();
        let auth_token = endpoint.auth_token.clone();
        let pool_key = format!("{worker_name}:{url}");
        let worker_name_owned = worker_name.to_string();
        let task_owned = task.to_string();
        let event_tx = self.job_event_tx.clone();
        let context_manager = self.context_manager.clone();
        let store = self.store.clone();
        let active_handles = Arc::clone(&self.active_handles);
        let pool = Arc::clone(&self.pool);

        let (cancel_tx, cancel_rx) = oneshot::channel();
        let handle = Arc::new(Mutex::new(ExternalJobHandle {
            job_id,
            worker_name: worker_name_owned.clone(),
            cancel_tx: Some(cancel_tx),
        }));
        active_handles
            .write()
            .await
            .insert(job_id, Arc::clone(&handle));

        if wait {
            let result = run_external_task(
                job_id,
                &url,
                auth_token.as_deref(),
                &task_owned,
                timeout,
                &worker_name_owned,
                event_tx.as_ref(),
                context_manager.as_ref(),
                store.as_ref(),
                cancel_rx,
                context,
                &pool,
                &pool_key,
            )
            .await;

            active_handles.write().await.remove(&job_id);
            result.map(Some)
        } else {
            tokio::spawn(async move {
                let result = run_external_task(
                    job_id,
                    &url,
                    auth_token.as_deref(),
                    &task_owned,
                    timeout,
                    &worker_name_owned,
                    event_tx.as_ref(),
                    context_manager.as_ref(),
                    store.as_ref(),
                    cancel_rx,
                    context,
                    &pool,
                    &pool_key,
                )
                .await;

                active_handles.write().await.remove(&job_id);

                match &result {
                    Ok(r) => {
                        tracing::info!(
                            "External worker '{}' job {} completed: status={}",
                            worker_name_owned,
                            job_id,
                            r.status
                        );
                    }
                    Err(e) => {
                        tracing::error!(
                            "External worker '{}' job {} failed: {}",
                            worker_name_owned,
                            job_id,
                            e
                        );
                    }
                }
            });

            Ok(None)
        }
    }

    /// Cancel an active external worker task.
    pub async fn cancel_task(&self, job_id: Uuid) -> bool {
        if let Some(handle) = self.active_handles.write().await.remove(&job_id) {
            let mut h = handle.lock().await;
            if let Some(tx) = h.cancel_tx.take() {
                let _ = tx.send(());
                return true;
            }
        }
        false
    }
}

/// Status of an external worker task.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "lowercase")]
pub enum ExternalTaskStatus {
    Success,
    Failed,
    Cancelled,
    #[serde(rename = "timed_out")]
    TimedOut,
    Partial(String),
}

impl std::fmt::Display for ExternalTaskStatus {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Success => write!(f, "success"),
            Self::Failed => write!(f, "failed"),
            Self::Cancelled => write!(f, "cancelled"),
            Self::TimedOut => write!(f, "timed_out"),
            Self::Partial(msg) => write!(f, "partial: {}", msg),
        }
    }
}

/// Result of an external worker task.
#[derive(Debug, Clone)]
pub struct ExternalTaskResult {
    pub status: ExternalTaskStatus,
    pub output: String,
    pub error: Option<String>,
    pub duration_ms: u64,
}

// ── Load balancer ──────────────────────────────────────────────────

use crate::config::WorkerEndpoint;

pub struct LoadBalancer {
    endpoints: Vec<WorkerEndpoint>,
    current_index: AtomicUsize,
}

impl LoadBalancer {
    pub fn new(endpoints: Vec<WorkerEndpoint>) -> Self {
        assert!(
            !endpoints.is_empty(),
            "LoadBalancer requires at least one endpoint"
        );
        Self {
            endpoints,
            current_index: AtomicUsize::new(0),
        }
    }

    pub fn next_endpoint(&self) -> &WorkerEndpoint {
        let idx = self.current_index.fetch_add(1, Ordering::Relaxed) % self.endpoints.len();
        &self.endpoints[idx]
    }

    pub fn endpoint_count(&self) -> usize {
        self.endpoints.len()
    }
}

// ── Connection pool ────────────────────────────────────────────────

use std::time::Instant;
use tokio::net::TcpStream;
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream};

type WsStream = WebSocketStream<MaybeTlsStream<TcpStream>>;

pub struct PooledConnection {
    pub stream: WsStream,
    pub worker_id: String,
    last_used: Instant,
}

pub struct WorkerConnectionPool {
    connections: Mutex<HashMap<String, Vec<PooledConnection>>>,
    max_idle_per_endpoint: usize,
    idle_timeout: Duration,
}

impl WorkerConnectionPool {
    pub fn new(max_idle_per_endpoint: usize, idle_timeout: Duration) -> Self {
        Self {
            connections: Mutex::new(HashMap::new()),
            max_idle_per_endpoint,
            idle_timeout,
        }
    }

    pub async fn try_acquire(&self, key: &str) -> Option<PooledConnection> {
        let mut conns = self.connections.lock().await;
        let pool = conns.get_mut(key)?;
        pool.pop()
    }

    pub async fn release(&self, key: String, mut conn: PooledConnection) {
        conn.last_used = Instant::now();
        let mut conns = self.connections.lock().await;
        let pool = conns.entry(key).or_default();
        if pool.len() < self.max_idle_per_endpoint {
            pool.push(conn);
        }
    }

    pub async fn evict_stale(&self) {
        let mut conns = self.connections.lock().await;
        let cutoff = self.idle_timeout;
        conns.retain(|_, pool| {
            pool.retain(|c| c.last_used.elapsed() < cutoff);
            !pool.is_empty()
        });
    }

    pub async fn drain(&self) {
        let mut conns = self.connections.lock().await;
        conns.clear();
    }

    pub async fn pool_size(&self) -> usize {
        let conns = self.connections.lock().await;
        conns.values().map(|v| v.len()).sum()
    }
}

// ── WebSocket task runner ───────────────────────────────────────────

async fn connect_and_handshake(
    url: &str,
    auth_token: Option<&str>,
    worker_name: &str,
) -> Result<(WsStream, String), OrchestratorError> {
    use tokio_tungstenite::tungstenite;

    let uri = url.parse::<http::Uri>().map_err(|e| {
        OrchestratorError::ExternalWorkerConnectionFailed {
            worker_name: worker_name.to_string(),
            reason: format!("invalid URL: {e}"),
        }
    })?;

    let mut req_builder = http::Request::builder()
        .uri(&uri)
        .header("Sec-WebSocket-Protocol", "ironclaw-agent-v1");

    if let Some(token) = auth_token {
        req_builder = req_builder.header("Authorization", format!("Bearer {token}"));
    }

    let host = uri.host().unwrap_or("localhost");
    let port_suffix = uri.port_u16().map(|p| format!(":{p}")).unwrap_or_default();
    req_builder = req_builder
        .header("Host", format!("{host}{port_suffix}"))
        .header("Connection", "Upgrade")
        .header("Upgrade", "websocket")
        .header(
            "Sec-WebSocket-Key",
            tungstenite::handshake::client::generate_key(),
        )
        .header("Sec-WebSocket-Version", "13");

    let ws_request =
        req_builder
            .body(())
            .map_err(|e| OrchestratorError::ExternalWorkerConnectionFailed {
                worker_name: worker_name.to_string(),
                reason: format!("failed to build request: {e}"),
            })?;

    let connect_timeout = Duration::from_secs(15);
    let (ws_stream, _response) = tokio::time::timeout(
        connect_timeout,
        tokio_tungstenite::connect_async(ws_request),
    )
    .await
    .map_err(|_| OrchestratorError::ExternalWorkerConnectionFailed {
        worker_name: worker_name.to_string(),
        reason: "connection timed out (15s)".to_string(),
    })?
    .map_err(|e| OrchestratorError::ExternalWorkerConnectionFailed {
        worker_name: worker_name.to_string(),
        reason: e.to_string(),
    })?;

    let (write_half, mut read) = ws_stream.split();

    let ready_timeout = Duration::from_secs(10);
    let ready_msg = tokio::time::timeout(ready_timeout, read.next())
        .await
        .map_err(|_| OrchestratorError::ExternalWorkerProtocolError {
            worker_name: worker_name.to_string(),
            reason: "no ready message within 10s".to_string(),
        })?
        .ok_or_else(|| OrchestratorError::ExternalWorkerProtocolError {
            worker_name: worker_name.to_string(),
            reason: "connection closed before ready".to_string(),
        })?
        .map_err(|e| OrchestratorError::ExternalWorkerProtocolError {
            worker_name: worker_name.to_string(),
            reason: format!("WebSocket error: {e}"),
        })?;

    let ready_text =
        ready_msg
            .to_text()
            .map_err(|e| OrchestratorError::ExternalWorkerProtocolError {
                worker_name: worker_name.to_string(),
                reason: format!("ready message not text: {e}"),
            })?;

    let ready_env: Envelope = serde_json::from_str(ready_text).map_err(|e| {
        OrchestratorError::ExternalWorkerProtocolError {
            worker_name: worker_name.to_string(),
            reason: format!("invalid ready envelope: {e}"),
        }
    })?;

    if ready_env.msg_type != "ready" {
        return Err(OrchestratorError::ExternalWorkerProtocolError {
            worker_name: worker_name.to_string(),
            reason: format!("expected 'ready', got '{}'", ready_env.msg_type),
        });
    }

    let ready: ReadyPayload = serde_json::from_value(ready_env.payload).map_err(|e| {
        OrchestratorError::ExternalWorkerProtocolError {
            worker_name: worker_name.to_string(),
            reason: format!("invalid ready payload: {e}"),
        }
    })?;

    let stream =
        write_half
            .reunite(read)
            .map_err(|_| OrchestratorError::ExternalWorkerProtocolError {
                worker_name: worker_name.to_string(),
                reason: "failed to reunite WebSocket stream halves".to_string(),
            })?;

    Ok((stream, ready.worker_id))
}

#[allow(clippy::too_many_arguments)]
async fn run_external_task(
    job_id: Uuid,
    url: &str,
    auth_token: Option<&str>,
    task: &str,
    timeout_ms: u64,
    worker_name: &str,
    event_tx: Option<&broadcast::Sender<(Uuid, String, SseEvent)>>,
    context_manager: Option<&Arc<ContextManager>>,
    store: Option<&Arc<dyn Database>>,
    cancel_rx: oneshot::Receiver<()>,
    context: TaskContext,
    pool: &WorkerConnectionPool,
    pool_key: &str,
) -> Result<ExternalTaskResult, OrchestratorError> {
    use tokio_tungstenite::tungstenite;

    // Try pooled connection first, fall back to fresh
    let (mut write, mut read, worker_id, from_pool) =
        if let Some(pooled) = pool.try_acquire(pool_key).await {
            tracing::debug!("Reusing pooled connection for '{worker_name}'");
            let wid = pooled.worker_id.clone();
            let (w, r) = pooled.stream.split();
            (w, r, wid, true)
        } else {
            let (stream, wid) = connect_and_handshake(url, auth_token, worker_name).await?;
            let (w, r) = stream.split();
            (w, r, wid, false)
        };

    let source = if from_pool { "pooled" } else { "new" };
    tracing::info!(
        "External worker '{}' ready (worker_id={}, connection={})",
        worker_name,
        worker_id,
        source
    );

    // Emit job_started event
    emit_event(
        event_tx,
        job_id,
        SseEvent::JobStatus {
            job_id: job_id.to_string(),
            message: format!("Connected to external worker '{worker_name}'"),
        },
    );

    // Send task_request
    let task_request = Envelope::new(
        "task_request",
        serde_json::json!({
            "task_id": job_id.to_string(),
            "prompt": task,
            "context": context,
            "timeout_ms": timeout_ms,
        }),
    );

    let msg = tungstenite::Message::Text(
        serde_json::to_string(&task_request)
            .map_err(|e| OrchestratorError::ExternalWorkerProtocolError {
                worker_name: worker_name.to_string(),
                reason: format!("failed to serialize task_request: {e}"),
            })?
            .into(),
    );

    write
        .send(msg)
        .await
        .map_err(|e| OrchestratorError::ExternalWorkerProtocolError {
            worker_name: worker_name.to_string(),
            reason: format!("failed to send task_request: {e}"),
        })?;

    // Read messages until task_result or timeout
    let task_timeout = Duration::from_millis(timeout_ms);
    let mut accumulated_output = String::new();
    let mut cancel_rx = cancel_rx;

    let result = tokio::time::timeout(task_timeout, async {
        loop {
            tokio::select! {
                msg = read.next() => {
                    let Some(msg_result) = msg else {
                        return Err(OrchestratorError::ExternalWorkerProtocolError {
                            worker_name: worker_name.to_string(),
                            reason: "connection closed unexpectedly".to_string(),
                        });
                    };

                    let ws_msg = msg_result.map_err(|e| {
                        OrchestratorError::ExternalWorkerProtocolError {
                            worker_name: worker_name.to_string(),
                            reason: format!("WebSocket error: {e}"),
                        }
                    })?;

                    if ws_msg.is_close() {
                        return Err(OrchestratorError::ExternalWorkerProtocolError {
                            worker_name: worker_name.to_string(),
                            reason: "connection closed by worker".to_string(),
                        });
                    }

                    if ws_msg.is_ping() || ws_msg.is_pong() {
                        continue;
                    }

                    let text = match ws_msg.to_text() {
                        Ok(t) => t,
                        Err(_) => continue,
                    };

                    let env: Envelope = match serde_json::from_str(text) {
                        Ok(e) => e,
                        Err(e) => {
                            tracing::warn!("Ignoring unparseable message from '{}': {}", worker_name, e);
                            continue;
                        }
                    };

                    match env.msg_type.as_str() {
                        "task_progress" => {
                            if let Ok(progress) = serde_json::from_value::<TaskProgressPayload>(env.payload) {
                                accumulated_output.push_str(&progress.delta);

                                emit_event(
                                    event_tx,
                                    job_id,
                                    SseEvent::JobMessage {
                                        job_id: job_id.to_string(),
                                        content: progress.delta.clone(),
                                        role: "assistant".to_string(),
                                    },
                                );

                                // Persist as job event
                                persist_event(store, job_id, "message", &progress.delta).await;
                            }
                        }
                        "task_result" => {
                            let result: TaskResultPayload =
                                serde_json::from_value(env.payload).map_err(|e| {
                                    OrchestratorError::ExternalWorkerProtocolError {
                                        worker_name: worker_name.to_string(),
                                        reason: format!("invalid task_result: {e}"),
                                    }
                                })?;

                            let final_output = if result.output.is_empty() {
                                accumulated_output.clone()
                            } else {
                                result.output.clone()
                            };

                            let status = match result.status.as_str() {
                                "success" => ExternalTaskStatus::Success,
                                "cancelled" => ExternalTaskStatus::Cancelled,
                                _ => ExternalTaskStatus::Failed,
                            };

                            return Ok(ExternalTaskResult {
                                status,
                                output: final_output,
                                error: result.error,
                                duration_ms: result.duration_ms,
                            });
                        }
                        "pong" => {}
                        other => {
                            tracing::debug!("Unknown message type '{}' from '{}'", other, worker_name);
                        }
                    }
                }
                _ = &mut cancel_rx => {
                    // Send cancel envelope
                    let cancel_env = Envelope::new(
                        "cancel",
                        serde_json::json!({ "task_id": job_id.to_string() }),
                    );
                    if let Ok(json) = serde_json::to_string(&cancel_env) {
                        let _ = write.send(tungstenite::Message::Text(json.into())).await;
                    }
                    return Ok(ExternalTaskResult {
                        status: ExternalTaskStatus::Cancelled,
                        output: accumulated_output.clone(),
                        error: None,
                        duration_ms: 0,
                    });
                }
            }
        }
    })
    .await;

    let task_result = match result {
        Ok(r) => r?,
        Err(_) => {
            return Err(OrchestratorError::ExternalWorkerTimeout {
                worker_name: worker_name.to_string(),
                job_id,
            });
        }
    };

    // Update context manager state
    let success = matches!(task_result.status, ExternalTaskStatus::Success);
    let final_state = if success {
        JobState::Completed
    } else {
        JobState::Failed
    };

    if let Some(cm) = context_manager {
        let _ = cm
            .update_context(job_id, |ctx| {
                ctx.transition_to(final_state, task_result.error.clone())
            })
            .await;
    }

    // Persist final event
    let final_msg = if success {
        format!("Completed: {}", task_result.output)
    } else {
        format!(
            "Failed: {}",
            task_result.error.as_deref().unwrap_or("unknown error")
        )
    };
    persist_event(store, job_id, "result", &final_msg).await;

    // Emit final SSE event
    let status_str = if success { "completed" } else { "failed" };
    emit_event(
        event_tx,
        job_id,
        SseEvent::JobResult {
            job_id: job_id.to_string(),
            status: status_str.to_string(),
            session_id: None,
            fallback_deliverable: None,
        },
    );

    // Update DB job record
    if let Some(db) = store {
        let status = if success { "completed" } else { "failed" };
        let _ = db
            .update_sandbox_job_status(
                job_id,
                status,
                Some(success),
                task_result.error.as_deref(),
                None,
                Some(Utc::now()),
            )
            .await;
    }

    // Return the connection to the pool for reuse on successful tasks.
    // On failure/cancel/timeout paths the connection may be in an
    // indeterminate state, so we drop it instead of risking corruption.
    if success {
        match write.reunite(read) {
            Ok(stream) => {
                tracing::debug!(
                    "Returning connection to pool for '{worker_name}' (key={pool_key})"
                );
                pool.release(
                    pool_key.to_string(),
                    PooledConnection {
                        stream,
                        worker_id,
                        last_used: std::time::Instant::now(),
                    },
                )
                .await;
            }
            Err(e) => {
                tracing::warn!(
                    "Failed to reunite WebSocket halves for '{worker_name}': {e}"
                );
            }
        }
    }

    Ok(task_result)
}

// ── Helpers ─────────────────────────────────────────────────────────

fn emit_event(
    tx: Option<&broadcast::Sender<(Uuid, String, SseEvent)>>,
    job_id: Uuid,
    event: SseEvent,
) {
    if let Some(tx) = tx {
        let _ = tx.send((job_id, "external".to_string(), event));
    }
}

async fn persist_event(
    store: Option<&Arc<dyn Database>>,
    job_id: Uuid,
    event_type: &str,
    data: &str,
) {
    if let Some(db) = store {
        let value = serde_json::json!({ "content": data });
        let _ = db.save_job_event(job_id, event_type, &value).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::LoadBalanceStrategy;

    #[test]
    fn envelope_serialization() {
        let env = Envelope::new("task_request", serde_json::json!({"prompt": "hello"}));
        let json = serde_json::to_string(&env).unwrap();
        assert!(json.contains("\"type\":\"task_request\""));
        assert!(json.contains("\"prompt\":\"hello\""));
    }

    #[test]
    fn envelope_deserialization() {
        let json = r#"{"id":"abc","type":"ready","timestamp":"2026-01-01T00:00:00Z","payload":{"worker_id":"w1","version":"1.0","mode":"websocket"}}"#;
        let env: Envelope = serde_json::from_str(json).unwrap();
        assert_eq!(env.msg_type, "ready");
        let ready: ReadyPayload = serde_json::from_value(env.payload).unwrap();
        assert_eq!(ready.worker_id, "w1");
    }

    #[test]
    fn task_result_deserialization() {
        let json = r#"{"task_id":"abc","status":"success","output":"done","error":null,"duration_ms":1234}"#;
        let result: TaskResultPayload = serde_json::from_str(json).unwrap();
        assert_eq!(result.status, "success");
        assert_eq!(result.output, "done");
        assert!(result.error.is_none());
        assert_eq!(result.duration_ms, 1234);
    }

    #[test]
    fn manager_new_empty() {
        let mgr = ExternalWorkerManager::new(vec![]);
        assert!(mgr.is_empty());
        assert!(mgr.get_worker("nanocode").is_none());
    }

    #[test]
    fn manager_new_with_workers() {
        let mgr = ExternalWorkerManager::new(vec![
            ExternalWorkerConfig {
                name: "nanocode".to_string(),
                url: "ws://localhost:9090/ws/agent".to_string(),
                auth_token: Some("tok".to_string()),
                timeout_ms: 300_000,
                endpoints: vec![],
                load_balance: LoadBalanceStrategy::default(),
            },
            ExternalWorkerConfig {
                name: "codex".to_string(),
                url: "ws://localhost:8443".to_string(),
                auth_token: None,
                timeout_ms: 600_000,
                endpoints: vec![],
                load_balance: LoadBalanceStrategy::default(),
            },
        ]);
        assert!(!mgr.is_empty());
        assert!(mgr.get_worker("nanocode").is_some());
        assert!(mgr.get_worker("codex").is_some());
        assert!(mgr.get_worker("unknown").is_none());
        assert_eq!(mgr.worker_names().len(), 2);
    }

    #[test]
    fn job_mode_db_roundtrip() {
        use crate::orchestrator::job_manager::JobMode;
        let ext = JobMode::External("nanocode".to_string());
        assert_eq!(ext.db_value(), "external:nanocode");
        assert_eq!(JobMode::from_db_value("external:nanocode"), ext);

        let worker = JobMode::Worker;
        assert_eq!(worker.db_value(), "worker");
        assert_eq!(JobMode::from_db_value("worker"), worker);
    }

    #[test]
    fn task_context_full_roundtrip() {
        let ctx = TaskContext {
            project_dir: Some("/workspace/myproject".to_string()),
            conversation_history: vec![
                ConversationMessage {
                    role: "user".to_string(),
                    content: "fix the bug".to_string(),
                },
                ConversationMessage {
                    role: "assistant".to_string(),
                    content: "working on it".to_string(),
                },
            ],
            environment: [("API_KEY".to_string(), "secret123".to_string())]
                .into_iter()
                .collect(),
            user_id: "user-42".to_string(),
            metadata: [("priority".to_string(), "high".to_string())]
                .into_iter()
                .collect(),
        };

        let json = serde_json::to_string(&ctx).unwrap();
        let deserialized: TaskContext = serde_json::from_str(&json).unwrap();

        assert_eq!(
            deserialized.project_dir,
            Some("/workspace/myproject".to_string())
        );
        assert_eq!(deserialized.conversation_history.len(), 2);
        assert_eq!(deserialized.conversation_history[0].role, "user");
        assert_eq!(deserialized.conversation_history[0].content, "fix the bug");
        assert_eq!(
            deserialized.environment.get("API_KEY"),
            Some(&"secret123".to_string())
        );
        assert_eq!(deserialized.user_id, "user-42");
        assert_eq!(
            deserialized.metadata.get("priority"),
            Some(&"high".to_string())
        );
    }

    #[test]
    fn task_context_backward_compat() {
        let json = r#"{}"#;
        let ctx: TaskContext = serde_json::from_str(json).unwrap();

        assert_eq!(ctx.project_dir, None);
        assert!(ctx.conversation_history.is_empty());
        assert!(ctx.environment.is_empty());
        assert_eq!(ctx.user_id, "");
        assert!(ctx.metadata.is_empty());
    }

    #[test]
    fn task_status_enum_serde() {
        assert_eq!(
            serde_json::to_string(&ExternalTaskStatus::Success).unwrap(),
            "\"success\""
        );
        assert_eq!(
            serde_json::to_string(&ExternalTaskStatus::Failed).unwrap(),
            "\"failed\""
        );
        assert_eq!(
            serde_json::to_string(&ExternalTaskStatus::Cancelled).unwrap(),
            "\"cancelled\""
        );
        assert_eq!(
            serde_json::to_string(&ExternalTaskStatus::TimedOut).unwrap(),
            "\"timed_out\""
        );
        let partial_json =
            serde_json::to_string(&ExternalTaskStatus::Partial("wip".to_string())).unwrap();
        assert!(partial_json.contains("partial"));
        assert!(partial_json.contains("wip"));

        let success: ExternalTaskStatus = serde_json::from_str("\"success\"").unwrap();
        assert_eq!(success, ExternalTaskStatus::Success);

        let failed: ExternalTaskStatus = serde_json::from_str("\"failed\"").unwrap();
        assert_eq!(failed, ExternalTaskStatus::Failed);
        let cancelled: ExternalTaskStatus = serde_json::from_str("\"cancelled\"").unwrap();
        assert_eq!(cancelled, ExternalTaskStatus::Cancelled);
        let timed_out: ExternalTaskStatus = serde_json::from_str("\"timed_out\"").unwrap();
        assert_eq!(timed_out, ExternalTaskStatus::TimedOut);
    }

    #[test]
    fn task_status_enum_matching() {
        let success = ExternalTaskStatus::Success;
        let failed = ExternalTaskStatus::Failed;
        let cancelled = ExternalTaskStatus::Cancelled;

        assert!(matches!(success, ExternalTaskStatus::Success));
        assert!(!matches!(failed, ExternalTaskStatus::Success));
        assert!(!matches!(cancelled, ExternalTaskStatus::Success));
    }

    #[test]
    fn load_balancer_round_robin() {
        use crate::config::WorkerEndpoint;

        let endpoints = vec![
            WorkerEndpoint {
                url: "ws://a:9090".to_string(),
                auth_token: None,
                weight: None,
            },
            WorkerEndpoint {
                url: "ws://b:9090".to_string(),
                auth_token: None,
                weight: None,
            },
            WorkerEndpoint {
                url: "ws://c:9090".to_string(),
                auth_token: None,
                weight: None,
            },
        ];
        let lb = LoadBalancer::new(endpoints);

        assert_eq!(lb.next_endpoint().url, "ws://a:9090");
        assert_eq!(lb.next_endpoint().url, "ws://b:9090");
        assert_eq!(lb.next_endpoint().url, "ws://c:9090");
        assert_eq!(lb.next_endpoint().url, "ws://a:9090");
        assert_eq!(lb.next_endpoint().url, "ws://b:9090");
        assert_eq!(lb.next_endpoint().url, "ws://c:9090");
    }

    #[test]
    fn load_balancer_single_endpoint() {
        use crate::config::WorkerEndpoint;

        let endpoints = vec![WorkerEndpoint {
            url: "ws://only:9090".to_string(),
            auth_token: None,
            weight: None,
        }];
        let lb = LoadBalancer::new(endpoints);

        for _ in 0..10 {
            assert_eq!(lb.next_endpoint().url, "ws://only:9090");
        }
    }

    #[test]
    fn build_task_context_populates_fields() {
        let env: HashMap<String, String> = [("API_KEY".to_string(), "secret".to_string())]
            .into_iter()
            .collect();
        let history = vec![ConversationMessage {
            role: "user".to_string(),
            content: "do the thing".to_string(),
        }];
        let meta: HashMap<String, String> = [("priority".to_string(), "high".to_string())]
            .into_iter()
            .collect();

        let ctx = build_task_context("user-1", Some("/workspace"), env, history, meta);

        assert_eq!(ctx.user_id, "user-1");
        assert_eq!(ctx.project_dir.as_deref(), Some("/workspace"));
        assert_eq!(ctx.environment.get("API_KEY").unwrap(), "secret");
        assert_eq!(ctx.conversation_history.len(), 1);
        assert_eq!(ctx.conversation_history[0].content, "do the thing");
        assert_eq!(ctx.metadata.get("priority").unwrap(), "high");
    }

    #[test]
    fn build_task_context_defaults() {
        let ctx = build_task_context("u", None, HashMap::new(), vec![], HashMap::new());

        assert_eq!(ctx.user_id, "u");
        assert!(ctx.project_dir.is_none());
        assert!(ctx.environment.is_empty());
        assert!(ctx.conversation_history.is_empty());
        assert!(ctx.metadata.is_empty());
    }

    #[tokio::test]
    async fn pool_try_acquire_empty_returns_none() {
        let pool = WorkerConnectionPool::new(2, Duration::from_secs(60));
        assert!(
            pool.try_acquire("nanocode:ws://localhost:9090")
                .await
                .is_none()
        );
    }

    #[tokio::test]
    async fn pool_evict_stale_removes_old() {
        let pool = WorkerConnectionPool::new(2, Duration::from_millis(1));
        // Pool is empty, evict should be a no-op
        pool.evict_stale().await;
        assert_eq!(pool.pool_size().await, 0);
    }

    #[tokio::test]
    async fn pool_drain_empties_all() {
        let pool = WorkerConnectionPool::new(2, Duration::from_secs(300));
        pool.drain().await;
        assert_eq!(pool.pool_size().await, 0);
    }

    #[test]
    fn manager_initializes_load_balancers() {
        use crate::config::WorkerEndpoint;

        let mgr = ExternalWorkerManager::new(vec![ExternalWorkerConfig {
            name: "multi".to_string(),
            url: "ws://fallback:9090".to_string(),
            auth_token: None,
            timeout_ms: 300_000,
            endpoints: vec![
                WorkerEndpoint {
                    url: "ws://a:9090".to_string(),
                    auth_token: None,
                    weight: None,
                },
                WorkerEndpoint {
                    url: "ws://b:9090".to_string(),
                    auth_token: None,
                    weight: None,
                },
            ],
            load_balance: LoadBalanceStrategy::default(),
        }]);

        assert!(mgr.load_balancers.get("multi").is_some());
        let lb = mgr.load_balancers.get("multi").unwrap();
        assert_eq!(lb.endpoint_count(), 2);
        assert_eq!(lb.next_endpoint().url, "ws://a:9090");
        assert_eq!(lb.next_endpoint().url, "ws://b:9090");
        assert_eq!(lb.next_endpoint().url, "ws://a:9090");
    }
}
