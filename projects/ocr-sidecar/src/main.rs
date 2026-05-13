use std::convert::Infallible;
use std::time::Instant;

use base64::Engine;
use serde::{Deserialize, Serialize};
use warp::{Filter, Rejection, Reply};
use warp::http::StatusCode;

const MAX_BODY_SIZE: u64 = 10 * 1024 * 1024;

#[derive(Clone)]
struct Config {
    auth_token: Option<String>,
    port: u16,
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

fn with_config(config: Config) -> impl Filter<Extract = (Config,), Error = Infallible> + Clone {
    warp::any().map(move || config.clone())
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

async fn run_tesseract(image_bytes: &[u8]) -> Result<String, AppError> {
    let mut temp_file = tempfile::Builder::new()
        .suffix(".png")
        .tempfile()
        .map_err(|e| AppError::OcrEngineFailure(e.to_string()))?;

    std::io::Write::write_all(&mut temp_file, image_bytes)
        .map_err(|e| AppError::OcrEngineFailure(e.to_string()))?;

    let output = tokio::process::Command::new("tesseract")
        .arg(temp_file.path())
        .arg("stdout")
        .arg("-l").arg("eng")
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

    Ok(text)
}

async fn ocr_handler(
    body: bytes::Bytes,
    _config: Config,
) -> Result<impl Reply, Rejection> {
    let start = Instant::now();

    let req: OcrRequest = serde_json::from_slice(&body)
        .map_err(|e| warp::reject::custom(AppError::BadRequest(e.to_string())))?;

    let image_bytes = base64::engine::general_purpose::STANDARD
        .decode(&req.image)
        .map_err(|e| warp::reject::custom(AppError::BadRequest(format!("Invalid base64: {}", e))))?;

    validate_image_format(&image_bytes)
        .map_err(warp::reject::custom)?;

    let text = run_tesseract(&image_bytes)
        .await
        .map_err(warp::reject::custom)?;

    let elapsed = start.elapsed().as_millis() as u64;

    let response = OcrResponse {
        text,
        engine: "tesseract".to_string(),
        model: None,
        elapsed_ms: elapsed,
    };

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

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt::init();

    let auth_token = std::env::var("LUNARWING_AUTH_TOKEN").ok();
    let port = std::env::var("OCR_PORT")
        .ok()
        .and_then(|p| p.parse().ok())
        .unwrap_or(8088);

    let config = Config {
        auth_token,
        port,
    };

    let config_clone = config.clone();

    let ocr_route = warp::path("ocr")
        .and(warp::post())
        .and(warp::body::content_length_limit(MAX_BODY_SIZE))
        .and(warp::body::bytes())
        .and(auth_filter(config_clone.clone()))
        .and(with_config(config_clone.clone()))
        .and_then(ocr_handler);

    let health_route = warp::path("health")
        .and(warp::get())
        .and_then(health_handler);

    let routes = ocr_route
        .or(health_route)
        .recover(handle_rejection);

    tracing::info!("Starting OCR sidecar on port {}", config.port);

    warp::serve(routes)
        .run(([0, 0, 0, 0], config.port))
        .await;
}
