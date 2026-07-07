# Spec: Near-Removal

Scope: feature

# Near Removal Feature Spec

## Purpose
Remove active NEAR AI and `near::agent` branding from LunarWing Rust/provider/WASM surfaces, replacing it with LunarWing-owned names while preserving runtime safety and explicitly documenting any temporary compatibility aliases.

## Scope
This feature covers active code and operational surfaces, including:

- Rust provider/config names such as `NearAiConfig`, `NearAiChatProvider`, `NearAiEmbeddings`, `nearai_chat`, and `build_nearai_model_fetch_config`.
- Provider/backend IDs and strings such as `nearai`, `near_ai`, and provider error identifiers where they represent active LunarWing behavior rather than historical records.
- Environment/config/secrets/persistence keys such as `NEARAI_*`, `llm_nearai_api_key`, and `nearai.session_token`.
- WIT package/world/interface namespaces and generated bindings that currently expose `near::agent`, `near:agent`, or related `near_agent_*` naming.
- Rust crate/package/dependency names in manifests and `Cargo.lock` where stale Near/IronClaw branding remains.
- Tests, snapshots, setup/onboarding, doctor/model CLI output, docs, examples, scripts, and release checklist entries tied to these active surfaces.

## Out Of Scope
- Historical archive documents unless they are linked as active instructions.
- Unrelated uses of the word `near` as ordinary English or proximity semantics.
- NEAR blockchain/auth concepts only if still deliberately supported as an external protocol feature; these must be classified before editing.
- Mechanical removal of compatibility aliases before the compatibility decision is documented.

## Canonical Naming Requirements
- Public LunarWing-owned Rust types should use `LunarWing*` or a more precise domain name when `LunarWing` would be redundant.
- Internal module and crate names should use `lunarwing_*` or concise domain names already established by the repo.
- WIT package namespaces must move from `near:agent/...` to a LunarWing-owned namespace, such as `lunarwing:agent/...`, unless implementation discovery proves another namespace is already established.
- Provider/backend identifiers should stop using `nearai` for active LunarWing behavior. Choose and document the replacement before implementation.

## Compatibility Requirements
- Before editing, classify each old name as: remove immediately, accept as temporary alias, generated artifact, historical-only, or unrelated.
- If old config/env/DB/WIT identifiers remain accepted, they must emit deterministic warnings or be documented as a silent compatibility bridge with a specific removal window.
- If old identifiers are removed immediately, docs and release notes must call out the breaking change and any manual migration required.
- Existing tenant secret/config migration must not lose secrets. If keys move, implement read-old/write-new or an explicit migration path.
- Existing WASM tools/channels must either be migrated with generated bindings or explicitly marked incompatible with clear docs.

## Verification Requirements
- Run all cargo commands from `ic/` using `taskset -c 0-5` and `-j6` per repo constraints.
- Use tmux for long-running cargo commands.
- Run targeted checks/tests for provider config, setup/onboarding, doctor/model CLI, embeddings, WIT host wrappers, and any changed WASM tools/channels.
- Run a final stale-name audit for `NearAi`, `NearAI`, `nearai`, `NEARAI_`, `near::agent`, `near:agent`, `near_agent`, `ironclaw`, and stale crate names, with an explicit allowlist for retained compatibility or historical references.
- Update `docs/ops/GOALS_1.1.9.md` or release notes when the feature changes checklist status or user-facing migration behavior.

## Commit Discipline
Split implementation into atomic commits by concern: provider/config rename, WIT ABI rename, crate/dependency rename, docs/tests, and required lockfile normalization.