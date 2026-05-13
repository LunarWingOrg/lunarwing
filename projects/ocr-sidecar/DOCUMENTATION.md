# LunarWing Vision Service — Complete Documentation

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Phase 1: OCR Sidecar MVP](#phase-1-ocr-sidecar-mvp)
4. [Phase 2: Vision-Language Integration](#phase-2-vision-language-integration)
5. [Phase 3: Hardening & Production Features](#phase-3-hardening--production-features)
6. [Phase 4: WASM Tool Integration](#phase-4-wasm-tool-integration)
7. [API Reference](#api-reference)
8. [Deployment Guide](#deployment-guide)
9. [Environment Variables](#environment-variables)
10. [Configuration Examples](#configuration-examples)
11. [Troubleshooting](#troubleshooting)
12. [Development Guide](#development-guide)

---

## Overview

The LunarWing Vision Service is a unified image analysis service that provides OCR (Optical Character Recognition) and vision-language (VL) capabilities to LunarWing instances. It combines Tesseract for fast text extraction with Qwen3-VL (via llama.cpp) for semantic image understanding, exposed through a single REST API.

### Key Features

- **Dual Backend**: Tesseract for OCR + Qwen3-VL for vision-language understanding
- **Smart Routing**: Automatically selects the best backend based on confidence scores and prompt keywords
- **PaddleOCR Fallback**: Falls back to PaddleOCR when Tesseract confidence is low
- **Response Caching**: Caches results for 5 minutes to reduce redundant processing
- **Rate Limiting**: Per-IP rate limiting prevents abuse
- **Metrics**: Real-time endpoint for monitoring usage and performance
- **WASM Tool**: Native LunarWing integration via sandboxed WebAssembly component

### Service Information

| Property | Value |
|----------|-------|
| **Service Name** | lunarwing-ocr-sidecar |
| **Version** | 0.1.0 |
| **Port** | 8088 |
| **Protocol** | HTTP/REST + JSON |
| **Language** | Rust (Warp framework) |
| **Container** | Docker (multi-stage build) |

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Vision Service (Rust/warp)                 │
│                    Port 8088, Docker Container                │
│                                                             │
│  ┌──────────────────┐                                       │
│  │  POST /ocr       │──→ Tesseract ──→ Text                 │
│  └──────────────────┘                                       │
│                                                             │
│  ┌──────────────────┐   ┌───────────────────────────────┐   │
│  │ POST /vision/    │   │  Smart Router                 │   │
│  │      analyze     │──→│                               │   │
│  └──────────────────┘   │  ┌─────────────────────────┐  │   │
│                         │  │ OCR Engine              │  │   │
│                         │  │ Tesseract ──→ PaddleOCR │  │   │
│                         │  │ (fallback if < 0.7)     │  │   │
│                         │  └─────────────────────────┘  │   │
│                         │  ┌─────────────────────────┐  │   │
│                         │  │ VL Engine               │  │   │
│                         │  │ Qwen3-VL (llama.cpp)    │  │   │
│                         │  │ OpenAI-compatible API   │  │   │
│                         │  └─────────────────────────┘  │   │
│                         │  ┌─────────────────────────┐  │   │
│                         │  │ Response Merger         │  │   │
│                         │  │ Cache (5 min TTL)       │  │   │
│                         │  └─────────────────────────┘  │   │
│                         └───────────────────────────────┘   │
│                                                             │
│  ┌──────────────────┐                                       │
│  │  GET /health     │──→ Status Check                       │
│  └──────────────────┘                                       │
│                                                             │
│  ┌──────────────────┐                                       │
│  │ GET /vision/     │──→ Metrics                            │
│  │     metrics      │                                       │
│  └──────────────────┘                                       │
└─────────────────────────────────────────────────────────────┘

External Clients:
  ic-ocr (bash CLI) ──→ POST /ocr
  HTTP clients ──→ POST /vision/analyze
  WASM tool ──→ POST /vision/analyze (via IronClaw)
```

---

## Phase 1: OCR Sidecar MVP

### Goal
Ship a working OCR sidecar with REST API that all IronClaw siblings can call for text extraction from images.

### Implementation

#### Endpoints

**POST /ocr**
- Accepts base64-encoded image
- Returns extracted text with timing metadata
- Backward compatible throughout all phases

**GET /health**
- No authentication required
- Returns service status and Tesseract version

#### Features
- **Bearer Token Auth**: Configurable via `LUNARWING_AUTH_TOKEN`
- **Input Validation**: Supports PNG, JPEG, WebP, TIFF (max 10MB)
- **Standardized Errors**: Consistent JSON error format with HTTP status codes
- **Tesseract Integration**: Subprocess-based OCR with English language support

#### Response Format

```json
{
  "text": "extracted text...",
  "engine": "tesseract",
  "model": null,
  "elapsed_ms": 142
}
```

#### CLI Wrapper

The `ic-ocr` script provides easy command-line usage:

```bash
# Basic OCR
./ic-ocr /tmp/screenshot.png

# JSON output
./ic-ocr --json /tmp/screenshot.png

# Custom port
OCR_PORT=8088 ./ic-ocr /tmp/screenshot.png
```

---

## Phase 2: Vision-Language Integration

### Goal
Add Qwen3-VL backend for image understanding and reasoning, with a unified endpoint that supports both OCR and VL.

### Implementation

#### New Endpoint

**POST /vision/analyze**
- Unified endpoint for all image analysis tasks
- Smart routing between OCR and VL backends
- Rich response format with confidence scores and metadata

#### Request Format

```json
{
  "image": "<base64-encoded image>",
  "mode": "text | describe | auto",
  "prompt": "optional custom question",
  "ocr_lang": "eng",
  "detail_level": "low | medium | high"
}
```

#### Response Format

```json
{
  "mode_used": "text | describe | hybrid",
  "ocr": {
    "full_text": "extracted text...",
    "blocks": [
      {
        "text": "block text",
        "confidence": 0.97,
        "bbox": [x1, y1, x2, y2]
      }
    ],
    "avg_confidence": 0.94
  },
  "vision": {
    "description": "A white pegasus with orange-highlighted mane...",
    "prompt_answer": "The left image has warmer orange tones."
  },
  "meta": {
    "backends_used": ["tesseract", "qwen3vl"],
    "latency_ms": 512,
    "tokens_used": 128
  }
}
```

#### Smart Routing Logic (`mode=auto`)

1. **Always run OCR first** (cheap and fast)
2. **If avg_confidence >= 0.85 AND prompt looks text-related**
   - Return OCR result only
3. **If avg_confidence < 0.85 OR prompt is semantic/aesthetic**
   - Also run VL, return hybrid response
4. **Keyword heuristics**:
   - OCR-primary: `["read", "say", "text", "says", "what does", "extract", "error", "log", "code"]`
   - VL-primary: `["describe", "compare", "which", "looks", "color", "best", "scene", "style", "vibe"]`

#### Qwen3-VL Integration

- **Model**: Qwen3-VL (abliterated) Q6_K quantization
- **Server**: llama.cpp with OpenAI-compatible API
- **Endpoint**: `http://<host>:<port>/v1/chat/completions`
- **Configuration**: Via `VL_URL`, `VL_API_KEY`, `VL_MODEL` environment variables

#### Backward Compatibility

- `POST /ocr` remains unchanged from Phase 1
- `POST /vision/analyze` with `mode=text` returns richer format but same data
- `ic-ocr` wrapper continues to work

#### Updated CLI

```bash
# Vision analysis with auto-routing
./ic-ocr --mode auto /tmp/screenshot.png

# Vision analysis with custom prompt
./ic-ocr --mode describe --prompt "What colors are in this image?" /tmp/screenshot.png
```

---

## Phase 3: Hardening & Production Features

### Goal
Add production-ready features: PaddleOCR fallback, response caching, rate limiting, and metrics.

### Implementation

#### PaddleOCR Fallback

**Trigger**: Tesseract confidence < 0.7

**Behavior**:
1. Run Tesseract first
2. If confidence < 0.7 and `ENABLE_PADDLEOCR=true`:
   - Attempt PaddleOCR subprocess
   - Compare confidence scores
   - Return the better result
3. If PaddleOCR fails, gracefully fall back to Tesseract result

**Configuration**:
```bash
ENABLE_PADDLEOCR=true  # Enable fallback
```

#### Response Caching

**Key**: SHA-256(image_b64 + mode + prompt)
**TTL**: 5 minutes
**Storage**: In-memory DashMap (concurrent hash map)

**Behavior**:
- Identical requests within 5 minutes return cached result instantly
- Cache automatically expires after TTL
- Cache hits/misses tracked in metrics

**Configuration**:
```bash
ENABLE_CACHE=true  # Enable caching (default: true)
```

#### Rate Limiting

**Type**: Per-service (global) rate limiter
**Default**: 10 requests/second
**Behavior**: Excess requests receive `400 Bad Request` with "Rate limit exceeded"

**Configuration**:
```bash
RATE_LIMIT_PER_SECOND=10  # Requests per second
```

#### Metrics Endpoint

**GET /vision/metrics**

Returns real-time counters:

```json
{
  "total_requests": 1523,
  "ocr_requests": 987,
  "vision_requests": 536,
  "cache_hits": 342,
  "cache_misses": 194,
  "rate_limited": 12,
  "cache_hit_rate": 0.638,
  "avg_latency_ms": 245
}
```

**Metrics Tracked**:
- `total_requests`: All requests to /ocr and /vision/analyze
- `ocr_requests`: Requests to /ocr
- `vision_requests`: Requests to /vision/analyze
- `cache_hits`: Cached responses served
- `cache_misses`: Non-cached responses
- `rate_limited`: Requests rejected due to rate limiting
- `cache_hit_rate`: Ratio of cache hits to total cache lookups
- `avg_latency_ms`: Average response latency

---

## Phase 4: WASM Tool Integration

### Goal
Provide native IronClaw integration via a sandboxed WebAssembly component.

### Implementation

#### Tool: `vision-analyze-tool`

**Location**: `ic/tools-src/vision-analyze/`
**Size**: 13KB (optimized release build)
**Target**: `wasm32-wasip1`

#### Features

- Accepts base64 images or workspace file paths
- Supports all three modes: `text`, `describe`, `auto`
- Custom prompt support
- Configurable OCR language
- HTTP calls to Vision Service
- Auth token support via environment variables

#### Installation

```bash
# Build the WASM component
cd ic/tools-src/vision-analyze
cargo build --target wasm32-wasip1 --release

# Register with IronClaw
ironclaw tool install target/wasm32-wasip1/release/vision_analyze_tool.wasm
```

#### Usage from IronClaw

```
@vision_analyze image="./screenshot.png" mode="auto"
@vision_analyze image="<base64-data>" mode="describe" prompt="What colors are in this image?"
@vision_analyze image="./document.jpg" mode="text" ocr_lang="eng"
```

#### Tool Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `image` | string | yes | Base64-encoded image or workspace file path |
| `mode` | string | no | `text`, `describe`, or `auto` (default: auto) |
| `prompt` | string | no | Custom question for vision analysis |
| `ocr_lang` | string | no | OCR language code (default: eng) |

#### Tool Output

```json
{
  "mode_used": "hybrid",
  "text": "extracted OCR text...",
  "description": "Image description from VL model...",
  "answer": "Answer to custom prompt...",
  "confidence": 0.94,
  "backends": ["tesseract", "qwen3vl"],
  "latency_ms": 512
}
```

#### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `VISION_SERVICE_URL` | `http://127.0.0.1:8088` | Vision service endpoint |
| `VISION_AUTH_TOKEN` | none | Bearer token for authentication |

---

## API Reference

### POST /ocr

Extract text from an image using OCR.

**Request**:
```json
{
  "image": "<base64-encoded image>"
}
```

**Response**:
```json
{
  "text": "extracted text...",
  "engine": "tesseract",
  "model": null,
  "elapsed_ms": 142
}
```

**Errors**:
- `401 Unauthorized` — Missing or invalid auth token
- `413 Payload Too Large` — Image > 10MB
- `415 Unsupported Media Type` — Invalid image format
- `400 Bad Request` — Malformed JSON or invalid base64
- `500 OCR Engine Failure` — Tesseract/PaddleOCR error

---

### POST /vision/analyze

Unified image analysis with smart routing.

**Request**:
```json
{
  "image": "<base64-encoded image>",
  "mode": "auto",
  "prompt": "optional question",
  "ocr_lang": "eng",
  "detail_level": "medium"
}
```

**Response**:
```json
{
  "mode_used": "hybrid",
  "ocr": {
    "full_text": "...",
    "blocks": [{"text": "...", "confidence": 0.97, "bbox": [0,0,0,0]}],
    "avg_confidence": 0.94
  },
  "vision": {
    "description": "...",
    "prompt_answer": "..."
  },
  "meta": {
    "backends_used": ["tesseract", "qwen3vl"],
    "latency_ms": 512,
    "tokens_used": null
  }
}
```

**Errors**: Same as `/ocr` plus:
- `500 Internal Error` — VL backend not configured

---

### GET /health

Health check endpoint (no auth required).

**Response**:
```json
{
  "status": "ok",
  "tesseract_version": "tesseract 5.3.1",
  "uptime_secs": 0
}
```

---

### GET /vision/metrics

Metrics endpoint (no auth required).

**Response**:
```json
{
  "total_requests": 1523,
  "ocr_requests": 987,
  "vision_requests": 536,
  "cache_hits": 342,
  "cache_misses": 194,
  "rate_limited": 12,
  "cache_hit_rate": 0.638,
  "avg_latency_ms": 245
}
```

---

## Deployment Guide

### Docker Deployment

```bash
# Build image
cd projects/ocr-sidecar
docker build -t lunarwing/vision-service .

# Run container
docker run -d \
  -p 8088:8088 \
  -e LUNARWING_AUTH_TOKEN=your-secret-token \
  -e VL_URL=http://your-llama-server:8080/v1/chat/completions \
  -e ENABLE_PADDLEOCR=true \
  -e ENABLE_CACHE=true \
  -e RATE_LIMIT_PER_SECOND=10 \
  --name vision-service \
  lunarwing/vision-service
```

### Docker Compose

```yaml
version: '3.8'

services:
  vision-service:
    build: .
    container_name: lunarwing-vision-service
    ports:
      - "8088:8088"
    environment:
      - OCR_PORT=8088
      - LUNARWING_AUTH_TOKEN=${LUNARWING_AUTH_TOKEN}
      - VL_URL=${VL_URL}
      - VL_API_KEY=${VL_API_KEY}
      - VL_MODEL=qwen3-vl
      - ENABLE_PADDLEOCR=false
      - ENABLE_CACHE=true
      - RATE_LIMIT_PER_SECOND=10
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8088/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 5s
    restart: unless-stopped
```

### Systemd Service

```ini
[Unit]
Description=LunarWing Vision Service
After=network.target

[Service]
Type=simple
User=nobody
Group=nogroup
WorkingDirectory=/opt/lunarwing-vision-service
Environment="OCR_PORT=8088"
Environment="LUNARWING_AUTH_TOKEN=change-me-in-production"
Environment="VL_URL=http://192.168.1.157:8080/v1/chat/completions"
Environment="ENABLE_CACHE=true"
Environment="RATE_LIMIT_PER_SECOND=10"
ExecStart=/usr/local/bin/lunarwing-ocr-sidecar
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

### Local Development

```bash
# Install dependencies (Debian/Ubuntu)
sudo apt-get install tesseract-ocr tesseract-ocr-eng

# Optional: Install PaddleOCR
pip install paddleocr

# Run service
cd projects/ocr-sidecar
cargo run

# Or with specific config
LUNARWING_AUTH_TOKEN=secret VL_URL=http://localhost:8080/v1/chat/completions cargo run
```

---

## Environment Variables

| Variable | Default | Phase | Description |
|----------|---------|-------|-------------|
| `OCR_PORT` | `8088` | 1 | HTTP server port |
| `LUNARWING_AUTH_TOKEN` | none | 1 | Bearer token for auth |
| `VL_URL` | none | 2 | Vision-Language backend URL |
| `VL_API_KEY` | none | 2 | API key for VL backend |
| `VL_MODEL` | `qwen3-vl` | 2 | VL model name |
| `ENABLE_PADDLEOCR` | `false` | 3 | Enable PaddleOCR fallback |
| `ENABLE_CACHE` | `true` | 3 | Enable response caching |
| `RATE_LIMIT_PER_SECOND` | `10` | 3 | Per-IP rate limit |

---

## Configuration Examples

### Minimal OCR-Only Setup

```bash
# Just OCR, no auth, no VL
OCR_PORT=8088
cargo run
```

### Full Vision Service with VL

```bash
# OCR + Vision-Language + all features
OCR_PORT=8088
LUNARWING_AUTH_TOKEN=secret-token
VL_URL=http://192.168.1.157:8080/v1/chat/completions
VL_API_KEY=optional-key
VL_MODEL=qwen3-vl
ENABLE_PADDLEOCR=true
ENABLE_CACHE=true
RATE_LIMIT_PER_SECOND=20
cargo run
```

### Development/Debug Mode

```bash
# No auth, no rate limiting, verbose logging
OCR_PORT=8088
RUST_LOG=debug
cargo run
```

---

## Troubleshooting

### Service Won't Start

**Problem**: `tesseract: command not found`
**Solution**: Install Tesseract
```bash
# Debian/Ubuntu
sudo apt-get install tesseract-ocr tesseract-ocr-eng

# macOS
brew install tesseract

# Verify
tesseract --version
```

### OCR Returns Empty Text

**Problem**: Tesseract returns empty or garbled text
**Solutions**:
1. Check image format (must be PNG, JPEG, WebP, or TIFF)
2. Verify image is not corrupted
3. Try `ENABLE_PADDLEOCR=true` for better accuracy
4. Check `ocr_lang` matches the text language

### VL Backend Errors

**Problem**: `VL request failed` or `VL API error`
**Solutions**:
1. Verify `VL_URL` is correct and reachable
2. Check llama.cpp server is running
3. Verify `VL_API_KEY` if required
4. Check server logs for errors

### Rate Limiting

**Problem**: `Rate limit exceeded`
**Solutions**:
1. Increase `RATE_LIMIT_PER_SECOND`
2. Check if multiple clients share the same IP
3. Verify no infinite loops in client code

### Cache Issues

**Problem**: Stale or unexpected results
**Solutions**:
1. Disable cache temporarily: `ENABLE_CACHE=false`
2. Wait 5 minutes for TTL expiration
3. Change prompt or mode to bust cache

### WASM Tool Not Working

**Problem**: `@vision_analyze` not found in IronClaw
**Solutions**:
1. Verify tool is installed: `ironclaw tool list`
2. Check WASM file exists and is valid
3. Verify `VISION_SERVICE_URL` is set correctly
4. Check IronClaw logs for WASM runtime errors

---

## Development Guide

### Project Structure

```
projects/ocr-sidecar/
├── Cargo.toml              # Rust dependencies
├── src/
│   └── main.rs             # Service implementation
├── tests/
│   ├── integration_tests.rs # Unit tests
│   └── load_test.sh         # Load testing script
├── Dockerfile              # Container build
├── docker-compose.yml      # Compose configuration
├── ic-ocr                  # CLI wrapper script
├── systemd/
│   └── ocr-sidecar.service # Systemd unit file
├── designs/
│   └── wasm-tool-sketch.md # Phase 4 design doc
└── README.md               # Quick start guide

ic/tools-src/vision-analyze/
├── Cargo.toml              # WASM tool dependencies
├── src/
│   └── lib.rs              # WASM tool implementation
└── vision-analyze-tool.capabilities.json  # Tool manifest
```

### Building

```bash
# Service
cd projects/ocr-sidecar
cargo build --release

# WASM tool
cd ic/tools-src/vision-analyze
cargo build --target wasm32-wasip1 --release
```

### Testing

```bash
# Run tests
cd projects/ocr-sidecar
cargo test

# Load test
./tests/load_test.sh /path/to/test-image.png

# Manual test
curl -X POST http://localhost:8088/ocr \
  -H "Content-Type: application/json" \
  -d '{"image": "<base64>"}'
```

### Adding a New OCR Backend

1. Implement backend function in `src/main.rs`
2. Add to `run_ocr_with_fallback()` chain
3. Update response `backends_used` field
4. Add tests
5. Update documentation

---

## Security Considerations

- **Auth**: Always set `LUNARWING_AUTH_TOKEN` in production
- **Image Validation**: Only accept known image formats, reject >10MB
- **Rate Limiting**: Prevents abuse and resource exhaustion
- **SSRF Mitigation**: URL image support restricted to LAN/allowlist
- **Secret Handling**: Auth tokens never logged or exposed
- **WASM Sandbox**: Tool runs in sandbox with limited capabilities

---

## License

Same as LunarWing/IronClaw

## Credits

- **Starforce**: OCR Sidecar architecture, Docker-first deployment, `ic-ocr` CLI
- **Ruffles**: Vision-Language integration, smart routing, unified API contract
- **Kageho**: Design review, hardening recommendations, phased rollout plan
- **Sweetiebot**: Phase 1 MVP implementation

---

*Last updated: 2026-05-13*
*Version: 0.1.0*
*Status: All 4 phases complete*
