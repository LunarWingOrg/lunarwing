# Premise

* There are only a small handful of failing cargo tests related to changes in the last two releases. They do not affect anything of value, but at some point it would be nice to revisit Cargo tests and apply any rewrites needed

## Status (updated 2026-06-23)

### Fixed (10 tests)

**e2e_reflex_compiler (8 tests) — FIXED**

Root cause: `fresh_backend()` used `LibSqlBackend::new_memory()` which does not share state between connections in libsql. Each `connect()` returned a fresh empty database, so migrations ran on one connection and `seed_completed_jobs` hit a different empty connection. Additionally, the INSERT statement referenced an `updated_at` column that does not exist in the current schema.

Fix: switched to `LibSqlBackend::new_local(tempdir)` (matching the pattern in `TestRigBuilder`) and removed the stale `updated_at` column from the test INSERT.

Tests now passing:
- e2e_compile_then_route_exact
- e2e_compile_then_route_fuzzy
- e2e_multiple_patterns_compile_and_route
- e2e_max_patterns_per_run_respected
- e2e_compile_idempotent
- e2e_evicted_pattern_excluded_from_router
- e2e_failed_build_not_persisted
- e2e_below_threshold_not_compiled

**e2e_spot_checks::spot_tests::spot_chain_write_read — FIXED**

Root cause: trace fixture `tests/fixtures/llm_traces/spot/chain_write_read.json` contained stale `ironclaw` text (paths, content, request hints) that didn't match the test's updated `lunarwing` text. The TraceLlm hint check warned about the mismatch and the tool wrote to the wrong path.

Fix: replaced all `ironclaw` references with `lunarwing` in the fixture JSON.

**e2e_worker_coverage::tests::tool_error_feedback — FIXED**

Root cause: trace fixture `tests/fixtures/llm_traces/worker/tool_error_feedback.json` used `/tmp/ironclaw_error_feedback_test/recovered.txt` but the test patches `/tmp/lunarwing_error_feedback_test/recovered.txt`. The string replace didn't match, so the fixture still directed the tool to write to a nonexistent directory.

Fix: replaced `ironclaw` with `lunarwing` in the fixture JSON.

### Deferred (6 tests)

**e2e_advanced_traces (2 tests) — DEFERRED**

- advanced::bootstrap_greeting_fires
- advanced::bootstrap_onboarding_clears_bootstrap

Root cause (partial): the static bootstrap greeting (`src/workspace/seeds/GREETING.md`) was rebranded from "chief of staff" text to "I'm LunarWing" text. The test assertions were updated, but the tests still fail because the bootstrap greeting mechanism itself doesn't fire — `bootstrap_pending` is either not set during workspace seeding or the broadcast doesn't reach the test channel. Zero debug/trace log output about bootstrap during the test run. Needs deeper investigation of the workspace seeding → `bootstrap_pending` flag → agent_loop broadcast path with a tracing subscriber initialized.

**multi_tenant_system_prompt (4 tests) — DEFERRED (known architectural bug)**

- tests::alice_system_prompt_contains_alice_identity
- tests::bob_system_prompt_contains_bob_identity
- tests::alice_identity_does_not_leak_into_bob_prompt
- tests::bob_identity_does_not_leak_into_alice_prompt

These tests are explicitly documented as expected-to-fail (see test file header). The bug: the agent loop uses `self.workspace()` which returns a single shared workspace (user_id="default"). Identity files (IDENTITY.md, SOUL.md, USER.md) seeded under per-user IDs ("alice", "bob") are invisible to this workspace. Fixing requires architectural work to plumb per-user workspaces through the agent loop, which is out of scope for a test-fix pass.
