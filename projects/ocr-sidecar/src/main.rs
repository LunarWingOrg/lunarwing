use std::convert::Infallible;
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::{Duration, Instant};

use base64::Engine;
use dashmap::DashMap;
use governor::{DefaultDirectRateLimiter, Quota, RateLimiter};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use warp::{Filter, Rejection, Reply};
use warp::http::StatusCode;

const MAX_BODY_SIZE: u64 = 10 * 1024 * 1024;
const CACHE_TTL_SECS: u64 = 300;

#[derive(Clone)]
struct Config {
    auth_token: Option<String>,
    port: u16,
    vl_url: Option<String>,
    vl_api_key: Option<String>,
    vl_model: String,
    enable_paddleocr: bool,
    enable_cache: bool,
    rate_limit_per_second: u32,
}

#[derive(Clone)]
struct AppState {
    config: Config,
    cache: Arc<DashMap<String, CachedResponse>>,
    rate_limiter: Arc<DefaultDirectRateLimiter>,
    metrics: Arc<Metrics>,
}

#[derive(Clone, Debug)]
struct CachedResponse {
    response: String,
    created_at: Instant,
}

#[derive(Clone, Debug, Default)]
struct Metrics {
    total_requests: std::sync::atomic::AtomicU64,
    ocr_requests: std::sync::atomic::AtomicU64,
    vision_requests: std::sync::atomic::AtomicU64,
    cache_hits: std::sync::atomic::AtomicU64,
    cache_misses: std::sync::atomic::AtomicU64,
    rate_limited: std::sync::atomic::AtomicU64,
    avg_latency_ms: std::sync::atomic::AtomicU64,
}

#[derive(Debug, Deserialize)]
struct OcrRequest {
    image: String,
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
    warp::addr::remote()
        .and_then(move |addr: Option<SocketAddr>| {
            let state = state.clone();
            async move {
                match addr {
                    Some(socket_addr) => {
                        let ip = socket_addr.ip().to_string();
                        match state.rate_limiter.check_key(&ip) {
                            Ok(()) => Ok(()),
                            Err(_) => {
                                state.metrics.rate_limited.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                                Err(warp::reject::custom(AppError::BadRequest("Rate limit exceeded".to_string())))
                            }
                        }
                    }
                    None => Ok(()),
                }
            }
        })
        .untuple_one()
}

fn auth_filter(config: Config) -> impl Filter<Extract = (), Error = Rejection> + Clone {
    warp::header::optional("authorization")
        .and(with_config(config))
        .and_then(|auth: Option<String>, cfg: Config| async move {
            match cfg.auth_token {
                None => Ok(()),
                Some(expected) => {
                    match auth {
                        Some(header) if header.starts_with("Bearer ") => {
                            let provided = header.trim_start_matches("Bearer ");
                            if provided == expected {
                                Ok(())
                            } else {
                                Err(warp::reject::custom(AppError::Unauthorized))
                            }
                        }
                        _ => Err(warp::reject::custom(AppError::Unauthorized)),
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
    let mut result = run_tesseract(image_bytes, lang).await?;
    
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

fn generate_cache_key(image_b64: &str, prompt: &Option<String>, mode: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(image_b64.as_bytes());
    hasher.update(mode.as_bytes());
    if let Some(p) = prompt {
        hasher.update(p.as_bytes());
    }
    format!("{:x}", hasher.finalize())
}

fn check_cache(cache: &DashMap<String, CachedResponse>, key: &str) -> Option<String> {
    if let Some(entry) = cache.get(key) {
        if entry.created_at.elapsed().as_secs() < CACHE_TTL_SECS {
            return Some(entry.response.clone());
        }
    }
    None
}

fn store_cache(cache: &DashMap<String, CachedResponse>, key: String, response: String) {
    cache.insert(key, CachedResponse {
        response,
        created_at: Instant::now(),
    });
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
            }
            ocr_result.avg_confidence < 0.85
        }
        _ => false,
    }
}

async fn run_vl(image_b64: &str, prompt: &str, config: &Config) -> Result<VisionResult, AppError> {
    let vl_url = config.vl_url.as_ref()
        .ok_or_else(|| AppError::InternalError)?;
    
    let client = reqwest::Client::new();
    
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
        "max_tokens": 1024
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
    
    Ok(VisionResult {
        description,
        prompt_answer: None,
    })
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
        let cache_key = generate_cache_key(&req.image, &req.prompt, &req.mode);
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
    
    let vision_result = if use_vl {
        let prompt = req.prompt.as_deref().unwrap_or("Describe this image.");
        match run_vl(&req.image, prompt, &state.config).await {
            Ok(result) => Some(result),
            Err(e) => {
                tracing::warn!("VL failed, falling back to OCR only: {}", e);
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
            tokens_used: None,
        },
    };
    
    // Store in cache
    if state.config.enable_cache {
        let cache_key = generate_cache_key(&req.image, &req.prompt, &req.mode);
        if let Ok(json_str) = serde_json::to_string(&response) {
            store_cache(&state.cache, cache_key, json_str);
        }
    }
    
    // Update metrics
    state.metrics.total_requests.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    state.metrics.vision_requests.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    
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

    let ocr_result = run_ocr_with_fallback(&image_bytes, "eng", state.config.enable_paddleocr)
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

    Ok(warp::reply::json(&response))
}

async fn health_handler() -> Result<impl Reply, Rejection> {
    let version_output = tokio::process::Command::new("tesseract")
        .arg("--version")
        .output()
        .await
        .map_err(|_| warp::reject::custom(AppError::InternalError))?;

    let version = String::from_utf8_lossy(&version_output.stdout);
    let tesseract_version = version.lines().next()
        .unwrap_or("unknown")
        .to_string();

    let response = HealthResponse {
        status: "ok".to_string(),
        tesseract_version,
        uptime_secs: 0,
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
    let enable_paddleocr = std::env::var("ENABLE_PADDLEOCR").map(|v| v == "1" || v == "true").unwrap_or(false);
    let enable_cache = std::env::var("ENABLE_CACHE").map(|v| v == "1" || v == "true").unwrap_or(true);
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
        enable_paddleocr,
        enable_cache,
        rate_limit_per_second,
    };

    let quota = Quota::per_second(std::num::NonZeroU32::new(rate_limit_per_second).unwrap_or(std::num::NonZeroU32::new(10).unwrap()));
    let rate_limiter = Arc::new(RateLimiter::direct(quota));

    let state = AppState {
        config: config.clone(),
        cache: Arc::new(DashMap::new()),
        rate_limiter,
        metrics: Arc::new(Metrics::default()),
    };

    let state_clone = state.clone();

    let ocr_route = warp::path("ocr")
        .and(warp::post())
        .and(warp::body::content_length_limit(MAX_BODY_SIZE))
        .and(warp::body::bytes())
        .and(rate_limit_filter(state_clone.clone()))
        .and(auth_filter(state_clone.config.clone()))
        .and(with_state(state_clone.clone()))
        .and_then(ocr_handler);

    let vision_route = warp::path("vision")
        .and(warp::path("analyze"))
        .and(warp::post())
        .and(warp::body::content_length_limit(MAX_BODY_SIZE))
        .and(warp::body::bytes())
        .and(rate_limit_filter(state.clone()))
        .and(auth_filter(state.config.clone()))
        .and(with_state(state.clone()))
        .and_then(vision_analyze_handler);

    let metrics_route = warp::path("vision")
        .and(warp::path("metrics"))
        .and(warp::get())
        .and(with_state(state.clone()))
        .and_then(metrics_handler);

    let health_route = warp::path("health")
        .and(warp::get())
        .and_then(health_handler);

    let routes = ocr_route
        .or(vision_route)
        .or(metrics_route)
        .or(health_route)
        .recover(handle_rejection);

    tracing::info!("Starting Vision Service on port {}", config.port);
    tracing::info!("PaddleOCR fallback: {}, Cache: {}, Rate limit: {}/s", 
        config.enable_paddleocr, config.enable_cache, config.rate_limit_per_second);

    warp::serve(routes)
        .run(([0, 0, 0, 0], config.port))
        .await;
}
