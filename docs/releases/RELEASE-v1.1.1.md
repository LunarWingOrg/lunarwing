# Release Notes for LunarWing v1.1.1 - Codename Freedom

**Release Date:** 2026-06-07

## Overview

LunarWing v1.1.1 is a release focused on adding polish, hardening the XMPP file transfer pipeline, removing proprietary channels from the codebase, and improving documentation and project infrastructure. The headline changes are full inbound XMPP file transfer support (XEP-0066 OOB extraction, download, and bridge transport), the removal of Discord, Feishu/Lark, and Slack channel/tool sources (continuing the proprietary channel removal initiative started with WhatsApp in 1.0.6), a new security port analysis identifying a high-severity cross-conversation history leakage bug inherited from upstream, additional polishing of the WeeChat channel (near-real-time long-poll ingestion plus first-DM and mirror-loop fixes, and a multi-tenant port fix) and the multi-tenant admin script, a documentation-accuracy pass, and other various minor changes.

---

## Changes

### XMPP Inbound File Transfer Support

LunarWing agents can now receive files sent over XMPP. Previously only outbound file transfers (agent to user via XEP-0363 HTTP File Upload) were supported. This release adds the full inbound pipeline:

- **OOB extraction** (`ic/src/channels/xmpp/mod.rs`) — New `extract_oob_attachments()` function parses `<x xmlns='jabber:x:oob'>` elements from incoming message stanzas, downloads file bytes via HTTP GET with a 30-second timeout and 20MB per-file size limit, infers MIME type from the response `Content-Type` header, and extracts the filename from the URL path.
- **Body deduplication** — When the message body exactly matches an OOB URL (the common XMPP client pattern where clients send the URL as both body text and a structured OOB element), the body is cleared to avoid the agent seeing a redundant raw URL alongside the structured attachment.
- **Empty-body acceptance** — Messages with no text body but valid OOB attachments are now accepted rather than silently dropped.
- **Bridge transport** (`ic/bridges/xmpp-bridge/src/main.rs`) — `enqueue_message()` now serializes inbound attachments as `BridgeAttachment` records with base64-encoded file data. The `attachments` field uses `#[serde(default)]` for backward compatibility with older bridge versions.
- **WASM channel decoding** (`ic/channels-src/xmpp/src/lib.rs`) — New `decode_inbound_attachments()` function base64-decodes each `BridgeIncomingAttachment`, stores bytes via `channel_host::store_attachment_data()`, and emits `InboundAttachment` records. The host merges stored data into `IncomingAttachment.data` for agent consumption.
- **Architecture documentation** (`docs/architecture/XMPP_FILE_TRANSFERS.md`) — Comprehensive document covering both outbound and inbound paths, protocol background (XEP-0363, XEP-0066), OMEMO considerations, size/timeout limits, and file listing by component.

| Limit | Value | Enforced at |
|-------|-------|-------------|
| Per-file download size | 20 MB | XmppChannel (OOB download) |
| Download timeout | 30 seconds | XmppChannel (reqwest client) |
| Per-attachment store | 20 MB | WASM host (`store_attachment_data`) |
| Total attachment store per callback | 50 MB | WASM host |

### Proprietary Channel Removal (Discord, Feishu/Lark, Slack)

Continuing the initiative started with WhatsApp removal in v1.1.0, three additional proprietary channel and tool sources have been removed from the codebase (~10,300 lines deleted across 96 files):

- **Discord WASM channel** — Removed `ic/channels-src/discord/` (Cargo workspace, capabilities manifest, build script, 1596-line `lib.rs`) and `ic/registry/channels/discord.json`.
- **Feishu/Lark WASM channel** — Removed `ic/channels-src/feishu/` (Cargo workspace, capabilities manifest, build script, 897-line `lib.rs`) and `ic/registry/channels/feishu.json`.
- **Slack WASM channel** — Removed `ic/channels-src/slack/` (Cargo workspace, capabilities manifest, build script, 829-line `lib.rs`) and `ic/registry/channels/slack.json`.
- **Slack WASM tool** — Removed `ic/tools-src/slack/` (Cargo workspace, API client, types, 165-line tool implementation) and `ic/registry/tools/slack.json`.
- **Relay channel infrastructure** — Removed `ic/src/channels/relay/` (channel, client, webhook, mod — 1,192 lines), `ic/src/config/relay.rs` (180 lines), and `ic/tests/relay_integration.rs` (215 lines). The relay subsystem was the underlying transport for proprietary webhook-based channels.
- **Web server relay endpoints** — Removed the relay-specific webhook server (`ic/src/channels/web/server.rs` — 457 lines) and extension handler relay routes.
- **Extension manager simplification** — Removed relay-specific extension lifecycle management, OAuth relay flows, and webhook-relay pairing from `ic/src/extensions/manager.rs` (~500 lines reduced).
- **Gate approval relay** — Removed `ic/src/gate/approval.rs` (144 lines) which handled relay-based remote approval flows.
- **WASM signature/schema simplification** — Reduced `ic/src/channels/wasm/signature.rs` by ~250 lines and `ic/src/channels/wasm/schema.rs` by ~60 lines, removing relay-specific signing and validation code.
- **FEATURE_PARITY.md updated** — Discord, Slack, and Feishu/Lark entries removed from the feature parity matrix. Slack is now marked "Removed — proprietary, not aligned with fork goals."
- **Bundle registry** — `ic/registry/_bundles.json` updated to remove proprietary channel entries.

Remaining proprietary channel to be addressed in future releases: Telegram.

### Security Port Analysis — IronClaw 0.29.1

New analysis document (`docs/proposals/OLDPROJECT_PORT_ANALYSES/ironclaw-0.29.1-port-analysis.md`) covering the upstream IronClaw v0.29.1 patch release. Key finding:

- **P0: Cross-conversation history leakage for non-UUID channel scopes** — LunarWing's v1 history persistence in `src/bridge/router.rs` only handles UUID-formatted conversation scopes correctly. When a channel produces a non-UUID scope (as XMPP does for room JIDs like `xmpp:room:dev@conference.example.org` or DM JIDs like `xmpp:dm:alice@example.org`), the `Uuid::parse_str()` call fails silently and all messages fall back to a single shared "assistant conversation" per user+channel. This causes history leakage across conversations and potential multi-tenant privacy violations. **This was fixed in v1.1.1** (`1.1.1-222-security-improvements-2`): `scoped_conversation_id()` now derives a stable UUID v5 from non-UUID scopes and `resolve_v1_conversation_for_message()` replaces the inline `Uuid::parse_str()` fallback. See `docs/architecture/FIXED_NON_UUID_SCOPE_LEAKAGE.md`.

Previous port analysis documents (`ironclaw-0.28.1`, `ironclaw-0.28.2`, `ironclaw-0.29.0`) were also updated with more specific information.

### Funding Infrastructure

Added project funding metadata for potential donors:

- **`funding.json`** — Machine-readable funding file with project metadata (name, description, license, tags), donation channels (BTC, XMR — addresses TBD), and plan definitions. Follows a structured schema with entity information, project details, and funding channel specifications.
- **`FUNDING_REQUEST.md`** — Placeholder stub referencing the funding.json file.

### Security Hardening — IronClaw Port Analysis Implementations

Four security items from the IronClaw 0.28.1 / 0.28.2 / 0.29.0 port analyses were implemented on branch `1.1.1-333-security-improvements-3`:

- **P0-A: Ghost-seeded tool permission cleanup** (`ic/src/app.rs`) — `seed_tool_permissions()` replaced with `cleanup_ghost_seeded_tool_permissions()`. Previous behavior wrote DB rows for every built-in tool's default permissions at startup; these "ghost" rows were indistinguishable from user-explicit overrides, creating a latent permission bypass vector. The new function performs a sentinel-gated one-shot migration that deletes ghost rows while preserving user overrides. Test `cleanup_ghost_seeded_tool_permissions_behavior` covers ghost removal, user-override preservation, and idempotency.
- **P1-H: Registry `hidden` field** (`ic/src/registry/manifest.rs`, `ic/src/extensions/mod.rs`, `ic/src/extensions/registry.rs`, `ic/src/registry/catalog.rs`) — Added `hidden: Option<bool>` to `ExtensionManifest` and `RegistryEntry`. Hidden entries are filtered from `ExtensionRegistry::all_entries()` and `RegistryCatalog::search()` results but remain installable by explicit name.
- **P2-A: Logs download endpoint** (`ic/src/channels/web/server.rs`) — New `/api/logs/download` route returns `recent_entries()` from the log broadcaster as NDJSON with `Content-Disposition: attachment; filename="lunarwing-logs.jsonl"`. Requires authentication. Gateway UI button not yet added (backend only).
- **P2-B: Approval gate clamping refactor** (`ic/src/bridge/router.rs`) — Extracted inline clamping logic into a named `clamp_always_to_resume_kind()` helper. Four unit tests cover: allow_always true, allow_always false, raw_always false, and non-Approval resume kinds (Authentication, External). Pure readability improvement, no behavior change.

Port analysis documents (`ironclaw-0.28.1`, `ironclaw-0.28.2`, `ironclaw-0.29.0`) updated to reflect implementation status.

### WebSocket Server-Side Keepalive

Server-side WebSocket keepalive implemented on branch `1.1.1-111-oof-june5staging-improvements-kestrel-local-1`. Previously, the server relied entirely on client-initiated ping/pong — if a client went silent (network partition, suspended tab, backgrounded app), the server held dead connections indefinitely.

- **Per-connection activity tracking** (`ic/src/channels/web/ws.rs`) — `WsConnectionTracker` upgraded from a simple `AtomicU64` counter to a per-connection `HashMap<Uuid, Instant>`. New API: `register_connection()`, `unregister_connection()`, `update_activity()`, `cleanup_stale()`.
- **Server-side ping** (`ic/src/channels/web/ws.rs`) — Sender task sends `Message::Ping` frames at configurable intervals (default 30s). Browsers auto-respond with Pong, keeping the idle timer alive.
- **Idle timeout** (`ic/src/channels/web/ws.rs`) — Receiver loop wrapped in `tokio::time::timeout()`. Any received frame (including Pong) resets the timer. Dead connections are closed after the idle timeout (default 120s).
- **Background stale cleanup** (`ic/src/channels/web/server.rs`) — 60-second sweeper task spawned in `start_server()` removes leaked tracker entries for connections that exited without unregistering (e.g., panicked handlers).
- **Configuration** (`ic/src/settings.rs`, `ic/src/config/channels.rs`) — `ws_ping_interval_secs` (default 30) and `ws_idle_timeout_secs` (default 120), configurable via `WS_PING_INTERVAL_SECS` and `WS_IDLE_TIMEOUT_SECS` env vars.
- **Tests** — 7 new tracker unit tests + 6 existing handler tests passing. Zero clippy warnings.

### WeeChat Channel Improvements

Substantial polish to the WeeChat (IRC) channel and its multi-tenant deployment, landing across three branches (`#13`, `#14`, `#15`).

- **Multi-tenant port/password fix** (`1.1.1-222-weechat-mulitenant-port-fix-2`) — The in-process WASM WeeChat channel previously ignored per-tenant relay/adapter ports and always polled the hardcoded defaults in `weechat.capabilities.json`, so only the one tenant whose ports happened to match worked. A generic, capability-declared **env-source mechanism** now injects each tenant's `RELAY_URL` / `WS_ADAPTER_URL` (and the per-tenant `RELAY_PASSWORD`, the second blocker — the adapter authenticates WASM requests against it) into channel config at `on_start`. A read-only pre-flight script (`ic/scripts/lunarwing-weechat-preflight.sh`) checks env-vs-registry alignment before upgrading existing tenants. See `docs/ops/WEECHAT-MULTITENANT-PORT-BUG.md`.
- **Near real-time ingestion (long-poll)** (`1.1.1-444-weechat-polish-and-fixes-4`) — Inbound delivery dropped from ~3s polling (and up to ~90s for a brand-new buffer's first DM) to ~ms. The adapter (`ws_adapter.py`) gained a global ordered event log and a blocking `GET /api/wait` endpoint; the WASM channel probes `/api/health` for support and consumes `/api/wait` via `do_longpoll`, falling back to per-buffer polling against older adapters. Timeout hierarchy: adapter wait ≤20s < WASM HTTP 25s < host callback 30s.
- **First-DM fix** — The first message in a freshly-created query/DM buffer was dropped at the **adapter**: a line for a buffer not yet in the cached buffer list was discarded entirely (so neither polling nor the long-poll cursor could deliver it). The adapter now refreshes its buffer list synchronously and retries, capturing the first line; `/api/wait` also replays the post-restart backlog so a DM right after an adapter restart isn't skipped.
- **Mirror-loop fix** — In long-poll mode the agent re-ingested and re-answered its own replies endlessly, because the `irc_privmsg`/`self_msg`/`no_log` tag filter lived only in the poll path. The filter moved into `handle_inbound_line` (`tags_allow_ingest`), the single choke point both ingest paths share (regression test `test_tags_allow_ingest`).
- **Debug-logging toggle** (`1.1.1-111-weechat-debug-logging-toggle-enable-1`) — The verbose debug logging in the WeeChat WASM channel and adapter is now toggleable via the `debug_logging` capability flag and **disabled by default**.
- **mt-admin + tooling** — `lunarwing-mt-admin.sh` now warns (non-fatally) if the adapter's `aiohttp` dependency is missing and runs each tenant's adapter/proxy from the tenant's own clone rather than the admin's source repo. New helper scripts: `create-tenant-*.sh` (provision a fresh tenant end-to-end), `upgrade-tenant-*.sh`, and `diag-weechat.sh` (read-only one-shot diagnostic). Full reference: `docs/architecture/WEECHAT-CHANNEL-ARCHITECTURE.md`.

### Self-Healing Improvements

Self-healing work documented in `docs/proposals/SELF_HEALING_IMPROVEMENTS_1.md`, including work from PR #6 and contributions by Kumogakare (documents) and Kestrel (suggested changes). The infrastructure health-check suite (`ic-infrastructure-health-check/`) and the watchdog installer (`ic/scripts/install-lunarwing-watchdog.sh`) were also improved — better per-service health checks and cron wrapper; an incorrect set of test fixtures/permission changes was reverted. Further healthcheck/self-healing enhancements are deferred to v1.1.2.

### Release Notes Archival

- Previous release notes (`RELEASE-v1.1.0.md`) moved from repo root to `docs/ops/RELEASE-v1.1.0.md` for long-term preservation. Going forward, all historical release notes live under `docs/ops/` or `docs/releases/`.

## Bug Fixes

- **XMPP messages with only file attachments were silently dropped** — `handle_message_stanza()` previously returned early when the message body was empty, ignoring messages that contained OOB file attachments but no text. Now checks for OOB payloads before dropping empty-body messages.
- **`cargo test` failed to compile** — `ic/tests/e2e_telegram_message_routing.rs` still called `Agent::run()` directly after the `self: Arc<Self>` refactor, breaking the whole test build. Wrapped with `Arc::new(agent).run()`. The default suite now compiles and runs — lib suite **3921 passed / 0 failed**; the only remaining `cargo test` failures are the two pre-existing `e2e_advanced_traces` bootstrap-greeting tests it unmasked (see Known Issues).

## Documentation

- `docs/architecture/XMPP_FILE_TRANSFERS.md` — Full architecture document for bidirectional XMPP file transfer support (outbound XEP-0363 + inbound XEP-0066 OOB)
- `docs/ops/STATUS_OF_REMOVAL_OF_PROPRIETARY_CHANNELS.md` — Tracks which proprietary channels have been removed (WhatsApp, Discord, Feishu/Lark) and which remain (Telegram)
- `docs/proposals/OLDPROJECT_PORT_ANALYSES/ironclaw-0.29.1-port-analysis.md` — Security analysis of upstream IronClaw 0.29.1 with the P0 conversation-isolation fix (now implemented)
- `docs/architecture/FIXED_NON_UUID_SCOPE_LEAKAGE.md` — Implementation note for the non-UUID conversation-scope leakage fix
- `docs/architecture/SECURITY_ENHANCEMENTS.md` — Session notes for the P0-A/P1-H security implementation work
- `docs/architecture/WEBSOCKET_KEEPALIVE_IMPLEMENTATION.md` — Summary of the WebSocket keepalive implementation
- `docs/proposals/WEBSOCKET_KEEPALIVE_IMPLEMENTATION.md` — Full design document for WebSocket server-side keepalive (problem statement, solution, configuration, migration notes)
- `docs/proposals/MULTICA_LUNARTICA_RESKIN.md` — Plan for reskinning Multica UI for Lunartica
- `docs/proposals/RENAME_IRONCLAW_WEECHAT_WS_CHANNEL_AND_ADAPTER` — Proposal to rename remaining ironclaw references in WeeChat channel, ws_adapter, and associated scripts
- `docs/architecture/WEECHAT-CHANNEL-ARCHITECTURE.md` — Authoritative WeeChat channel reference (components, ingestion/latency model, config precedence, known issues with fix status)
- `docs/ops/WEECHAT-MULTITENANT-PORT-BUG.md` — The per-tenant port/password fix and the env-sourced-fields mechanism
- `docs/bugs/README.md` — New Open-vs-Fixed bug index; the `docs/bugs/` set was reconciled against the code (stale "open" reports that are actually fixed were corrected)
- `docs/proposals/SELF_HEALING_IMPROVEMENTS_1.md` — Self-healing infrastructure improvements reference
- `docs/ops/PENDING_CLEANUP.md` — Updated with current removal status (Discord, Feishu, Slack marked as removed)
- `ic/FEATURE_PARITY.md` — Updated to reflect proprietary channel removals
- Previous release notes archived to `docs/ops/`

## Known Issues (not a complete list. see `docs/bugs` for more)

- **`wasm-tools` not found on build** — Cosmetic warning during `build-tenant --with-wasm`. Raw WASM files are copied without stripping/componentizing. Functionality is unaffected; install `wasm-tools` to eliminate the warning.
- **Gotify skill frontmatter** — Legacy `GOTIFYSKILL.md` files from Ironclaw may have missing YAML frontmatter delimiters, causing a skill load warning on startup. Does not affect Gotify native wasm tool functionality.
- **SSRF tests** — the named `openai_codex_rejects_ssrf_*` tests pass locally (verified 2026-06-07); the previously-noted env-specific SSRF failure did not reproduce here. Re-confirm in CI.
- **E2E playwright tests: 172 passing, 5 skipped (network-dependent).** Tool execution timeout bug (BUG-e2e-tool-execution-timeout.md) resolved — root cause was an unresolved tool approval in `test_tool_approval.py` blocking the agent loop for subsequent tests.
- Bug docs created:
  - ~~docs/bugs/BUG-e2e-tool-execution-timeout.md - echo/time tool tests timeout waiting for assistant response~~ **FIXED** — pending approval cleanup added to `test_tool_approval.py`
  - docs/bugs/BUG-e2e-clipboard-copy-test.md - clipboard API permissions in headless Chromium (skipped in CI, not a blocker)
  - docs/bugs/BUG-e2e-oauth-url-parameter-tests.md - all 6 tests skip during fixture setup due to transient network issues (skipped, not a blocker)
- **XMPP inbound file uploads — implemented, not yet e2e-tested** — inbound OOB parsing (`extract_oob_attachments()`) ships in v1.1.1 (the earlier "silently ignored / not parsed" description is now stale), but the full receive pipeline has not been exercised end-to-end. This is the one real file-transfer caveat for the release. See `docs/ops/XMPP_KNOWN_ISSUES.md` and `docs/architecture/XMPP_FILE_TRANSFERS.md`.
- **Multica Bridge** - Multica Bridge may require significant improvements. May also be copied into a new renamed bridge/channel type.
- **Multitenant Admin Script** - A flag exists to set an api key for a model endpoint, but no such flag exists to set an http url automatically via this method. Since the proxy is not necessary, this should be a priority at some point.
- **Logs download endpoint has no UI button** — `/api/logs/download` is available as a backend API but the corresponding gateway UI "download logs" button has not been added yet.
- ~~**Cross-conversation history leakage (P0)** — Non-UUID channel conversation scopes (XMPP room JIDs, DM JIDs, WeeChat buffer names) silently collapse into a shared history thread.~~ **FIXED** — `scoped_conversation_id()` now derives stable UUID v5 from non-UUID scopes; `resolve_v1_conversation_for_message()` replaces inline `Uuid::parse_str()` fallback. See `docs/proposals/OLDPROJECT_PORT_ANALYSES/ironclaw-0.29.1-port-analysis.md` implementation note.
- ~~**`test_context_length_recovery_via_compaction_and_retry` failing**~~ **FIXED (2026-06-07)** — the test's stub returned an *empty* success response, which tripped the empty-response retry in `respond_with_tools()` (an extra LLM call → `3 vs 2`). The stub now returns real recovery content via `StubLlm::set_response`, so the path is 1 fail + 1 retry = 2 calls. The default `cargo test` lib suite is green (3921 passed / 0 failed).
- **`e2e_advanced_traces` bootstrap-greeting tests failing** — `bootstrap_greeting_fires` and `bootstrap_onboarding_clears_bootstrap` fail at `tests/e2e_advanced_traces.rs:834/874` ("bootstrap greeting should produce a response"): the static bootstrap greeting doesn't arrive in the test rig. **Pre-existing**, surfaced only once the `cargo test` compile blocker (telegram test) was fixed — the binary couldn't build before, so it never ran. Not `StubLlm`/LLM-related; needs investigation. See `docs/bugs/BUG-e2e-bootstrap-greeting-tests.md`.
- ~~**Issue with weechat multitenant setup related to way adapter is configured**~~ **FIXED (v1.1.1)** — per-tenant relay/adapter ports and relay password are now injected via a capability-declared env-source mechanism; existing tenants need the documented backfill (`install-wasm` + `patch-env` + restart). See `docs/ops/WEECHAT-MULTITENANT-PORT-BUG.md` and `docs/architecture/WEECHAT-CHANNEL-ARCHITECTURE.md`.

## Upgrade Notes

1. **Database migrations**: V19 (reflex patterns), V20 (reflex embeddings), and V21 (NULL-safe unique constraint on `memory_documents`) will run automatically on startup. V21 deduplicates any existing rows with NULL `agent_id` before adding the constraint. **Back up your database before upgrading.** PostgreSQL 15+ is required for V21's `NULLS NOT DISTINCT` syntax.
2. **Tenant git remotes**: Tenant repos created before v1.0.8 may have their git origin pointing to a local path (`/home/cmc/lunarwing`) instead of the GitHub remote. Fix with `git remote set-url origin https://github.com/LunarWingOrg/lunarwing.git` before pulling updates.
3. **Port registry migration**: Existing multi-tenant deployments will auto-migrate the port registry from v4 to v5 on the next `add-tenant` or `ports list` call, renaming `reserved_3` to `weechat_adapter`. For standalone migration, run `ic/scripts/migrate-ports-v5.sh` as root.
4. **Pebble worker**: Tenants wanting Pebble support can run `configure-pebble <name> --nanogpt-api-key <key>` after building with `--with-pebble` to ensure real functionality.
5. **Multi-tenant onboarding**: Tenant provisioning now sets `ONBOARD_COMPLETED=true` to skip the setup wizard. Existing tenants that have already completed onboarding are unaffected (the TOML flag is still checked as a fallback).
6. **Proprietary channel removal**: If your deployment previously used the Discord, Feishu/Lark, or Slack WASM channels or the Slack tool, these are no longer available. The relay channel infrastructure has also been removed. Migrate to open-protocol alternatives (XMPP, WeeChat, DarkIRC) before upgrading.
7. **XMPP bridge compatibility**: The bridge contract now includes an `attachments` field in `BridgeMessage`. The field uses `#[serde(default)]` so older bridge binaries will still work (attachments will be empty), but rebuild the XMPP bridge binary to enable inbound file transfer support.

## Features and changes deferred to future releases

Items are grouped to respect the release cadence (`docs/ops/RELEASE_CADENCE.md`): odd-numbered releases focus on bug fixes / security / polish / cleanup, even-numbered releases focus on features, and the next major (v2.0.0) carries one very large change.

| Feature | Target |
|---------|--------|
| Healthcheck and Self-Healing Enhancements | v.1.1.2 |
| Remove other non-supported extensions from the LW repo, specifically Google related ones. | v1.1.2 |
| Better implementation of memory `lapse` bug fix previously implemented in 1.1.0 | v1.1.2 |
| Update funding.json with actual payment addresses and additional info | v1.1.3 |
| Multica bridge and channel refinements and agent orchestration workflow improvements (currently marked as pre-release/experimental feature; more testing required) | v1.1.4 |
| Lunartica UI reskin | v1.1.4 |
| XMPP OMEMO MUC fallback fix | v1.1.5 |
| XMPP File Upload Extensive round of further polishing | v1.1.5 |
| Drop support for custom tensorzero proxy, since it is simply no longer necessary. This has been verified. Local models are able to perform sufficiently and LunarWing agents can utilize all tool calls over Tensorzero directly. This would involve disabling the service on existing tenants as well as disabling the service by default on new ones | v1.1.5 |
| External Worker enhancements | v1.1.6 |
| Add rootless docker and rootless podman as mechanisms for mt admin setup | v1.1.6 |
| List of planned suggested features to pre-emptively improve security via input validation | v1.1.7 |
| WASM Channel Polishing | v1.1.7 |
| Rename ironclaw references in WeeChat channel and adapter | v1.1.7 |
| Add the custom Git WASM workspace tool source code created months ago back to LunarWing, test again | v1.1.8 |
| Upgrade version of tensorzero, plus optional tighter integration across deployments | v1.1.8 |
| Proprietary channel removal continuation (Telegram) | v1.1.9 |
| Decision to remove Github extension | v1.1.9 |
| v2 engine route | v2.0.0 |
| Better githooks for repo | v2.0.1 |
| LunarWing developer CI/CD Pipeline | v2.0.1 |
| LunarWing decision on switching to Codeberg or Self-hosted Gitlab rather than Github to host monorepo (GH can still be used as a mirror) | v2.0.1 |
| LunarVoice (Further planning required) | v2.0.4 |
| Stabilization & polish buffer — reserved for v2 engine and LunarVoice fallout (no new features planned; fill from bugs found across 2.0.0-2.0.2) | v2.0.3 |
| Character Lorebook support / Agent Profile enhancements / Workspace Seeding Improvements / Agent Profile switching / User Profile switching (Further planning required) | v2.0.2 |
| New suite of planned features with concepts adopted from Hermes Agent. Human Delay mode concept from there has been added already in a previous release. Will also create comprehensive documentation for each of the new features | v2.0.4 |

## Release Cadence

*A brief note about release cadence*

### Lunarwing abides by a release cadence. This helps to organize introduction of new `feature` and `polish` focused releases.
### For more information, please see:
* docs/ops/RELEASE_CADENCE.md
#### Occasionally, exceptions are made to the release cadence guidelines, but the goal is to try to stay within this paradigm.

## Testing

*In accordance with developer guidelines, a brief testing period must begin before each release.*

*Testing before final release has COMMENCED — see `docs/ops/PRE-RELEASE-TESTING.md` for the full checklist.*

*No new changes besides urgent fixes will be accepted into staging during evaluation period.*
