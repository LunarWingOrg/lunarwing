# LunarWing OCR Sidecar

Lightweight OCR and vision analysis sidecar service for LunarWing. Provides a REST API for text extraction (Tesseract) and vision-language understanding (Qwen3-VL) with smart routing.

## Quick Start

```bash
# Build and run with Docker Compose
cd projects/ocr-sidecar
docker-compose up --build

# Or run locally (requires Rust + Tesseract)
cargo run
```

## API

### POST /ocr
Extract text from an image (Phase 1, backward compatible).

**Request:**
```json
{
  "image": "<base64-encoded image>"
}
```

**Response:**
```json
{
  "text": "extracted text...",
  "engine": "tesseract",
  "model": null,
  "elapsed_ms": 142
}
```

### POST /vision/analyze
Unified vision analysis endpoint with smart routing (Phase 2).

**Request:**
```json
{
  "image": "<base64-encoded image>",
  "mode": "text | describe | auto",
  "prompt": "optional custom question",
  "ocr_lang": "eng",
  "detail_level": "low | medium | high"
}
```

| Field | Required | Description |
|-------|----------|-------------|
| `image` | yes | Base64-encoded image |
| `mode` | no | `text`=OCR only, `describe`=VL only, `auto`=smart routing (default: auto) |
| `prompt` | no | Custom question for VL backend |
| `ocr_lang` | no | Tesseract language (default: eng) |
| `detail_level` | no | Controls VL token budget (default: medium) |

**Response:**
```json
{
  "mode_used": "text | describe | hybrid",
  "ocr": {
    "full_text": "extracted text...",
    "blocks": [
      { "text": "block text", "confidence": 0.97, "bbox": [x1, y1, x2, y2] }
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

**Smart Routing (`mode=auto`):**
1. Runs OCR first (always — cheap and fast)
2. If avg_confidence >= 0.85 AND prompt looks text-related → returns OCR only
3. If avg_confidence < 0.85 OR prompt is semantic/aesthetic → also runs VL, returns hybrid
4. Keyword heuristics: OCR-primary `["read", "say", "text", "extract"]`, VL-primary `["describe", "compare", "which", "looks", "color"]`

### GET /health
Health check endpoint (no auth required).

**Response:**
```json
{
  "status": "ok",
  "tesseract_version": "tesseract 5.3.1",
  "uptime_secs": 0
}
```

### GET /vision/metrics
Metrics endpoint (no auth required, Phase 3).

**Response:**
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

## Authentication

Set `LUNARWING_AUTH_TOKEN` environment variable to enable bearer token auth:

```bash
export LUNARWING_AUTH_TOKEN="your-secret-token"
```

All endpoints except `/health` require:
```
Authorization: Bearer <token>
```

## CLI Wrapper

The `ic-ocr` script wraps the API for easy command-line usage:

```bash
# Basic OCR (backward compatible)
./ic-ocr /tmp/screenshot.png

# Full JSON response
./ic-ocr --json /tmp/screenshot.png

# Vision analysis with auto-routing
./ic-ocr --mode auto /tmp/screenshot.png

# Vision analysis with custom prompt
./ic-ocr --mode describe --prompt "What colors are in this image?" /tmp/screenshot.png

# Custom port
OCR_PORT=8088 ./ic-ocr /tmp/screenshot.png
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `OCR_PORT` | `8088` | HTTP server port |
| `LUNARWING_AUTH_TOKEN` | none | Bearer token for auth |
| `VL_URL` | none | Vision-Language backend URL (e.g., llama.cpp OpenAI-compatible endpoint) |
| `VL_API_KEY` | none | API key for VL backend (optional) |
| `VL_MODEL` | `qwen3-vl` | VL model name |
| `ENABLE_PADDLEOCR` | `false` | Enable PaddleOCR fallback when Tesseract confidence < 0.7 |
| `ENABLE_CACHE` | `true` | Enable response caching (5 min TTL) |
| `RATE_LIMIT_PER_SECOND` | `10` | Per-IP rate limit for OCR/vision endpoints |

## Supported Image Formats

- PNG
- JPEG
- WebP
- TIFF

Max payload size: 10MB

## Error Responses

All errors return JSON:
```json
{
  "error": "error_code",
  "detail": "Human-readable message",
  "code": 400
}
```

Common error codes:
- `401` - Unauthorized (missing/invalid token)
- `413` - Payload Too Large (>10MB)
- `415` - Unsupported Media Type (invalid image format)
- `400` - Bad Request (malformed JSON or base64)
- `500` - OCR Engine Failure

## Deployment

### Docker
```bash
docker build -t lunarwing/ocr-sidecar .
docker run -p 8088:8088 -e LUNARWING_AUTH_TOKEN=secret lunarwing/ocr-sidecar
```

### Systemd
See `systemd/ocr-sidecar.service` for a systemd unit file template.

## Architecture

```
┌─────────────────────────────────────────────────┐
│         Vision Service (Rust/warp)              │
│         Docker container, port 8088             │
│                                                 │
│  Phase 1:                                       │
│  ┌──────────────────┐                           │
│  │  POST /ocr       │──→ Tesseract              │
│  └──────────────────┘                           │
│                                                 │
│  Phase 2:                                       │
│  ┌──────────────────┐   ┌─────────────────────┐ │
│  │ POST /vision/    │   │  Smart Router       │ │
│  │      analyze     │──→│                     │ │
│  └──────────────────┘   │  ┌───────────────┐  │ │
│                         │  │ OCR Engine    │  │ │
│                         │  │ Tesseract ────┤  │ │
│                         │  └───────────────┘  │ │
│                         │  ┌───────────────┐  │ │
│                         │  │ VL Engine     │  │ │
│                         │  │ Qwen3-VL ─────┤  │ │
│                         │  │ (llama.cpp)   │  │ │
│                         │  └───────────────┘  │ │
│                         │  ┌───────────────┐  │ │
│                         │  │ Response      │  │ │
│                         │  │ Merger        │  │ │
│                         │  └───────────────┘  │ │
│                         └─────────────────────┘ │
│                                                 │
│  ┌──────────────────┐                           │
│  │  GET /health     │──→ backend status check   │
│  └──────────────────┘                           │
└─────────────────────────────────────────────────┘

External:
  ic-ocr (bash) ──→ POST /ocr
  LunarWing (http tool) ──→ POST /vision/analyze
  WASM tool (Phase 4)   ──→ POST /vision/analyze
```

## Phase 3 Features

### PaddleOCR Fallback
When `ENABLE_PADDLEOCR=true`, if Tesseract confidence < 0.7, the service automatically tries PaddleOCR and uses the better result.

### Response Caching
When `ENABLE_CACHE=true` (default), responses are cached for 5 minutes based on image hash + prompt + mode. Identical requests return cached results instantly.

### Rate Limiting
All `/ocr` and `/vision/analyze` endpoints are rate-limited per IP (default: 10 req/s). Excess requests receive `400 Bad Request` with "Rate limit exceeded".

### Metrics
`GET /vision/metrics` provides real-time counters for requests, cache performance, and rate limiting.

## Phase 4: WASM Tool Integration

The `vision-analyze-tool` WASM component provides native LunarWing integration.

### Installation

```bash
# Build the WASM component
cd ic/tools-src/vision-analyze
cargo build --target wasm32-wasi --release

# Register with LunarWing
lunarwing tool install target/wasm32-wasi/release/vision_analyze_tool.wasm
```

### Usage from LunarWing

```
@vision_analyze image="./screenshot.png" mode="auto"
@vision_analyze image="<base64-data>" mode="describe" prompt="What colors are in this image?"
@vision_analyze image="./document.jpg" mode="text" ocr_lang="eng"
```

### Tool Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| `image` | yes | Base64-encoded image or workspace file path |
| `mode` | no | `text`, `describe`, or `auto` (default: auto) |
| `prompt` | no | Custom question for vision analysis |
| `ocr_lang` | no | OCR language code (default: eng) |

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `VISION_SERVICE_URL` | `http://127.0.0.1:8088` | Vision service endpoint |
| `VISION_AUTH_TOKEN` | none | Bearer token for authentication |

## License

AGPLv3 — same as LunarWing
