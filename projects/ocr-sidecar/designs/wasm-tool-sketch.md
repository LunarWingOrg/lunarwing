# WASM Tool Interface Sketch — Phase 4 Direction

> Non-binding directional draft. Intended to avoid API lock-in as the service evolves.

## Tool Name
`vision_analyze`

## Input Schema
```json
{
  "image": "<base64-encoded image or file path>",
  "mode": "text | describe | auto",
  "prompt": "optional custom question",
  "ocr_lang": "eng",
  "detail_level": "low | medium | high"
}
```

## Output Schema
```json
{
  "mode_used": "text | describe | hybrid",
  "ocr": {
    "full_text": "...",
    "blocks": [],
    "avg_confidence": 0.94
  },
  "vision": {
    "description": "...",
    "prompt_answer": "..."
  },
  "meta": {
    "backends_used": ["tesseract"],
    "latency_ms": 512
  }
}
```

## Implementation Notes
- WASM tool wraps HTTP calls to `POST /vision/analyze` (Phase 2+ endpoint)
- Falls back to `POST /ocr` for text-only mode
- Handles base64 encoding internally
- Supports both file paths and inline base64 images

## Open Questions
- Should the WASM tool handle image resizing before upload?
- How should auth tokens be injected? (env var vs config)
- Should results be cached in workspace memory?
