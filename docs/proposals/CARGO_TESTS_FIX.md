# Premise

* There are only a small handful of failing cargo tests related to changes in the last two releases. They do not affect anything of value, but at some point it would be nice to revisit Cargo tests and apply any rewrites needed

## Current failing tests

e2e_advanced_traces::advanced::bootstrap_onboarding_clears_bootstrap, e2e_advanced_traces::advanced::bootstrap_greeting_fires,
e2e_reflex_compiler::e2e_compile_then_route_fuzzy, e2e_reflex_compiler::e2e_multiple_patterns_compile_and_route,
e2e_reflex_compiler::e2e_max_patterns_per_run_respected, e2e_reflex_compiler::e2e_compile_then_route_exact, e2e_reflex_compiler::e2e_compile_idempotent,
e2e_reflex_compiler::e2e_evicted_pattern_excluded_from_router, e2e_reflex_compiler::e2e_failed_build_not_persisted,
e2e_reflex_compiler::e2e_below_threshold_not_compiled, e2e_spot_checks::spot_tests::spot_chain_write_read, e2e_worker_coverage::tests::tool_error_feedback,
multi_tenant_system_prompt::tests::alice_system_prompt_contains_alice_identity,
multi_tenant_system_prompt::tests::bob_identity_does_not_leak_into_alice_prompt,
multi_tenant_system_prompt::tests::alice_identity_does_not_leak_into_bob_prompt, multi_tenant_system_prompt::tests::bob_system_prompt_contains_bob_identity

Failure mode confirmed for multi_tenant: agent uses generic default prompt, no user identity.
