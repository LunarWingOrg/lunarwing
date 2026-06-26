//! SSH Bridge API — HTTP endpoints for SSH host and key management.
//!
//! This module provides RESTful API endpoints for managing SSH hosts and keys
//! through the SSH bridge.
//!
//! # Endpoints
//!
//! ## Hosts
//!
//! - `GET /api/ssh/hosts` — List all configured hosts
//! - `GET /api/ssh/hosts/:host` — Get host configuration
//! - `POST /api/ssh/hosts` — Add a new host
//! - `DELETE /api/ssh/hosts/:host` — Remove a host
//!
//! ## Keys
//!
//! - `POST /api/ssh/hosts/:host/key` — Upload SSH key for a host
//! - `DELETE /api/ssh/hosts/:host/key` — Delete SSH key for a host
//! - `GET /api/ssh/hosts/:host/key/status` — Check if key exists
//!
//! ## Agent
//!
//! - `GET /api/ssh/agent/status` — Get agent server status
//! - `GET /api/ssh/agent/keys` — List keys loaded in agent
//!
//! # Example Usage
//!
//! ```bash
//! # Add a host
//! curl -X POST http://localhost:8080/api/ssh/hosts \
//!   -H "Content-Type: application/json" \
//!   -d '{
//!     "host": "prod.example.com",
//!     "port": 22,
//!     "user": "deploy",
//!     "key_type": "ed25519"
//!   }'
//!
//! # Upload key
//! curl -X POST http://localhost:8080/api/ssh/hosts/prod.example.com/key \
//!   -H "Content-Type: application/json" \
//!   -d '{
//!     "key_data": "-----BEGIN OPENSSH PRIVATE KEY-----\n...\n-----END OPENSSH PRIVATE KEY-----",
//!     "passphrase": null
//!   }'
//!
//! # List hosts
//! curl http://localhost:8080/api/ssh/hosts
//! ```

use axum::{
    extract::{Path, State},
    http::StatusCode,
    Json,
    routing::{delete, get, post},
    Router,
};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::RwLock;
use tracing::{info, warn, instrument};
use axum::response::IntoResponse;

use crate::bridge::ssh::{
    SSHBridge, SSHHostConfig, SSHKeyType, HostKeyMode, SshBridgeError,
    SSHCredentials,
};
use crate::bridge::ssh_agent::SshAgentServer;
use crate::bridge::ssh_secrets::SshSecretsManager;
use crate::secrets::types::SecretError;

/// API state — holds references to the SSH bridge components.
pub struct SshApiState {
    /// SSH bridge instance
    pub bridge: Arc<RwLock<SSHBridge>>,
    /// SSH secrets manager
    pub secrets: Arc<SshSecretsManager>,
    /// SSH agent server (if running)
    pub agent: Arc<RwLock<Option<Arc<SshAgentServer>>>>,
}

/// API router for SSH endpoints.
pub fn create_router(state: Arc<SshApiState>) -> Router {
    Router::new()
        .route("/hosts", get(list_hosts).post(add_host))
        .route("/hosts/:host", get(get_host).delete(remove_host))
        .route("/hosts/:host/key", post(upload_key).delete(delete_key))
        .route("/hosts/:host/key/status", get(key_status))
        .route("/agent/status", get(agent_status))
        .route("/agent/keys", get(agent_keys))
        .with_state(state)
}

// ============================================================================
// Request/Response Types
// ============================================================================

/// Host configuration for API requests.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HostRequest {
    /// Hostname or IP address
    pub host: String,
    /// SSH port (default: 22)
    #[serde(default = "default_port")]
    pub port: u16,
    /// Username to connect as
    pub user: String,
    /// Key type (ed25519, ecdsa, rsa)
    pub key_type: SSHKeyType,
    /// Host key verification mode (Strict, AcceptFirst)
    #[serde(default)]
    pub host_key_mode: HostKeyMode,
    /// Known host key (optional, for Strict mode)
    #[serde(default)]
    pub known_host_key: Option<String>,
}

fn default_port() -> u16 { 22 }

impl From<HostRequest> for SSHHostConfig {
    fn from(req: HostRequest) -> Self {
        SSHHostConfig {
            host: req.host,
            port: req.port,
            user: req.user,
            key_type: req.key_type,
            host_key_mode: req.host_key_mode,
            known_host_key: req.known_host_key,
            connect_timeout_secs: 10,
            operation_timeout_secs: 30,
            keepalive_interval_secs: 60,
            keepalive_max_misses: 3,
        }
    }
}

/// SSH key upload request.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct KeyUploadRequest {
    /// Key data (PEM or OpenSSH format)
    pub key_data: String,
    /// Optional passphrase if key is encrypted
    #[serde(default)]
    pub passphrase: Option<String>,
}

/// Host configuration response.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HostResponse {
    pub host: String,
    pub port: u16,
    pub user: String,
    pub key_type: String,
    pub host_key_mode: String,
    pub has_key: bool,
}

impl From<SSHHostConfig> for HostResponse {
    fn from(config: SSHHostConfig) -> Self {
        Self {
            host: config.host,
            port: config.port,
            user: config.user,
            key_type: config.key_type.to_string(),
            host_key_mode: config.host_key_mode.to_string(),
            has_key: false,
        }
    }
}

/// Agent status response.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentStatusResponse {
    pub running: bool,
    pub socket_path: Option<String>,
    pub keys_loaded: usize,
}

/// Generic API response.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ApiResponse<T> {
    pub success: bool,
    pub data: Option<T>,
    pub error: Option<String>,
}

impl<T: Serialize> ApiResponse<T> {
    pub fn success(data: T) -> Self {
        Self {
            success: true,
            data: Some(data),
            error: None,
        }
    }

    pub fn error(message: String) -> Self {
        Self {
            success: false,
            data: None,
            error: Some(message),
        }
    }
}

// ============================================================================
// Host Endpoints
// ============================================================================

/// GET /api/ssh/hosts — List all configured hosts.
#[instrument(skip(state))]
async fn list_hosts(
    State(state): State<Arc<SshApiState>>,
) -> Result<Json<ApiResponse<Vec<HostResponse>>>, ApiError> {
    let bridge = state.bridge.read().await;
    let hosts = bridge.list_hosts().await;

    let mut responses = Vec::new();
    for config in hosts {
        let has_key = state.secrets.key_exists(&config.host).await?;
        responses.push(HostResponse {
            host: config.host,
            port: config.port,
            user: config.user,
            key_type: config.key_type.to_string(),
            host_key_mode: config.host_key_mode.to_string(),
            has_key,
        });
    }

    Ok(Json(ApiResponse::success(responses)))
}

/// GET /api/ssh/hosts/:host — Get host configuration.
#[instrument(skip(state))]
async fn get_host(
    State(state): State<Arc<SshApiState>>,
    Path(host): Path<String>,
) -> Result<Json<ApiResponse<HostResponse>>, ApiError> {
    let bridge = state.bridge.read().await;
    let config = bridge.get_host_config(&host).await?;

    let has_key = state.secrets.key_exists(&host).await?;
    let response = HostResponse {
        host: config.host,
        port: config.port,
        user: config.user,
        key_type: config.key_type.to_string(),
        host_key_mode: config.host_key_mode.to_string(),
        has_key,
    };

    Ok(Json(ApiResponse::success(response)))
}

/// POST /api/ssh/hosts — Add a new host.
#[instrument(skip(state))]
async fn add_host(
    State(state): State<Arc<SshApiState>>,
    Json(request): Json<HostRequest>,
) -> Result<Json<ApiResponse<String>>, ApiError> {
    let config = SSHHostConfig::from(request);
    let host = config.host.clone();

    let mut bridge = state.bridge.write().await;
    bridge.add_host(config).await?;

    info!("Added host: {}", host);
    Ok(Json(ApiResponse::success(format!("Host {} added", host))))
}

/// DELETE /api/ssh/hosts/:host — Remove a host.
#[instrument(skip(state))]
async fn remove_host(
    State(state): State<Arc<SshApiState>>,
    Path(host): Path<String>,
) -> Result<Json<ApiResponse<String>>, ApiError> {
    let mut bridge = state.bridge.write().await;
    bridge.remove_host(&host).await?;

    info!("Removed host: {}", host);
    Ok(Json(ApiResponse::success(format!("Host {} removed", host))))
}

// ============================================================================
// Key Endpoints
// ============================================================================

/// POST /api/ssh/hosts/:host/key — Upload SSH key for a host.
#[instrument(skip(state))]
async fn upload_key(
    State(state): State<Arc<SshApiState>>,
    Path(host): Path<String>,
    Json(request): Json<KeyUploadRequest>,
) -> Result<Json<ApiResponse<String>>, ApiError> {
    let key_data = request.key_data.as_bytes().to_vec();
    let passphrase = request.passphrase;

    // Store the key in secrets
    state.secrets.store_key(&host, &key_data, passphrase.as_deref()).await?;

    // If agent is running, add key to agent
    {
        let agent_guard = state.agent.read().await;
        if let Some(agent) = agent_guard.as_ref() {
            let creds = SSHCredentials {
                key_data: key_data.clone(),
                passphrase: passphrase.clone(),
            };
            agent.add_key(host.clone(), creds).await?;
        }
    }

    info!("Uploaded key for host: {}", host);
    Ok(Json(ApiResponse::success(format!("Key uploaded for {}", host))))
}

/// DELETE /api/ssh/hosts/:host/key — Delete SSH key for a host.
#[instrument(skip(state))]
async fn delete_key(
    State(state): State<Arc<SshApiState>>,
    Path(host): Path<String>,
) -> Result<Json<ApiResponse<String>>, ApiError> {
    // Remove from secrets
    state.secrets.delete_key(&host).await?;

    // Remove from agent if running
    {
        let agent_guard = state.agent.read().await;
        if let Some(agent) = agent_guard.as_ref() {
            agent.remove_key(&host).await?;
        }
    }

    info!("Deleted key for host: {}", host);
    Ok(Json(ApiResponse::success(format!("Key deleted for {}", host))))
}

/// GET /api/ssh/hosts/:host/key/status — Check if key exists.
#[instrument(skip(state))]
async fn key_status(
    State(state): State<Arc<SshApiState>>,
    Path(host): Path<String>,
) -> Result<Json<ApiResponse<KeyStatusResponse>>, ApiError> {
    let exists = state.secrets.key_exists(&host).await?;

    Ok(Json(ApiResponse::success(KeyStatusResponse {
        host,
        exists,
    })))
}

/// Key status response.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct KeyStatusResponse {
    pub host: String,
    pub exists: bool,
}

// ============================================================================
// Agent Endpoints
// ============================================================================

/// GET /api/ssh/agent/status — Get agent server status.
#[instrument(skip(state))]
async fn agent_status(
    State(state): State<Arc<SshApiState>>,
) -> Result<Json<ApiResponse<AgentStatusResponse>>, ApiError> {
    let agent_guard = state.agent.read().await;

    let response = if let Some(agent) = agent_guard.as_ref() {
        let keys = agent.list_keys().await;
        AgentStatusResponse {
            running: true,
            socket_path: Some(agent.socket_path().to_string_lossy().to_string()),
            keys_loaded: keys.len(),
        }
    } else {
        AgentStatusResponse {
            running: false,
            socket_path: None,
            keys_loaded: 0,
        }
    };

    Ok(Json(ApiResponse::success(response)))
}

/// GET /api/ssh/agent/keys — List keys loaded in agent.
#[instrument(skip(state))]
async fn agent_keys(
    State(state): State<Arc<SshApiState>>,
) -> Result<Json<ApiResponse<Vec<String>>>, ApiError> {
    let agent_guard = state.agent.read().await;

    let keys = if let Some(agent) = agent_guard.as_ref() {
        agent.list_keys().await
    } else {
        Vec::new()
    };

    Ok(Json(ApiResponse::success(keys)))
}

// ============================================================================
// Error Handling
// ============================================================================

/// API error type.
#[derive(Debug)]
pub struct ApiError {
    pub status: StatusCode,
    pub message: String,
}

impl std::fmt::Display for ApiError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.message)
    }
}

impl std::error::Error for ApiError {}

impl From<SshBridgeError> for ApiError {
    fn from(err: SshBridgeError) -> Self {
        Self {
            status: StatusCode::BAD_REQUEST,
            message: err.to_string(),
        }
    }
}

impl From<SecretError> for ApiError {
    fn from(err: SecretError) -> Self {
        Self {
            status: StatusCode::INTERNAL_SERVER_ERROR,
            message: err.to_string(),
        }
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> axum::response::Response {
        let body = serde_json::json!({
            "success": false,
            "error": self.message
        });

        (self.status, Json(body)).into_response()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_host_request_conversion() {
        let request = HostRequest {
            host: "example.com".to_string(),
            port: 22,
            user: "admin".to_string(),
            key_type: SSHKeyType::Ed25519,
            host_key_mode: HostKeyMode::Strict,
            known_host_key: None,
        };

        let config: SSHHostConfig = request.into();
        assert_eq!(config.host, "example.com");
        assert_eq!(config.user, "admin");
        assert_eq!(config.key_type, SSHKeyType::Ed25519);
    }

    #[test]
    fn test_api_response_success() {
        let response = ApiResponse::success("test");
        assert!(response.success);
        assert_eq!(response.data, Some("test"));
        assert!(response.error.is_none());
    }

    #[test]
    fn test_api_response_error() {
        let response = ApiResponse::<()>::error("test error".to_string());
        assert!(!response.success);
        assert!(response.data.is_none());
        assert_eq!(response.error, Some("test error".to_string()));
    }
}
