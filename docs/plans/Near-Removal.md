---
plan name: Near-Removal
plan description: Provider ABI migration
plan status: done
---

## Idea
Remove NEAR AI branding and identifiers from Rust provider/config surfaces and rename the WASM WIT ABI namespace away from `near::agent` to LunarWing-owned names. This is broader than crate/dependency cleanup and may be compatibility-breaking for existing WASM tools/channels and tenant configs, so the plan treats compatibility decisions, migration behavior, and verification as first-class deliverables. The intended end state is that active LunarWing Rust code, WIT bindings, config structs, env/docs where feasible, and package/dependency names no longer expose `Near*`, `nearai`, `NEARAI_*`, or `near::agent` naming except where deliberately retained as a temporary legacy alias with a documented removal window.

## Implementation
- Audit all Rust, WIT, manifest, generated binding, config, env, migration, docs, tests, and script references to `NearAi`, `NearAI`, `nearai`, `NEARAI_*`, `near::agent`, `near-agent`, `near:agent`, and stale `Near*` crate/dependency names; classify each as active rename, temporary legacy alias, generated artifact, historical archive, or unrelated NEAR blockchain text.
- Define canonical replacements before editing: provider/backend ID, Rust type names, module filenames, secret keys, env vars, config fields, WIT package/world/interface namespaces, generated binding module names, and Cargo package/dependency names using `lunarwing`/`LunarWing` naming consistently.
- Decide and document compatibility policy: whether old `nearai` backend IDs, `NEARAI_*` env vars, `nearai.session_token` DB settings, and `near::agent` WIT imports remain accepted as aliases for 1.1.9 or are removed immediately; if aliases remain, implement deterministic warnings and a specific future removal note.
- Rename Rust provider/config implementation surfaces: files such as `nearai_chat.rs`, types such as `NearAiConfig`, `NearAiChatProvider`, `NearAiEmbeddings`, helper functions such as `build_nearai_model_fetch_config`, module exports/imports, tests, and error/provider strings according to the canonical mapping.
- Replace or migrate configuration and persistence surfaces: env var readers/writers, bootstrap `.env` keys, secret names, DB setting keys, default config docs, setup/onboarding flow, doctor output, model CLI provider IDs, embeddings provider config, and tests; add migration or alias handling only if the compatibility policy requires it.
- Rename WIT ABI namespaces and generated bindings from `near::agent` / `near:agent` to a LunarWing-owned namespace across tool and channel WIT definitions, guest examples, host wrappers, linker registration, generated module references, tool builder templates, WASM examples, and fixture tests.
- Rename any actual Rust crates/dependencies still carrying stale Near/IronClaw branding in `Cargo.toml` package names, dependency keys, workspace members, and imports; refresh `Cargo.lock` only when Cargo requires it and keep lockfile changes paired with manifest changes.
- Update documentation and operational artifacts that describe active behavior: README, setup docs, tool/channel authoring docs, WIT compatibility docs, env examples, release notes/checklist, and any feature parity notes affected by removing NEAR AI naming.
- Run focused verification in tmux from `ic/` with repo constraints: `taskset -c 0-5 cargo fmt --all -- --check`, targeted `cargo check -j6`, targeted provider/config/WIT/wasm tests, and wider cargo tests where practical; never use full debug builds.
- Perform final stale-name audits with explicit allowlists for historical archives or temporary aliases, then prepare atomic commits split by provider/config rename, WIT ABI rename, crate/dependency rename, docs/tests, and lockfile normalization; do not push without explicit request.

## Required Specs
<!-- SPECS_START -->
- Near-Removal
<!-- SPECS_END -->