# Release Notes for LunarWing v1.0.6

**Release Date:** TBD

## Overview

LunarWing v1.0.6 introduces the Vision Service (OCR sidecar with 4-phase rollout), a native `vision-analyze` WASM tool, the `openai_compatible` embedding provider, nanocode worker improvements, a comprehensive documentation audit, and pre-release testing automation.

## New Features

### Vision Service / OCR Sidecar

Standalone Rust service (`projects/ocr-sidecar/`) providing image analysis capabilities to all LunarWing instances via REST API on port 8088.

- **Phase 1** — Tesseract OCR: `POST /ocr` for basic text extraction from images (PNG, JPEG, WebP, TIFF)
- **Phase 2** — Vision-Language integration: `POST /vision/analyze` with smart routing that selects OCR, VL (Qwen3-VL via llama.cpp), or hybrid mode based on confidence scores and prompt keywords
- **Phase 3** — Production hardening: PaddleOCR fallback (when Tesseract confidence < 0.7), response caching (5min TTL), per-IP rate limiting, `GET /vision/metrics` endpoint
- **Phase 4** — WASM tool: `vision-analyze` tool in `ic/tools-src/vision-analyze/` provides native LunarWing integration through the sandboxed WASM runtime

CLI wrapper: `projects/ocr-sidecar/ic-ocr` for command-line usage.

### vision-analyze WASM Tool

New WASM tool (`ic/tools-src/vision-analyze/`) that connects to the Vision Service sidecar. Supports `text`, `describe`, and `auto` modes. Accepts base64-encoded images or workspace file paths. Registered in `ic/tools-src/TOOLS.md`.

### OpenAI-Compatible Embedding Provider

Added `openai_compatible` as a fourth embedding provider alongside `openai`, `nearai`, and `ollama`. Allows connecting to any OpenAI-compatible embedding endpoint (e.g., TensorZero, local models) via configurable base URL.

- New `EMBEDDING_BASE_URL` env var and `base_url` field in settings.json
- Setup wizard now offers "OpenAI-compatible (custom URL)" as a provider choice
- Settings-level base URL is used as fallback when env var is not set

### Nanocode Worker Improvements

- Added troubleshooting guide (`lunarcode4lunarwing/TROUBLESHOOTING.md`)
- Applied `safeParse` patch for nanocode v1.2.28 schema validation bug (`patches/fn.ts`)
- Updated `CLAUDE.md` with full architecture documentation, known issues, and end-to-end flow

## Improvements

### Pre-Release Testing

- Created `docs/guides/TESTING_GUIDE.md` — comprehensive pre-release test checklist covering channels, routines, workers, tools, database, security, performance, and rollback procedures
- Created `ic/scripts/release-test.sh` — automated release test script covering 16 checks (gateway, memory, routines, jobs, skills, tools, credential leak detection)

### Documentation

- Full documentation audit (`docs/DOCS_AUDIT.md`) identifying 22 medium-priority and 15 low-priority items (stale IronClaw references, missing index entries, naming inconsistencies)
- Branch guide (`docs/guides/BRANCH_GUIDE.md`) — agent branching strategy for staging
- Feature branch tracking (`FEATURE_BRANCHES_1.0.6.md`)
- Vision project proposals and design docs (`docs/proposals/VisionProject/`)

### Web UI

- Added vision-related i18n strings for English and Chinese

## Documentation

### New
- `projects/ocr-sidecar/README.md` — Vision/OCR sidecar API reference
- `projects/ocr-sidecar/DOCUMENTATION.md` — Complete vision service technical documentation
- `docs/guides/TESTING_GUIDE.md` — Pre-release test checklist
- `docs/guides/BRANCH_GUIDE.md` — Agent branching strategy
- `docs/DOCS_AUDIT.md` — Full documentation audit
- `docs/guides/MIGRATE_IRONCLAW_TO_MT.md` — PostgreSQL migration to MT
- `docs/guides/MIGRATE_IRONCLAW_LIBSQL_TO_MT.md` — libSQL cross-backend migration to MT
- `docs/proposals/VisionProject/KAGEHO_SUMMARY.md` — OCR/Vision integration discussion summary
- `docs/proposals/VisionProject/KAGEHO_BUILD_PLAN.md` — Kageho vision build plan
- `docs/proposals/VisionProject/KAGEHO_LOG.md` — Kageho vision implementation log
- `lunarcode4lunarwing/TROUBLESHOOTING.md` — Nanocode worker troubleshooting

### Updated
- `CLAUDE.md` — Added vision service, OCR sidecar, embeddings, projects/ directory
- `docs/README.md` — Added proposals, bugs, missing guides/ops entries
- `lunarcode4lunarwing/CLAUDE.md` — Full architecture documentation
- `ic/tools-src/TOOLS.md` — Added vision-analyze tool
- `MANIFESTO.md` — Minor updates

### Removed
- `AUDIT.md`, `RIPOUTCLAUDECODE.md`, `IDEA_TRACKING.md` — Superseded by Vikunja task tracking

## Artifacts

**Docker Images:**
- `lunarwing-worker:latest` (sandbox worker)
- `lunarwing-worker-nanocode:latest` (nanocode external worker)
- `lunarwing/ocr-sidecar:latest` (vision/OCR sidecar)

**Binaries:**
- `lunarwing` (main daemon)
- `xmpp-bridge` (XMPP bridge service)
- `ocr-sidecar` (vision/OCR service)

**WASM Tools:**
- `vision-analyze` (vision/OCR analysis)

## Feature Branches

See `FEATURE_BRANCHES_1.0.6.md` for the complete list of feature branches included in this release.
