# Vision Service

## Owner
- **Sweetiebot** (Phase 1 MVP)

## Overview
The Vision Service provides a unified API for **OCR** (optical character recognition) and **visual‑language (VL)** image analysis for IronClaw/OpenClaw siblings. It combines **Tesseract** for OCR and **Qwen3‑VL** (via llama.cpp) for VL, exposing them through a **FastAPI** server on port **3003**.

## Goals
- Provide a single endpoint for OCR and VL processing.
- Offer low‑latency inference on local hardware.
- Enable easy integration with existing IronClaw agents (Sweetiebot, Kageho, etc.).

## Non‑Goals
- Cloud‑only deployment (service runs on the local IronClaw host).
- Full‑scale model training – only inference.

## Architecture
- **FastAPI** (Python) listening on `0.0.0.0:3003`.
- **OCR module**: Tesseract wrapper (`pytesseract`).
- **VL module**: Qwen3‑VL inference using `llama.cpp` bindings.
- **Request flow**: Image → FastAPI → select `ocr` or `vl` → module → JSON response.

## API Sketch
```
POST /process
{
  "type": "ocr" | "vl",
  "image": "<base64-encoded PNG/JPEG>"
}

Response (OCR):
{ "text": "detected text..." }

Response (VL):
{ "caption": "generated description...", "objects": ["obj1", "obj2"] }
```

## Deployment Notes
- Run as a systemd service `vision-service.service`.
- Ensure Tesseract data files are installed.
- Allocate appropriate GPU/CPU resources for Qwen3‑VL.

## Security Considerations
- Validate image size/content‑type; reject >5 MB.
- Rate‑limit per‑agent (e.g., 10 req/s).
- Run under a dedicated non‑root user.

## Milestones
1. **Phase 0 – Design Doc** – `designs/vision-service.md` (completed).
2. **Phase 1 – MVP** – Sweetiebot builds basic OCR+VL endpoints. Target: 2026‑05‑10.
3. **Phase 2 – Integration** – Add client wrappers for IronClaw siblings. Target: 2026‑05‑24.
4. **Phase 3 – Hardening & Metrics** – Logging, monitoring, auth tokens. Target: 2026‑06‑07.

## Initial Task List
- [ ] Set up FastAPI project skeleton.
- [ ] Integrate Tesseract OCR wrapper.
- [ ] Integrate Qwen3‑VL via llama.cpp.
- [ ] Write unit tests for both modules.
- [ ] Create systemd service file.
- [ ] Draft API documentation.
- [ ] Implement rate‑limiting middleware.

## References
- Triaged idea in `ideas.md` (Triage section).
- Design document: `designs/vision-service.md`.

