# PEBBLE.md

This file gives Pebble repo-specific guidance for working in this project.

## Project Overview
- **LunarWing** is a self-hosted, privacy-first AI agent, a hard fork of IronClaw (NearAI), started February 2026. Upstream compatibility is **not** a goal.
- The core daemon lives in `ic/` (internal path inherited from upstream; the product name is LunarWing).
- Written in Rust (edition 2024, MSRV 1.92).
- License is **AGPLv3** (the LICENSE file), even though `Cargo.toml`'s `license` field may still read MIT/Apache-2.0 from upstream — verify before relying on it.
- Focus areas: XMPP/OMEMO, Gotify, scheduled routines with retry/backoff, systemd/OpenRC deployment, multi-tenancy. Proprietary channels (Slack, Discord, Telegram) are intentionally unsupported.

## Repository Shape
- `ic/` — core LunarWing daemon (Cargo workspace).
- `ic_sm/`, `gotify-wasm/`, `ironclaw-gotify-tool/`, `ironclaw_weechat_wss/`, and other top-level dirs — related tools/components; inspect each before changing.
- `docs/` — guides (e.g., branching strategy under `docs/guides/`).
- `.pebble/` — Pebble settings (currently untracked).
- `CLAUDE.md`, `AGENTS.md`, `MANIFESTO.md`, `MIGRATION_GUIDES.MD`, `UPGRADE_CARGO.md` — project conventions; read these for deeper context.
- Verify the exact contents/purpose of less-obvious top-level dirs before editing.

## Commands
Run LunarWing commands from `ic/`. The exact LunarWing command list in `CLAUDE.md` is truncated — verify there before relying on these. The IronClaw section documents this workflow, which the fork likely mirrors:
- `cargo fmt`
- `cargo clippy --all --benches --tests --examples --all-features` (target zero warnings)
- `cargo test`
- `cargo test --features integration` (PostgreSQL tests)
- `RUST_LOG=...=debug cargo run`

## Working Agreement
- Branching: `staging` is the integration branch — feature branches merge there first; releases are tagged from staging.
  - Feature branches: `1.0.6-<FeatureName>` (e.g. `1.0.6-LunarVision`).
  - Agent branches: `staging-<agentname>-<n>` (e.g. `staging-ruffles-1`).
  - Experimental: `experimental-*`.
  - See `docs/guides/` (BRANCHING guide) for details.
- Do not add support for proprietary channels (Slack, Discord, Telegram).
- Keep all new tools/extensions/channels AGPLv3-compatible.
- Prefer small, reviewable changes aligned with existing repo workflows.
- Keep shared defaults in `.pebble/settings.json`; reserve `.pebble/settings.local.json` for machine-local overrides.
- Update `PEBBLE.md` intentionally when repo workflows or conventions change.
