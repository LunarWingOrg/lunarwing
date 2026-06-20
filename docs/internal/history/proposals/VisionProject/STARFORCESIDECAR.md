# Starforce's OCR Sidecar — Integration Guide (Summary)

## Approach
Lightweight **sidecar container** running a Rust/warp HTTP server on port 8088. Engine-agnostic: wraps llama.cpp (or Tesseract/EasyOCR) behind a simple JSON API.

## Key Design Decisions
- Single endpoint: `POST /ocr` with base64 image input
- Returns `{ text, engine, model, elapsed_ms }`
- Bash wrapper script (`ic-ocr`) hides base64/curl complexity
- Dockerized with health check
- Future path: WASM tool wrapping the same HTTP API

## Source
Full guide saved from tinyhost link on 2026-05-02.

