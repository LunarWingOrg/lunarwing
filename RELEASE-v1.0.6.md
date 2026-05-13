# Release Notes for LunarWing v1.0.6

**Release Date:** 2026-05-13

## Overview

LunarWing v1.0.6 is a major feature release introducing the Vision Service (OCR sidecar with 4-phase rollout), a fully integrated nanocode external worker with git and secret injection support, the WeeChat relay WASM channel improvements, the `openai_compatible` embedding provider with configurable endpoints, production multi-tenant tooling improvements, and pre-release testing automation.

## New Features

### Nanocode External Worker — Git & Secret Injection

The nanocode worker (`lunarcode4lunarwing/`) is now a fully integrated external worker with git operations, secret injection, and per-tenant isolation.

- **Git credential injection** — `GITHUB_TOKEN` / `GH_TOKEN` env vars are automatically configured as HTTPS credential helpers for github.com; `GIT_AUTHOR_NAME` and `GIT_AUTHOR_EMAIL` set the commit identity
- **SSH key mounting** — Host SSH keys can be bind-mounted to `/home/nanocode/.host-ssh` (read-only); the entrypoint copies them to `~/.ssh` with correct permissions and adds a default `StrictHostKeyChecking accept-new` config
- **Host .gitconfig forwarding** — Mount `.host-gitconfig` to import the host's git configuration
- **Per-tenant env file** — `nanocode.env` in the tenant's `env/` directory is loaded into the container via `--env-file`, keeping secrets out of the image
- **GitHub CLI (`gh`)** — Pre-installed in the container image; authenticates via `GITHUB_TOKEN` from the environment
- **Multi-language toolchain** — Container ships Rust (via rustup), Go, Python 3, Node.js, Bun, ripgrep, jq, neovim, cmake, clang, and build-essential
- **safeParse patch** — Applied workaround for nanocode v1.2.28 PartID/SessionID schema validation bug (`patches/fn.ts`)
- **Configurable TensorZero function** — `config/nanocode.json` controls the LLM routing function name
- **Troubleshooting guide** — `lunarcode4lunarwing/TROUBLESHOOTING.md`
- **Full architecture docs** — `lunarcode4lunarwing/CLAUDE.md` rewritten with end-to-end flow, known issues, and integration details

### WeeChat Relay WASM Channel

New WASM channel (`ic/channels-src/weechat/`) bridging WeeChat's relay protocol to LunarWing. Allows receiving and sending messages through any IRC network via a local WeeChat instance.

- Relay protocol v0.2.0 with buffer listing, message polling, and send support
- Capabilities file with configurable relay host, port, and password
- Per-tenant port allocation in the multi-tenant setup (port offset +5)

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

- New `EMBEDDING_BASE_URL` env var and `base_url` field in `settings.json`
- Setup wizard now offers "OpenAI-compatible (custom URL)" as a provider choice
- Settings-level base URL is used as fallback when env var is not set
- Memory embedding search validated end-to-end with TensorZero routing

## Multi-Tenant Administration Improvements

### Port Registry v3

The port registry (`/etc/lunarwing/ports.json`) has been bumped from v2 to v3 with a new `nanocode_wss` port allocation per tenant. Each tenant's 10-port block now includes:

| Offset | Service |
|--------|---------|
| +0 | Gateway |
| +1 | HTTP |
| +2 | XMPP bridge |
| +3 | PostgreSQL |
| +4 | TensorZero proxy |
| +5 | WeeChat relay |
| +6 | Orchestrator |
| +7 | Nanocode WSS |
| +8-9 | Reserved |

### Nanocode Worker Build Integration

`lunarwing-mt-admin.sh` now supports building and managing nanocode worker containers per-tenant:

- `build-tenant <name> --with-nanocode` builds the Docker image
- `build-nanocode-worker [--no-cache]` builds the image standalone
- `start-tenant` automatically creates and starts the nanocode container with tenant-scoped env, auth token, and workspace volume
- `stop-tenant` stops and cleans up the nanocode container

### Gotify Configuration

- Gotify URL and notification title are now configurable per-tenant during `add-tenant` via `--gotify-url` and mt-admin env vars
- Gotify WASM tool `lib.rs` updated to support configurable message titles

## Bug Fixes

### WASM Build Target (wasip2)

`build-wasm-extensions.sh` was not specifying `--target wasm32-wasip2`, causing `cargo component build` to default to `wasip1`. The install function expected `wasip2` artifacts, resulting in only 1 of 20 extensions being installed. Fixed by adding `--target wasm32-wasip2` to the build command.

### Nanocode Docker Build Context

The nanocode worker Docker build failed because the build script created a symlink to `nanocode-config/nanocode`, but Docker's `COPY` cannot follow symlinks that resolve outside the build context. Fixed by using `cp -rL` (dereference and copy) instead of `ln -s`.

### Nanocode Workspace Permissions

The nanocode container runs as user `nanocode` (system UID) but the host workspace directory was owned by the tenant user. Fixed by adding `chmod 777` to the workspace directory creation in `lunarwing-mt-admin.sh`.

### Proprietary Channel Removal

Removed WhatsApp (Meta) channel source and related artifacts as part of the fork's commitment to open-protocol-only channels.

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
- `lunarcode4lunarwing/CLAUDE.md` — Full nanocode worker architecture documentation

### Updated
- `CLAUDE.md` — Added vision service, OCR sidecar, embeddings, nanocode worker, projects/ directory
- `docs/README.md` — Added proposals, bugs, missing guides/ops entries
- `ic/tools-src/TOOLS.md` — Added vision-analyze tool
- `MANIFESTO.md` — Minor updates

### Removed
- `AUDIT.md`, `RIPOUTCLAUDECODE.md`, `IDEA_TRACKING.md` — Superseded by Vikunja task tracking

## Known Issues

- Web gateway WebSocket connections drop after idle periods (no server-side ping/keepalive). SSE path has 30-second keepalive; WebSocket does not. Workaround: refresh the page.
- WASM channels (DarkIRC, WeeChat) poll their backend endpoints on startup regardless of whether the service is running, producing connection-refused log noise. Remove unused channel `.wasm` files from the state directory to silence.
- Tenant repo clones set `origin` to the source user's home directory, which other tenant users cannot access. Script changes must be manually copied to tenant repos.
- `lunarwing-mt-admin.sh` does not auto-generate `config.toml` with external worker settings and auth token during `add-tenant`. Must be created manually.



## Artifacts

**Docker Images:**
- `lunarwing-worker-nanocode:latest` (nanocode external worker — Bun, Rust, Go, Python, Node.js, gh CLI)
- `lunarwing-worker:latest` (sandbox worker)
- `lunarwing/ocr-sidecar:latest` (vision/OCR sidecar)

**Binaries:**
- `lunarwing` (main daemon)
- `xmpp-bridge` (XMPP bridge service)
- `ocr-sidecar` (vision/OCR service)

**WASM Extensions (19 total):**
- Channels (7): darkirc, discord, feishu, slack, telegram, weechat, xmpp
- Tools (12): github, gmail, google-calendar, google-docs, google-drive, google-sheets, google-slides, gotify, llm-context, slack, telegram, web-search
- Standalone tool: vision-analyze (requires OCR sidecar)

## Upgrade Notes

1. **Port registry migration** — Existing tenants on v2 registries will not have `nanocode_wss` ports allocated. Run `add-tenant` for new tenants or manually add the port entry to `/etc/lunarwing/ports.json`.
2. **WASM rebuild required** — All WASM extensions should be rebuilt with the corrected `--target wasm32-wasip2` flag. Run `build-tenant <name> --with-wasm` or `build-all --with-wasm`.
3. **Nanocode config.toml** — After adding a tenant, create `config.toml` in the tenant's state directory with the `[[sandbox.external_workers]]` section including the `auth_token`. See the multi-tenancy docs for the format.
4. **Embedding provider** — To use the new `openai_compatible` provider, set `EMBEDDING_PROVIDER=openai_compatible` and `EMBEDDING_BASE_URL` in the tenant's env file, or configure via the web UI settings.

## Feature Branches Merged

| Branch | Description |
|--------|-------------|
| `1.0.6-LunarVision` | Vision service: OCR sidecar (4 phases), vision-analyze WASM tool |
| `1.0.6-EmbeddedMemoryUpdate` | Configurable embedding URL, `openai_compatible` embedding provider |
| `1.0.6-CleanupRound2` | Proprietary channel removal, nanocode worker image rename, pre-release testing |

## Deferred to Future Releases

| Feature | Target |
|---------|--------|
| Lunartica/Multica bridge WASM tool | v1.0.7+ |
| LunarVoice (voice capabilities) | v1.0.7+ |
| XMPP MUC fixes | v1.0.7+ |
| Server-side WebSocket keepalive | v1.0.7 |
| Auto-generate config.toml in mt-admin | v1.0.7 |
| Shared repo path for tenant clones | v1.0.7 |
