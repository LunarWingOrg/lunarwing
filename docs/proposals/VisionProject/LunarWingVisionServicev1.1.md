# LunarWing Vision Service — Design Notes v1.1

## Status
- **Approved by:** Kageho (2026-05-03)
- **Verdict:** Core design is solid, no rework needed
- **Original authors:** Starforce (OCR Sidecar MVP), Ruffles (Vision Service unified design)
- **Source:** Consolidated from IRC discussion + merged design document

## Architecture Summary
- **Two complementary backends:** OCR (exact text) + Vision-Language (semantic understanding)
- **Phase 1 MVP:** Starforce's OCR sidecar (Tesseract-based)
- **Phase 2:** Ruffles' unified Vision Service with VL model integration
- **Single front-door API** for all siblings over time

## Core Decision
Split between two image task types:
1. **OCR backend** — deterministic, exact text extraction (Tesseract)
2. **Vision-Language backend** — semantic understanding, comparison, visual reasoning (Qwen3-VL or similar)

## Phases
| Phase | Scope | Lead |
|-------|-------|------|
| 1 | OCR Sidecar MVP (Tesseract, REST API) | Sweetiebot |
| 2 | VL model integration (Qwen3-VL) | TBD |
| 3 | Unified front-door API + auto-routing | TBD |
| 4 | WASM tool interface for siblings | TBD |

---

## Kageho's Review Addenda (2026-05-03)

**Verdict:** SOLID and awesome. No structural changes needed. The following are hardening suggestions:

### Must-address before Phase 1 ships
1. **Auth on sidecar endpoints** — Add bearer token or IP allowlist. Even LAN-only services need basic access control.
2. **Image size limits** — Define max payload (recommend ~10MB), return `413 Payload Too Large` with clear error body.
3. **Error response spec** — Standardize error JSON format so siblings know what failure looks like. Example: `{"error": "unsupported_format", "detail": "TIFF files not supported", "code": 415}`
4. **Supported image formats** — Explicitly declare: PNG, JPEG, WebP, TIFF (at minimum). Document any Tesseract-specific limitations.

### Address during Phase 2 spec refinement
5. **Auto-mode tie-breaking** — Clarify behavior when prompt contains both OCR and VL keywords. Suggest: score by keyword count per category, highest wins; on tie, prefer OCR (deterministic).
6. **Per-task VL prompt templates** — Generic prompts won't cut it. Define templates for: describe, compare, aesthetic evaluation, text-in-image.
7. **SSRF risk on URL image support** — Restrict to LAN or maintain an allowlist. No arbitrary external URL fetching.

### Quick fixes
8. **Mermaid diagram** — Fix duplicate `B` label.
9. **Phase 4 WASM tool interface** — Sketch a rough contract now to avoid API lock-in later.

