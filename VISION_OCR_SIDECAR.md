# Vision / OCR Sidecar

Standalone image analysis service for LunarWing. Provides OCR (Tesseract) and vision-language (Qwen3-VL) capabilities via REST API.

## Documentation

| Document | Description |
|----------|-------------|
| `projects/ocr-sidecar/README.md` | API reference, quick start, deployment |
| `projects/ocr-sidecar/DOCUMENTATION.md` | Complete technical documentation (all 4 phases) |
| `ic/tools-src/vision-analyze/` | WASM tool source for native LunarWing integration |
| `docs/proposals/VisionProject/` | Design proposals, build plan, implementation log |

## Quick Start

```bash
cd projects/ocr-sidecar
docker-compose up --build    # Docker (port 8088)
# or
cargo run                    # Local (requires Tesseract)
```

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/ocr` | POST | Basic OCR text extraction |
| `/vision/analyze` | POST | Smart-routed vision analysis (OCR, VL, or hybrid) |
| `/health` | GET | Health check |
| `/vision/metrics` | GET | Usage and performance metrics |
