# Release Notes for LunarWing v1.0.7

**Release Date:** Pending

## Overview

LunarWing v1.0.7 is a hardening and operational polish release. It corrects the project license to AGPLv3, migrates the port registry to v3, adds Rust development tooling to the nanocode worker image, introduces comprehensive troubleshooting guides for WeeChat and nanocode multi-tenant setups, and resolves several operational issues discovered during multi-tenant testing.

## Changes

### License Correction

The Cargo.toml license field has been corrected from `MIT OR Apache-2.0` (inherited from upstream) to `AGPL-3.0-or-later`, aligning with the repository's actual LICENSE file.

### Port Registry v3 Migration Script

Added `ic/scripts/migrate-ports-v3.sh` — a standalone script to upgrade `/etc/lunarwing/ports.json` from v2 to v3 without recreating tenants. Safely adds the `nanocode_wss` port entry (offset +7) to all existing tenants and bumps the version field.

### Nanocode Worker: Rust Development Toolchain

#### The nanocode worker Dockerfile (`lunarcode4lunarwing/Dockerfile`) now includes a full C/C++/Rust development toolchain in the runtime image:

- `gcc`, `g++`, `libc-dev`, `binutils` — core C/C++ compilation and linking
- `cmake`, `ninja-build` — build systems for native projects
- `clang`, `lld`, `llvm` — alternative compiler, linker, and tooling
- `pkg-config` — library discovery for `-sys` crates
- `libssl-dev`, `zlib1g-dev`, `libsqlite3-dev`, `libpq-dev` — common Rust crate dependencies
- `libffi-dev`, `libz-dev`, `liblzma-dev`, `libzstd-dev` — compression and FFI libraries
- `protobuf-compiler`, `libprotobuf-dev` — Protocol Buffers compilation

##### Additionally, the following packages were also added:

- `musl-tools`
- `libcurl4-openssl-dev`
- `libxml2-dev`
- `python3-dev`

This allows nanocode to compile Rust projects from source inside the container without hitting linker or missing-header errors.

### Nanocode Multi-Tenant Setup Guide

New documentation at `docs/ops/NANOCODE-MULTITENANT.md` covering the complete multi-tenant nanocode worker deployment:

- Image build (shared across tenants)
- Per-tenant container startup with correct port/auth/volume mapping
- Daemon `config.toml` configuration (TOML ordering requirements)
- Verification steps and troubleshooting

### Nanocode Tenant Startup Script

Added `ic/scripts/start-nanocode-starforce.sh` — reference script for starting the nanocode container for the starforce tenant. Demonstrates the correct `docker run` flags, port binding, env vars, and volume mounts without including secrets.

### WeeChat Channel Troubleshooting Guide

New comprehensive troubleshooting guide at `docs/guides/ironclaw_weechat_wss/weechat_relay/TROUBLESHOOTING.md` covering:

- **Multi-tenant port mismatch** — DB settings override capabilities.json; stale ports after tenant recreation
- **Relay type** — must be `api` (WeeChat 4.x+), not `weechat` protocol
- **Authentication failures** — secret/password sync between DB and WeeChat
- **Boolean deserialization** — `"false"` (string) vs `false` (bool) in setup_fields JSON
- **Workspace state cache** — clearing stale cached config
- **WeeChat idle disconnect** — `relay.network.time_inactive` setting
- **Pairing approval** — command reference with examples

### Documentation Improvements

- Updated documentation with branching strategy, code style guidelines, shared agentic loop architecture, external workers section, and expanded repo structure
- Added libSQL migration testing notes
- Cleaned up outdated proposal documents and plan files

## Bug Fixes

### libSQL Migration Testing

Tested and documented file-based libSQL to PostgreSQL migration methods for multi-tenant deployments. Validated that schema and data transfer works correctly across backends.

### DNS Resolution in Docker Builds

Documented the DNS resolution failure during Docker builds (rustup/npm cannot resolve hostnames) and the fix: adding `{"dns": ["1.1.1.1", "8.8.8.8"]}` to `/etc/docker/daemon.json`. This is now covered in the nanocode multi-tenant guide.

## Known Issues

- **OMEMO MUC fallback spam** — Posting in an encrypted MUC room triggers ~20 OMEMO fallback notice messages in the private 1:1 JID chat, even when OMEMO is disabled for that JID. Discovered 2026-05-12.
- **Rare processing loop stall** — The agent processing loop has been observed to get stuck once (single occurrence). Root cause not yet identified.
- **WebSocket idle disconnect** — Web gateway WebSocket connections still drop after idle periods (no server-side keepalive). SSE path has 30-second keepalive; WebSocket does not.
- **Nanocode `@nanogpt/plugin` warning** — Non-fatal npm 404 on container startup. The plugin is already bundled in the image; nanocode attempts a redundant `bun install` that fails harmlessly.

## Upgrade Notes

1. **Port registry** — Run `ic/scripts/migrate-ports-v3.sh` to upgrade existing v2 registries to v3. No tenant restart required for the migration itself.
2. **Nanocode image rebuild** — Run `sudo ic/scripts/lunarwing-mt-admin.sh build-nanocode-worker` to pick up the new Rust development packages.
3. **License** — The crate now declares `AGPL-3.0-or-later`. Downstream consumers should verify license compatibility.

## Deferred to Future Releases

| Feature | Target |
|---------|--------|
| Lunartica/Multica bridge WASM tool | v1.0.8+ |
| Reflex compiler (smart rules engine which will drastically reduce the need to call LLMs to run certain tools which are frequently used) | v1.0.8+ |
| LunarVoice (audio input/output) | v1.0.8+ |
| XMPP MUC OMEMO fixes | v1.0.8 |
| Character Lorebooks / profile enhancements | v1.0.9+ |
| Updated CI/CD Development Pipeline for LunarWing | v1.0.8 |
| Server-side WebSocket keepalive | v1.0.8 |
| Proprietary Channel removal (Discord, Slack, Telegram sources) | v1.0.8+ |

## Testing

Full pre-release test suite passed against the `starforce` multi-tenant instance:

- `ic/scripts/release-test.sh` — all 24 automated checks pass
- XMPP — 1:1 and MUC send/receive verified
- WeeChat — send/receive messages verified
- Gotify — push notification delivery verified
- Routines — cron, event-driven, manual, lightweight and full_job with tools all verified
- Nanocode external worker — job submission and execution verified
- Docker sandbox worker — job execution verified
- GitHub integration — auth and repo access verified
- Image/vision tools — LunarVision/K.E.R.S. verified
- Web search — results returned
- REPL v2 — interactive session verified
- Memory — read, write, search all functional
- Embedded Memory via openai api compatible endpoint - memory_search functional
- Job management — create, list, status, cancel verified
- Web gateway — pages served, API responsive
