//! Core hook types and traits.

use std::time::Duration;

use async_trait::async_trait;
use base64::Engine;
use serde::{Deserialize, Serialize};

/// Points in the agent lifecycle where hooks can be attached.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum HookPoint {
    /// Before processing an inbound user message.
    BeforeInbound,
    /// Before executing a tool call.
    BeforeToolCall,
    /// Before sending an outbound response.
    BeforeOutbound,
    /// When a new session starts.
    OnSessionStart,
    /// When a session ends (pruned or expired).
    OnSessionEnd,
    /// Transform the final response before completing a turn.
    TransformResponse,
}

impl HookPoint {
    /// Human-readable hook point identifier.
    pub fn as_str(&self) -> &'static str {
        match self {
            HookPoint::BeforeInbound => "beforeInbound",
            HookPoint::BeforeToolCall => "beforeToolCall",
            HookPoint::BeforeOutbound => "beforeOutbound",
            HookPoint::OnSessionStart => "onSessionStart",
            HookPoint::OnSessionEnd => "onSessionEnd",
            HookPoint::TransformResponse => "transformResponse",
        }
    }
}

/// Contextual data carried with each hook invocation.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum HookEvent {
    /// An inbound user message about to be processed.
    Inbound {
        user_id: String,
        channel: String,
        content: String,
        /// Attachments on the inbound message, if any. Populated by the agent
        /// loop so hooks (e.g. LunarVision) can inspect image/document
        /// attachments before the message reaches the LLM.
        attachments: Vec<AttachmentSummary>,
        thread_id: Option<String>,
    },
    /// A tool call about to be executed.
    ToolCall {
        tool_name: String,
        parameters: serde_json::Value,
        user_id: String,
        /// "chat" for interactive, or a job ID string for autonomous jobs.
        context: String,
    },
    /// An outbound response about to be sent.
    Outbound {
        user_id: String,
        channel: String,
        content: String,
        thread_id: Option<String>,
    },
    /// A new session was created.
    SessionStart { user_id: String, session_id: String },
    /// A session was ended (pruned).
    SessionEnd { user_id: String, session_id: String },
    /// The final response is being transformed before completing a turn.
    ResponseTransform {
        user_id: String,
        thread_id: String,
        response: String,
    },
}

impl HookEvent {
    /// Returns the [`HookPoint`] this event corresponds to.
    pub fn hook_point(&self) -> HookPoint {
        match self {
            HookEvent::Inbound { .. } => HookPoint::BeforeInbound,
            HookEvent::ToolCall { .. } => HookPoint::BeforeToolCall,
            HookEvent::Outbound { .. } => HookPoint::BeforeOutbound,
            HookEvent::SessionStart { .. } => HookPoint::OnSessionStart,
            HookEvent::SessionEnd { .. } => HookPoint::OnSessionEnd,
            HookEvent::ResponseTransform { .. } => HookPoint::TransformResponse,
        }
    }

    /// Apply a modification string to the event's primary content field.
    pub fn apply_modification(&mut self, modified: &str) {
        match self {
            HookEvent::Inbound { content, .. } | HookEvent::Outbound { content, .. } => {
                *content = modified.to_string();
            }
            HookEvent::ToolCall { parameters, .. } => match serde_json::from_str(modified) {
                Ok(parsed) => *parameters = parsed,
                Err(e) => {
                    tracing::warn!(
                        "Hook returned non-JSON modification for ToolCall, ignoring: {}",
                        e
                    );
                }
            },
            HookEvent::ResponseTransform { response, .. } => {
                *response = modified.to_string();
            }
            HookEvent::SessionStart { .. } | HookEvent::SessionEnd { .. } => {
                // Session events don't have modifiable content
            }
        }
    }
}

/// The result of executing a hook.
#[derive(Debug, Clone)]
pub enum HookOutcome {
    /// Continue processing, optionally with modified content.
    Continue {
        /// If `Some`, replace the event's primary content with this value.
        modified: Option<String>,
    },
    /// Reject the event entirely.
    Reject {
        /// Human-readable reason for the rejection.
        reason: String,
    },
}

impl HookOutcome {
    /// Shorthand for `Continue { modified: None }`.
    pub fn ok() -> Self {
        HookOutcome::Continue { modified: None }
    }

    /// Shorthand for `Continue { modified: Some(value) }`.
    pub fn modify(value: String) -> Self {
        HookOutcome::Continue {
            modified: Some(value),
        }
    }

    /// Shorthand for `Reject { reason }`.
    pub fn reject(reason: impl Into<String>) -> Self {
        HookOutcome::Reject {
            reason: reason.into(),
        }
    }
}

/// How to handle hook execution failures.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum HookFailureMode {
    /// On error/timeout, continue processing as if the hook returned `ok()`.
    FailOpen,
    /// On error/timeout, reject the event.
    FailClosed,
}

/// Hook execution errors.
#[derive(Debug, thiserror::Error)]
pub enum HookError {
    #[error("Hook execution failed: {reason}")]
    ExecutionFailed { reason: String },

    #[error("Hook timed out after {timeout:?}")]
    Timeout { timeout: Duration },

    #[error("Hook rejected: {reason}")]
    Rejected { reason: String },
}

/// A lightweight, serializable summary of an attachment on an inbound message.
///
/// Carried on [`HookEvent::Inbound`] so hooks (e.g. LunarVision) can inspect
/// attachments without owning the full `IncomingAttachment` (which includes
/// raw bytes). The `data_b64` field is populated only for small images that
/// the channel has already downloaded; for large or un-downloaded attachments
/// it is `None` and the hook must use `source_url` if it needs the bytes.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AttachmentSummary {
    /// What kind of content this is: `"image"`, `"audio"`, or `"document"`.
    pub kind: String,
    /// MIME type (e.g. `"image/jpeg"`, `"audio/ogg"`, `"application/pdf"`).
    pub mime_type: String,
    /// Original filename, if known.
    pub filename: Option<String>,
    /// File size in bytes, if known.
    pub size_bytes: Option<u64>,
    /// URL to download the file from the channel's API, if available.
    pub source_url: Option<String>,
    /// Base64-encoded raw file data, populated for small files already in memory.
    /// `None` for large attachments or those not yet downloaded.
    pub data_b64: Option<String>,
    /// Text already extracted from this attachment (e.g. audio transcript, PDF
    /// text). Empty if no extraction has been performed.
    pub extracted_text: Option<String>,
}

impl AttachmentSummary {
    /// Build a summary from a full `IncomingAttachment`, base64-encoding the
    /// data field if it is non-empty.
    pub fn from_incoming(
        attachment: &crate::channels::IncomingAttachment,
    ) -> Self {
        let kind = match attachment.kind {
            crate::channels::AttachmentKind::Audio => "audio",
            crate::channels::AttachmentKind::Image => "image",
            crate::channels::AttachmentKind::Document => "document",
        };
        let data_b64 = if attachment.data.is_empty() {
            None
        } else {
            Some(base64::engine::general_purpose::STANDARD.encode(&attachment.data))
        };

        Self {
            kind: kind.to_string(),
            mime_type: attachment.mime_type.clone(),
            filename: attachment.filename.clone(),
            size_bytes: attachment.size_bytes,
            source_url: attachment.source_url.clone(),
            data_b64,
            extracted_text: attachment.extracted_text.clone(),
        }
    }
}

/// Contextual data carried with each hook invocation.
pub struct HookContext {
    /// Arbitrary metadata hooks can use.
    pub metadata: serde_json::Value,
}

impl Default for HookContext {
    fn default() -> Self {
        Self {
            metadata: serde_json::Value::Null,
        }
    }
}

/// Trait for implementing lifecycle hooks.
///
/// Hooks intercept and can modify agent operations at well-defined points.
#[async_trait]
pub trait Hook: Send + Sync {
    /// A unique name for this hook.
    fn name(&self) -> &str;

    /// The lifecycle points this hook should be called at.
    fn hook_points(&self) -> &[HookPoint];

    /// How to handle failures in this hook.
    ///
    /// Default: `FailOpen` (continue on error).
    fn failure_mode(&self) -> HookFailureMode {
        HookFailureMode::FailOpen
    }

    /// Maximum time this hook is allowed to run.
    ///
    /// Default: 5 seconds.
    fn timeout(&self) -> Duration {
        Duration::from_secs(5)
    }

    /// Execute the hook.
    async fn execute(&self, event: &HookEvent, ctx: &HookContext)
    -> Result<HookOutcome, HookError>;
}
