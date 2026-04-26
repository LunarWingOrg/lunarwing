use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ConfigureRequest {
    pub jid: String,
    pub password: String,
    #[serde(default)]
    pub dm_policy: String,
    #[serde(default)]
    pub allow_from: Vec<String>,
    #[serde(default)]
    pub allow_rooms: Vec<String>,
    #[serde(default)]
    pub encrypted_rooms: Vec<String>,
    #[serde(default)]
    pub device_id: u32,
    pub omemo_store_dir: Option<String>,
    #[serde(default = "default_true")]
    pub allow_plaintext_fallback: bool,
    #[serde(default)]
    pub max_messages_per_hour: u32,
    pub resource: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ConfigureResponse {
    pub configured: bool,
    pub running: bool,
    pub jid: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct BridgeMessage {
    pub message_id: String,
    pub user_id: String,
    pub user_name: Option<String>,
    pub content: String,
    pub thread_id: Option<String>,
    pub metadata_json: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
pub struct MessagesQuery {
    pub cursor: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
pub struct MessagesResponse {
    #[serde(default)]
    pub cursor: u64,
    #[serde(default)]
    pub messages: Vec<BridgeMessage>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct OutboundRateLimitRequest {
    pub max_messages_per_hour: Option<u32>,
    #[serde(default)]
    pub reset_counter: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct OutboundRateLimitResponse {
    pub configured: bool,
    pub running: bool,
    pub configured_max_messages_per_hour: u32,
    pub active_max_messages_per_hour: u32,
    pub outbound_messages_last_hour: usize,
    pub reset_counter_applied: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SendRequest {
    pub target: String,
    pub content: String,
    pub metadata_json: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
pub struct BridgeStatusResponse {
    #[serde(default)]
    pub configured: bool,
    #[serde(default)]
    pub running: bool,
    #[serde(default)]
    pub current_cursor: u64,
    #[serde(default)]
    pub queued_messages: usize,
    pub jid: Option<String>,
    #[serde(default)]
    pub configured_rooms: Vec<String>,
    #[serde(default)]
    pub rooms_with_presence: Vec<String>,
    #[serde(default)]
    pub configured_max_messages_per_hour: u32,
    #[serde(default)]
    pub active_max_messages_per_hour: u32,
    #[serde(default)]
    pub outbound_messages_last_hour: usize,
    #[serde(default)]
    pub outbound_rate_limit_overridden: bool,
    #[serde(default)]
    pub omemo_enabled: bool,
    pub device_id: Option<u32>,
    pub fingerprint: Option<String>,
    #[serde(default)]
    pub bundle_published: bool,
    #[serde(default)]
    pub prekeys_available: usize,
    pub migration_state: Option<String>,
    pub last_omemo_error: Option<String>,
    #[serde(default)]
    pub encrypted_rooms_total: usize,
    #[serde(default)]
    pub encrypted_rooms_ready: usize,
    pub last_room_error: Option<String>,
}

const fn default_true() -> bool {
    true
}
