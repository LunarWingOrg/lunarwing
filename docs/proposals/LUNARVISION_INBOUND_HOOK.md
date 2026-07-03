# LunarVision Inbound Hook — Design Spec

**Date:** 2026-07-03
**Status:** Draft (pending review)
**Branch:** `post-1.2.0-lunarvision-inbound-hook-draft`
**Target release:** Post-1.2.0 (after UI rework)

---

## Goal

When an image is sent to an agent via XMPP (or any channel), automatically route it through the LunarVision sidecar *before* the agent processes the message. The agent receives both the vision analysis (as text) and the raw image (as multimodal input), giving it structured OCR/VL context alongside the pixels.

**Option B — Augment, don't replace.** The original image attachment is preserved on the message and still reaches the LLM as a multimodal `ContentPart::ImageUrl`. The hook adds a `<lunarvision_analysis>` text block to the message content. The agent sees both.

---

## Architecture

```
XMPP image arrives
       │
       ▼
agent_loop.rs:1278  BeforeInbound hook fires
       │
       ▼  HookEvent::Inbound now carries attachments (NEW)
       │
LunarVisionHook.execute()
       │
       ├─ for each image attachment with data:
       │     POST {service_url}/v1/vision/analyze
       │     └─ returns OCR/VL text
       │
       ▼
HookOutcome::modify(original_content + <lunarvision_analysis> blocks)
       │
       ▼
agent_loop continues with modified content
       │
       ▼
augment_with_attachments()  ← original attachments still on message
       │
       ├─ builds <attachments> metadata block
       └─ image data → ContentPart::ImageUrl (multimodal)
       │
       ▼
LLM sees: [lunarvision text] + [user text] + [raw image pixels]
```

---

## Changes

### 1. `HookEvent::Inbound` extended with `attachments`

**File:** `ic/src/hooks/hook.rs`

New variant field:
```rust
Inbound {
    user_id: String,
    channel: String,
    content: String,
    attachments: Vec<AttachmentSummary>,  // NEW
    thread_id: Option<String>,
}
```

### 2. New type: `AttachmentSummary`

**File:** `ic/src/hooks/hook.rs`

A serializable, lightweight view of `IncomingAttachment` suitable for passing to hooks. Does not carry raw bytes directly — instead has `data_b64: Option<String>` (base64-encoded, populated for small images already in memory).

```rust
pub struct AttachmentSummary {
    pub kind: String,           // "image" | "audio" | "document"
    pub mime_type: String,
    pub filename: Option<String>,
    pub size_bytes: Option<u64>,
    pub source_url: Option<String>,
    pub data_b64: Option<String>,
    pub extracted_text: Option<String>,
}
```

Includes `AttachmentSummary::from_incoming(&IncomingAttachment)` for conversion.

### 3. New hook: `LunarVisionHook`

**File:** `ic/src/hooks/lunarvision.rs`

- Implements `Hook` trait
- Hook point: `BeforeInbound` only
- Failure mode: `FailOpen` (sidecar down → image flows through as raw pixels)
- Timeout: 60s (VL inference can be slow)
- Calls `{service_url}/v1/vision/analyze` with `{ image, mode, ocr_lang, detail_level }`
- Prepends `<lunarvision_analysis attachment="filename">` blocks to message content
- Per-attachment fail-open: if one image fails analysis, others still process

### 4. Agent loop call site updated

**File:** `ic/src/agent/agent_loop.rs:1280`

`HookEvent::Inbound` construction now maps `message.attachments` into `AttachmentSummary` via `from_incoming()`.

### 5. Hook auto-registration

**File:** `ic/src/hooks/bundled.rs:136`

`register_bundled_hooks()` now calls `LunarVisionHook::from_env()` and registers the hook at priority 50 (after `AuditLogHook` at 25) if `VISION_SERVICE_URL` is set. If the env var is empty or unset, the hook is not registered — zero overhead.

---

## Configuration

The hook reads `VISION_SERVICE_URL` from the global env var (same mechanism as the existing `vision-analyze` WASM tool). No new config field needed — the plumbing from `2026-06-30-vision-analyze-tool-wiring-design.md` already writes this per-tenant.

| Setting | Source | Default |
|---------|--------|---------|
| `service_url` | `VISION_SERVICE_URL` env | (none — hook disabled if unset) |
| `mode` | hardcoded in hook | `"auto"` |
| `ocr_lang` | hardcoded in hook | `"eng"` |
| `detail_level` | hardcoded in hook | `"medium"` |

Future: these could be promoted to config fields if tenants need per-instance tuning.

---

## Failure Modes

| Scenario | Behavior |
|----------|----------|
| `VISION_SERVICE_URL` not set | Hook not registered. Images flow through as raw pixels. |
| Sidecar unreachable | Per-attachment: logged, skipped. Other images still attempt. Message proceeds unmodified if all fail. |
| Sidecar returns HTTP error | Same as above — logged, skipped, fail-open. |
| Sidecar returns invalid JSON | Same — logged, skipped. |
| Hook times out (60s) | `FailOpen` — message proceeds without vision text. |
| Image has no `data` (large file, not downloaded) | Hook skips it (no bytes to send). Image still reaches LLM via augment. |

---

## What This Does NOT Do

- Does **not** replace the `vision-analyze` WASM tool. The agent can still call it explicitly for follow-up analysis.
- Does **not** remove images from `message.attachments`. The LLM gets both vision text and raw pixels (Option B).
- Does **not** handle non-image attachments (audio, documents). Those are left to existing transcription/extraction middleware.
- Does **not** add a new config field. Reuses `VISION_SERVICE_URL`.

---

## Future Extensions

- **Per-tenant config:** promote `mode`, `ocr_lang`, `detail_level` to config fields.
- **Audio hook:** same pattern for audio attachments → transcription sidecar.
- **Vision-on-demand:** let the hook skip images below a confidence threshold and defer to the WASM tool for detailed analysis.
- **Caching:** cache vision results for identical image hashes to avoid re-analysis on retransmits.
