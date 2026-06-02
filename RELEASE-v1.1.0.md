# Release Notes for LunarWing v1.1.0 - Codename Evolution

**Release Date:** TBD

## Overview

LunarWing v1.1.0 is a major feature release bringing Multica/Lunartica integration, expanded multi-tenant tooling for Pebble and WeeChat ws_adapter, improved LLM resilience, and cross-backend migration support. In addition, it includes major bug fixes, improvements to workspace seeding, and an easier onboarding process for new users.

---

## Changes

### Multica/Lunartica Bridge WASM Tool & Channel

Initial integration with the Multica self-hostable agent orchestration server:

- **`multica-bridge` WASM tool** (`ic/tools-src/multica-bridge/`) — Phase 1 & 2 complete. Provides bridge capabilities with schema definitions, configuration module, and capabilities manifest. Registered in `ic/registry/tools/multica-bridge.json`.
- **`multica` WASM channel** (`ic/channels-src/multica/`) — Phase 2 complete. Channel source with build script, capabilities manifest, and registry entry at `ic/registry/channels/multica.json`.
- **`multica-poll` skill** (`ic/skills/multica-poll/`) — Skill prompt for polling Multica.
- **Multica deployment guide** (`docs/guides/MULTICA_DEPLOYMENT.md`) — Server compatibility verification and deployment walkthrough.
- **Compatibility confirmed** (`docs/proposals/MULTICA_SERVER_COMPATIBILITY_CONFIRMED.md`) — Verification that Multica server is compatible with the bridge tool.

Live testing against a running Multica instance is the next step.

### Pebble Worker Multi-Tenant Support

The `lunarwing-mt-admin.sh` script now fully supports Pebble worker lifecycle:

- **`build-tenant --with-pebble`** — Builds the Pebble worker Docker image as part of tenant provisioning. Also available via `build-all --with-pebble` and standalone `build-pebble-worker`.
- **`configure-pebble <name>`** — New command to configure the Pebble worker for a tenant, accepting `--nanogpt-api-key` and `--model` (default: `openai/gpt-5.2`).
- **Pebble Dockerfile improvements** — Builder stage now clones Pebble from upstream (`nanogpt-community/pebble`) via shallow git clone instead of requiring a local copy, making builds self-contained.

### WeeChat ws_adapter Multi-Tenant Support

Full multi-tenant lifecycle management for the WeeChat WebSocket adapter:

- **Port registry v5** — The `reserved_3` port slot is now `weechat_adapter`. Existing registries are auto-migrated (v4 -> v5). New tenants get `weechat_adapter` at base+9. The `ports list` output now includes a `WS_ADPT` column.
- **Systemd and OpenRC service templates** — `add-tenant` now renders and installs `lunarwing-weechat-adapter-<tenant>` service units for both init systems, with proper `After=` ordering, environment passthrough (`WEECHAT_ADAPTER_PORT`, `RELAY_URL`, `RELAY_PASSWORD`), and `PartOf=` dependency on the main tenant service.
- **Configurable adapter port** — `ws_adapter.py` now reads `WEECHAT_ADAPTER_PORT` as an env var (in addition to the existing `ADAPTER_PORT`), allowing per-tenant port assignment without CLI flags.

### LLM Request Timeout Fix for rig-core Providers

The `openai_compatible`, `anthropic`, and `ollama` providers were silently ignoring the `LLM_REQUEST_TIMEOUT_SECS` configuration (default 120s). The factory functions in `ic/src/llm/mod.rs` did not pass the timeout parameter to rig-core's client builder, causing these providers to fall back to reqwest's default timeout instead of the user-configured value.

All three rig-core-based provider factories now build a `reqwest::Client` with the configured timeout and inject it via `.http_client()`:

- `create_openai_compat_from_registry(config, request_timeout_secs)`
- `create_anthropic_from_registry(config, request_timeout_secs)`
- `create_ollama_from_registry(config, request_timeout_secs)`

The timeout value is now logged in each provider's `tracing::debug!` output. Providers that already applied the timeout correctly are unaffected.

### libSQL-to-PostgreSQL Migration Tooling

Added scripts and documentation to support cross-backend migration from legacy Ironclaw libSQL instances to LunarWing multi-tenant PostgreSQL:

- **`ic/scripts/export-libsql.sh`** — Exports all tables from an Ironclaw libSQL database as CSV files, using Python's `csv` module for reliable handling of multiline values and binary data
- **`ic/scripts/import-to-pg.sh`** — Imports exported CSVs into a tenant's PostgreSQL database with explicit column lists, FK constraint deferral, and sequence reset
- **`ic/scripts/reimport-fixes.sh`** — Handles re-import of tables that require special treatment: hex-encoded BYTEA columns for `secrets`, Python-based CSV re-export for `settings` (JSON quoting), and `agent_jobs` (multiline descriptions)
- **`docs/guides/MIGRATE_IRONCLAW_LIBSQL_TO_MT.md`** — Updated with additional notes from real production live migrations.

Also performed more testing of this process from various versions of Ironclaw including 0.24.0 and 0.25.0.

### Tool Calling Diagnostic Script

Added `ic/scripts/lunarwing_toolcall_diag.py` — a standalone diagnostic script that tests tool call functionality against a running LunarWing instance. Validates that the LLM provider can generate properly-formatted tool calls and that the agent processes them correctly.

### Port Registry v5 Migration

The multi-tenant port registry has been upgraded from v4 to v5, reclaiming the last reserved slot for the WeeChat ws_adapter:

- **`reserved_3` renamed to `weechat_adapter`** — New tenants allocate `weechat_adapter` at base+9. Existing registries are auto-migrated inline during `add-tenant` or `ports list`.
- **Standalone migration script** — `ic/scripts/migrate-ports-v5.sh` performs the v4-to-v5 migration independently of `mt-admin`, for operators who need to migrate registries without provisioning a new tenant. Requires root and validates the current version before acting.
- **`ports list` updated** — Output now includes a `WS_ADPT` column reflecting the new slot.

### Stuck-Run Recovery Hardening

The hard-timeout path in the agent loop was significantly tightened:

- **Stuck window reduced from ~600s to ~30s** — Previously, the hard-kill timer waited a full second `handle_message_timeout` period (~600s with defaults) before aborting a stuck task. Now it fires after `HARD_KILL_GRACE_SECS` (30s), reducing the window where new messages queue indefinitely behind an orphaned task.
- **Orphaned task abort** — The hard-kill path now calls `abort_handle.abort()` to actually cancel the stuck tokio task, rather than just resetting thread state around it.
- **Pending message cleanup** — New `fail_turn_hard()` method clears the thread's `pending_messages` queue on hard timeout, preventing stale queued messages from leaking into future turns. The normal `fail_turn()` still preserves pending messages for the requeue-on-error recovery path.
- **3 regression tests** added covering `fail_turn_hard` queue clearing, `fail_turn` queue preservation, and no-op on empty threads.

### Onboarding Bootstrap Rework

Bootstrap workspace seeding now respects a new `ONBOARD_COMPLETED` environment variable:

- **Multi-tenant skip** — When `ONBOARD_COMPLETED=true` is set (as multi-tenant provisioning does), the setup wizard and bootstrap seeding are skipped entirely. Previously only the TOML `profile_onboarding_completed` flag was checked, which required a first-run cycle to set.
- **Single-tenant unchanged** — For single-tenant instances, the flag defaults to `false` and the normal first-run onboarding flow is preserved.
- **BOOTSTRAP.md removed from workspace template** — The bootstrap prompt file (`ic/deploy/workspace-template/BOOTSTRAP.md`) was removed; onboarding logic is now fully code-driven.

### Multi-Tenant Admin Improvements

- **`--llm-api-key` flag for `add-tenant`** — API key for the LLM backend can now be passed directly during tenant provisioning, eliminating the need to manually edit `lunarwing.env` after creation.
- **TensorZero default URL corrected** — Default upstream URL changed from `http://192.168.1.157:3000` to `http://192.168.1.157:3000/openai/v1`, fixing routing for OpenAI-compatible proxy paths.
- **Build reminder** — `build-tenant` now prints a post-build reminder at the end of output with next-step instructions.
- **Tenant Configuration Guide** — New `docs/ops/TENANT-CONFIGURATION.md` (331 lines) covering post-provisioning customization: file layout, LLM provider switching, XMPP bridge setup, Gotify, routine management, env var priority order, and applying changes across init systems.

### Community Resources

- Created `COMMUNITY.md` with IRC channel information (`#lunarwing` on Libera Chat), connection instructions for WeeChat and browser clients, and community guidelines
- README updated with community links, restructured sections, and new project logo

### Proposals & Planning Documents

- **`docs/proposals/REFINE_LIBSQL_MIGRATION_GUIDE.md`** — Automation of the libSQL migration workflow
- **`docs/proposals/WEECHAT_CLIENT_RELAY_API_AUTOMATION.md`** — WeeChat relay API automation
- **`docs/proposals/WEECHAT_LOCAL_WS_ADAPTER_ISSUE.md`** — WeeChat local ws_adapter issue analysis
- **`docs/proposals/WEECHAT_WS_ADAPTER_MISSING_DEPENDENCY_AND_AUTOMATION.md`** — Missing dependency and automation concerns
- **`docs/proposals/WEECHAT_WS_ADAPTER_SYNC_PROTOCOL.md`** — WebSocket adapter synchronization protocol design
- **`docs/proposals/MULTICA_INTEGRATION_PLAN.md`** — Multica integration phased plan
- **`docs/proposals/MULTICA_POSSIBLE_CONSIDERATIONS.md`** — Considerations for Multica adoption

## Bug Fixes

- **Empty-response "momentary lapse" fix (enhanced)** — Reasoning models (Qwen3, DeepSeek R1, Gemma 4, GLM-5) occasionally return responses consisting entirely of `<think>` tags, which `clean_response` strips to empty text. Previously, the agent silently substituted "I'm not sure how to respond to that." with no retry and no diagnostic logging. Now `respond_with_tools` retries up to `MAX_EMPTY_RESPONSE_RETRIES` (default 1, meaning 2 total attempts) before falling back. Added `truncate_for_log()` helper for safe diagnostic output, explicit handling for `None` content responses, and 6 regression tests covering the retry and fallback paths.
- **LLM timeout not applied to rig-core providers** — `LLM_REQUEST_TIMEOUT_SECS` was silently ignored for `openai_compatible`, `anthropic`, and `ollama` backends. See Changes section above for details.
- **Tool call diagnostic script error** — Fixed Python script that was not correctly referencing its entry point
- **Stuck tasks blocking message queue** — Hard-timeout recovery left orphaned tokio tasks running and stale pending messages in the queue. See Stuck-Run Recovery Hardening above.
- **TensorZero default URL missing path** — Multi-tenant admin default upstream URL was missing the `/openai/v1` path suffix, causing routing failures for OpenAI-compatible proxy requests.
- **Multi-tenant bootstrap seeding on provisioned tenants** — Tenants created via `mt-admin` would still receive the first-run onboarding flow because only the TOML flag was checked. Now respects `ONBOARD_COMPLETED` env var.

## Documentation

- README restructured with updated sections, community information, and new, current logo
- `COMMUNITY.md` created with Libera Chat IRC details and connection guides
- libSQL migration guide updated with lessons from live Kageho migration
- Multica deployment guide and server compatibility verification added
- Multi-tenancy production guide updated with Pebble worker configuration
- `docs/ops/TENANT-CONFIGURATION.md` — comprehensive post-provisioning configuration guide for operators and tenant users
- SOUL.md workspace template updated with more generic placeholder names
- Seven new proposal/planning documents added (see Proposals section)
- Began some of the implementation work to port some of the unique and useful features from Hermes Agent to LunarWing. This work is not included in this release, but there is documentation present for it.
- `GOALS_1.1.0.md` created with release milestone targets

## Known Issues

- **`wasm-tools` not found on build** — Cosmetic warning during `build-tenant --with-wasm`. Raw WASM files are copied without stripping/componentizing. Functionality is unaffected; install `wasm-tools` to eliminate the warning.
- **Gotify skill frontmatter** — Legacy `GOTIFYSKILL.md` files from Ironclaw may have missing YAML frontmatter delimiters, causing a skill load warning on startup. Does not affect Gotify native wasm tool functionality.
- **Multica bridge not yet live-tested** — The multica-bridge WASM tool and channel are built but have not yet been validated against a running Multica server instance yet.

## Upgrade Notes

1. **Database migrations**: V19 (reflex patterns) and V20 (reflex embeddings) will run automatically on startup. Back up your database before upgrading.
2. **Ironclaw migration**: Agents running on the legacy Ironclaw fork can now be migrated using the new export/import scripts. See `docs/guides/MIGRATE_IRONCLAW_LIBSQL_TO_MT.md` for the full walkthrough. Preserve the `SECRET_MASTER_KEY` from the old instance to ensure encrypted secrets remain accessible.
3. **Tenant git remotes**: Tenant repos created before v1.0.8 may have their git origin pointing to a local path (`/home/cmc/lunarwing`) instead of the GitHub remote. Fix with `git remote set-url origin https://github.com/LunarWingOrg/lunarwing.git` before pulling updates.
4. **Port registry migration**: Existing multi-tenant deployments will auto-migrate the port registry from v4 to v5 on the next `add-tenant` or `ports list` call, renaming `reserved_3` to `weechat_adapter`. For standalone migration, run `ic/scripts/migrate-ports-v5.sh` as root.
5. **Pebble worker**: Tenants wanting Pebble support can run `configure-pebble <name> --nanogpt-api-key <key>` after building with `--with-pebble` to ensure real functionality.
6. **Multi-tenant onboarding**: Tenant provisioning now sets `ONBOARD_COMPLETED=true` to skip the setup wizard. Existing tenants that have already completed onboarding are unaffected (the TOML flag is still checked as a fallback).

## Features Deferred to Future Releases

| Feature | Target |
|---------|--------|
| Multica bridge refinements | v1.1.1+ (pre-release feature) |
| LunarVoice (2-way audio input/output) | v1.1.4+ |
| Character Lorebooks / profile enhancements | v1.1.4+ |
| Proprietary channel removal (Discord, Slack, Telegram sources) | v1.1.4+ |
| XMPP OMEMO MUC fallback fix | v1.1.3 |
| Server-side WebSocket keepalive | v1.1.3 |
| New suite of planned features with concepts adopted from Hermes Agent | v1.1.6+ |

## Testing

*Testing will be completed before final release — see `docs/ops/PRE-RELEASE-TESTING.md` for the full checklist.*
