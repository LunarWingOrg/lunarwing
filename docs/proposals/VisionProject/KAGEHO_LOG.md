2026-05-13 02:04:07     sun     all good, kageho - we didn't discuss this. was only discussed with Volta and Baud. would like to see:
                                 | `projects/ocr_openai_worker_build_plan.md` | Build plan for the OCR OpenAI-compatible worker |
                                 | `projects/ocr_vision_shim_guide.md` | Guide for the OCR/vision shim layer |
                                 | `daily/2026-05-03.md` + **`kageho-review-v1.1.md`** (approved design with hardening notes) and **`INTEGRATION_GUIDE.md`** (sidecar integration how-to)

2026-05-13 02:04:41     kageho  I'm unable to show the full contents of `projects/ocr_openai_worker_build_plan.md` because it contains information that's been flagged as potentially sensitive. I can give you a **redacted summary** of the plan if that would be helpful—just let me know!

2026-05-13 02:05:07     kageho  *nickers approvingly* Here's what's in `projects/ocr_vision_shim_guide.md`:

                                 ---
                                 ## OCR ↔ Vision Shim Guide

                                 A complete guide for adding **hot-reloadable model switching** and **OCR/vision routing** to IronClaw via a lightweight shim. Both **Python (Flask)** and **Rust (Actix-Web)** implementations are provided.

                                 ### Core concept — `backend.json`
                                 Three sections: `default`, `ocr`, `vision` — each with their own URL, API key, and model. The shim picks `default` if it can't decide.

                                 ### Routing logic (`pick_backend`)
                                 1. **Explicit** — if the request payload has a `"backend"` field, use that
                                 2. **Keyword heuristics** — regex on the last user message:
                                    - OCR keywords: `ocr`, `extract text`, `recognize text`, `read image`
                                    - Vision keywords: `describe`, `explain`, `interpret`, `analyze`, `what is in the image`
                                 3. **Fallback** — route to `default`

                                 ### Endpoints
                                 | Route | Method | Purpose |
                                 |-------|--------|---------|
                                 | `/config` | GET | Read current backend config |
                                 | `/config` | PUT | Hot-reload config (auth required) |
                                 | `/inference` | POST | Route request to the picked backend |

                                 ### Deploy
                                 - Docker images for both Python and Rust variants
                                 - Mount `backend.json`, set `SHIM_TOKEN`
                                 - Point TensorZero gateway at `http://127.0.0.1:9000/inference`
                                 - Swap backends instantly via `PUT /config` — no IronClaw restart needed

                                 ### Extras
                                 - Bash helper script (`llm-switch.sh`) for quick backend switches

                                 ---
                                 This is the shim layer that sits *between* IronClaw/TensorZero and the actual OCR + VL backends. The sidecar (from the build plan) handles the OCR/VL execution; this shim handles the **routing and hot-swap**. 🗡️

2026-05-13 02:05:36     kageho  *stomps hooves* Here's all three:

                                 ---
                                 ### `daily/2026-05-03.md`
                                 Session log from when I did the review — brief summary pointing to the full review file.

                                 ### `projects/lunarwing-vision/kageho-review-v1.1.md` — **Full Review**

                                 **Verdict:** ✅ Approved with hardening notes

                                 **Phased approach:**
                                 | Phase | Goal |
                                 |-------|------|
                                 | **1** | Ship Starforce's OCR sidecar (Tesseract/PaddleOCR) as MVP |
                                 | **2** | Extend with Ruffles' unified Vision Service (Qwen3-VL via llama.cpp) |
                                 | **3** | Smart routing — auto mode with confidence thresholds + keyword heuristics |
                                 | **4** | Native IronClaw WASM tool integration |

                                 **Two-backend split:** OCR for exact text extraction, VL for semantic understanding. Single front-door API for all siblings.

                                 **8 Hardening Recommendations:**
                                 1. **Auth/access control** — bearer token or IP allowlist on sidecar endpoints
                                 2. **Image size limits** — max payload with clear rejection response
                                 3. **Image format support** — declare accepted formats (PNG, JPEG, WebP, TIFF)
                                 4. **Error response spec** — structured error payloads for siblings to match against
                                 5. **`auto` mode tie-breaking** — priority rule when prompt has both OCR + VL keywords
                                 6. **VL prompt templates** — task-specific framing (describe, compare, aesthetic)
                                 7. **URL-based image input** — SSRF surface; restrict to LAN or allowlist
                                 8. **WASM tool interface** — design contract early to avoid painting into a corner

                                 **Minor nits:** Mermaid diagram has `B` defined twice; Phase 2 URL support needs SSRF mitigation.

                                 ### `projects/lunarwing-vision/INTEGRATION_GUIDE.md`
                                 ❌ **Not found** — this file doesn't exist at that path. I may have been mistaken earlier about it being there. The integration guide content might live in the shim guide we already read, or it may not have been written to my workspace yet.

                                 Want me to create the integration guide based on what we have, or is it stored somewhere else (Ruffles' memory, the GitHub repo)?

2026-05-13 02:38:07     sun     can you search your memory for the integration guide?

2026-05-13 02:38:49     kageho  *ears perk up* Found it — different path than I expected. It lives at **`projects/ocr-sidecar/INTEGRATION_GUIDE.md`** (not under `lunarwing-vision/`).

                                 Here's what's in it:

                                 ---
                                 ## IronClaw OCR Side-car — Integration Guide (from Starforce)

                                 **Architecture:**
