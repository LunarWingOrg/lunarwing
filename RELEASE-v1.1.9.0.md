# Release Notes for LunarWing v1.1.9.0 - Codename `Kiyome (きよめ/清め)`

**Release Date:** TBD

> Codename *Kiyome* (きよめ/清め) means purification or cleansing. v1.1.9.0 is a mainly a cleanup release: it removes stale branding, unsupported provider and channel surfaces, dead vendored code, and several upgrade hazards while keeping the v1 line stable for operators. It does, however, introduce a new interactive tenant management system that allows new users as well as existing ones to manage new and existing multi-tenant agents in a far simpler manner. In the future, a web based version of this will also be added. This greatly simplifies the onboarding process for new users and will help ensure upgrades are easier as well! 

## Overview

v1.1.9.0 is the first release to use the four-part release-note version. The Rust crates and package manifests remain at `1.1.9`; the release itself is documented as `1.1.9.0` because any `1.1.9.x` releases will be small hotfixes, and the `1.1.9.x` line is the final LunarWing v1 release line before LunarWing v2.

## Highlights

- Final v1 versioning scheme: release notes use `1.1.9.0`; crates remain `1.1.9`.
- Remaining active IronClaw, NEAR AI, and `near::agent` surfaces were renamed toward LunarWing-owned names.
- External worker protocol moved to `lunarwing-agent-v1`, with `ironclaw-agent-v1` kept as a temporary compatibility alias.
- Built-in LLM provider registry was reduced to `ollama` and `openai_compatible`; LunarWing Cloud and OpenAI Codex remain special backends outside the registry.
- Deprecated `codex4lunarwing/` external worker was removed. This does not remove the `openai_codex` LLM backend.
- Telegram channel and tool support was removed from active source, registry, and build surfaces.
- Vendored upstream Nanocode source was removed; the Nanocode worker now clones upstream during image build.
- Multi-tenant onboarding gained the `lunarwing_mt_onboard` CLI, in-place upgrade wrapping, and Kawarimi export wrapping.
- Registry artifact installation was hardened around checksums and trusted artifact hosts.
- One data migration, `V22__rename_leak_pattern.sql`, renames the `nearai_session` leak pattern to `lunarwing_cloud_session`.

## Changes

### Versioning and v1 Line

- Release documentation now uses `v1.1.9.0`.
- Crate versions in `ic/Cargo.toml` and workspace crate manifests remain `1.1.9`.
- `1.1.9.x` is reserved for final LunarWing v1 hotfixes.
- The next major release line is v2. A blog post detailing the announcement of LunarWing v2 and what its goals will be will be published shortly after the release of 1.1.9.0.

### Naming, Protocol, and Compatibility Cleanup

- Remaining repo directories were renamed:
  - `ironclaw_weechat_wss/` -> `lunarwing_weechat_wss/`
  - `darkirc_channel_for_ironclaw/` -> `darkirc_channel_for_lunarwing/`
- Root compatibility symlinks for the old directory names are present in v1.1.9.0 only. Operators should re-render tenant units before v2.0.0, where those symlinks are scheduled for removal.
- External workers now speak `lunarwing-agent-v1`. The daemon offers both `lunarwing-agent-v1` and `ironclaw-agent-v1`; workers accept both for one deprecation cycle.
- WIT and WASM host ABI naming moved from `near:agent` / `near::agent` toward `lunarwing:agent`.
- The leak detection pattern name `nearai_session` was renamed to `lunarwing_cloud_session` in code and PostgreSQL seed data.

### Providers and Model Routing

- `ic/providers.json` now ships only:
  - `ollama`
  - `openai_compatible`
- LunarWing Cloud remains the default backend and is handled outside `providers.json`.
- OpenAI Codex remains available as the special `openai_codex` backend.
- Direct `LLM_BACKEND=openai` / `open_ai` is rejected. Use `LLM_BACKEND=openai_compatible` with `LLM_BASE_URL`, `LLM_API_KEY`, and `LLM_MODEL`.
- Removed provider registry entries include direct OpenAI, Anthropic, Bedrock, Gemini OAuth, OpenRouter, Groq, NVIDIA NIM, Venice, Together, Fireworks, DeepSeek, Z.AI/BigModel, Cerebras, SambaNova, io.net, Yandex, MiniMax, Cloudflare Workers AI, Tinfoil, and similar one-off built-ins. Use `openai_compatible` or a user provider override for compatible APIs.

### Removed Integrations

- Removed `codex4lunarwing/`, the deprecated Codex external worker container.
- Removed active Telegram WASM channel/tool source, registry manifests, default bundles, and build-script wiring.
- Removed default bundled GitHub and Linear skills from `ic/skills/`.
- The fresh-install extension bundle is now the LunarWing bundle: DarkIRC, WeeChat, XMPP, and Gotify.

### Workers

- Nanocode no longer vendors the upstream Nanocode source tree in `nanocode-config/nanocode`.
- `lunarcode4lunarwing/Dockerfile` clones upstream Nanocode at image build time and supports `NANOCODE_REF`.
- `build_nanocode_worker` was wired for clone-based builds and `WITH_TOOLCHAINS`.
- Opencode and Nanocode workers gained `WITH_TOOLCHAINS` build controls for slim versus fuller images.
- Worker Dockerfiles gained `apt-get update` fallback behavior using `snapshot.debian.org`.
- External worker config generation now covers `nanocode`, `pebble`, and `opencode` in tenant `config.toml`.

### Multi-Tenant Onboarding, Upgrade, and Migration

- Added `lunarwing_mt_onboard/`, an interactive Python CLI wrapper around `ic/scripts/lunarwing-mt-admin.sh`.
- The onboarding CLI supports provisioning, dry-run/apply upgrade mode, and dry-run/apply Kawarimi export mode.
- Added or documented in-place tenant upgrade flows around `upgrade-preflight.sh`, `upgrade-tenant-version.sh`, and the `mt-admin upgrade-tenant` verb.
- Added tenant rename migration docs for the v1.1.9 directory rename window.
- Kawarimi export/import now carries the data required for reliable migration: `SECRETS_MASTER_KEY`, XMPP credentials/config, OMEMO state, workspace state, worker config, and optional vision config.
- `import-tenant.sh` supports `--with-opencode`, `--with-toolchains`, `--with-vision`, `--tensorzero-url`, and explicit owner-scope migration.
- Owner-scope migration now hard-stops when multiple non-target scopes are present or old scopes remain after rekeying.

### Registry, Build, and Security Hardening

- Registry artifact installs now reject checksum mismatches instead of silently falling back.
- Artifact download hosts are restricted to GitHub/GitHubusercontent style hosts.
- Legacy WASM artifact manifests with removed URLs are source-build-only (`url: null`, `sha256: null`).
- TensorZero per-tenant proxy provisioning is opt-in for new tenants. New tenants should point directly at a standalone TensorZero/OpenAI-compatible endpoint unless `--enable-proxy` is explicitly used.
- `scripts/build-lunarwing.sh --wasm` remains as compatibility handling, but supported WASM artifacts are built through the current dedicated paths.

### Docs, Tests, and CI

- `docs/ops/GOALS_1.1.9.md` was replaced by `docs/ops/AGENT_GOALS_1.1.9.md`.
- Many stale `1.2.0` future references were retargeted to `2.0.0`.
- Root README and docs indexes were updated for v1.1.9 direction.
- Old documentation was archived or reorganized under `docs/internal/history/`.
- Added `ic/scripts/branch-test-loop.sh` for branch testing with snapshot-based WASM reuse.
- Updated old worker test scripts and documented their status in `docs/ops/TEST-SCRIPTS-STATUS.md`.
- Added the Codeberg mirror workflow.
- Old docker image publishing replaced
- Obsolete GCP VM bootstrap files were removed.
- Obsolete owner guard was removed.

### Dependency and Crate Updates

- `wasmtime` and `wasmtime-wasi` updated to `36.0.12`.
- `russh` updated to `0.62` with `ring` and `rsa` features; `russh-keys` was removed.
- `tokio-stream` now enables the `net` feature.
- Several dead dependencies and provider-specific dependency paths were removed.
- `deny.toml` and `Cargo.lock` were refreshed during the cleanup pass.

## Bug Fixes and Polish

- Added data migration `V22__rename_leak_pattern.sql` for the `lunarwing_cloud_session` leak-detection pattern name.
- Fixed Kawarimi import gaps around Opencode worker inclusion and owner-scope migration hard-stops.
- Preserved worker configuration through migration.
- Updated provider tests and assertions for the reduced provider registry.
- Regenerated shell completions under LunarWing naming.
- Removed obsolete root entrypoint and refreshed env examples.
- Updated workspace template defaults.
- Fixed old automated test harness issues, including missing worker entries and stale test dependencies.

## Upgrade Notes

1. Back up PostgreSQL before upgrading. v1.1.9.0 has a small data migration, not a broad schema expansion, but DB backup remains required practice.
2. Re-render tenant units after upgrading to pick up renamed WeeChat and DarkIRC paths. The old root symlinks are a v1.1.9 compatibility bridge only.
3. Reconfigure removed LLM providers through `openai_compatible`, `ollama`, `LunarWing Cloud`, OpenAI Codex, or a user provider override.
4. Do not confuse the removed `codex4lunarwing/` external worker with the still-present `openai_codex` LLM backend (pending removal) 
5. New tenants do not get the TensorZero proxy by default. Use `--enable-proxy` only when you intentionally want the per-tenant proxy service.
6. Nanocode worker builds now need network access to clone upstream Nanocode unless your build environment provides a cached or mirrored source path.
7. Use `python3 -m lunarwing_mt_onboard` for new multi-tenant provisioning. `setup-instance.sh` now warns that it is deprecated unless `LUNARWING_ONBOARD_LEGACY_OK=1` is set.
8. `upgrade-tenant-version.sh` remains PostgreSQL/rootful-Docker oriented. The legacy v1.0.3-v1.0.8 path requires an explicit target and refuses targets above v1.1.3.

## Known Issues

This list is the release-note view of the important carried issues. Some older docs are stale, so entries below are based on current code, scripts, and active manifests where they disagree.

### Resolved Since v1.1.8

- Kawarimi import now supports `--with-opencode`; Opencode no longer has to be built separately after import.
- Owner-scope migration during import now fails closed when multiple non-target scopes are present or rekey verification leaves old scopes behind.
- External worker config generation covers `nanocode`, `pebble`, and `opencode`.
- The old Codex external worker removal is complete; the remaining Codex code is the separate `openai_codex` LLM backend.

### Open or Carried Forward

- `create_job` still defaults `wait` to `true`. Long external worker jobs can block the current conversation turn; set `wait=false` when responsiveness matters.
- Worker `~/` path expansion remains a caveat for Opencode and likely Nanocode/Pebble. Use absolute `/workspace/...` paths in worker tasks.
- `ssh_git` still leaves `ref` optional in the tool schema. Pass `ref` explicitly to avoid null/remote-HEAD ambiguity.
- `ssh_git` clone still inherits normal Git behavior for bare repos whose `HEAD` points at a missing branch. Normalize bare repos with `git symbolic-ref HEAD refs/heads/main` or pass `ref`.
- `DELETE /hosts/{host}` removes host config but does not delete the associated key secret. Use `DELETE /hosts/{host}/key` for key cleanup.
- Built-in and WASM SSH tools still reject RSA keys; use Ed25519 or ECDSA.
- `ssh_git` AcceptFirst pinning is not durable because its known-hosts file is ephemeral. Prefer `Strict` with a pinned `known_host_key`.
- XMPP inbound file transfer has implementation coverage, but live end-to-end validation against real clients is still pending.
- OMEMO device trust may still require trusting the agent device from a client.
- Rootless worker workspace ownership still relies on permissive workspace permissions; UID pinning remains deferred.
- `podman save | load` image distribution remains slow for worker images.
- Rootless container crash recovery still depends on health/self-heal cadence rather than immediate parent supervision.
- Historical Telegram references remain in docs/tests/archive material, but active Telegram source, registry, and build surfaces were removed.
- Active bug docs still include unbounded spawned-task `mpsc` waits, plus test-only E2E/CI issues for headless clipboard, OAuth URL parameters, and bootstrap greetings.
- Single-instance setup remains less maintained than multi-tenant setup. Prefer the multi-tenant tooling for production.
- Kawarimi cross-host migration remains PostgreSQL-only and is a cutover with tenant downtime.
- `/api/logs/download` exists as a backend endpoint, but the gateway UI still lacks a download button.
- DarkIRC remains opt-in and still has the carried PM length limitation from DarkFi event metering.
- Multica bridge remains experimental.
