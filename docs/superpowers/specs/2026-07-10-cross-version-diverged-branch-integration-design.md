# Cross-Version Diverged Branch Integration Design

## Goal

Apply the intended changes from `icporto`, `kiyome/remove-codex-llm-provider`, and `dependabot/cargo/ic/cmov-0.5.4` to the currently checked-out branches in both `lunarwing` and `LunarWing_v2`, while preserving unrelated work and correcting defects in the source branches.

## Targets And Source Material

- V1 target: `lunarwing` on `rmcodex4v1`.
- V2 target: `LunarWing_v2` on `rmcodex4v2`.
- `icporto`: `31881548555ff38c4447c4f043c3d652dc507258` and `2881ac41c2e223f78f715ed308cf7794b454b6ec`.
- Codex provider removal: `1c5b8b1db842e4880337c08290543d3b51faa36c`.
- `cmov` update: `4dcd37e4dcffd38772d4b9851b3cad0cd692fb7a`.

The repositories stay on their current branches. The existing dirty V1 MCP, extension, web, and proposal changes are outside the integration path and must remain untouched.

## Selected Approach

Use a corrected patch-level port in both repositories.

Directly merging the source branches is unsuitable because their histories are substantially behind the V1 target and V2 has unrelated Git history. Blindly applying the Codex-removal commit is also unsafe: its `ic/src/config/llm.rs` snapshot is truncated in the middle of an expression and cannot parse. Reimplementing everything independently would introduce unnecessary drift from the named branches.

The corrected port preserves each branch's intended behavior, repairs omissions found during investigation, and keeps equivalent files aligned across V1 and V2.

## Serde Migration

Replace the unmaintained `serde_yml` dependency with `serde_norway 0.9` in the root daemon and `lunarwing_skills` manifests. Update all live SKILL.md and memory-frontmatter deserialization calls, both relevant lockfiles, the stale `kCargo.toml` shadow manifest carried by the source branch, and the cargo-deny advisory waiver.

Retain existing parsing behavior and add the source branch's focused `serde_norway::from_str` smoke test. Context7 confirms that `serde_norway::from_str` is the current deserialization API, and the resolved `0.9.42` crate has MSRV 1.71.1, below the repositories' Rust 1.92 requirement.

## Codex LLM Provider Removal

Remove only the dedicated LunarWing Codex/ChatGPT-subscription LLM backend and its credential overlay:

- delete the six provider, session, auth, token-refresh, and test-helper modules named by the source commit;
- remove the Codex-specific config types, registry-provider fields, factory paths, exports, wizard entry, and direct `eventsource-stream` dependency;
- preserve all generic provider-resolution helpers and all non-Codex tests accidentally deleted by the source commit;
- remove stale struct fields from the gateway workflow harness and model-listing path;
- remove `openai_codex` from setup and config round-trip expectations;
- reject `openai_codex`, `openai-codex`, and `codex` explicitly with a migration error instead of allowing the unknown-provider fallback to reinterpret them as `openai_compatible`.

`openai_compatible`, LunarWing Cloud, Ollama, OpenClaw's legacy OpenAI-to-compatible import mapping, embeddings, transcription, Codex-named model metadata, external workers, and the separate Pebble project remain in scope and unchanged.

## CLI Compatibility

Remove `--openai-codex` from the `login` command, help output, and checked-in Bash, Fish, and Zsh completions. Keep `lunarwing login` as a unit compatibility command that exits successfully with a message directing users to `lunarwing onboard --provider-only`.

Add parsing coverage proving that bare `login` remains accepted while `login --openai-codex` is rejected.

## Dependency Lock Update

Update the root `ic/Cargo.lock` from `cmov 0.5.3` to `0.5.4` with the source branch's checksum. `cmov` is transitive through `ctutils`; no source API changes are required. The standalone XMPP bridge lock already contains `cmov 0.5.4`. Current Cargo metadata reports MSRV 1.85 for `cmov 0.5.4`, below the workspace requirement.

## Documentation

Add `docs/proposals/IRONCLAW_ADDITION_CANDIDATES.md` to both repositories and index it from `docs/README.md`. Preserve the source document's candidate inventory while correcting verified stale claims:

- describe the serde migration as part of this integration;
- clarify raw versus injected WASM leak-scan behavior;
- include the duplicate web job-result contract in the typed-status scope;
- describe Wasmtime work as a fresh audit from the current `36.0.12` baseline;
- use the repository-required `taskset -c 0-5`, `-j6`, and exact formatting commands.

Update live setup and LLM architecture documentation where present. Do not rewrite historical release notes or unrelated comparisons that mention Codex as historical or external context.

## Error Handling And Compatibility

Removed backend aliases fail during `LlmConfig::resolve` with `ConfigError::InvalidValue`. The error identifies the removed backend and directs operators to supported providers. This prevents silent fallback, avoids late authentication failures, and gives existing deployments an actionable migration path.

No database, network, wire-format, or persistent-state migration is introduced.

## Verification

Use test-driven coverage for removed aliases and CLI parsing, then run in each repository from `ic/`:

- targeted config, CLI, skills, setup, and config-round-trip tests;
- `cargo fmt --all -- --check`;
- default, PostgreSQL-only, and libSQL-only `cargo check` commands;
- all-target/all-feature Clippy with warnings denied;
- standalone XMPP bridge check;
- `cargo deny check`;
- repository-wide searches proving live `serde_yml`, its advisory waiver, and dedicated Codex-provider wiring are gone;
- `git diff --check` and final dirty-worktree review.

Every Cargo command must use `taskset -c 0-5` and at most six jobs. No debug build is used.
