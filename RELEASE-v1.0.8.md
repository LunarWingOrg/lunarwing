# Release Notes for LunarWing v1.0.8

**Release Date:** Pending

## Overview

LunarWing v1.0.8 is a feature release. It introduces the reflex compiler for LLM-free fast-path execution of recurring prompts, two new external worker containers (Pebble and Codex), supervised mode for human-gated tool execution, XEP-0363 HTTP file upload support for XMPP, response suppression with proper future cancellation, and a comprehensive documentation overhaul renaming IronClaw references to LunarWing throughout.

## New Features

### Reflex Compiler

A smart rules engine that detects recurring user prompts and compiles them into optimized execution paths, bypassing the LLM entirely for known patterns. This drastically reduces latency and cost for frequently-used commands.

- **Three-tier matching**: exact match (O(1) hash lookup), fuzzy match (Jaro-Winkler similarity via `strsim`), and semantic match (embedding cosine similarity when an `EmbeddingProvider` is configured)
- **Auto-promotion**: fuzzy hits that match 3+ times are automatically promoted to the exact-match cache for O(1) routing on subsequent calls
- **Stale pattern eviction**: patterns that haven't been accessed beyond a configurable threshold are pruned automatically
- **Dual-backend persistence**: new migrations V19 (`reflex_patterns`) and V20 (`reflex_embeddings`) for both PostgreSQL and libSQL
- **CLI management**: `reflex list`, `reflex show`, `reflex delete`, `reflex status`
- **E2E tests**: full compilation pipeline test suite

### Pebble External Worker

New persistent external worker container (`pebble4lunarwing/`) that wraps the Pebble agentic coding harness as a LunarWing-managed worker.

- Rust-based binary speaking the `ironclaw-agent-v1` WebSocket protocol
- Spawns `pebble prompt --output-format ndjson` per task, streaming NDJSON events back as `task_progress` messages
- Health endpoints (`GET /health`, `GET /ready`)
- Docker Compose support with CLI one-shot mode
- Dispatched via `create_job(mode: "pebble", ...)`

### Codex4LunarWing Worker Container

New dedicated LunarWing Codex worker container (`codex4lunarwing/`), replacing the deprecated `codex4ironclaw/`.

- Docker image wrapping `@openai/codex` as a persistent managed worker
- Full-auto mode with LunarWing WebSocket bridge
- Health server, smoke tests, and persistent mounted storage
- Dispatched via `create_job(mode: "codex", ...)`

### Supervised Mode (Human Delay Mode Phase 1)

A new safety mode where all tool actions require explicit human approval before execution, regardless of the tool's configured approval tier.

- New `--supervised` CLI flag and `SUPERVISED_MODE` env var
- `supervised_mode` propagated through `ThreadConfig`, `GateContext`, and `ThreadExecutionContext`
- In supervised mode, the approval gate pauses execution for every tool call, with no "always approve" option for tools that normally require approval
- Orthogonal to `ExecutionMode` and takes precedence over per-tool `ApprovalRequirement`

### XMPP XEP-0363 HTTP File Upload

Initial implementation of XEP-0363 HTTP File Upload for the XMPP channel, enabling agents to send file attachments.

- `OutboundAttachment` struct for file metadata and data
- HTTP upload service discovery via `DiscoItemsQuery`
- `SlotRequest`/`SlotResult` handling for upload slot negotiation
- OOB (Out-of-Band) URL delivery alongside text messages
- Bridge server and WASM channel updates
- Contract tests for the XEP-0363 flow

### Response Suppression and Future Cancellation

Hardened message handling with proper timeout behavior and cleanup.

- Soft timeout fires an `AtomicBool` suppression flag, preventing stale responses from being delivered to the user
- Hard-kill timer follows the soft timeout as a secondary cancellation mechanism if the task does not complete
- Message handler timeout fix for a known timeout issue

### Gate and Lease Accounting Guards

Added guards to gate and lease accounting to prevent resource accounting drift.

## Bug Fixes

### Reflex Compiler Fixes

- libSQL `prune` now returns evicted status to match PostgreSQL behavior
- User's actual input variant is promoted to the exact-match cache (not the normalized form)
- Auto-promotion now works correctly with semantic routing; migration idempotency fixed
- E2E test corrections (`.route()` to `.try_route()`)

### XMPP

- Legacy device ID migration now succeeds (test updated to reflect that legacy migrations pass)

### Instrumentation

- Hot-path instrumentation logs downgraded to `debug` to reduce log noise; `warn` retained on sentinel events
- Detailed logging added for follow-up-message-after-rejection approval edge case

### Code Quality

- `cargo fmt` applied across crate to fix formatting from recent merges

## Documentation

### IronClaw to LunarWing Rename Pass

Comprehensive documentation reorg renaming IronClaw references to LunarWing across the repository, including:

- `FEATURE_PARITY.md` — all column headers and notes updated from IronClaw to LunarWing
- `CLAUDE.md` — updated branching conventions, removed broken references to deleted files
- `README.md` — fixed typo, updated worker container references, fixed release notes link
- `docs/README.md` — removed deleted file entries, fixed stale references

### New Documentation

- `docs/ops/RELEASE_CADENCE.md` — release cadence policy (odd = bugfix, even = feature)
- `docs/ops/FUTURE_RELEASE_ITEMS.md` — items deferred beyond v1.0.8
- `docs/ops/PRE-RELEASE-TESTING.md` — pre-release testing landscape and quick-start
- `docs/internal/GRANT_PROPOSAL_FRAMEWORK.md` — grant proposal framework
- `docs/architecture/ATOMICBOOL_DEEPER_PROPAGATION.md` — AtomicBool cancellation propagation design
- `docs/architecture/RESPONSE_SUPPRESSION_IMPLEMENTATION.md` — response suppression design
- `docs/guides/REFLEX_COMPILER_TESTING.md` — reflex compiler testing guide
- Human Delay Mode documentation: index/summary, testing guide, phase 1 checklist, phase 2 plan
- `pebble4lunarwing/CLAUDE.md` and `pebble4lunarwing/README.md`
- `codex4lunarwing/CLAUDE.md`

### Cleanup

- Deleted obsolete `FEATURE_BRANCHES_1.0.6.md`, `GOALS_FOR_NEXT_RELEASES.md`, `docs/guides/BRANCH_GUIDE.md`
- Cleaned up old directories and outdated ironclaw references throughout docs

## Known Issues

- **XMPP XEP-0363**: file upload is implemented but not yet fully tested end-to-end in a production environment
- **Reflex compiler**: first iteration — semantic routing requires a configured embedding provider; long-term pattern stability needs extended testing
- **OMEMO MUC fallback spam**: still present from v1.0.7 (posting in encrypted MUC triggers fallback notices in 1:1 chat)
- **Rare processing loop stall**: single occurrence observed in v1.0.7; not yet reproduced

## Upgrade Notes

1. **Database migrations**: two new migrations (V19, V20) will run automatically on startup. Back up your database before upgrading.
2. **Pebble worker**: if deploying the pebble worker, add a `[[sandbox.external_workers]]` entry to `config.toml` with `name = "pebble"`.
3. **Codex worker**: migrate from `codex4ironclaw/` to `codex4lunarwing/` — rebuild the Docker image from the new directory.
4. **Supervised mode**: opt-in via `--supervised` CLI flag or `SUPERVISED_MODE=true` env var. No changes needed for existing deployments.

## Deferred to Future Releases

| Feature | Target |
|---------|--------|
| Lunartica/Multica bridge WASM tool | v1.1.0+ |
| LunarVoice (audio input/output) | v1.1.0+ |
| Character Lorebooks / profile enhancements | v1.1.0+ |
| Proprietary channel removal (Discord, Slack, Telegram sources) | v1.1.0+ |
| XMPP OMEMO MUC fallback fix | v1.0.9 |
| Server-side WebSocket keepalive | v1.0.9 |

## Testing

*Testing to be completed before final release — see `docs/ops/PRE-RELEASE-TESTING.md` for the full checklist.*
