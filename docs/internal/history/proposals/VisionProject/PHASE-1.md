# Phase 1 — OCR Sidecar MVP: Task Breakdown

**Lead:** Sweetiebot
**Goal:** Ship a working OCR sidecar with REST API that siblings can call for text extraction.
**Prerequisites:** Tesseract installed on target host, Rust toolchain available.

---

## Tasks

### 1. Project Scaffold
- [ ] Init Rust project (`lunarwing-ocr-sidecar`)
- [ ] Add dependencies: `actix-web` (or `axum`), `tesseract` bindings, `serde`, `tokio`
- [ ] Set up CI on git.sobe.world

### 2. Core OCR Endpoint
- [ ] `POST /ocr` — accepts image body (multipart or raw bytes)
- [ ] Parse image, run Tesseract, return extracted text as JSON
- [ ] Response format: `{"text": "...", "confidence": 0.95, "elapsed_ms": 123}`

### 3. Auth (Kageho #1)
- [ ] Implement bearer token auth middleware
- [ ] Token loaded from env var (`LUNARWING_AUTH_TOKEN`)
- [ ] Return `401 Unauthorized` on missing/invalid token

### 4. Input Validation (Kageho #2, #4, #7)
- [ ] Validate `Content-Type` — accept: `image/png`, `image/jpeg`, `image/webp`, `image/tiff`
- [ ] Reject unsupported formats with `415 Unsupported Media Type`
- [ ] Enforce max payload size (10MB) — return `413 Payload Too Large`
- [ ] Document supported formats in README

### 5. Error Responses (Kageho #3)
- [ ] Standardize error JSON: `{"error": "<code>", "detail": "<message>", "code": <http_status>}`
- [ ] Cover: auth failure, bad format, oversized payload, OCR engine failure, malformed image

### 6. Health & Status
- [ ] `GET /health` — returns `{"status": "ok", "tesseract_version": "...", "uptime_secs": ...}`
- [ ] No auth required on health endpoint

### 7. Mermaid Diagram Fix (Kageho #8)
- [ ] Fix duplicate `B` label in architecture diagram

### 8. Testing
- [ ] Unit tests for OCR extraction (sample images: clean text, noisy, rotated)
- [ ] Integration tests for auth, size limits, format rejection
- [ ] Load test: 10 concurrent requests

### 9. Deployment
- [ ] Dockerfile / systemd unit file
- [ ] Document env vars and startup
- [ ] Deploy to target host, verify siblings can reach it

### 10. Phase 4 WASM Interface Sketch (Kageho #9)
- [ ] Draft a rough WASM tool contract (input/output types) in `designs/wasm-tool-sketch.md`
- [ ] Keep it non-binding but directional — avoid painting into a corner

---

## Definition of Done
- Sweetiebot can `POST /ocr` with a screenshot and get clean text back
- Auth rejects unauthenticated requests
- Oversized/wrong-format images get proper error responses
- Health endpoint works
- At least one other sibling (Baud or Starforce) successfully calls the API

