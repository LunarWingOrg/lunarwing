//! Vision Analysis WASM Tool for IronClaw.
//!
//! Analyzes images using the LunarWing Vision Service.
//! Supports OCR text extraction, image description, and custom queries.
//!
//! # Usage
//!
//! The tool accepts either a base64-encoded image or a workspace file path.
//! Mode can be "text" (OCR only), "describe" (vision-language), or "auto" (smart routing).

wit_bindgen::generate!({
    world: "sandboxed-tool",
    path: "../../wit/tool.wit",
});

use base64::Engine;
use serde::{Deserialize, Serialize};

const DEFAULT_VISION_URL: &str = "http://127.0.0.1:8088";
const MAX_IMAGE_SIZE: usize = 10 * 1024 * 1024;
const MAX_RETRIES: u32 = 3;
const BASE_DELAY_MS: u64 = 250;
const MAX_DELAY_MS: u64 = 5000;

fn is_retryable(status: u16) -> bool {
    matches!(status, 429 | 502 | 503 | 504)
} // 10MB

struct VisionAnalyzeTool;

impl exports::near::agent::tool::Guest for VisionAnalyzeTool {
    fn execute(req: exports::near::agent::tool::Request) -> exports::near::agent::tool::Response {
        match execute_inner(&req.params) {
            Ok(result) => exports::near::agent::tool::Response {
                output: Some(result),
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

#[derive(Debug, Deserialize)]
struct AnalyzeParams {
    /// Base64-encoded image or workspace file path
    image: String,
    /// Analysis mode: "text" | "describe" | "auto"
    #[serde(default = "default_mode")]
    mode: String,
    /// Custom question or prompt for vision analysis
    #[serde(default)]
    prompt: Option<String>,
    /// OCR language (default: "eng")
    #[serde(default = "default_lang")]
    ocr_lang: String,
}

fn default_mode() -> String {
    "auto".to_string()
}
fn default_lang() -> String {
    "eng".to_string()
}

#[derive(Debug, Serialize)]
struct ToolOutput {
    mode_used: String,
    text: Option<String>,
    description: Option<String>,
    answer: Option<String>,
    confidence: Option<f32>,
    backends: Vec<String>,
    latency_ms: u64,
}

fn execute_inner(params: &str) -> Result<String, String> {
    let params: AnalyzeParams =
        serde_json::from_str(params).map_err(|e| format!("Invalid parameters: {e}"))?;

    if params.image.is_empty() {
        return Err("'image' must not be empty".into());
    }

    // Determine if image is a file path or base64
    let image_b64 = if params.image.starts_with("/")
        || params.image.starts_with("./")
        || params.image.starts_with("~/")
    {
        // Read from workspace
        let path = if params.image.starts_with("~/") {
            params.image.replacen("~", ".", 1)
        } else {
            params.image.clone()
        };

        let content = near::agent::host::workspace_read(&path)
            .ok_or_else(|| format!("Could not read workspace file: {}", path))?;

        // Check if content is already base64
        if is_valid_base64(&content) {
            content
        } else {
            // Assume it's binary and encode
            base64::engine::general_purpose::STANDARD.encode(content.as_bytes())
        }
    } else {
        // Assume it's base64
        if !is_valid_base64(&params.image) {
            return Err("Invalid base64 image data".into());
        }
        params.image.clone()
    };

    // Check image size
    let decoded_len = base64::engine::general_purpose::STANDARD
        .decode(&image_b64)
        .map_err(|e| format!("Invalid base64: {e}"))?
        .len();

    if decoded_len > MAX_IMAGE_SIZE {
        return Err(format!(
            "Image too large: {} bytes (max: {})",
            decoded_len, MAX_IMAGE_SIZE
        ));
    }

    // Get vision service URL from env or use default
    let vision_url =
        std::env::var("VISION_SERVICE_URL").unwrap_or_else(|_| DEFAULT_VISION_URL.to_string());

    // Build request payload
    let request_body = serde_json::json!({
        "image": image_b64,
        "mode": params.mode,
        "prompt": params.prompt,
        "ocr_lang": params.ocr_lang,
    });

    // Determine endpoint
    let base = if params.mode == "text" && params.prompt.is_none() {
        "/v1/ocr"
    } else {
        "/v1/vision/analyze"
    };
    let endpoint = format!("{vision_url}{base}");

    // Build headers
    let mut headers = serde_json::json!({
        "Content-Type": "application/json"
    });

    // Add auth token if available
    if let Ok(token) = std::env::var("VISION_AUTH_TOKEN") {
        if !token.is_empty() {
            headers["Authorization"] = serde_json::json!(format!("Bearer {}", token));
        }
    }

    // Make HTTP request
    let mut last_error = String::new();
    let mut delay_ms = BASE_DELAY_MS;

    for attempt in 0..=MAX_RETRIES {
        if attempt > 0 {
            std::thread::sleep(std::time::Duration::from_millis(delay_ms));
            delay_ms = (delay_ms * 2).min(MAX_DELAY_MS);
        }

        let body_bytes = request_body.to_string().into_bytes();
        let response = near::agent::host::http_request(
            "POST",
            &endpoint,
            &headers.to_string(),
            Some(&body_bytes),
            Some(60000),
        )
        .map_err(|e| {
            last_error = format!("Vision service request failed: {e}");
        });

        let Ok(response) = response else {
            continue;
        };

        if response.status < 200 || response.status >= 300 {
            if is_retryable(response.status) && attempt < MAX_RETRIES {
                last_error = format!(
                    "Vision service returned {} (retry {}/{})",
                    response.status,
                    attempt + 1,
                    MAX_RETRIES
                );
                continue;
            }
            let body_str = String::from_utf8_lossy(&response.body);
            return Err(format!(
                "Vision service error {}: {}",
                response.status, body_str
            ));
        }

        let body_str = String::from_utf8_lossy(&response.body);
        let vision_response: serde_json::Value = serde_json::from_str(&body_str)
            .map_err(|e| format!("Failed to parse vision service response: {e}"))?;

        let output = if endpoint.ends_with("/ocr") {
            ToolOutput {
                mode_used: "text".to_string(),
                text: vision_response["text"].as_str().map(|s| s.to_string()),
                description: None,
                answer: None,
                confidence: None,
                backends: vec!["tesseract".to_string()],
                latency_ms: vision_response["elapsed_ms"].as_u64().unwrap_or(0),
            }
        } else {
            let mode_used = vision_response["mode_used"].as_str().unwrap_or("auto").to_string();
            let ocr_text = vision_response["ocr"]["full_text"].as_str().map(|s| s.to_string());
            let description = vision_response["vision"]["description"].as_str().map(|s| s.to_string());
            let answer = vision_response["vision"]["prompt_answer"].as_str().map(|s| s.to_string());
            let confidence = vision_response["ocr"]["avg_confidence"].as_f64().map(|f| f as f32);
            let backends: Vec<String> = vision_response["meta"]["backends_used"].as_array()
                .map(|arr| arr.iter().filter_map(|v| v.as_str().map(|s| s.to_string())).collect())
                .unwrap_or_default();
            let latency = vision_response["meta"]["latency_ms"].as_u64().unwrap_or(0);
            ToolOutput { mode_used, text: ocr_text, description, answer, confidence, backends, latency_ms: latency }
        };

        return serde_json::to_string(&output).map_err(|e| format!("Failed to serialize output: {e}"));
    }

    Err(last_error)
}

fn is_valid_base64(s: &str) -> bool {
    base64::engine::general_purpose::STANDARD.decode(s).is_ok()
}

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
    }
  }
}"#;
