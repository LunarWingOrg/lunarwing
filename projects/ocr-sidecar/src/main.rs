use std::convert::Infallible;
use std::sync::Arc;
use std::time::{Duration, Instant};

use base64::Engine;
use dashmap::DashMap;
use governor::{Quota, RateLimiter};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use warp::{Filter, Rejection, Reply};
use warp::http::StatusCode;

const MAX_BODY_SIZE: u64 = 10 * 1024 * 1024;
const CACHE_TTL_SECS: u64 = 300;
const CACHE_MAX_ENTRIES: usize = 10000;
const CACHE_FILE_EXT: &str = ".cache";

#[derive(Clone)]
struct Config {
    auth_token: Option<String>,
    port: u16,
    vl_url: Option<String>,
    vl_api_key: Option<String>,
    vl_model: String,
    vl_timeout_secs: u64,
    enable_paddleocr: bool,
    enable_cache: bool,
    enable_prometheus: bool,
    rate_limit_per_second: u32,
}

#[derive(Clone)]
struct AppState {
    config: Config,
    cache: Arc<DashMap<String, CachedResponse>>,
    rate_limiter: Arc<governor::RateLimiter<governor::state::NotKeyed, governor::state::InMemoryState, governor::clock::QuantaClock>>,
    metrics: Arc<Metrics>,
    start_time: Instant,
    tesseract_version: String,
}

#[derive(Clone, Debug)]
struct CachedResponse {
    response: String,
    created_at: Instant,
}

#[derive(Debug)]
struct Metrics {
    total_requests: std::sync::atomic::AtomicU64,
    ocr_requests: std::sync::atomic::AtomicU64,
    vision_requests: std::sync::atomic::AtomicU64,
    cache_hits: std::sync::atomic::AtomicU64,
    cache_misses: std::sync::atomic::AtomicU64,
    rate_limited: std::sync::atomic::AtomicU64,
    avg_latency_ms: std::sync::atomic::AtomicU64,
    errors_unauthorized: std::sync::atomic::AtomicU64,
    errors_bad_request: std::sync::atomic::AtomicU64,
    errors_ocr_engine: std::sync::atomic::AtomicU64,
    errors_rate_limited: std::sync::atomic::AtomicU64,
    errors_internal: std::sync::atomic::AtomicU64,
    errors_unsupported_media: std::sync::atomic::AtomicU64,
    vl_tokens_used: std::sync::atomic::AtomicU64,
    vl_fallback_count: std::sync::atomic::AtomicU64,
    ocr_duration_buckets: Vec<std::sync::atomic::AtomicU64>,
    ocr_duration_sum_ms: std::sync::atomic::AtomicU64,
    ocr_duration_count: std::sync::atomic::AtomicU64,
    vision_duration_buckets: Vec<std::sync::atomic::AtomicU64>,
    vision_duration_sum_ms: std::sync::atomic::AtomicU64,
    vision_duration_count: std::sync::atomic::AtomicU64,
    tesseract_confidence_buckets: Vec<std::sync::atomic::AtomicU64>,
    tesseract_confidence_sum: std::sync::atomic::AtomicU64,
    tesseract_confidence_count: std::sync::atomic::AtomicU64,
    paddleocr_confidence_buckets: Vec<std::sync::atomic::AtomicU64>,
    paddleocr_confidence_sum: std::sync::atomic::AtomicU64,
    paddleocr_confidence_count: std::sync::atomic::AtomicU64,
}

impl Default for Metrics {
    fn default() -> Self {
        Self {
            total_requests: Default::default(),
            ocr_requests: Default::default(),
            vision_requests: Default::default(),
            cache_hits: Default::default(),
            cache_misses: Default::default(),
            rate_limited: Default::default(),
            avg_latency_ms: Default::default(),
            errors_unauthorized: Default::default(),
            errors_bad_request: Default::default(),
            errors_ocr_engine: Default::default(),
            errors_rate_limited: Default::default(),
            errors_internal: Default::default(),
            errors_unsupported_media: Default::default(),
            vl_tokens_used: Default::default(),
            vl_fallback_count: Default::default(),
            ocr_duration_buckets: (0..13).map(|_| std::sync::atomic::AtomicU64::new(0)).collect(),
            ocr_duration_sum_ms: Default::default(),
            ocr_duration_count: Default::default(),
            vision_duration_buckets: (0..13).map(|_| std::sync::atomic::AtomicU64::new(0)).collect(),
            vision_duration_sum_ms: Default::default(),
            vision_duration_count: Default::default(),
            tesseract_confidence_buckets: (0..10).map(|_| std::sync::atomic::AtomicU64::new(0)).collect(),
            tesseract_confidence_sum: Default::default(),
            tesseract_confidence_count: Default::default(),
            paddleocr_confidence_buckets: (0..10).map(|_| std::sync::atomic::AtomicU64::new(0)).collect(),
            paddleocr_confidence_sum: Default::default(),
            paddleocr_confidence_count: Default::default(),
        }
    }
}

const DURATION_BUCKETS: [f64; 13] = [
    0.001, 0.005, 0.01, 0.025, 0.05, 0.1,
    0.25, 0.5, 1.0, 2.5, 5.0, 10.0, f64::INFINITY,
];

const CONFIDENCE_BUCKETS: [f64; 10] = [
    0.3, 0.5, 0.7, 0.8, 0.85, 0.9, 0.95, 0.99, 1.0, f64::INFINITY,
];

fn record_histogram(buckets: &[std::sync::atomic::AtomicU64], value: f64, boundaries: &[f64]) {
    for (i, &le) in boundaries.iter().enumerate() {
        if value <= le {
            buckets[i].fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        }
    }
}

impl Clone for Metrics {
    fn clone(&self) -> Self {
        Self {
            total_requests: std::sync::atomic::AtomicU64::new(self.total_requests.load(std::sync::atomic::Ordering::Relaxed)),
            ocr_requests: std::sync::atomic::AtomicU64::new(self.ocr_requests.load(std::sync::atomic::Ordering::Relaxed)),
            vision_requests: std::sync::atomic::AtomicU64::new(self.vision_requests.load(std::sync::atomic::Ordering::Relaxed)),
            cache_hits: std::sync::atomic::AtomicU64::new(self.cache_hits.load(std::sync::atomic::Ordering::Relaxed)),
            cache_misses: std::sync::atomic::AtomicU64::new(self.cache_misses.load(std::sync::atomic::Ordering::Relaxed)),
            rate_limited: std::sync::atomic::AtomicU64::new(self.rate_limited.load(std::sync::atomic::Ordering::Relaxed)),
            avg_latency_ms: std::sync::atomic::AtomicU64::new(self.avg_latency_ms.load(std::sync::atomic::Ordering::Relaxed)),
            errors_unauthorized: std::sync::atomic::AtomicU64::new(self.errors_unauthorized.load(std::sync::atomic::Ordering::Relaxed)),
            errors_bad_request: std::sync::atomic::AtomicU64::new(self.errors_bad_request.load(std::sync::atomic::Ordering::Relaxed)),
            errors_ocr_engine: std::sync::atomic::AtomicU64::new(self.errors_ocr_engine.load(std::sync::atomic::Ordering::Relaxed)),
            errors_rate_limited: std::sync::atomic::AtomicU64::new(self.errors_rate_limited.load(std::sync::atomic::Ordering::Relaxed)),
            errors_internal: std::sync::atomic::AtomicU64::new(self.errors_internal.load(std::sync::atomic::Ordering::Relaxed)),
            errors_unsupported_media: std::sync::atomic::AtomicU64::new(self.errors_unsupported_media.load(std::sync::atomic::Ordering::Relaxed)),
            vl_tokens_used: std::sync::atomic::AtomicU64::new(self.vl_tokens_used.load(std::sync::atomic::Ordering::Relaxed)),
            vl_fallback_count: std::sync::atomic::AtomicU64::new(self.vl_fallback_count.load(std::sync::atomic::Ordering::Relaxed)),
            ocr_duration_buckets: self.ocr_duration_buckets.iter().map(|a| std::sync::atomic::AtomicU64::new(a.load(std::sync::atomic::Ordering::Relaxed))).collect(),
            ocr_duration_sum_ms: std::sync::atomic::AtomicU64::new(self.ocr_duration_sum_ms.load(std::sync::atomic::Ordering::Relaxed)),
            ocr_duration_count: std::sync::atomic::AtomicU64::new(self.ocr_duration_count.load(std::sync::atomic::Ordering::Relaxed)),
            vision_duration_buckets: self.vision_duration_buckets.iter().map(|a| std::sync::atomic::AtomicU64::new(a.load(std::sync::atomic::Ordering::Relaxed))).collect(),
            vision_duration_sum_ms: std::sync::atomic::AtomicU64::new(self.vision_duration_sum_ms.load(std::sync::atomic::Ordering::Relaxed)),
            vision_duration_count: std::sync::atomic::AtomicU64::new(self.vision_duration_count.load(std::sync::atomic::Ordering::Relaxed)),
            tesseract_confidence_buckets: self.tesseract_confidence_buckets.iter().map(|a| std::sync::atomic::AtomicU64::new(a.load(std::sync::atomic::Ordering::Relaxed))).collect(),
            tesseract_confidence_sum: std::sync::atomic::AtomicU64::new(self.tesseract_confidence_sum.load(std::sync::atomic::Ordering::Relaxed)),
            tesseract_confidence_count: std::sync::atomic::AtomicU64::new(self.tesseract_confidence_count.load(std::sync::atomic::Ordering::Relaxed)),
            paddleocr_confidence_buckets: self.paddleocr_confidence_buckets.iter().map(|a| std::sync::atomic::AtomicU64::new(a.load(std::sync::atomic::Ordering::Relaxed))).collect(),
            paddleocr_confidence_sum: std::sync::atomic::AtomicU64::new(self.paddleocr_confidence_sum.load(std::sync::atomic::Ordering::Relaxed)),
            paddleocr_confidence_count: std::sync::atomic::AtomicU64::new(self.paddleocr_confidence_count.load(std::sync::atomic::Ordering::Relaxed)),
        }
    }
}

#[derive(Debug, Deserialize)]
struct OcrRequest {
    image: String,
    #[serde(default = "default_ocr_lang")]
    ocr_lang: String,
}

#[derive(Debug, Serialize)]
struct OcrResponse {
    text: String,
    engine: String,
    model: Option<String>,
    elapsed_ms: u64,
}

#[derive(Debug, Serialize)]
struct HealthResponse {
    status: String,
    tesseract_version: String,
    uptime_secs: u64,
    vl_available: bool,
}

#[derive(Debug, Deserialize)]
#[allow(dead_code)]
struct VisionAnalyzeRequest {
    image: String,
    #[serde(default = "default_mode")]
    mode: String,
    #[serde(default)]
    prompt: Option<String>,
    #[serde(default = "default_ocr_lang")]
    ocr_lang: String,
    #[serde(default = "default_detail_level")]
    detail_level: String,
}

fn default_mode() -> String { "auto".to_string() }
fn default_ocr_lang() -> String { "eng".to_string() }
fn default_detail_level() -> String { "medium".to_string() }

#[derive(Debug, Serialize)]
struct VisionAnalyzeResponse {
    mode_used: String,
    ocr: OcrResult,
    vision: Option<VisionResult>,
    meta: MetaInfo,
}

#[derive(Debug, Serialize)]
struct OcrResult {
    full_text: String,
    blocks: Vec<TextBlock>,
    avg_confidence: f32,
}

#[derive(Debug, Serialize)]
struct TextBlock {
    text: String,
    confidence: f32,
    bbox: [i32; 4],
}

#[derive(Debug, Serialize)]
struct VisionResult {
    description: String,
    prompt_answer: Option<String>,
}

#[derive(Debug, Serialize)]
struct MetaInfo {
    backends_used: Vec<String>,
    latency_ms: u64,
    tokens_used: Option<u32>,
}

#[derive(Debug, Serialize)]
struct ErrorResponse {
    error: String,
    detail: String,
    code: u16,
}

#[derive(Debug, thiserror::Error)]
enum AppError {
    #[error("Unauthorized")]
    Unauthorized,
    #[error("Unsupported media type: {0}")]
    UnsupportedMediaType(String),
    #[error("Bad request: {0}")]
    BadRequest(String),
    #[error("OCR engine failure: {0}")]
    OcrEngineFailure(String),
    #[error("Rate limit exceeded")]
    RateLimited,
    #[error("Internal server error")]
    InternalError,
}

impl warp::reject::Reject for AppError {}

async fn handle_rejection(err: Rejection) -> Result<impl Reply, Infallible> {
    let (code, error_response) = if err.is_not_found() {
        (StatusCode::NOT_FOUND, ErrorResponse {
            error: "not_found".to_string(),
            detail: "Resource not found".to_string(),
            code: 404,
        })
    } else if let Some(_) = err.find::<warp::reject::PayloadTooLarge>() {
        (StatusCode::PAYLOAD_TOO_LARGE, ErrorResponse {
            error: "payload_too_large".to_string(),
            detail: "Request body exceeds 10MB limit".to_string(),
            code: 413,
        })
    } else if let Some(e) = err.find::<AppError>() {
        match e {
            AppError::Unauthorized => (StatusCode::UNAUTHORIZED, ErrorResponse {
                error: "unauthorized".to_string(),
                detail: e.to_string(),
                code: 401,
            }),
            AppError::UnsupportedMediaType(_) => (StatusCode::UNSUPPORTED_MEDIA_TYPE, ErrorResponse {
                error: "unsupported_media_type".to_string(),
                detail: e.to_string(),
                code: 415,
            }),
            AppError::BadRequest(_) => (StatusCode::BAD_REQUEST, ErrorResponse {
                error: "bad_request".to_string(),
                detail: e.to_string(),
                code: 400,
            }),
            AppError::OcrEngineFailure(_) => (StatusCode::INTERNAL_SERVER_ERROR, ErrorResponse {
                error: "ocr_engine_failure".to_string(),
                detail: e.to_string(),
                code: 500,
            }),
            AppError::RateLimited => (StatusCode::TOO_MANY_REQUESTS, ErrorResponse {
                error: "rate_limited".to_string(),
                detail: e.to_string(),
                code: 429,
            }),
            AppError::InternalError => (StatusCode::INTERNAL_SERVER_ERROR, ErrorResponse {
                error: "internal_error".to_string(),
                detail: e.to_string(),
                code: 500,
            }),
        }
    } else {
        (StatusCode::INTERNAL_SERVER_ERROR, ErrorResponse {
            error: "internal_error".to_string(),
            detail: "Internal server error".to_string(),
            code: 500,
        })
    };

    let json = warp::reply::json(&error_response);
    Ok(warp::reply::with_status(json, code))
}

fn with_state(state: AppState) -> impl Filter<Extract = (AppState,), Error = Infallible> + Clone {
    warp::any().map(move || state.clone())
}

fn rate_limit_filter(state: AppState) -> impl Filter<Extract = (), Error = Rejection> + Clone {
    warp::any()
        .and_then(move || {
            let state = state.clone();
            async move {
                match state.rate_limiter.check() {
                    Ok(()) => Ok(()),
                    Err(_) => {
                        state.metrics.rate_limited.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                        Err(warp::reject::custom(AppError::RateLimited))
                    }
                }
            }
        })
        .untuple_one()
}

fn auth_filter(config: Config) -> impl Filter<Extract = (), Error = Rejection> + Clone {
    warp::header::optional("authorization")
        .and_then(move |auth: Option<String>| {
            let expected = config.auth_token.clone();
            async move {
                match expected {
                    None => Ok(()),
                    Some(token) => {
                        match auth {
                            Some(header) if header.starts_with("Bearer ") => {
                                let provided = header.trim_start_matches("Bearer ");
                                if provided == token {
                                    Ok(())
                                } else {
                                    Err(warp::reject::custom(AppError::Unauthorized))
                                }
                            }
                            _ => Err(warp::reject::custom(AppError::Unauthorized)),
                        }
                    }
                }
            }
        })
        .untuple_one()
}

fn validate_image_format(body: &[u8]) -> Result<(), AppError> {
    if body.starts_with(b"\x89PNG\r\n\x1a\n") {
        Ok(())
    } else if body.starts_with(b"\xff\xd8\xff") {
        Ok(())
    } else if body.len() > 12 && body.starts_with(b"RIFF") && &body[8..12] == b"WEBP" {
        Ok(())
    } else if body.starts_with(b"II\x2a\x00") || body.starts_with(b"MM\x00\x2a") {
        Ok(())
    } else {
        Err(AppError::UnsupportedMediaType(
            "Supported formats: PNG, JPEG, WebP, TIFF".to_string()
        ))
    }
}

async fn run_tesseract(image_bytes: &[u8], lang: &str) -> Result<OcrResult, AppError> {
    let mut temp_file = tempfile::Builder::new()
        .suffix(".png")
        .tempfile()
        .map_err(|e| AppError::OcrEngineFailure(e.to_string()))?;

    std::io::Write::write_all(&mut temp_file, image_bytes)
        .map_err(|e| AppError::OcrEngineFailure(e.to_string()))?;

    let output = tokio::process::Command::new("tesseract")
        .arg(temp_file.path())
        .arg("stdout")
        .arg("-l").arg(lang)
        .output()
        .await
        .map_err(|e| AppError::OcrEngineFailure(e.to_string()))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(AppError::OcrEngineFailure(stderr.to_string()));
    }

    let text = String::from_utf8_lossy(&output.stdout)
        .trim()
        .to_string();

    let confidence = estimate_confidence(&text);

    Ok(OcrResult {
        full_text: text.clone(),
        blocks: vec![TextBlock {
            text,
            confidence,
            bbox: [0, 0, 0, 0],
        }],
        avg_confidence: confidence,
    })
}

fn estimate_confidence(text: &str) -> f32 {
    if text.is_empty() {
        return 0.0;
    }
    let lines: Vec<&str> = text.lines().collect();
    let non_empty_lines = lines.iter().filter(|l| !l.trim().is_empty()).count();
    let ratio = non_empty_lines as f32 / lines.len().max(1) as f32;
    (0.5 + ratio * 0.5).min(1.0)
}

async fn run_paddleocr(image_bytes: &[u8]) -> Result<OcrResult, AppError> {
    let mut temp_file = tempfile::Builder::new()
        .suffix(".png")
        .tempfile()
        .map_err(|e| AppError::OcrEngineFailure(e.to_string()))?;

    std::io::Write::write_all(&mut temp_file, image_bytes)
        .map_err(|e| AppError::OcrEngineFailure(e.to_string()))?;

    let output = tokio::process::Command::new("paddleocr")
        .arg("--image_dir").arg(temp_file.path())
        .arg("--use_angle_cls").arg("true")
        .arg("--lang").arg("en")
        .arg("--show_log").arg("false")
        .output()
        .await
        .map_err(|e| AppError::OcrEngineFailure(format!("PaddleOCR not available: {}", e)))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(AppError::OcrEngineFailure(format!("PaddleOCR failed: {}", stderr)));
    }

    let text = String::from_utf8_lossy(&output.stdout)
        .trim()
        .to_string();

    let confidence = estimate_confidence(&text).min(0.95);

    Ok(OcrResult {
        full_text: text.clone(),
        blocks: vec![TextBlock {
            text,
            confidence,
            bbox: [0, 0, 0, 0],
        }],
        avg_confidence: confidence,
    })
}

async fn run_ocr_with_fallback(image_bytes: &[u8], lang: &str, enable_paddle: bool) -> Result<OcrResult, AppError> {
    let result = run_tesseract(image_bytes, lang).await?;

    if result.avg_confidence < 0.7 && enable_paddle {
        tracing::info!("Tesseract confidence {:.2} < 0.7, trying PaddleOCR fallback", result.avg_confidence);
        match run_paddleocr(image_bytes).await {
            Ok(paddle_result) => {
                if paddle_result.avg_confidence > result.avg_confidence {
                    tracing::info!("PaddleOCR confidence {:.2} better than Tesseract {:.2}, using PaddleOCR",
                        paddle_result.avg_confidence, result.avg_confidence);
                    return Ok(paddle_result);
                }
            }
            Err(e) => {
                tracing::warn!("PaddleOCR fallback failed: {}", e);
            }
        }
    }

    Ok(result)
}

fn generate_cache_key(image_b64: &str, prompt: &Option<String>, mode: &str, detail_level: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(image_b64.as_bytes());
    hasher.update(mode.as_bytes());
    hasher.update(detail_level.as_bytes());
    if let Some(p) = prompt {
        hasher.update(p.as_bytes());
    }
    format!("{:x}", hasher.finalize())
}

fn check_cache(cache: &DashMap<String, CachedResponse>, key: &str) -> Option<String> {
    if let Some(entry) = cache.get(key) {
        if entry.created_at.elapsed().as_secs() < CACHE_TTL_SECS {
            return Some(entry.response.clone());
        } else {
            // Expired entry — remove it (lazy eviction)
            drop(entry);
            cache.remove(key);
        }
    }
    None
}

fn store_cache(cache: &DashMap<String, CachedResponse>, key: String, response: String) {
    cache.insert(key, CachedResponse {
        response,
        created_at: Instant::now(),
    });

    // Opportunistic eviction: if cache has grown large, sweep expired entries
    if cache.len() > CACHE_MAX_ENTRIES {
        let now = Instant::now();
        cache.retain(|_, v| now.duration_since(v.created_at).as_secs() < CACHE_TTL_SECS);
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
enum VlTaskType {
    OcrSupplement,
    Describe,
    Answer,
    Classify,
}

impl VlTaskType {
    fn prompt(self, detail_level: &str) -> String {
        match self {
            VlTaskType::OcrSupplement => {
                "The OCR result may be incomplete or low-confidence. \
                 Describe any visible text, numbers, labels, or UI elements \
                 that may have been missed. Also note any diagrams or visual context.".to_string()
            }
            VlTaskType::Describe => match detail_level {
                "low" | "brief" | "short" => "Describe this image in one sentence.".to_string(),
                "high" | "detailed" | "full" => "Describe this image in detail, including objects, text, scene, colors, and any notable features.".to_string(),
                _ => "Describe this image.".to_string(),
            },
            VlTaskType::Answer => String::new(),
            VlTaskType::Classify => {
                "Classify this image into the most appropriate category. \
                 Respond with a single category label followed by a brief justification.".to_string()
            }
        }
    }

    fn max_tokens(self) -> u32 {
        match self {
            VlTaskType::OcrSupplement => 512,
            VlTaskType::Describe => 1024,
            VlTaskType::Answer => 512,
            VlTaskType::Classify => 128,
        }
    }
}

fn classify_task_type(user_prompt: &Option<String>, mode: &str) -> VlTaskType {
    if mode == "text" {
        return VlTaskType::OcrSupplement;
    }
    match user_prompt {
        Some(p) if !p.trim().is_empty() => {
            let p_lower = p.to_lowercase();
            let classify_keywords = ["classify", "categorize", "label", "tag", "type of"];
            if classify_keywords.iter().any(|&k| p_lower.contains(k)) {
                VlTaskType::Classify
            } else {
                VlTaskType::Answer
            }
        }
        _ => VlTaskType::Describe,
    }
}

fn build_vl_prompt(user_prompt: &Option<String>, detail_level: &str, task: VlTaskType) -> (String, bool) {
    match task {
        VlTaskType::Answer => match user_prompt {
            Some(p) if !p.trim().is_empty() => (p.clone(), true),
            _ => (VlTaskType::Describe.prompt(detail_level), false),
        },
        _ => {
            let base = task.prompt(detail_level);
            match user_prompt {
                Some(p) if !p.trim().is_empty() && task != VlTaskType::Answer => {
                    (format!("{base}\n\nUser question: {p}"), false)
                }
                _ => (base, false),
            }
        }
    }
}

fn should_use_vl(ocr_result: &OcrResult, prompt: &Option<String>, mode: &str) -> bool {
    match mode {
        "text" => false,
        "describe" => true,
        "auto" => {
            if let Some(p) = prompt {
                let p_lower = p.to_lowercase();
                let vl_keywords = ["describe", "compare", "which", "looks", "color", "best", "scene", "style", "vibe"];
                let ocr_keywords = ["read", "say", "text", "says", "what does", "extract", "error", "log", "code"];

                let vl_score = vl_keywords.iter().filter(|&&k| p_lower.contains(k)).count();
                let ocr_score = ocr_keywords.iter().filter(|&&k| p_lower.contains(k)).count();

                if vl_score > ocr_score {
                    return true;
                }
                if ocr_score > vl_score {
                    return false;
                }

                if vl_score == ocr_score && vl_score > 0 {
                    return ocr_result.full_text.trim().len() < 50;
                }
            }
            ocr_result.avg_confidence < 0.85
        }
        _ => false,
    }
}

async fn run_vl(image_b64: &str, prompt: &str, config: &Config, max_tokens: u32) -> Result<(VisionResult, Option<u32>), AppError> {
    let vl_url = config.vl_url.as_ref()
        .ok_or_else(|| AppError::InternalError)?;

    let timeout = Duration::from_secs(config.vl_timeout_secs);
    let client = reqwest::Client::builder()
        .timeout(timeout)
        .build()
        .map_err(|_| AppError::InternalError)?;

    let request_body = serde_json::json!({
        "model": config.vl_model,
        "messages": [
            {
                "role": "user",
                "content": [
                    {
                        "type": "image_url",
                        "image_url": {
                            "url": format!("data:image/png;base64,{})", image_b64)
                        }
                    },
                    {
                        "type": "text",
                        "text": prompt
                    }
                ]
            }
        ],
        "max_tokens": max_tokens
    });

    let mut request = client.post(vl_url)
        .header("Content-Type", "application/json")
        .json(&request_body);

    if let Some(key) = &config.vl_api_key {
        request = request.header("Authorization", format!("Bearer {}", key));
    }

    let response = request.send()
        .await
        .map_err(|e| AppError::OcrEngineFailure(format!("VL request failed: {}", e)))?;

    let status = response.status();
    if !status.is_success() {
        let text = response.text().await.unwrap_or_default();
        return Err(AppError::OcrEngineFailure(format!("VL API error {}: {}", status, text)));
    }

    let json: serde_json::Value = response.json()
        .await
        .map_err(|e| AppError::OcrEngineFailure(format!("VL JSON parse error: {}", e)))?;

    let description = json["choices"][0]["message"]["content"]
        .as_str()
        .unwrap_or("")
        .to_string();

    // Extract token usage from the API response
    let tokens_used = json["usage"]["total_tokens"]
        .as_u64()
        .map(|t| t as u32);

    Ok((
        VisionResult {
            description,
            prompt_answer: None,
        },
        tokens_used,
    ))
}

async fn vision_analyze_handler(
    body: bytes::Bytes,
    state: AppState,
) -> Result<impl Reply, Rejection> {
    let start = Instant::now();

    let req: VisionAnalyzeRequest = serde_json::from_slice(&body)
        .map_err(|e| warp::reject::custom(AppError::BadRequest(e.to_string())))?;

    let image_bytes = base64::engine::general_purpose::STANDARD
        .decode(&req.image)
        .map_err(|e| warp::reject::custom(AppError::BadRequest(format!("Invalid base64: {}", e))))?;

    validate_image_format(&image_bytes)
        .map_err(warp::reject::custom)?;

    // Check cache
    if state.config.enable_cache {
        let cache_key = generate_cache_key(&req.image, &req.prompt, &req.mode, &req.detail_level);
        if let Some(cached) = check_cache(&state.cache, &cache_key) {
            state.metrics.cache_hits.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            return Ok(warp::reply::json(&serde_json::json!({
                "cached": true,
                "response": serde_json::from_str::<serde_json::Value>(&cached).unwrap_or_default()
            })));
        }
        state.metrics.cache_misses.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    }

    let ocr_result = run_ocr_with_fallback(&image_bytes, &req.ocr_lang, state.config.enable_paddleocr)
        .await
        .map_err(warp::reject::custom)?;

    let use_vl = should_use_vl(&ocr_result, &req.prompt, &req.mode);

    let mut tokens_used: Option<u32> = None;

    let vision_result = if use_vl {
        let task = classify_task_type(&req.prompt, &req.mode);
        let (vl_prompt, is_question) = build_vl_prompt(&req.prompt, &req.detail_level, task);
        let max_tokens = task.max_tokens();
        match run_vl(&req.image, &vl_prompt, &state.config, max_tokens).await {
            Ok((mut result, tokens)) => {
                if is_question {
                    result.prompt_answer = Some(result.description.clone());
                }
                tokens_used = tokens;
                Some(result)
            }
            Err(e) => {
                tracing::warn!("VL failed, falling back to OCR only: {}", e);
                state.metrics.vl_fallback_count.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                None
            }
        }
    } else {
        None
    };

    let mode_used = if vision_result.is_some() {
        if req.mode == "auto" { "hybrid" } else { "describe" }
    } else {
        "text"
    };

    let mut backends = vec!["tesseract".to_string()];
    if ocr_result.avg_confidence >= 0.7 && state.config.enable_paddleocr {
        backends.push("paddleocr".to_string());
    }
    if vision_result.is_some() {
        backends.push("qwen3vl".to_string());
    }

    let elapsed = start.elapsed().as_millis() as u64;

    let response = VisionAnalyzeResponse {
        mode_used: mode_used.to_string(),
        ocr: ocr_result,
        vision: vision_result,
        meta: MetaInfo {
            backends_used: backends,
            latency_ms: elapsed,
            tokens_used,
        },
    };

    // Store in cache
    if state.config.enable_cache {
        let cache_key = generate_cache_key(&req.image, &req.prompt, &req.mode, &req.detail_level);
        if let Ok(json_str) = serde_json::to_string(&response) {
            store_cache(&state.cache, cache_key, json_str);
        }
    }

    state.metrics.total_requests.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    state.metrics.vision_requests.fetch_add(1, std::sync::atomic::Ordering::Relaxed);

    update_avg_latency(&state.metrics, elapsed);
    record_histogram(&state.metrics.vision_duration_buckets, elapsed as f64 / 1000.0, &DURATION_BUCKETS);
    state.metrics.vision_duration_sum_ms.fetch_add(elapsed, std::sync::atomic::Ordering::Relaxed);
    state.metrics.vision_duration_count.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    if let Some(t) = tokens_used {
        state.metrics.vl_tokens_used.fetch_add(t as u64, std::sync::atomic::Ordering::Relaxed);
    }

    Ok(warp::reply::json(&response))
}

async fn ocr_handler(
    body: bytes::Bytes,
    state: AppState,
) -> Result<impl Reply, Rejection> {
    let start = Instant::now();

    let req: OcrRequest = serde_json::from_slice(&body)
        .map_err(|e| warp::reject::custom(AppError::BadRequest(e.to_string())))?;

    let image_bytes = base64::engine::general_purpose::STANDARD
        .decode(&req.image)
        .map_err(|e| warp::reject::custom(AppError::BadRequest(format!("Invalid base64: {}", e))))?;

    validate_image_format(&image_bytes)
        .map_err(warp::reject::custom)?;

    let ocr_result = run_ocr_with_fallback(&image_bytes, &req.ocr_lang, state.config.enable_paddleocr)
        .await
        .map_err(warp::reject::custom)?;

    let elapsed = start.elapsed().as_millis() as u64;

    let response = OcrResponse {
        text: ocr_result.full_text,
        engine: if ocr_result.avg_confidence >= 0.7 && state.config.enable_paddleocr {
            "paddleocr".to_string()
        } else {
            "tesseract".to_string()
        },
        model: None,
        elapsed_ms: elapsed,
    };

    state.metrics.total_requests.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    state.metrics.ocr_requests.fetch_add(1, std::sync::atomic::Ordering::Relaxed);

    update_avg_latency(&state.metrics, elapsed);
    record_histogram(&state.metrics.ocr_duration_buckets, elapsed as f64 / 1000.0, &DURATION_BUCKETS);
    state.metrics.ocr_duration_sum_ms.fetch_add(elapsed, std::sync::atomic::Ordering::Relaxed);
    state.metrics.ocr_duration_count.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    record_histogram(&state.metrics.tesseract_confidence_buckets, ocr_result.avg_confidence as f64, &CONFIDENCE_BUCKETS);
    state.metrics.tesseract_confidence_sum.fetch_add((ocr_result.avg_confidence * 1000.0) as u64, std::sync::atomic::Ordering::Relaxed);
    state.metrics.tesseract_confidence_count.fetch_add(1, std::sync::atomic::Ordering::Relaxed);

    Ok(warp::reply::json(&response))
}

/// Update the rolling average latency using an exponential moving average.
/// alpha = 0.1 means new samples contribute 10% to the average.
fn update_avg_latency(metrics: &Metrics, latency_ms: u64) {
    let alpha: f64 = 0.1;
    loop {
        let current = metrics.avg_latency_ms.load(std::sync::atomic::Ordering::Relaxed) as f64;
        let new_val = if current == 0.0 {
            latency_ms as f64
        } else {
            current * (1.0 - alpha) + (latency_ms as f64) * alpha
        };
        if metrics.avg_latency_ms.compare_exchange(
            current as u64,
            new_val as u64,
            std::sync::atomic::Ordering::Relaxed,
            std::sync::atomic::Ordering::Relaxed,
        ).is_ok() {
            break;
        }
    }
}

async fn health_handler(state: AppState) -> Result<impl Reply, Rejection> {
    let uptime_secs = state.start_time.elapsed().as_secs();

    let response = HealthResponse {
        status: "ok".to_string(),
        tesseract_version: state.tesseract_version.clone(),
        uptime_secs,
        vl_available: state.config.vl_url.is_some(),
    };

    Ok(warp::reply::json(&response))
}

#[derive(Debug, Serialize)]
struct MetricsResponse {
    total_requests: u64,
    ocr_requests: u64,
    vision_requests: u64,
    cache_hits: u64,
    cache_misses: u64,
    rate_limited: u64,
    cache_hit_rate: f32,
    avg_latency_ms: u64,
}

async fn metrics_handler(state: AppState) -> Result<impl Reply, Rejection> {
    let total = state.metrics.total_requests.load(std::sync::atomic::Ordering::Relaxed);
    let cache_hits = state.metrics.cache_hits.load(std::sync::atomic::Ordering::Relaxed);
    let cache_misses = state.metrics.cache_misses.load(std::sync::atomic::Ordering::Relaxed);
    let total_cache = cache_hits + cache_misses;

    let response = MetricsResponse {
        total_requests: total,
        ocr_requests: state.metrics.ocr_requests.load(std::sync::atomic::Ordering::Relaxed),
        vision_requests: state.metrics.vision_requests.load(std::sync::atomic::Ordering::Relaxed),
        cache_hits,
        cache_misses,
        rate_limited: state.metrics.rate_limited.load(std::sync::atomic::Ordering::Relaxed),
        cache_hit_rate: if total_cache > 0 { cache_hits as f32 / total_cache as f32 } else { 0.0 },
        avg_latency_ms: state.metrics.avg_latency_ms.load(std::sync::atomic::Ordering::Relaxed),
    };

    Ok(warp::reply::json(&response))
}

async fn prometheus_metrics_handler(state: AppState) -> Result<impl Reply, Rejection> {
    if !state.config.enable_prometheus {
        return Err(warp::reject::not_found());
    }

    let m = &state.metrics;
    let o = std::sync::atomic::Ordering::Relaxed;
    let mut buf = String::with_capacity(4096);

    use std::fmt::Write;

    writeln!(buf, "# HELP lunarvision_requests_total Total requests by endpoint and status.").unwrap();
    writeln!(buf, "# TYPE lunarvision_requests_total counter").unwrap();
    writeln!(buf, "lunarvision_requests_total{{endpoint=\"ocr\",status=\"success\"}} {}", m.ocr_requests.load(o)).unwrap();
    writeln!(buf, "lunarvision_requests_total{{endpoint=\"vision\",status=\"success\"}} {}", m.vision_requests.load(o)).unwrap();

    writeln!(buf, "# HELP lunarvision_cache_hits_total Cache hits.").unwrap();
    writeln!(buf, "# TYPE lunarvision_cache_hits_total counter").unwrap();
    writeln!(buf, "lunarvision_cache_hits_total {}", m.cache_hits.load(o)).unwrap();
    writeln!(buf, "# HELP lunarvision_cache_misses_total Cache misses.").unwrap();
    writeln!(buf, "# TYPE lunarvision_cache_misses_total counter").unwrap();
    writeln!(buf, "lunarvision_cache_misses_total {}", m.cache_misses.load(o)).unwrap();
    writeln!(buf, "# HELP lunarvision_rate_limited_total Requests rejected by rate limiter.").unwrap();
    writeln!(buf, "# TYPE lunarvision_rate_limited_total counter").unwrap();
    writeln!(buf, "lunarvision_rate_limited_total {}", m.rate_limited.load(o)).unwrap();
    writeln!(buf, "# HELP lunarvision_vl_tokens_used_total Total tokens consumed by VL backend.").unwrap();
    writeln!(buf, "# TYPE lunarvision_vl_tokens_used_total counter").unwrap();
    writeln!(buf, "lunarvision_vl_tokens_used_total {}", m.vl_tokens_used.load(o)).unwrap();
    writeln!(buf, "# HELP lunarvision_vl_fallback_total VL failures that fell back to OCR only.").unwrap();
    writeln!(buf, "# TYPE lunarvision_vl_fallback_total counter").unwrap();
    writeln!(buf, "lunarvision_vl_fallback_total {}", m.vl_fallback_count.load(o)).unwrap();

    writeln!(buf, "# HELP lunarvision_errors_total Errors by type.").unwrap();
    writeln!(buf, "# TYPE lunarvision_errors_total counter").unwrap();
    writeln!(buf, "lunarvision_errors_total{{type=\"unauthorized\"}} {}", m.errors_unauthorized.load(o)).unwrap();
    writeln!(buf, "lunarvision_errors_total{{type=\"bad_request\"}} {}", m.errors_bad_request.load(o)).unwrap();
    writeln!(buf, "lunarvision_errors_total{{type=\"ocr_engine_failure\"}} {}", m.errors_ocr_engine.load(o)).unwrap();
    writeln!(buf, "lunarvision_errors_total{{type=\"rate_limited\"}} {}", m.errors_rate_limited.load(o)).unwrap();
    writeln!(buf, "lunarvision_errors_total{{type=\"unsupported_media\"}} {}", m.errors_unsupported_media.load(o)).unwrap();
    writeln!(buf, "lunarvision_errors_total{{type=\"internal\"}} {}", m.errors_internal.load(o)).unwrap();

    let cache_hits = m.cache_hits.load(o);
    let cache_misses = m.cache_misses.load(o);
    let total_cache = cache_hits + cache_misses;

    writeln!(buf, "# HELP lunarvision_cache_hit_ratio Cache effectiveness (hits / total lookups).").unwrap();
    writeln!(buf, "# TYPE lunarvision_cache_hit_ratio gauge").unwrap();
    writeln!(buf, "lunarvision_cache_hit_ratio {}", if total_cache > 0 { cache_hits as f64 / total_cache as f64 } else { 0.0 }).unwrap();
    writeln!(buf, "# HELP lunarvision_cache_entries Current entries in the response cache.").unwrap();
    writeln!(buf, "# TYPE lunarvision_cache_entries gauge").unwrap();
    writeln!(buf, "lunarvision_cache_entries {}", state.cache.len()).unwrap();
    writeln!(buf, "# HELP lunarvision_vl_available VL backend configured (1) or not (0).").unwrap();
    writeln!(buf, "# TYPE lunarvision_vl_available gauge").unwrap();
    writeln!(buf, "lunarvision_vl_available {}", if state.config.vl_url.is_some() { 1 } else { 0 }).unwrap();
    writeln!(buf, "# HELP lunarvision_uptime_seconds Service uptime.").unwrap();
    writeln!(buf, "# TYPE lunarvision_uptime_seconds gauge").unwrap();
    writeln!(buf, "lunarvision_uptime_seconds {}", state.start_time.elapsed().as_secs()).unwrap();
    writeln!(buf, "# HELP lunarvision_avg_latency_ms Exponential moving average request latency.").unwrap();
    writeln!(buf, "# TYPE lunarvision_avg_latency_ms gauge").unwrap();
    writeln!(buf, "lunarvision_avg_latency_ms {}", m.avg_latency_ms.load(o)).unwrap();
    writeln!(buf, "# HELP lunarvision_rate_limit_per_second Configured rate limit.").unwrap();
    writeln!(buf, "# TYPE lunarvision_rate_limit_per_second gauge").unwrap();
    writeln!(buf, "lunarvision_rate_limit_per_second {}", state.config.rate_limit_per_second).unwrap();

    for (endpoint, buckets, sum, count) in [
        ("ocr", &m.ocr_duration_buckets, &m.ocr_duration_sum_ms, &m.ocr_duration_count),
        ("vision", &m.vision_duration_buckets, &m.vision_duration_sum_ms, &m.vision_duration_count),
    ] {
        writeln!(buf, "# HELP lunarvision_request_duration_seconds Request latency distribution.").unwrap();
        writeln!(buf, "# TYPE lunarvision_request_duration_seconds histogram").unwrap();
        for (i, &le) in DURATION_BUCKETS.iter().enumerate() {
            let le_str = if le.is_infinite() { "+Inf".to_string() } else { le.to_string() };
            writeln!(buf, "lunarvision_request_duration_seconds_bucket{{endpoint=\"{endpoint}\",le=\"{le_str}\"}} {}", buckets[i].load(o)).unwrap();
        }
        writeln!(buf, "lunarvision_request_duration_seconds_sum{{endpoint=\"{endpoint}\"}} {}", sum.load(o) as f64 / 1000.0).unwrap();
        writeln!(buf, "lunarvision_request_duration_seconds_count{{endpoint=\"{endpoint}\"}} {}", count.load(o)).unwrap();
    }

    for (engine, buckets, sum, count) in [
        ("tesseract", &m.tesseract_confidence_buckets, &m.tesseract_confidence_sum, &m.tesseract_confidence_count),
        ("paddleocr", &m.paddleocr_confidence_buckets, &m.paddleocr_confidence_sum, &m.paddleocr_confidence_count),
    ] {
        writeln!(buf, "# HELP lunarvision_ocr_confidence OCR engine confidence distribution.").unwrap();
        writeln!(buf, "# TYPE lunarvision_ocr_confidence histogram").unwrap();
        for (i, &le) in CONFIDENCE_BUCKETS.iter().enumerate() {
            let le_str = if le.is_infinite() { "+Inf".to_string() } else { le.to_string() };
            writeln!(buf, "lunarvision_ocr_confidence_bucket{{engine=\"{engine}\",le=\"{le_str}\"}} {}", buckets[i].load(o)).unwrap();
        }
        writeln!(buf, "lunarvision_ocr_confidence_sum{{engine=\"{engine}\"}} {}", sum.load(o) as f64 / 1000.0).unwrap();
        writeln!(buf, "lunarvision_ocr_confidence_count{{engine=\"{engine}\"}} {}", count.load(o)).unwrap();
    }

    Ok(warp::reply::with_header(buf, "Content-Type", "text/plain; version=0.0.4; charset=utf-8"))
}

async fn openapi_handler() -> Result<impl Reply, Rejection> {
    let spec = serde_json::json!({
        "openapi": "3.0.3",
        "info": {
            "title": "LunarWing OCR Sidecar",
            "description": "OCR and vision-language analysis service",
            "version": "1.0.0"
        },
        "servers": [
            {"url": "/v1", "description": "Versioned API"}
        ],
        "paths": {
            "/ocr": {
                "post": {
                    "summary": "Extract text from an image",
                    "tags": ["ocr"],
                    "security": [{"bearerAuth": []}],
                    "requestBody": {
                        "required": true,
                        "content": {
                            "application/json": {
                                "schema": {"$ref": "#/components/schemas/OcrRequest"}
                            }
                        }
                    },
                    "responses": {
                        "200": {"description": "OCR result", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/OcrResponse"}}}},
                        "429": {"description": "Rate limited"}
                    }
                }
            },
            "/vision/analyze": {
                "post": {
                    "summary": "Unified vision analysis with smart routing",
                    "tags": ["vision"],
                    "security": [{"bearerAuth": []}],
                    "requestBody": {
                        "required": true,
                        "content": {
                            "application/json": {
                                "schema": {"$ref": "#/components/schemas/VisionAnalyzeRequest"}
                            }
                        }
                    },
                    "responses": {
                        "200": {"description": "Analysis result", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/VisionAnalyzeResponse"}}}}
                    }
                }
            },
            "/vision/metrics": {
                "get": {
                    "summary": "JSON metrics",
                    "tags": ["metrics"],
                    "responses": {"200": {"description": "Metrics"}}
                }
            }
        },
        "/health": {
            "get": {
                "summary": "Health check",
                "tags": ["health"],
                "responses": {"200": {"description": "Service status"}}
            }
        },
        "/metrics": {
            "get": {
                "summary": "Prometheus metrics",
                "tags": ["metrics"],
                "responses": {"200": {"description": "Prometheus text format", "content": {"text/plain": {}}}}
            }
        },
        "components": {
            "securitySchemes": {
                "bearerAuth": {"type": "http", "scheme": "bearer"}
            },
            "schemas": {
                "OcrRequest": {
                    "type": "object",
                    "required": ["image"],
                    "properties": {
                        "image": {"type": "string", "description": "Base64-encoded image"},
                        "ocr_lang": {"type": "string", "default": "eng"}
                    }
                },
                "OcrResponse": {
                    "type": "object",
                    "properties": {
                        "text": {"type": "string"},
                        "engine": {"type": "string"},
                        "elapsed_ms": {"type": "integer"}
                    }
                },
                "VisionAnalyzeRequest": {
                    "type": "object",
                    "required": ["image"],
                    "properties": {
                        "image": {"type": "string"},
                        "mode": {"type": "string", "enum": ["text", "describe", "auto"], "default": "auto"},
                        "prompt": {"type": "string"},
                        "ocr_lang": {"type": "string", "default": "eng"},
                        "detail_level": {"type": "string", "default": "medium"}
                    }
                },
                "VisionAnalyzeResponse": {
                    "type": "object",
                    "properties": {
                        "mode_used": {"type": "string"},
                        "ocr": {"type": "object"},
                        "vision": {"type": "object"},
                        "meta": {"type": "object"}
                    }
                }
            }
        }
    });
    Ok(warp::reply::json(&spec))
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt::init();

    let auth_token = std::env::var("LUNARWING_AUTH_TOKEN").ok();
    let port = std::env::var("OCR_PORT")
        .ok()
        .and_then(|p| p.parse().ok())
        .unwrap_or(8088);

    let vl_url = std::env::var("VL_URL").ok();
    let vl_api_key = std::env::var("VL_API_KEY").ok();
    let vl_model = std::env::var("VL_MODEL").unwrap_or_else(|_| "qwen3-vl".to_string());
    let vl_timeout_secs = std::env::var("VL_TIMEOUT_SECS")
        .ok()
        .and_then(|p| p.parse().ok())
        .unwrap_or(30);
    let enable_paddleocr = std::env::var("ENABLE_PADDLEOCR").map(|v| v == "1" || v == "true").unwrap_or(false);
    let enable_cache = std::env::var("ENABLE_CACHE").map(|v| v == "1" || v == "true").unwrap_or(true);
    let enable_prometheus = std::env::var("ENABLE_PROMETHEUS").map(|v| v == "1" || v == "true").unwrap_or(true);
    let rate_limit_per_second = std::env::var("RATE_LIMIT_PER_SECOND")
        .ok()
        .and_then(|p| p.parse().ok())
        .unwrap_or(10);

    let config = Config {
        auth_token,
        port,
        vl_url,
        vl_api_key,
        vl_model,
        vl_timeout_secs,
        enable_paddleocr,
        enable_cache,
        enable_prometheus,
        rate_limit_per_second,
    };

    let quota = Quota::per_second(std::num::NonZeroU32::new(rate_limit_per_second).unwrap_or(std::num::NonZeroU32::new(10).unwrap()));
    let rate_limiter = Arc::new(RateLimiter::direct(quota));

    let start_time = Instant::now();

    // Cache tesseract version at startup instead of spawning subprocess per health check
    let tesseract_version = std::process::Command::new("tesseract")
        .arg("--version")
        .output()
        .ok()
        .and_then(|o| {
            String::from_utf8_lossy(&o.stdout)
                .lines()
                .next()
                .map(|s| s.to_string())
        })
        .unwrap_or_else(|| "unknown".to_string());

    tracing::info!("Tesseract: {}", tesseract_version);

    let state = AppState {
        config: config.clone(),
        cache: Arc::new(DashMap::new()),
        rate_limiter,
        metrics: Arc::new(Metrics::default()),
        start_time,
        tesseract_version,
    };

    let state_clone = state.clone();

    let api_v1 = warp::path("v1");

    let ocr_route = api_v1
        .and(warp::path("ocr"))
        .and(warp::post())
        .and(warp::body::content_length_limit(MAX_BODY_SIZE))
        .and(warp::body::bytes())
        .and(rate_limit_filter(state_clone.clone()))
        .and(auth_filter(state_clone.config.clone()))
        .and(with_state(state_clone.clone()))
        .and_then(ocr_handler);

    let vision_route = api_v1
        .and(warp::path("vision"))
        .and(warp::path("analyze"))
        .and(warp::post())
        .and(warp::body::content_length_limit(MAX_BODY_SIZE))
        .and(warp::body::bytes())
        .and(rate_limit_filter(state.clone()))
        .and(auth_filter(state.config.clone()))
        .and(with_state(state.clone()))
        .and_then(vision_analyze_handler);

    let metrics_route = api_v1
        .and(warp::path("vision"))
        .and(warp::path("metrics"))
        .and(warp::get())
        .and(with_state(state.clone()))
        .and_then(metrics_handler);

    let openapi_route = warp::path("openapi.json")
        .and(warp::get())
        .and_then(openapi_handler);

    let prometheus_route = warp::path("metrics")
        .and(warp::get())
        .and(with_state(state.clone()))
        .and_then(prometheus_metrics_handler);

    let health_route = warp::path("health")
        .and(warp::get())
        .and(with_state(state.clone()))
        .and_then(health_handler);

    let routes = ocr_route
        .or(vision_route)
        .or(metrics_route)
        .or(openapi_route)
        .or(prometheus_route)
        .or(health_route)
        .recover(handle_rejection);

    tracing::info!("Starting Vision Service on port {}", config.port);
    tracing::info!("PaddleOCR fallback: {}, Cache: {}, Rate limit: {}/s",
        config.enable_paddleocr, config.enable_cache, config.rate_limit_per_second);

    warp::serve(routes)
        .run(([0, 0, 0, 0], config.port))
        .await;
}
