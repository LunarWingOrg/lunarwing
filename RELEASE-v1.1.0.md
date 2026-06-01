# Release Notes for LunarWing v1.1.0 - Codename Evolution

**Release Date:** TBD

## Overview

LunarWing v1.1.0 is a major feature release.

# Rest of this is from last release, needs to be updated with proper feature release formatting...

________________________

## Changes

### LLM Request Timeout Fix for rig-core Providers

The `openai_compatible`, `anthropic`, and `ollama` providers were silently ignoring the `LLM_REQUEST_TIMEOUT_SECS` configuration (default 120s). The factory functions in `ic/src/llm/mod.rs` did not pass the timeout parameter to rig-core's client builder, causing these providers to fall back to reqwest's default timeout instead of the user-configured value.

All three rig-core-based provider factories now build a `reqwest::Client` with the configured timeout and inject it via `.http_client()`:

- `create_openai_compat_from_registry(config, request_timeout_secs)`
- `create_anthropic_from_registry(config, request_timeout_secs)`
- `create_ollama_from_registry(config, request_timeout_secs)`

The timeout value is now logged in each provider's `tracing::debug!` output. Providers that already applied the timeout correctly (NEAR AI, GitHub Copilot, Codex ChatGPT) are unaffected.

### libSQL-to-PostgreSQL Migration Tooling

Added scripts and documentation to support cross-backend migration from legacy Ironclaw libSQL instances to LunarWing multi-tenant PostgreSQL:

- **`ic/scripts/export-libsql.sh`** — Exports all tables from an Ironclaw libSQL database as CSV files, using Python's `csv` module for reliable handling of multiline values and binary data
- **`ic/scripts/import-to-pg.sh`** — Imports exported CSVs into a tenant's PostgreSQL database with explicit column lists, FK constraint deferral, and sequence reset
- **`ic/scripts/reimport-fixes.sh`** — Handles re-import of tables that require special treatment: hex-encoded BYTEA columns for `secrets`, Python-based CSV re-export for `settings` (JSON quoting), and `agent_jobs` (multiline descriptions)
- **`docs/guides/MIGRATE_IRONCLAW_LIBSQL_TO_MT.md`** — Updated with additional notes from the live Kageho migration

Also performed more testing of this process from various versions of Ironclaw!

### Tool Calling Diagnostic Script

Added `ic/scripts/lunarwing_toolcall_diag.py` — a standalone diagnostic script that tests tool call functionality against a running LunarWing instance. Validates that the LLM provider can generate properly-formatted tool calls and that the agent processes them correctly.

### Community Resources

- Created `COMMUNITY.md` with IRC channel information (`#lunarwing` on Libera Chat), connection instructions for WeeChat and browser clients, and community guidelines
- README updated with community links, restructured sections, and new project logo

### Proposals

Two new proposal documents for future work:

- **`docs/proposals/REFINE_LIBSQL_MIGRATION_GUIDE.md`** — Automation of the libSQL migration workflow
- **`docs/proposals/WEECHAT_CLIENT_RELAY_API_AUTOMATION.md`** — WeeChat relay API automation

## Bug Fixes

- **LLM timeout not applied to rig-core providers** — `LLM_REQUEST_TIMEOUT_SECS` was silently ignored for `openai_compatible`, `anthropic`, and `ollama` backends. See Changes section above for details.
- **Tool call diagnostic script error** — Fixed Python script that was not correctly referencing its entry point

## Documentation

- README restructured with updated sections, community information, and new logo
- `COMMUNITY.md` created with Libera Chat IRC details and connection guides
- libSQL migration guide updated with lessons from live Kageho migration
- Two new proposals added for future automation work

## Known Issues

- **`wasm-tools` not found on build** — Cosmetic warning during `build-tenant --with-wasm`. Raw WASM files are copied without stripping/componentizing. Functionality is unaffected; install `wasm-tools` to eliminate the warning.
- **Gotify skill frontmatter** — Legacy `GOTIFYSKILL.md` files from Ironclaw may have missing YAML frontmatter delimiters, causing a skill load warning on startup. Does not affect Gotify tool functionality.

## Upgrade Notes

1. **Database migrations**: V19 (reflex patterns) and V20 (reflex embeddings) will run automatically on startup. Back up your database before upgrading.
2. **Ironclaw migration**: Agents running on the legacy Ironclaw fork can now be migrated using the new export/import scripts. See `docs/guides/MIGRATE_IRONCLAW_LIBSQL_TO_MT.md` for the full walkthrough. Preserve the `SECRET_MASTER_KEY` from the old instance to ensure encrypted secrets remain accessible.
3. **Tenant git remotes**: Tenant repos created before v1.0.8 may have their git origin pointing to a local path (`/home/cmc/lunarwing`) instead of the GitHub remote. Fix with `git remote set-url origin https://github.com/LunarWingOrg/lunarwing.git` before pulling updates.

## Deferred to Future Releases

| Feature | Target |
|---------|--------|
| Lunartica/Multica bridge WASM tool | v1.1.0+ |
| LunarVoice (2-way audio input/output) | v1.1.0+ |
| Character Lorebooks / profile enhancements | v1.1.0+ |
| Proprietary channel removal (Discord, Slack, Telegram sources) | v1.1.0+ |
| XMPP OMEMO MUC fallback fix | v1.1.1 |
| Server-side WebSocket keepalive | v1.1.1 |
| New suite of planned features with concepts adopted from Hermes Agent | v1.1.2+ |

## Testing

*Testing has been completed before final release — see `docs/ops/PRE-RELEASE-TESTING.md` for the full checklist.*
