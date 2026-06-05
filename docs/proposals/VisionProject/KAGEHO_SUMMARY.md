Here’s a deduplicated and cleaned-up version that keeps the important information while removing repeated blocks, repeated timestamps, and duplicated excerpts.

---

# OCR / Vision Integration Discussion Summary

## Requested Documents

Sun requested the following files that had previously only been discussed with Volta and Baud:

* `projects/ocr_openai_worker_build_plan.md` — Build plan for the OCR OpenAI-compatible worker
* `projects/ocr_vision_shim_guide.md` — OCR/Vision shim layer guide
* `daily/2026-05-03.md`
* `kageho-review-v1.1.md` — Approved design review with hardening notes
* `INTEGRATION_GUIDE.md` — Sidecar integration guide

---

# OCR OpenAI Worker Build Plan

Kageho could not provide the full contents because the document was flagged as potentially sensitive, but offered to provide a redacted summary instead.

---

# OCR ↔ Vision Shim Guide

A guide for adding hot-reloadable model switching and OCR/vision routing to IronClaw using a lightweight shim layer.

Implementations provided:

* Python (Flask)
* Rust (Actix-Web)

## Core Concept — `backend.json`

The shim uses three backend profiles:

* `default`
* `ocr`
* `vision`

Each backend defines:

* URL
* API key
* model

If routing cannot determine the correct backend, it falls back to `default`.

## Routing Logic (`pick_backend`)

### 1. Explicit Backend Selection

If the request payload includes a `"backend"` field, use it directly.

### 2. Keyword Heuristics

Regex matching on the final user message.

OCR keywords:

* `ocr`
* `extract text`
* `recognize text`
* `read image`

Vision keywords:

* `describe`
* `explain`
* `interpret`
* `analyze`
* `what is in the image`

### 3. Fallback

Route to `default`.

---

## API Endpoints

| Route        | Method | Purpose                                  |
| ------------ | ------ | ---------------------------------------- |
| `/config`    | GET    | Read current backend configuration       |
| `/config`    | PUT    | Hot-reload configuration (auth required) |
| `/inference` | POST   | Route request to selected backend        |

---

## Deployment Notes

* Docker images exist for both Python and Rust variants
* Mount `backend.json`
* Set `SHIM_TOKEN`
* Point TensorZero gateway to:
  `http://127.0.0.1:9000/inference`
* Backends can be swapped instantly through `PUT /config`
* No IronClaw restart required

### Extras

* `llm-switch.sh` helper script for fast backend switching

---

## Shim vs Sidecar Responsibilities

The shim layer sits between IronClaw/TensorZero and the OCR/VL backends.

Responsibilities:

* **Shim:** routing + hot-swapping
* **Sidecar:** OCR/VL execution

---

# `kageho-review-v1.1.md` — Full Review

## Verdict

✅ Approved with hardening notes

---

## Phased Rollout Plan

| Phase | Goal                                                        |
| ----- | ----------------------------------------------------------- |
| 1     | Ship Starforce OCR sidecar (Tesseract/PaddleOCR) MVP        |
| 2     | Extend with unified Vision Service (Qwen3-VL via llama.cpp) |
| 3     | Add smart routing with confidence thresholds + heuristics   |
| 4     | Native IronClaw WASM tool integration                       |

---

## Architecture Direction

Two-backend split:

* OCR backend for precise text extraction
* Vision-language backend for semantic understanding

Unified behind a single front-door API.

---

## Hardening Recommendations

1. Auth/access control

   * Bearer token or IP allowlist

2. Image size limits

   * Reject oversized payloads clearly

3. Explicit image format support

   * PNG, JPEG, WebP, TIFF

4. Structured error response schema

5. `auto` mode tie-breaking rules

   * When OCR and VL keywords both appear

6. Vision-language prompt templates

   * Describe / compare / aesthetic modes

7. URL image input SSRF mitigation

   * Restrict to LAN or allowlist

8. Early WASM interface contract definition

### Minor Notes

* Mermaid diagram defines `B` twice
* Phase 2 URL support requires SSRF mitigation

---

# Integration Guide Discovery

Initially, `projects/lunarwing-vision/INTEGRATION_GUIDE.md` was reported missing.

Later, Kageho located the actual file:

`projects/ocr-sidecar/INTEGRATION_GUIDE.md`

---

# OCR Sidecar Integration Guide

## Architecture

```text
Agent
  → http tool (or ic-ocr wrapper)
  → localhost:8088/ocr
  → llama-cli (qwen3vl)
  → text
```

---

## API Contract

| Endpoint  | Method | Purpose              |
| --------- | ------ | -------------------- |
| `/ocr`    | POST   | OCR request/response |
| `/health` | GET    | Health check         |

### OCR Payload

```json
{
  "image_b64": "...",
  "mime": "...",
  "prompt": "...",
  "options": {}
}
```

Response:

```json
{
  "text": "..."
}
```

---

## Key Components

1. Rust/warp HTTP server

   * Decodes base64
   * Calls OCR binary
   * Returns text + metadata

2. Dockerfile

   * Multi-stage build
   * Rust builder → Debian slim runtime

3. `docker-compose.yml`

   * Healthchecks
   * `.env` configuration

4. `ic-ocr` wrapper script

   * Base64 encoding
   * curl + jq helpers

5. IronClaw routine example

   * Scheduled image capture
   * OCR
   * memory_write integration

---

## Environment Variables

| Variable       | Default                 |
| -------------- | ----------------------- |
| `OCR_PORT`     | `8088`                  |
| `OCR_MODEL`    | `/app/model.bin`        |
| `OCR_ENDPOINT` | `http://127.0.0.1:8088` |

---

## Future Direction

Replace the wrapper script with a native IronClaw WASM tool:

```text
ocr_llamacpp
```

once the API stabilizes.

---

# Daily Logs Timeline

## `daily/2026-05-02.md`

Status:

* Starforce delivered the OCR sidecar integration guide
* Ruffles was developing a larger multi-phase OCR/VLM architecture plan
* Kageho planned to review Ruffles’ proposal and merge any useful additions from Starforce’s approach
* Awaiting Christopher to provide Ruffles’ plan

---

## `daily/2026-05-03.md`

Outcome:

* Ruffles’ v1.1 plan reviewed
* Approved with 8 hardening recommendations

Implementation had not yet started at the time of the discussion.

---

# Overall Timeline

| Date  | Event                                         |
| ----- | --------------------------------------------- |
| May 2 | Starforce sidecar integration guide delivered |
| May 3 | Ruffles v1.1 reviewed and approved            |
| Later | Shim layer and routing architecture clarified |

Current status:

* Architecture direction established
* Hardening notes documented
* Phase 1 implementation had not yet begun at the time of the conversation.
