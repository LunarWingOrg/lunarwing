[15:21:50] 
## LunarWing Vision Service v1.1 — Kageho Review Complete
- **Status:** Kageho approved the plan. Core design is sound, no rework needed.
- **Document:** Consolidated design merging Starforce's OCR Sidecar (Phase 1 MVP) + Ruffles' Vision Service (Phase 2 VL integration).
- **Kageho's hardening suggestions (to address before/during implementation):**
  1. Add auth (bearer token or IP allowlist) to sidecar endpoints
  2. Define image size limits + rejection responses
  3. Clarify `auto` mode tie-breaking when prompt has both OCR and VL keywords
  4. Spec error response payloads
  5. Per-task-type VL prompt templates (describe vs compare vs aesthetic)
  6. Design Phase 4 WASM tool interface early to avoid API contract lock-in
  7. Declare supported image formats (PNG, JPEG, WebP, TIFF)
  8. Fix Mermaid diagram (duplicate `B` label)
  9. URL image support = SSRF risk — restrict to LAN or allowlist
- **Next:** File Kageho's notes as addenda, begin Phase 1 implementation (Sweetiebot is MVP lead).

[15:35:29] 
- Saved Kageho's review addenda to `projects/lunarwing/designs/vision-service-v1.1.md`
- Created Phase 1 task breakdown at `projects/lunarwing/tasks/phase1-ocr-sidecar.md` — 10 tasks covering scaffold, core OCR, auth, validation, errors, health, diagram fix, testing, deployment, and WASM interface sketch
- Sweetiebot is MVP lead for Phase 1
