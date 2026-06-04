# Release Notes for LunarWing v1.1.1 - Codename Unknown

**Release Date:** TDB

## Overview

LunarWing v1.1.1 is primarily a release purely focused on adding polish, bug-fixing, and improvement of existing features.

---

## Changes

### None yet


## Bug Fixes

- One change for X, Y, or Z

## Documentation

- Archive previous release notes into docs/ops going forward such that developers may reference previous changes.

## Known Issues

- **`wasm-tools` not found on build** — Cosmetic warning during `build-tenant --with-wasm`. Raw WASM files are copied without stripping/componentizing. Functionality is unaffected; install `wasm-tools` to eliminate the warning.
- **Gotify skill frontmatter** — Legacy `GOTIFYSKILL.md` files from Ironclaw may have missing YAML frontmatter delimiters, causing a skill load warning on startup. Does not affect Gotify native wasm tool functionality.
- **5 tests are failing due to not being updated after previous production code refactors. No production code is broken and these test failures have been throroughly documented.** - See docs/bugs for further information on these test failures and proposed fixes.
- **One test is failing due to an assertion count mismatch**
- **One test is failing due to env-specific SSRF check.**
- **Two tests for gateway workflow harness and test_rig from the test harness are failing for similar reasons to the ones above.** - See docs/bugs for further information on these test failures and proposed fixes.
- **Several E2E playwright tests may also need to be updated to account for major code refactoring.**
- **XMPP inbound file uploads not supported** — The bridge supports outbound XEP-0363 HTTP file uploads but does not parse inbound OOB (`<x xmlns='jabber:x:oob'>`) elements from incoming stanzas. Files sent to the agent via XMPP are silently ignored. See `docs/ops/XMPP_KNOWN_ISSUES.md`.
- **Multica Bridge** - Multica Bridge may require significant improvements. May also be copied into a new renamed bridge/channel type.
- **Multitenant Admin Script** -  A flag exists to set an api key for a model endpoint, but no such flag exists to set an http url automatically via this method.

## Upgrade Notes

1. **Database migrations**: V19 (reflex patterns), V20 (reflex embeddings), and V21 (NULL-safe unique constraint on `memory_documents`) will run automatically on startup. V21 deduplicates any existing rows with NULL `agent_id` before adding the constraint. **Back up your database before upgrading.** PostgreSQL 15+ is required for V21's `NULLS NOT DISTINCT` syntax.
2. **Tenant git remotes**: Tenant repos created before v1.0.8 may have their git origin pointing to a local path (`/home/cmc/lunarwing`) instead of the GitHub remote. Fix with `git remote set-url origin https://github.com/LunarWingOrg/lunarwing.git` before pulling updates.
3. **Port registry migration**: Existing multi-tenant deployments will auto-migrate the port registry from v4 to v5 on the next `add-tenant` or `ports list` call, renaming `reserved_3` to `weechat_adapter`. For standalone migration, run `ic/scripts/migrate-ports-v5.sh` as root.
4. **Pebble worker**: Tenants wanting Pebble support can run `configure-pebble <name> --nanogpt-api-key <key>` after building with `--with-pebble` to ensure real functionality.
5. **Multi-tenant onboarding**: Tenant provisioning now sets `ONBOARD_COMPLETED=true` to skip the setup wizard. Existing tenants that have already completed onboarding are unaffected (the TOML flag is still checked as a fallback).

## Features Deferred to Future Releases

| Feature | Target |
|---------|--------|
| Multica bridge and channel refinements and agent orechestration workflow improvements (currently marked as pre-release/experimental feature; more testing required) | v1.1.1+ |
| LunarVoice (Further planning required) | v1.1.4+ |
| Character Lorebook support / Agent Profile enhancements / Workspace Seeding Improvements / Agent Profile switching / User Profile switching (Further planning required) | v1.1.4+ |
| XMPP OMEMO MUC fallback fix | v1.1.1+ |
| XMPP inbound file upload support (XEP-0363/OOB parsing) | v1.1.1+ |
| Server-side WebSocket keepalive adjustment | v1.1.1+ |
| New suite of planned features with concepts adopted from Hermes Agent, Will seperate some of these out into actual categories here in the next release notes. Human Delay mode concept from there has been added already in a previous release. Will also create comprehensive documentation for each of the new features | v1.1.4+ |
| List of planned suggested features to pre-emptively improve security via input validation | v1.1.1+ |
| Proprietary channel removal continuation (Discord, Slack, Telegram sources) | v1.1.1+ |
| Attempt to safely remove the other non-supported default proprietary channels that still remain. Discord, Slack, Telegram, and others still remain. Core code changes will be required for all of these cases, just like what was done with WhatsApp removal in previous release | v1.1.1+ |
| Remove other non-supported extensions from the LW repo, specifically Google related ones. | v1.1.1+ |
| LunarWing developer CI/CD Pipeline | v1.1.2+ |
| LunarWing decision on continuing to use Github to publish source code or simply use it as a mirror | v.1.1.2+ |
| It is still undecided if Github extension should be removed from the main LunarWing repo or continued to be supported. | v1.1.2+ |
| Add the custom Git WASM workspace tool source code created months ago back to LunarWing, test again | v1.1.2+ |
| Upgrade version of tensorzero, plus optional tighter integration across deployments | v1.1.2+ |
| Drop support for custom tensorzero proxy, since it is simply no longer necessary. This has been verified. Local models are able to perform sufficiently and LunarWing agents can utilize all tool calls over Tensorzero directly. | v1.1.2+ |

## Testing

*Testing in progress before final release — see `docs/ops/PRE-RELEASE-TESTING.md` for the full checklist.*
