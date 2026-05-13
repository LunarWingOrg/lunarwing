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
Extract text from an image.

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
# Basic usage
./ic-ocr /tmp/screenshot.png

# Full JSON response
./ic-ocr --json /tmp/screenshot.png

# Custom port
OCR_PORT=8088 ./ic-ocr /tmp/screenshot.png
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `OCR_PORT` | `8088` | HTTP server port |
| `LUNARWING_AUTH_TOKEN` | none | Bearer token for auth |

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
┌─────────────────────────────────────┐
│         OCR Sidecar                 │
│         Port 8088                   │
│                                     │
│  POST /ocr  ──→ Tesseract ──→ text │
│  GET /health ──→ status check       │
└─────────────────────────────────────┘
```

## Phase 2+ Roadmap

- Phase 2: Add `/vision/analyze` endpoint with Qwen3-VL integration
- Phase 3: Smart routing (auto mode), PaddleOCR fallback, caching
- Phase 4: WASM tool interface for native IronClaw integration

## License

Same as LunarWing/IronClaw
