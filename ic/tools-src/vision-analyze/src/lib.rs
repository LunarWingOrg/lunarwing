//! Vision Analysis WASM Tool for IronClaw.
//!
//! Thin client that forwards image analysis requests to the LunarWing
//! Vision Service (OCR sidecar). Does one HTTP call and returns the result.
//!
//! # Design Principles
//!
//! - No `std::env::var()` — WASM sandbox has no env access
//! - No `std::thread::sleep()` — WASM sandbox has no threads
//! - No auth logic — host injects credentials at HTTP boundary
//! - No retry — fail fast; retries belong in the host/agent layer
//! - Strict URL allowlist — localhost sidecar only

wit_bindgen::generate!({
    world: "sandboxed-tool",
    path: "../../wit/tool.wit",
});

use serde::{Deserialize, Serialize};

// ── Constants ───────────────────────────────────────────────────────────────

const DEFAULT_VISION_URL: &str = "http://127.0.0.1:8088";
const MAX_IMAGE_SIZE: usize = 10 * 1024 * 1024; // 10MB

/// Allowed loopback hosts for the vision service URL (host portion, sans port).
/// Any port is accepted — per-tenant sidecars bind distinct loopback ports.
/// External/LAN hosts are rejected; the loopback-only security property is preserved.
/// IPv6 literals are stored without brackets to match the daemon's capabilities
/// normalization (allowlist.rs strips [] before matching).
const ALLOWED_HOSTS: &[&str] = &[
    "127.0.0.1",
    "localhost",
    "host.containers.internal",
    "::1",
];

// ── Types ───────────────────────────────────────────────────────────────────

#[derive(Debug, Deserialize)]
struct VisionRequest {
    /// Base64-encoded image, or a workspace file path.
    image: Option<String>,
    /// Workspace file path to read image from.
    file_path: Option<String>,
    /// Analysis mode: "text" (OCR), "describe" (VL), "auto" (smart routing).
    #[serde(default = "default_mode")]
    mode: String,
    /// Optional prompt for VL queries.
    #[serde(default)]
    prompt: Option<String>,
    /// OCR language (default: "eng").
    #[serde(default = "default_lang")]
    ocr_lang: String,
    /// Detail level for VL: "low", "medium", "high".
    #[serde(default = "default_detail")]
    detail_level: String,
    /// Vision service URL (must be on the localhost allowlist).
    #[serde(default = "default_url")]
    service_url: String,
}

fn default_mode() -> String { "auto".to_string() }
fn default_lang() -> String { "eng".to_string() }
fn default_detail() -> String { "medium".to_string() }
fn default_url() -> String { DEFAULT_VISION_URL.to_string() }

#[derive(Debug, Serialize)]
struct SidecarRequest {
    image: String,
    mode: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    prompt: Option<String>,
    ocr_lang: String,
    detail_level: String,
}

#[derive(Debug, Serialize)]
struct OcrOnlyRequest {
    image: String,
    ocr_lang: String,
}

#[derive(Debug, Serialize)]
struct ToolOutput {
    status: String,
    endpoint: String,
    #[serde(flatten)]
    data: serde_json::Value,
}

// ── Tool Implementation ─────────────────────────────────────────────────────

struct VisionAnalyzeTool;

impl exports::near::agent::tool::Guest for VisionAnalyzeTool {
    fn execute(req: exports::near::agent::tool::Request) -> exports::near::agent::tool::Response {
        match execute_inner(&req.params, req.context.as_deref()) {
            Ok(output) => exports::near::agent::tool::Response {
                output: Some(output),
                error: None,
            },
            Err(e) => exports::near::agent::tool::Response {
                output: None,
                error: Some(e),
            },
        }
    }

    fn schema() -> String {
        SCHEMA.to_string()
    }

    fn description() -> String {
        "Analyze images using OCR and vision-language models. Extract text, describe scenes, \
         or answer questions about image content. Supports smart auto-routing between OCR and \
         vision backends. Accepts base64 images or workspace file paths."
            .to_string()
    }
}

fn execute_inner(params_json: &str, context_json: Option<&str>) -> Result<String, String> {
    let req: VisionRequest = serde_json::from_str(params_json)
        .map_err(|e| format!("Invalid parameters: {e}"))?;

    // Resolve the effective service URL with host-wins precedence:
    //   1. host-injected via Request.context (JobContext.vision_service_url) — trusted,
    //      the LLM cannot redirect vision calls when the host provides a URL.
    //   2. LLM-provided via params (req.service_url) — used only if host didn't inject.
    //   3. default_url() (http://127.0.0.1:8088) — single-tenant fallback.
    let host_url: Option<String> = context_json
        .and_then(|c| serde_json::from_str::<serde_json::Value>(c).ok())
        .and_then(|v| v.get("vision_service_url").and_then(|s| s.as_str()).map(|s| s.to_string()))
        .filter(|s| !s.is_empty());

    let effective_url: String = if let Some(h) = host_url.as_deref() {
        h.to_string()
    } else if !req.service_url.is_empty() {
        req.service_url.clone()
    } else {
        default_url()
    };

    // Validate the effective URL against the (loopback-only) allowlist
    let service_url = validate_service_url(&effective_url)?;

    // Get image data — either from direct base64 or workspace file
    let image_b64 = get_image_data(&req)?;

    // Validate image size (rough estimate from base64 length)
    let decoded_size = image_b64.len() * 3 / 4;
    if decoded_size > MAX_IMAGE_SIZE {
        return Err(format!(
            "Image too large: ~{} bytes (max {} bytes)",
            decoded_size, MAX_IMAGE_SIZE
        ));
    }

    // Validate mode
    match req.mode.as_str() {
        "text" | "describe" | "auto" => {}
        other => return Err(format!("Invalid mode '{other}'. Use: text, describe, auto")),
    }

    // Route to the appropriate endpoint
    let (endpoint, body_json) = if req.mode == "text" {
        let body = OcrOnlyRequest {
            image: image_b64,
            ocr_lang: req.ocr_lang,
        };
        (
            format!("{service_url}/v1/ocr"),
            serde_json::to_string(&body).map_err(|e| format!("Serialize error: {e}"))?,
        )
    } else {
        let body = SidecarRequest {
            image: image_b64,
            mode: req.mode,
            prompt: req.prompt,
            ocr_lang: req.ocr_lang,
            detail_level: req.detail_level,
        };
        (
            format!("{service_url}/v1/vision/analyze"),
            serde_json::to_string(&body).map_err(|e| format!("Serialize error: {e}"))?,
        )
    };

    // Single HTTP request — no retry
    let headers = r#"{"Content-Type": "application/json"}"#;
    let body_bytes = body_json.into_bytes();

    let response = near::agent::host::http_request(
        "POST",
        &endpoint,
        headers,
        Some(&body_bytes),
        Some(60000), // 60s timeout — VL inference can be slow
    )
    .map_err(|e| format!("Vision service request failed: {e}"))?;

    if response.status >= 200 && response.status < 300 {
        let body_str = String::from_utf8(response.body)
            .map_err(|_| "Vision service returned non-UTF8 response".to_string())?;

        let data: serde_json::Value = serde_json::from_str(&body_str)
            .map_err(|e| format!("Vision service returned invalid JSON: {e}"))?;

        let output = ToolOutput {
            status: "success".to_string(),
            endpoint,
            data,
        };

        serde_json::to_string(&output)
            .map_err(|e| format!("Serialize output error: {e}"))
    } else {
        let body_str = String::from_utf8(response.body).unwrap_or_default();
        Err(format!(
            "Vision service returned HTTP {}: {}",
            response.status, body_str
        ))
    }
}

// ── Helpers ─────────────────────────────────────────────────────────────────

/// Validate that the service URL points to a localhost-only sidecar.
/// Accepts any port on the allowed loopback hosts; rejects external/LAN hosts.
fn validate_service_url(url: &str) -> Result<String, String> {
    let url = url.trim_end_matches('/');

    let host_port = url
        .strip_prefix("http://")
        .ok_or_else(|| format!("Service URL must use http://, got: {url}"))?;

    // Take the authority portion (before any path) and split host from port.
    let authority = host_port.split('/').next().unwrap_or(host_port);
    // Strip the port: IPv6 literal `[::1]:8088` -> `::1` (brackets removed to match
    // the daemon's capabilities normalization); otherwise split on the last ':'.
    let host = if let Some(rest) = authority.strip_prefix('[') {
        // IPv6 literal: everything up to ']', brackets removed
        rest.split(']').next().map(|h| h.to_string()).unwrap_or_else(|| authority.to_string())
    } else {
        authority.rsplit_once(':').map(|(h, _)| h.to_string()).unwrap_or_else(|| authority.to_string())
    };

    if !ALLOWED_HOSTS.contains(&host.as_str()) {
        return Err(format!(
            "Service URL host '{host}' not in allowlist (loopback-only). Allowed: {}",
            ALLOWED_HOSTS.join(", ")
        ));
    }

    Ok(url.to_string())
}

/// Get base64-encoded image data from either direct input or workspace file.
fn get_image_data(req: &VisionRequest) -> Result<String, String> {
    match (&req.image, &req.file_path) {
        (Some(b64), None) => {
            if b64.is_empty() {
                return Err("'image' field is empty".to_string());
            }
            Ok(b64.clone())
        }
        (None, Some(path)) => {
            let content = near::agent::host::workspace_read(path)
                .ok_or_else(|| format!("Could not read workspace file: {path}"))?;

            if content.is_empty() {
                return Err(format!("Workspace file is empty: {path}"));
            }
            Ok(content.trim().to_string())
        }
        (Some(_), Some(_)) => {
            Err("Provide either 'image' or 'file_path', not both".to_string())
        }
        (None, None) => {
            Err("Provide either 'image' (base64) or 'file_path' (workspace path)".to_string())
        }
    }
}

export!(VisionAnalyzeTool);
const SCHEMA: &str = r#"{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "type": "object",
  "title": "VisionAnalyzeParams",
  "description": "Parameters for analyzing images with OCR and vision-language models",
  "required": ["image"],
  "properties": {
    "image": {
      "type": "string",
      "description": "Base64-encoded image data or workspace file path (e.g., './screenshot.png' or '~/image.jpg')"
    },
    "mode": {
      "type": "string",
      "enum": ["text", "describe", "auto"],
      "default": "auto",
      "description": "Analysis mode: 'text' for OCR only, 'describe' for vision-language description, 'auto' for smart routing"
    },
    "prompt": {
      "type": "string",
      "description": "Custom question or prompt for vision analysis (e.g., 'What colors are in this image?')"
    },
    "ocr_lang": {
      "type": "string",
      "default": "eng",
      "description": "OCR language code (e.g., 'eng', 'fra', 'deu')"
    },
    "detail_level": {
      "type": "string",
      "enum": ["low", "medium", "high"],
      "default": "medium",
      "description": "Detail level for vision-language analysis (ignored in 'text' mode)"
    },
    "service_url": {
      "type": "string",
      "default": "http://127.0.0.1:8088",
      "description": "Vision service base URL. Must point at a loopback sidecar on the allowlist (127.0.0.1, localhost, host.containers.internal, or [::1]). Override the port to reach a per-tenant sidecar (e.g. 'http://127.0.0.1:20015')."
    }
  }
}"#;

#[cfg(test)]
mod tests {
    use super::validate_service_url;

    #[test]
    fn allowlist_accepts_any_loopback_port() {
        // Per-tenant ports (the whole point of this change)
        assert!(validate_service_url("http://127.0.0.1:20015").is_ok());
        assert!(validate_service_url("http://127.0.0.1:20005").is_ok());
        // Original default port still works
        assert!(validate_service_url("http://127.0.0.1:8088").is_ok());
        // Other loopback hosts, any port
        assert!(validate_service_url("http://localhost:30000").is_ok());
        assert!(validate_service_url("http://host.containers.internal:8088").is_ok());
        assert!(validate_service_url("http://[::1]:8088").is_ok());
        // Trailing slash tolerated
        assert!(validate_service_url("http://127.0.0.1:20015/").is_ok());
    }

    #[test]
    fn allowlist_rejects_non_loopback() {
        // LAN IP (even the host's own LAN address) must be rejected
        assert!(validate_service_url("http://192.168.1.187:8080").is_err());
        // External host
        assert!(validate_service_url("http://example.com:8088").is_err());
        // Link-local multicast (not loopback)
        assert!(validate_service_url("http://224.0.0.1:8088").is_err());
    }

    #[test]
    fn allowlist_rejects_https_and_no_scheme() {
        // https:// not allowed (sidecar is plain http on loopback)
        assert!(validate_service_url("https://127.0.0.1:8088").is_err());
        // Missing scheme
        assert!(validate_service_url("127.0.0.1:8088").is_err());
    }

    #[test]
    fn allowlist_rejects_path_only_traversal() {
        // A URL whose host portion is not loopback must be rejected even with a path
        assert!(validate_service_url("http://example.com/v1/ocr").is_err());
        // Loopback with a path is fine
        assert!(validate_service_url("http://127.0.0.1:20015/v1/ocr").is_ok());
    }
}
