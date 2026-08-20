//! Hook to route inbound image attachments through LunarVision before the agent
//! sees them. Implements the "augment, don't replace" model (Option B): the
//! original image stays on `message.attachments` and is delivered to the LLM as
//! multimodal input, while the hook prepends a `<lunarvision>` text block so the
//! agent gets both the machine-vision analysis *and* the raw pixels.
//!
//! See: `docs/proposals/LUNARVISION_INBOUND_HOOK.md`

use std::time::Duration;

use async_trait::async_trait;
use serde::{Deserialize, Serialize};

use crate::hooks::hook::{
    AttachmentSummary, Hook, HookContext, HookError, HookEvent, HookFailureMode, HookOutcome,
    HookPoint,
};

/// Configuration for the LunarVision inbound hook.
#[derive(Debug, Clone)]
pub struct LunarVisionHookConfig {
    /// Base URL of the per-tenant vision sidecar (e.g. `http://127.0.0.1:20015`).
    pub service_url: String,
    /// OCR language code passed to the sidecar (default: `"eng"`).
    pub ocr_lang: String,
    /// Detail level for VL descriptions (default: `"medium"`).
    pub detail_level: String,
    /// Vision mode: `"auto"` (smart routing), `"text"` (OCR only), or `"describe"`.
    pub mode: String,
}

impl Default for LunarVisionHookConfig {
    fn default() -> Self {
        Self {
            service_url: String::new(),
            ocr_lang: "eng".to_string(),
            detail_level: "medium".to_string(),
            mode: "auto".to_string(),
        }
    }
}

/// Inbound hook that routes image attachments through the LunarVision sidecar.
///
/// For each image attachment on an inbound message, this hook:
/// 1. Sends the image (base64) to `{service_url}/v1/vision/analyze`
/// 2. Collects the OCR/VL text from the response
/// 3. Prepends a `<lunarvision>` block to the message content
///
/// The original image attachment is **not** removed — it still reaches the LLM
/// as multimodal input via `augment_with_attachments`. This gives the agent both
/// the structured vision analysis and the raw pixels (Option B).
///
/// **Failure mode:** `FailOpen`. If the sidecar is unreachable, times out, or
/// returns an error, the hook returns `Continue` unmodified — the image flows
/// through as raw pixels with no vision text. Vision is an enhancement, not a
/// gate.
pub struct LunarVisionHook {
    config: LunarVisionHookConfig,
    client: reqwest::Client,
}

impl LunarVisionHook {
    /// Create a new hook. Returns `None` if `service_url` is empty (hook will
    /// not be registered).
    pub fn new(config: LunarVisionHookConfig) -> Option<Self> {
        if config.service_url.trim().is_empty() {
            return None;
        }

        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(55))
            .connect_timeout(Duration::from_secs(5))
            .build()
            .ok()?;

        Some(Self { config, client })
    }

    /// Construct from the global `VISION_SERVICE_URL` env var with defaults.
    pub fn from_env() -> Option<Self> {
        let url = crate::context::VISION_SERVICE_URL.as_deref()?;
        if url.is_empty() {
            return None;
        }
        Self::new(LunarVisionHookConfig {
            service_url: url.to_string(),
            ..Default::default()
        })
    }

    /// Call the vision sidecar for a single image attachment.
    ///
    /// Returns the analysis text on success, or an error string on failure
    /// (caller decides whether to log-and-continue or abort).
    async fn analyze_image(&self, image_b64: &str) -> Result<String, String> {
        #[derive(Serialize)]
        struct SidecarRequest<'a> {
            image: &'a str,
            mode: &'a str,
            ocr_lang: &'a str,
            detail_level: &'a str,
        }

        let endpoint = format!(
            "{}/v1/vision/analyze",
            self.config.service_url.trim_end_matches('/')
        );

        let body = SidecarRequest {
            image: image_b64,
            mode: &self.config.mode,
            ocr_lang: &self.config.ocr_lang,
            detail_level: &self.config.detail_level,
        };

        let response = self
            .client
            .post(&endpoint)
            .json(&body)
            .send()
            .await
            .map_err(|e| format!("vision request failed: {e}"))?;

        let status = response.status();
        if !status.is_success() {
            let body_text = response.text().await.unwrap_or_default();
            return Err(format!("vision sidecar HTTP {status}: {body_text}"));
        }

        // The sidecar returns JSON. We extract the text content from common
        // response shapes. The VL server's response schema varies by mode, so
        // we try several known fields.
        let data: serde_json::Value = response
            .json()
            .await
            .map_err(|e| format!("vision sidecar returned invalid JSON: {e}"))?;

        Ok(extract_vision_text(&data))
    }
}

/// Extract human-readable text from a vision sidecar JSON response.
///
/// Handles common response shapes from the LunarVision VL server:
/// - `{"text": "..."}` — OCR mode
/// - `{"description": "..."}` — describe mode
/// - `{"result": "..."}` — generic
/// - `{"analysis": "..."}` — analysis mode
/// - `{"data": {"text": "..."}}` — nested (tool output wrapper)
/// - Any string value — last resort
fn extract_vision_text(data: &serde_json::Value) -> String {
    // Direct fields (most common)
    for field in &["text", "description", "result", "analysis", "content"] {
        if let Some(s) = data.get(field).and_then(|v| v.as_str()) {
            if !s.is_empty() {
                return s.to_string();
            }
        }
    }

    // Nested under "data" (matches ToolOutput wrapper shape)
    if let Some(inner) = data.get("data") {
        for field in &["text", "description", "result", "analysis"] {
            if let Some(s) = inner.get(field).and_then(|v| v.as_str()) {
                if !s.is_empty() {
                    return s.to_string();
                }
            }
        }
    }

    // Fallback: serialize the whole thing. Better than nothing.
    serde_json::to_string_pretty(data).unwrap_or_else(|_| "<unparseable vision response>".into())
}

#[async_trait]
impl Hook for LunarVisionHook {
    fn name(&self) -> &str {
        "builtin.lunarvision_inbound"
    }

    fn hook_points(&self) -> &[HookPoint] {
        &[HookPoint::BeforeInbound]
    }

    fn failure_mode(&self) -> HookFailureMode {
        // If the sidecar is down, let the image through as raw pixels.
        // Vision is an enhancement, not a gate.
        HookFailureMode::FailOpen
    }

    fn timeout(&self) -> Duration {
        // VL inference can be slow, especially on GPU-backed Qwen3-VL.
        // The WASM tool uses 60s; we give the hook 60s total for all images
        // in a single message (bounded by the sidecar's per-request latency).
        Duration::from_secs(60)
    }

    async fn execute(
        &self,
        event: &HookEvent,
        _ctx: &HookContext,
    ) -> Result<HookOutcome, HookError> {
        let HookEvent::Inbound {
            content,
            attachments,
            ..
        } = event
        else {
            return Ok(HookOutcome::ok());
        };

        // Filter to image attachments that have data
        let image_attachments: Vec<&AttachmentSummary> = attachments
            .iter()
            .filter(|a| a.kind == "image")
            .filter(|a| a.data_b64.as_deref().is_some_and(|d| !d.is_empty()))
            .collect();

        if image_attachments.is_empty() {
            // No images to analyze — pass through unchanged
            return Ok(HookOutcome::ok());
        }

        tracing::debug!(
            hook = self.name(),
            image_count = image_attachments.len(),
            "LunarVision inbound hook processing image attachments"
        );

        // Analyze each image. Failures are logged and skipped (fail-open per
        // attachment, not all-or-nothing).
        let mut vision_blocks: Vec<String> = Vec::new();

        for (idx, attachment) in image_attachments.iter().enumerate() {
            let image_b64 = attachment.data_b64.as_deref().unwrap_or_default();
            let label = attachment
                .filename
                .as_deref()
                .unwrap_or_else(|| format!("image_{}", idx + 1));

            match self.analyze_image(image_b64).await {
                Ok(text) => {
                    tracing::debug!(
                        hook = self.name(),
                        attachment = %label,
                        text_len = text.len(),
                        "LunarVision analysis succeeded"
                    );
                    vision_blocks.push(format!(
                        "<lunarvision_analysis attachment=\"{label}\">\n{text}\n</lunarvision_analysis>"
                    ));
                }
                Err(err) => {
                    tracing::warn!(
                        hook = self.name(),
                        attachment = %label,
                        error = %err,
                        "LunarVision analysis failed for attachment (skipping, fail-open)"
                    );
                }
            }
        }

        if vision_blocks.is_empty() {
            // All analyses failed — return unmodified
            return Ok(HookOutcome::ok());
        }

        // Prepend vision blocks to the original content. The original content
        // is preserved intact; the agent sees the analysis as additional
        // context before the user's message.
        let vision_section = vision_blocks.join("\n\n");
        let new_content = if content.is_empty() {
            vision_section
        } else {
            format!("{vision_section}\n\n{content}")
        };

        Ok(HookOutcome::modify(new_content))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extract_vision_text_direct_field() {
        let data = serde_json::json!({"text": "Hello world"});
        assert_eq!(extract_vision_text(&data), "Hello world");
    }

    #[test]
    fn extract_vision_text_description_field() {
        let data = serde_json::json!({"description": "A cat sitting on a chair"});
        assert_eq!(extract_vision_text(&data), "A cat sitting on a chair");
    }

    #[test]
    fn extract_vision_text_nested_data() {
        let data = serde_json::json!({"status": "success", "data": {"text": "Nested text"}});
        assert_eq!(extract_vision_text(&data), "Nested text");
    }

    #[test]
    fn extract_vision_text_empty_string_falls_through() {
        let data = serde_json::json!({"text": "", "description": "Real content"});
        assert_eq!(extract_vision_text(&data), "Real content");
    }

    #[test]
    fn lunarvision_hook_new_rejects_empty_url() {
        assert!(LunarVisionHook::new(LunarVisionHookConfig::default()).is_none());
    }

    #[test]
    fn lunarvision_hook_new_accepts_valid_url() {
        let hook = LunarVisionHook::new(LunarVisionHookConfig {
            service_url: "http://127.0.0.1:20015".to_string(),
            ..Default::default()
        });
        assert!(hook.is_some());
        let hook = hook.unwrap();
        assert_eq!(hook.name(), "builtin.lunarvision_inbound");
        assert_eq!(hook.hook_points(), &[HookPoint::BeforeInbound]);
        assert_eq!(hook.failure_mode(), HookFailureMode::FailOpen);
        assert_eq!(hook.timeout(), Duration::from_secs(60));
    }
}
