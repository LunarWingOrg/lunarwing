# LunarWing OCR Sidecar

Lightweight OCR sidecar service for LunarWing/IronClaw siblings. Provides a REST API for text extraction from images using Tesseract.

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
  Siblings (http tool) ──→ POST /vision/analyze
  WASM tool (Phase 4) ──→ POST /vision/analyze
```

## Phase 3+ Roadmap

- Phase 3: PaddleOCR fallback, response caching, metrics endpoint, rate limiting
- Phase 4: WASM tool interface for native IronClaw integration

## License

Same as LunarWing/IronClaw
