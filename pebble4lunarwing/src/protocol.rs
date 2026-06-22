use serde::{Deserialize, Serialize};
use std::time::{SystemTime, UNIX_EPOCH};

pub const SUBPROTOCOL: &str = "ironclaw-agent-v1";
pub const WORKER_VERSION: &str = "pebble-worker-0.1.0";
pub const DEFAULT_TIMEOUT_MS: u64 = 300_000;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Envelope {
    pub id: String,
    #[serde(rename = "type")]
    pub msg_type: String,
    pub timestamp: String,
    pub payload: serde_json::Value,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReadyPayload {
    pub worker_id: String,
    pub version: String,
    pub mode: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct TaskContext {
    pub project_dir: Option<String>,
    pub conversation_history: Vec<ConversationMessage>,
    pub environment: std::collections::HashMap<String, String>,
    pub user_id: String,
    pub metadata: std::collections::HashMap<String, String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConversationMessage {
    pub role: String,
    pub content: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskRequest {
    pub task_id: String,
    pub prompt: String,
    #[serde(default)]
    pub context: TaskContext,
    pub timeout_ms: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskProgress {
    pub task_id: String,
    pub delta: String,
    pub done: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskResult {
    pub task_id: String,
    pub status: String,
    pub output: String,
    pub error: Option<String>,
    pub duration_ms: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[allow(dead_code)]
pub struct CancelPayload {
    pub task_id: String,
}

pub fn envelope_id() -> String {
    let ts = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let rand: u64 = {
        use std::collections::hash_map::RandomState;
        use std::hash::{BuildHasher, Hasher};
        let mut hasher = RandomState::new().build_hasher();
        hasher.write_u128(ts);
        hasher.finish()
    };
    format!("{ts:x}-{rand:x}")
}

pub fn iso_timestamp() -> String {
    let d = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    let secs = d.as_secs();
    let millis = d.subsec_millis();
    format!("{secs}.{millis:03}Z")
}

pub fn create_envelope(msg_type: &str, payload: impl Serialize) -> Envelope {
    Envelope {
        id: envelope_id(),
        msg_type: msg_type.to_string(),
        timestamp: iso_timestamp(),
        payload: serde_json::to_value(payload).unwrap_or_default(),
    }
}

pub fn ready_envelope(worker_id: &str) -> Envelope {
    create_envelope(
        "ready",
        ReadyPayload {
            worker_id: worker_id.to_string(),
            version: WORKER_VERSION.to_string(),
            mode: "websocket".to_string(),
        },
    )
}

pub fn progress_envelope(task_id: &str, delta: &str) -> Envelope {
    create_envelope(
        "task_progress",
        TaskProgress {
            task_id: task_id.to_string(),
            delta: delta.to_string(),
            done: false,
        },
    )
}

pub fn result_envelope(
    task_id: &str,
    status: &str,
    output: &str,
    error: Option<&str>,
    duration_ms: u64,
) -> Envelope {
    create_envelope(
        "task_result",
        TaskResult {
            task_id: task_id.to_string(),
            status: status.to_string(),
            output: output.to_string(),
            error: error.map(ToString::to_string),
            duration_ms,
        },
    )
}

pub fn pong_envelope() -> Envelope {
    create_envelope("pong", serde_json::json!({}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn envelope_round_trips_through_json() {
        let env = ready_envelope("test-worker");
        let json = serde_json::to_string(&env).unwrap();
        let parsed: Envelope = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.msg_type, "ready");
        let payload: ReadyPayload = serde_json::from_value(parsed.payload).unwrap();
        assert_eq!(payload.worker_id, "test-worker");
        assert_eq!(payload.version, WORKER_VERSION);
        assert_eq!(payload.mode, "websocket");
    }

    #[test]
    fn progress_envelope_serializes_correctly() {
        let env = progress_envelope("task-123", "building...");
        let json = serde_json::to_string(&env).unwrap();
        let parsed: Envelope = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.msg_type, "task_progress");
        let payload: TaskProgress = serde_json::from_value(parsed.payload).unwrap();
        assert_eq!(payload.task_id, "task-123");
        assert_eq!(payload.delta, "building...");
        assert!(!payload.done);
    }

    #[test]
    fn result_envelope_serializes_correctly() {
        let env = result_envelope("task-123", "success", "all done", None, 1234);
        let json = serde_json::to_string(&env).unwrap();
        let parsed: Envelope = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.msg_type, "task_result");
        let payload: TaskResult = serde_json::from_value(parsed.payload).unwrap();
        assert_eq!(payload.task_id, "task-123");
        assert_eq!(payload.status, "success");
        assert_eq!(payload.output, "all done");
        assert!(payload.error.is_none());
        assert_eq!(payload.duration_ms, 1234);
    }

    #[test]
    fn result_envelope_with_error() {
        let env = result_envelope("task-456", "error", "", Some("timeout"), 5000);
        let payload: TaskResult = serde_json::from_value(env.payload).unwrap();
        assert_eq!(payload.status, "error");
        assert_eq!(payload.error.as_deref(), Some("timeout"));
    }

    #[test]
    fn task_request_deserializes_from_agent_format() {
        let json = r#"{
            "task_id": "abc-123",
            "prompt": "fix the bug",
            "context": {},
            "timeout_ms": 60000
        }"#;
        let req: TaskRequest = serde_json::from_str(json).unwrap();
        assert_eq!(req.task_id, "abc-123");
        assert_eq!(req.prompt, "fix the bug");
        assert_eq!(req.timeout_ms, Some(60000));
    }

    #[test]
    fn task_request_works_without_optional_fields() {
        let json = r#"{"task_id": "x", "prompt": "hello"}"#;
        let req: TaskRequest = serde_json::from_str(json).unwrap();
        assert_eq!(req.task_id, "x");
        assert!(req.timeout_ms.is_none());
    }

    #[test]
    fn task_request_extended_context() {
        let json = r#"{
            "task_id": "ext-1",
            "prompt": "deploy it",
            "context": {
                "project_dir": "/workspace/myproject",
                "environment": {"API_KEY": "secret123", "DEBUG": "1"},
                "user_id": "user-42",
                "conversation_history": [
                    {"role": "user", "content": "please deploy"},
                    {"role": "assistant", "content": "on it"}
                ],
                "metadata": {"priority": "high"}
            },
            "timeout_ms": 120000
        }"#;
        let req: TaskRequest = serde_json::from_str(json).unwrap();
        assert_eq!(req.task_id, "ext-1");
        assert_eq!(
            req.context.project_dir.as_deref(),
            Some("/workspace/myproject")
        );
        assert_eq!(req.context.environment.get("API_KEY").unwrap(), "secret123");
        assert_eq!(req.context.environment.get("DEBUG").unwrap(), "1");
        assert_eq!(req.context.user_id, "user-42");
        assert_eq!(req.context.conversation_history.len(), 2);
        assert_eq!(req.context.metadata.get("priority").unwrap(), "high");
    }

    #[test]
    fn task_request_empty_context_backward_compat() {
        let json = r#"{
            "task_id": "old-1",
            "prompt": "do stuff",
            "context": {}
        }"#;
        let req: TaskRequest = serde_json::from_str(json).unwrap();
        assert!(req.context.project_dir.is_none());
        assert!(req.context.environment.is_empty());
        assert!(req.context.conversation_history.is_empty());
        assert_eq!(req.context.user_id, "");
        assert!(req.context.metadata.is_empty());
    }
}
