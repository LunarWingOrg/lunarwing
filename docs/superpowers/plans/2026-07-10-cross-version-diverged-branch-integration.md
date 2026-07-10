# Cross-Version Diverged Branch Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the intended `icporto`, Codex-provider-removal, and `cmov 0.5.4` changes onto the current V1 and V2 branches with corrected behavior and matched documentation.

**Architecture:** Treat `lunarwing` and `LunarWing_v2` as independent targets with equivalent core source. Apply source patches only where valid, reconstruct the corrupt Codex config change around the current resolver, and prove removal at config and CLI boundaries before broad verification.

**Tech Stack:** Rust 2024, Cargo, Clap, Serde, `serde_norway`, Insta snapshots, cargo-deny, Markdown.

**Execution constraint:** Do not switch branches, overwrite unrelated V1 changes, run debug builds, or commit automatically. Every Cargo command runs from the relevant `ic/` directory under `taskset -c 0-5` with at most six jobs.

---

### Task 1: Add Removal Regression Tests In Both Repositories

**Files:**
- Modify: `lunarwing/ic/src/config/llm.rs`
- Modify: `LunarWing_v2/ic/src/config/llm.rs`
- Modify: `lunarwing/ic/src/cli/mod.rs`
- Modify: `LunarWing_v2/ic/src/cli/mod.rs`

- [x] **Step 1: Add a failing backend-alias test**

Add this test in each `config/llm.rs` test module, using the existing environment lock:

```rust
#[test]
fn removed_openai_codex_aliases_are_rejected() {
    let _guard = lock_env();
    // SAFETY: The process-wide test environment is protected by ENV_MUTEX.
    unsafe {
        std::env::remove_var("LLM_BACKEND");
    }

    for backend in ["openai_codex", "openai-codex", "codex"] {
        let settings = Settings {
            llm_backend: Some(backend.to_string()),
            ..Default::default()
        };
        let error = LlmConfig::resolve(&settings).expect_err("removed backend must fail");
        let message = error.to_string();
        assert!(message.contains(backend), "{message}");
        assert!(message.contains("openai_compatible"), "{message}");
    }
}
```

- [x] **Step 2: Add failing CLI compatibility tests**

Add to each `cli/mod.rs` test module:

```rust
#[test]
fn login_compat_command_remains_available() {
    let cli = Cli::try_parse_from(["lunarwing", "login"]).expect("login should parse");
    assert!(cli.command.is_some());
}

#[test]
fn removed_openai_codex_login_flag_is_rejected() {
    let result = Cli::try_parse_from(["lunarwing", "login", "--openai-codex"]);
    assert!(result.is_err());
}
```

- [x] **Step 3: Run the two focused tests and confirm RED**

Run in each `ic/` directory:

```bash
taskset -c 0-5 cargo test -j6 --lib removed_openai_codex_aliases_are_rejected -- --nocapture
taskset -c 0-5 cargo test -j6 --lib removed_openai_codex_login_flag_is_rejected -- --nocapture
```

Expected: the backend test fails because Codex still resolves; the CLI test fails because the flag still parses.

### Task 2: Port The Serde And Lockfile Changes

**Files:**
- Modify in both repositories: `ic/Cargo.toml`, `ic/Cargo.lock`, `ic/bridges/xmpp-bridge/Cargo.lock`, `ic/crates/lunarwing_skills/Cargo.toml`, `ic/crates/lunarwing_skills/src/parser.rs`, `ic/crates/lunarwing_skills/src/types.rs`, `ic/deny.toml`, `ic/kCargo.toml`, `ic/src/bridge/store_adapter.rs`, `ic/src/skills/mod.rs`, `ic/src/skills/parser.rs`

- [x] **Step 1: Apply the `icporto` serde patch without its document commit**

Port commit `31881548555ff38c4447c4f043c3d652dc507258` to both worktrees. The result must replace every live `serde_yml::from_str` call with `serde_norway::from_str`, declare `serde_norway = "0.9"`, resolve `serde_norway 0.9.42`, and remove `RUSTSEC-2025-0068` from `deny.toml`.

- [x] **Step 2: Update root `cmov` lock entries**

In both root `ic/Cargo.lock` files, set:

```toml
[[package]]
name = "cmov"
version = "0.5.4"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "0c9ea0ac24bc397ab3c98583a3c9ba74fa56b09a4449bbe172b9b1ddb016027a"
```

The standalone XMPP bridge lock already contains this entry and must remain on `0.5.4`.

- [x] **Step 3: Run focused skills tests**

```bash
taskset -c 0-5 cargo test -j6 -p lunarwing_skills -- --test-threads=6
```

Expected: all `lunarwing_skills` tests pass in both repositories.

### Task 3: Reconstruct The Codex Provider Removal

**Files:**
- Delete in both repositories: `ic/src/llm/codex_auth.rs`, `ic/src/llm/codex_chatgpt.rs`, `ic/src/llm/codex_test_helpers.rs`, `ic/src/llm/openai_codex_provider.rs`, `ic/src/llm/openai_codex_session.rs`, `ic/src/llm/token_refreshing.rs`
- Modify in both repositories: `ic/Cargo.toml`, `ic/src/app.rs`, `ic/src/cli/mod.rs`, `ic/src/cli/models.rs`, `ic/src/config/llm.rs`, `ic/src/config/mod.rs`, `ic/src/llm/config.rs`, `ic/src/llm/mod.rs`, `ic/src/llm/models.rs`, `ic/src/main.rs`, `ic/src/settings.rs`, `ic/src/setup/wizard.rs`, `ic/tests/support/gateway_workflow_harness.rs`, `ic/tests/config_round_trip.rs`

- [x] **Step 1: Apply valid Kiyome hunks and delete dedicated modules**

Apply commit `1c5b8b1db842e4880337c08290543d3b51faa36c` except its corrupt `ic/src/config/llm.rs` hunk. This removes provider exports/factories, Codex-specific structs and registry fields, wizard setup, binary imports of deleted provider types, and the direct `eventsource-stream` manifest dependency. The source branch's interim no-op `login --openai-codex` behavior is replaced by the final compatibility command in Task 4.

- [x] **Step 2: Remove only Codex-specific resolver code**

In each current `config/llm.rs`:

- remove `openai_codex` from `LlmConfig` construction;
- remove dedicated backend detection and `OpenAiCodexConfig` resolution;
- remove `LLM_USE_CODEX_AUTH` and `CODEX_AUTH_PATH` credential overrides;
- restore normal API-key and base-URL resolution;
- remove the old Codex-positive tests;
- preserve `parse_extra_headers_with_key`, `default_session_path`, all generic provider tests, and all decorator tests.

Add explicit alias rejection directly after the existing direct-OpenAI rejection:

```rust
if matches!(
    backend_lower.as_str(),
    "openai_codex" | "openai-codex" | "codex"
) {
    return Err(ConfigError::InvalidValue {
        key: "LLM_BACKEND".to_string(),
        message: format!(
            "LLM_BACKEND={backend} has been removed. Use lunarwing_cloud, ollama, \
             or openai_compatible instead."
        ),
    });
}
```

- [x] **Step 3: Repair source-commit omissions**

Remove `is_codex_chatgpt`, `refresh_token`, and `auth_path` from the `RegistryProviderConfig` initializer in `tests/support/gateway_workflow_harness.rs`. Remove `openai_codex` from the supported backend list in `tests/config_round_trip.rs` while preserving its remaining round-trip coverage.

- [x] **Step 4: Reconcile lockfiles**

Run in each `ic/` directory:

```bash
taskset -c 0-5 cargo update -p cmov --precise 0.5.4
```

Expected: `Cargo.lock` reflects manifest dependency removal, `serde_norway 0.9.42`, and `cmov 0.5.4` without unrelated upgrades. `eventsource-stream` may remain transitively through `rig-core` but must not be a direct `lunarwing` dependency.

### Task 4: Implement CLI Compatibility And Setup Documentation

**Files:**
- Modify in both repositories: `ic/src/cli/mod.rs`, `ic/src/main.rs`, `ic/lunarwing.bash`, `ic/lunarwing.fish`, `ic/lunarwing.zsh`, `ic/src/setup/README.md`
- Modify in V1: `lunarwing/ic/src/llm/CLAUDE.md`

- [x] **Step 1: Convert Login to a unit compatibility command**

Use this command shape in both `cli/mod.rs` files:

```rust
/// Explain how to reconfigure an LLM provider.
#[command(
    about = "Reconfigure an LLM provider",
    long_about = "Standalone provider login is no longer available. Use `lunarwing onboard --provider-only` to reconfigure the active provider."
)]
Login,
```

Handle it in both `main.rs` files with:

```rust
Some(Command::Login) => {
    init_cli_tracing();
    println!(
        "Standalone provider login is no longer available. Run `lunarwing onboard --provider-only` to reconfigure the active provider."
    );
    return Ok(());
}
```

- [x] **Step 2: Remove the old completion flag**

Delete only the `--openai-codex` option from the checked-in Bash, Fish, and Zsh completion definitions. Keep the `login` subcommand.

- [x] **Step 3: Synchronize live documentation**

Remove `openai_codex` from the setup README's inference backend list in both repositories. In V1's LLM module spec, remove the six deleted modules, the Codex provider/auth sections, and the dedicated factory wording; document that the provider chain now always starts with `create_llm_provider`.

- [x] **Step 4: Re-run the RED tests and confirm GREEN**

Run in both repositories:

```bash
taskset -c 0-5 cargo test -j6 --lib removed_openai_codex_aliases_are_rejected -- --nocapture
taskset -c 0-5 cargo test -j6 --lib login_compat_command_remains_available -- --nocapture
taskset -c 0-5 cargo test -j6 --lib removed_openai_codex_login_flag_is_rejected -- --nocapture
```

Expected: all three tests pass.

### Task 5: Add And Correct The `icporto` Proposal

**Files:**
- Create in both repositories: `docs/proposals/IRONCLAW_ADDITION_CANDIDATES.md`
- Create in V2: `docs/superpowers/specs/2026-07-10-cross-version-diverged-branch-integration-design.md`, `docs/superpowers/plans/2026-07-10-cross-version-diverged-branch-integration.md`
- Modify in both repositories: `docs/README.md`

- [x] **Step 1: Port the proposal inventory**

Start from commit `2881ac41c2e223f78f715ed308cf7794b454b6ec`, preserve its priorities and candidate ordering, then correct the verified stale statements listed in the design document.

- [x] **Step 2: Correct repository-specific verification commands**

The proposal's default verification block must read:

```bash
taskset -c 0-5 cargo fmt --all -- --check
taskset -c 0-5 cargo test -j6 -- --test-threads=6
taskset -c 0-5 cargo check -j6 --no-default-features --features libsql
taskset -c 0-5 cargo check -j6 --no-default-features --features postgres
```

- [x] **Step 3: Update documentation indexes**

Add the proposal to the `proposals/` table and the cross-version design/plan to the `superpowers/` tables in both `docs/README.md` files.

### Task 6: Targeted And Full Verification

**Files:**
- Verify all modified files in both repositories.

- [x] **Step 1: Run targeted tests in each repository**

```bash
taskset -c 0-5 cargo test -j6 -p lunarwing_skills -- --test-threads=6
taskset -c 0-5 cargo test -j6 --lib config::llm::tests -- --test-threads=6
taskset -c 0-5 cargo test -j6 --lib cli::tests -- --test-threads=6
taskset -c 0-5 cargo test -j6 --lib setup::wizard::tests -- --test-threads=6
taskset -c 0-5 cargo test -j6 --test config_round_trip -- --test-threads=6
```

- [x] **Step 2: Run formatting and compile matrices in each repository**

```bash
taskset -c 0-5 cargo fmt --all -- --check
taskset -c 0-5 cargo check -j6 --locked
taskset -c 0-5 cargo check -j6 --locked --no-default-features --features postgres
taskset -c 0-5 cargo check -j6 --locked --no-default-features --features libsql
taskset -c 0-5 cargo check -j6 --locked --manifest-path bridges/xmpp-bridge/Cargo.toml
```

- [x] **Step 3: Run lint and dependency policy checks in each repository**

```bash
taskset -c 0-5 cargo clippy -j6 --all --benches --tests --examples -- -D warnings
taskset -c 0-5 cargo clippy -j6 --all --benches --tests --examples --all-features -- -D warnings
taskset -c 0-5 cargo deny check
```

- [x] **Step 4: Run structural checks**

Confirm in both repositories:

```bash
rg -n "serde_yml|RUSTSEC-2025-0068" ic
rg -n "openai_codex|openai-codex|LLM_USE_CODEX_AUTH|CODEX_AUTH_PATH" ic/src ic/tests ic/Cargo.toml
git diff --check
git status --short --branch
```

Expected: the serde/advisory search is empty; remaining Codex search hits are limited to the explicit removed-alias test/migration error or intentionally preserved unrelated/historical context; diff checks pass; the original V1 dirty files remain present and unchanged except for files explicitly named in this plan.
