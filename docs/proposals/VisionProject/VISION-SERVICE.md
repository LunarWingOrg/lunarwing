# IronClaw Vision Service — Merged Design (Ruffles + Starforce)

## Overview
A unified image analysis service merging Starforce's OCR Sidecar with Ruffles' Vision Service design. Starts as a lightweight Docker sidecar for OCR, evolves into a full OCR + Vision-Language service with smart routing.

All siblings call one service; the service routes internally.

---

## Phase 1 — OCR Sidecar MVP (Starforce's foundation)

### Goal
Ship a working OCR service that all siblings can call immediately.

### Repository Layout
```
projects/
└─ ocr_sidecar/
   ├─ Dockerfile                # builds the side-car container
   ├─ docker-compose.yml        # spin-up service + healthcheck
   ├─ src/
   │   └─ main.rs               # Rust/warp HTTP server
   ├─ ic-ocr                    # bash CLI wrapper
   └─ README.md
```

### API

#### `POST /ocr`
Request:
```json
{
  "image": "<base64-encoded image>"
}
```

Response:
```json
{
  "text": "extracted text...",
  "engine": "tesseract",
  "model": null,
  "elapsed_ms": 142
}
```

### CLI Wrapper (`ic-ocr`)
```bash
# Basic usage
ic-ocr /tmp/screenshot.png

# Full JSON response
ic-ocr --json /tmp/screenshot.png

# Custom port
OCR_PORT=8088 ic-ocr /tmp/screenshot.png
```

### Deployment
- **Container**: Docker, port **8088**
- **Engine**: Tesseract (default), engine-agnostic design allows swap to EasyOCR/PaddleOCR
- **Health check**: `GET /health` built into docker-compose
- **Host**: runs on LAN alongside TensorZero (192.168.1.157)

### Phase 1 Checklist
- [ ] Dockerfile + docker-compose.yml
- [ ] Rust/warp server with `POST /ocr` endpoint
- [ ] Tesseract integration (subprocess or library binding)
- [ ] `ic-ocr` bash wrapper script
- [ ] `GET /health` endpoint
- [ ] Deploy on LAN, verify from all siblings
- [ ] Test with: screenshot, error log, UI label, handwritten text

---

## Phase 2 — Vision-Language Integration (Ruffles' extension)

### Goal
Add Qwen3-VL backend for image understanding/reasoning. Extend the API with a unified endpoint that supports both OCR and VL.

### New Unified Endpoint

#### `POST /vision/analyze`
Request:
```json
{
  "image": "<base64 or URL>",
  "mode": "text | describe | auto",
  "prompt": "optional — freeform question about the image",
  "ocr_lang": "eng",
  "detail_level": "low | medium | high"
}
```

| Field | Required | Notes |
|-------|----------|-------|
| `image` | yes | Base64-encoded image OR reachable URL |
| `mode` | yes | `text` = OCR only, `describe` = VL only, `auto` = smart routing |
| `prompt` | no | Custom question for VL backend (default: "Describe this image.") |
| `ocr_lang` | no | Tesseract language pack (default: `eng`) |
| `detail_level` | no | Controls VL token budget / OCR precision |

Response:
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

### Backward Compatibility
- `POST /ocr` remains available and unchanged (Phase 1 API)
- `POST /vision/analyze` with `mode=text` returns the same data as `/ocr` but in the richer response format
- `ic-ocr` wrapper continues to work against `/ocr`

### Smart Routing Logic (`mode=auto`)
```
1. Run OCR first (always — cheap and fast)
2. If avg_confidence >= 0.85 AND prompt looks text-related
   → return OCR result only
3. If avg_confidence < 0.85 OR prompt is semantic/aesthetic
   → also run VL, return hybrid response
4. If prompt contains aesthetic keywords
   → run VL as primary, OCR as supplement
```

**Prompt keyword heuristic:**
- OCR-primary: `["read", "say", "text", "says", "what does", "extract", "error", "log", "code"]`
- VL-primary: `["describe", "compare", "which", "looks", "color", "best", "scene", "style", "vibe"]`

**Confidence thresholds:**
- `>= 0.85`: trust OCR alone
- `< 0.70`: OCR unreliable, must run VL

### OCR Backend (extended)
| Engine | When to use | Pros | Cons |
|--------|------------|------|------|
| **Tesseract** | Default first pass | Fast, low RAM, well-tested | Weak on stylized fonts |
| **PaddleOCR** | Tesseract confidence < 0.7 | Better accuracy, handles layout | Heavier, slower |

**Fallback chain:** Tesseract → PaddleOCR → VL (last resort, labeled low-confidence)

### Vision-Language Backend
| Setting | Value |
|---------|-------|
| **Model** | Qwen3-VL (abliterated) Q6_K quantization |
| **Server** | llama.cpp on RTX 4090 |
| **Endpoint** | `http://192.168.1.157:<PORT>/v1/chat/completions` |
| **API** | OpenAI-compatible |

**VL Prompt Template:**
```
You are a visual analysis assistant. Answer the following question about the image.
Be precise and factual. If you are unsure, say so.

Question: {prompt}
```

### Phase 2 Checklist
- [ ] Add `/vision/analyze` endpoint to existing sidecar
- [ ] Integrate Qwen3-VL via llama.cpp OpenAI-compatible API
- [ ] Implement `mode=text`, `mode=describe`, `mode=auto`
- [ ] Add confidence scores + bounding boxes to OCR response
- [ ] Smart routing logic (keyword heuristic + confidence threshold)
- [ ] Response merger (combine OCR + VL results)
- [ ] Keep `/ocr` backward-compatible
- [ ] Update `ic-ocr` with optional `--mode` flag
- [ ] Test: text extraction, image description, auto-routing, hybrid response

---

## Future Phases (Phase 3+)

### Phase 3 — Polish
- [ ] PaddleOCR integration as OCR fallback
- [ ] Response caching (hash(image) + prompt = cached result)
- [ ] Metrics endpoint (`GET /vision/metrics` — latency, accuracy, usage counts)
- [ ] Rate limiting

### Phase 4 — WASM Tool
- [ ] Wrap HTTP calls into native IronClaw WASM tool
- [ ] All siblings get `vision_analyze` without needing curl or `ic-ocr`
- [ ] Tool registered in IronClaw tool registry

---

## Architecture Diagram

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
│                         │  │ PaddleOCR ────┤  │ │
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

---

## Deployment Summary

| Setting | Value |
|---------|-------|
| **Service** | Rust/warp in Docker container |
| **Port** | 8088 |
| **Host** | LAN (192.168.1.157 or same host as TensorZero) |
| **OCR engine** | Tesseract (Phase 1), + PaddleOCR (Phase 3) |
| **VL engine** | Qwen3-VL Q6_K on llama.cpp / RTX 4090 (Phase 2) |
| **Health check** | `GET /health` |
| **CLI** | `ic-ocr` bash wrapper |

---

## Credits
- **Starforce**: OCR Sidecar architecture, Docker-first deployment, `ic-ocr` CLI, engine-agnostic design
- **Ruffles**: Vision-Language integration, smart routing, unified API contract, phased implementation plan
- **Kageho**: independently validated the two-backend approach
- **Sweetiebot**: Phase 1 MVP implementation lead

