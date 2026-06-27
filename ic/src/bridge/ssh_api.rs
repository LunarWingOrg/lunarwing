//! SSH Bridge API — HTTP endpoints for SSH host and key management.

use axum::{
    extract::{Path, State},
    http::StatusCode,
    Json,
    routing::{get, post},
    Router,
};
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use tokio::sync::RwLock;
use tracing::{info, instrument};
use axum::response::IntoResponse;

use crate::bridge::ssh::{
    SSHBridge, SSHHostConfig, SSHKeyType, HostKeyMode, SshBridgeError, SSHCredentials,
};
use crate::bridge::ssh_agent::SshAgentServer;
use crate::bridge::ssh_secrets::SshSecretsManager;
use crate::secrets::SecretError;
use secrecy::SecretString;

pub struct SshApiState {
    pub bridge: Arc<RwLock<SSHBridge>>,
    pub secrets: Arc<SshSecretsManager>,
    pub agent: Arc<RwLock<Option<Arc<SshAgentServer>>>>,
}

pub fn create_router(state: Arc<SshApiState>) -> Router {
    Router::new()
        .route("/hosts", get(list_hosts).post(add_host))
        .route("/hosts/{host}", get(get_host).delete(remove_host))
        .route("/hosts/{host}/key", post(upload_key).delete(delete_key))
        .route("/hosts/{host}/key/status", get(key_status))
        .route("/agent/status", get(agent_status))
        .route("/agent/keys", get(agent_keys))
        .with_state(state)
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HostRequest {
    pub host: String,
    #[serde(default = "default_port")]
    pub port: u16,
    pub user: String,
    pub key_type: SSHKeyType,
    #[serde(default)]
    pub host_key_mode: HostKeyMode,
    #[serde(default)]
    pub known_host_key: Option<String>,
}

fn default_port() -> u16 { 22 }

impl From<HostRequest> for SSHHostConfig {
    fn from(req: HostRequest) -> Self {
        SSHHostConfig {
            host: req.host, port: req.port, user: req.user, key_type: req.key_type,
            host_key_mode: req.host_key_mode, known_host_key: req.known_host_key,
            connect_timeout_secs: 10, operation_timeout_secs: 30,
            keepalive_interval_secs: 60, keepalive_max_misses: 3,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct KeyUploadRequest {
    pub key_data: String,
    #[serde(default)]
    pub passphrase: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HostResponse {
    pub host: String, pub port: u16, pub user: String,
    pub key_type: String, pub host_key_mode: String, pub has_key: bool,
}

impl From<SSHHostConfig> for HostResponse {
    fn from(config: SSHHostConfig) -> Self {
        Self { host: config.host, port: config.port, user: config.user,
            key_type: config.key_type.to_string(), host_key_mode: config.host_key_mode.to_string(), has_key: false }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentStatusResponse {
    pub running: bool, pub socket_path: Option<String>, pub keys_loaded: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ApiResponse<T> {
    pub success: bool, pub data: Option<T>, pub error: Option<String>,
}

impl<T: Serialize> ApiResponse<T> {
    pub fn success(data: T) -> Self { Self { success: true, data: Some(data), error: None } }
    pub fn error(message: String) -> Self { Self { success: false, data: None, error: Some(message) } }
}

#[instrument(skip(state))]
async fn list_hosts(State(state): State<Arc<SshApiState>>) -> Result<Json<ApiResponse<Vec<HostResponse>>>, ApiError> {
    let bridge = state.bridge.read().await;
    let hosts = bridge.list_hosts().await;
    let mut responses = Vec::new();
    for config in hosts {
        let has_key = state.secrets.key_exists(&config.host).await?;
        responses.push(HostResponse { host: config.host, port: config.port, user: config.user,
            key_type: config.key_type.to_string(), host_key_mode: config.host_key_mode.to_string(), has_key });
    }
    Ok(Json(ApiResponse::success(responses)))
}

#[instrument(skip(state))]
async fn get_host(State(state): State<Arc<SshApiState>>, Path(host): Path<String>) -> Result<Json<ApiResponse<HostResponse>>, ApiError> {
    let bridge = state.bridge.read().await;
    let config = bridge.get_host_config(&host).await?;
    let has_key = state.secrets.key_exists(&host).await?;
    Ok(Json(ApiResponse::success(HostResponse { host: config.host, port: config.port, user: config.user,
        key_type: config.key_type.to_string(), host_key_mode: config.host_key_mode.to_string(), has_key })))
}

#[instrument(skip(state))]
async fn add_host(State(state): State<Arc<SshApiState>>, Json(request): Json<HostRequest>) -> Result<Json<ApiResponse<String>>, ApiError> {
    let config = SSHHostConfig::from(request);
    let host = config.host.clone();
    let bridge = state.bridge.write().await;
    bridge.add_host(config).await?;
    info!("Added host: {}", host);
    Ok(Json(ApiResponse::success(format!("Host {} added", host))))
}

#[instrument(skip(state))]
async fn remove_host(State(state): State<Arc<SshApiState>>, Path(host): Path<String>) -> Result<Json<ApiResponse<String>>, ApiError> {
    let bridge = state.bridge.write().await;
    bridge.remove_host(&host).await?;
    info!("Removed host: {}", host);
    Ok(Json(ApiResponse::success(format!("Host {} removed", host))))
}

#[instrument(skip(state))]
async fn upload_key(State(state): State<Arc<SshApiState>>, Path(host): Path<String>, Json(request): Json<KeyUploadRequest>) -> Result<Json<ApiResponse<String>>, ApiError> {
    let key_data = request.key_data.as_bytes().to_vec();
    let passphrase = request.passphrase;

    state.secrets.store_key(&host, &key_data, passphrase.as_deref()).await?;

    {
        let agent_guard = state.agent.read().await;
        if let Some(agent) = agent_guard.as_ref() {
            let creds = SSHCredentials {
                key_data: key_data.clone().into(),
                passphrase: passphrase.map(|s| SecretString::new(s.into_boxed_str())),
            };
            agent.add_key(host.clone(), creds).await?;
        }
    }

    info!("Uploaded key for host: {}", host);
    Ok(Json(ApiResponse::success(format!("Key uploaded for {}", host))))
}

#[instrument(skip(state))]
async fn delete_key(State(state): State<Arc<SshApiState>>, Path(host): Path<String>) -> Result<Json<ApiResponse<String>>, ApiError> {
    state.secrets.delete_key(&host).await?;
    {
        let agent_guard = state.agent.read().await;
        if let Some(agent) = agent_guard.as_ref() {
            agent.remove_key(&host).await?;
        }
    }
    info!("Deleted key for host: {}", host);
    Ok(Json(ApiResponse::success(format!("Key deleted for {}", host))))
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct KeyStatusResponse { pub host: String, pub exists: bool }

#[instrument(skip(state))]
async fn key_status(State(state): State<Arc<SshApiState>>, Path(host): Path<String>) -> Result<Json<ApiResponse<KeyStatusResponse>>, ApiError> {
    let exists = state.secrets.key_exists(&host).await?;
    Ok(Json(ApiResponse::success(KeyStatusResponse { host, exists })))
}

#[instrument(skip(state))]
async fn agent_status(State(state): State<Arc<SshApiState>>) -> Result<Json<ApiResponse<AgentStatusResponse>>, ApiError> {
    let agent_guard = state.agent.read().await;
    let response = if let Some(agent) = agent_guard.as_ref() {
        let keys = agent.list_keys().await;
        AgentStatusResponse { running: true, socket_path: Some(agent.socket_path().to_string_lossy().to_string()), keys_loaded: keys.len() }
    } else {
        AgentStatusResponse { running: false, socket_path: None, keys_loaded: 0 }
    };
    Ok(Json(ApiResponse::success(response)))
}

#[instrument(skip(state))]
async fn agent_keys(State(state): State<Arc<SshApiState>>) -> Result<Json<ApiResponse<Vec<String>>>, ApiError> {
    let agent_guard = state.agent.read().await;
    let keys = if let Some(agent) = agent_guard.as_ref() { agent.list_keys().await } else { Vec::new() };
    Ok(Json(ApiResponse::success(keys)))
}

#[derive(Debug)]
pub struct ApiError { pub status: StatusCode, pub message: String }
impl std::fmt::Display for ApiError { fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result { write!(f, "{}", self.message) } }
impl std::error::Error for ApiError {}
impl From<SshBridgeError> for ApiError { fn from(err: SshBridgeError) -> Self { Self { status: StatusCode::BAD_REQUEST, message: err.to_string() } } }
impl From<SecretError> for ApiError { fn from(err: SecretError) -> Self { Self { status: StatusCode::INTERNAL_SERVER_ERROR, message: err.to_string() } } }
impl IntoResponse for ApiError {
    fn into_response(self) -> axum::response::Response {
        let body = serde_json::json!({ "success": false, "error": self.message });
        (self.status, Json(body)).into_response()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn test_host_request_conversion() {
        let request = HostRequest { host: "example.com".into(), port: 22, user: "admin".into(),
            key_type: SSHKeyType::Ed25519, host_key_mode: HostKeyMode::Strict, known_host_key: None };
        let config: SSHHostConfig = request.into();
        assert_eq!(config.host, "example.com");
    }
}
