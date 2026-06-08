# Bug Tracker Index

Reconciled against the code on **2026-06-07** (v1.1.1). **2026-06-08:** pruned superseded
agent-transcript dumps (their content lives in the canonical docs below + this index), added
`BUG-LAPSE.md`, and trimmed `WEECHAT-NO-SECRET-ACCESS.md`. **Open** = still reproducible in the
current tree. **Fixed** = resolved; the doc is retained for history with a status banner at the top.

## Open

| Doc | Summary | Severity |
|-----|---------|----------|
| [BUG-unbounded-mpsc-recv-in-spawned-tasks.md](BUG-unbounded-mpsc-recv-in-spawned-tasks.md) | Two `agent_loop.rs` notification forwarders `recv().await` with no timeout (the 3rd relay site was removed in v1.1.1) | Medium |
| [BUG-e2e-clipboard-copy-test.md](BUG-e2e-clipboard-copy-test.md) | Headless Chromium clipboard permissions — skipped in CI | Low (env, non-blocker) |
| [BUG-e2e-oauth-url-parameter-tests.md](BUG-e2e-oauth-url-parameter-tests.md) | Fixture needs network/proxy to fetch WASM — skipped in CI | Low (env, non-blocker) |
| [MISSING-CONFIG-FOR-NANOCODE.md](MISSING-CONFIG-FOR-NANOCODE.md) | `mt-admin` doesn't auto-generate the nanocode `external_workers` config + token | Low |
| [BUG-e2e-bootstrap-greeting-tests.md](BUG-e2e-bootstrap-greeting-tests.md) | `bootstrap_greeting_fires` + `bootstrap_onboarding_clears_bootstrap`: static greeting not observed by the test rig (`e2e_advanced_traces.rs:834/874`). Pre-existing; unmasked by the compile fix. Not `StubLlm`/LLM-related. | Med (test-only) |

## Fixed (retained for history)

| Doc | Resolution |
|-----|------------|
| [BUG-subagent-worker-hang.md](BUG-subagent-worker-hang.md) | Job watcher updates `ContextManager` (`job_manager.rs:529`); supervised WASM polling |
| [BUG-LAPSE.md](BUG-LAPSE.md) | `<function=NAME>` tool-call dialect recovered before response cleaning, so it no longer cleans to empty and trips the "I'm not sure how to respond" fallback (`reasoning.rs`, commit `7a9aca2c`) |
| *(no doc)* `memory_write` null/omitted `layer` | Omitting `layer` now writes to the workspace default scope instead of erroring `Layer not found: null` (`memory.rs`). Was reported in the removed LIST-OF-BUGS-BY-NOKO.md. |
| [BUG-daemon-stops-polling-xmpp-bridge.md](BUG-daemon-stops-polling-xmpp-bridge.md) | Supervised polling loop respawns inner loop + `health_check()` (`wrapper.rs:2285`) |
| [BUG-engine-crate-test-failures.md](BUG-engine-crate-test-failures.md) | `cargo test -p lunarwing_engine` green (271 passed, 0 failed) |
| [BUG-rust-integration-test-harness-failures.md](BUG-rust-integration-test-harness-failures.md) | `Arc::new(agent).run()` applied (incl. the telegram e2e site that blocked compilation) |
| [BUG-e2e-tool-execution-timeout.md](BUG-e2e-tool-execution-timeout.md) | Pending-approval cleanup in `test_tool_approval.py` |
| [BUG-workspace-concurrency-fixes-v1.1.0.md](BUG-workspace-concurrency-fixes-v1.1.0.md) | Fixed in v1.1.0 (migration V21 + atomic workspace ops) |
| [WEECHAT-NO-SECRET-ACCESS.md](WEECHAT-NO-SECRET-ACCESS.md) | Channel messages resolve under the owner credential scope (`resolve_message_scope`, `wrapper.rs:768`) |
| [XMPP-OMEMO-BUG-TO-DO.md](XMPP-OMEMO-BUG-TO-DO.md) | OMEMO MUC fallback-spam / stuck-loop appear resolved; reopen if they recur |
| *(no doc)* `test_context_length_recovery_via_compaction_and_retry` | Fixed 2026-06-07 — stub returned empty success → tripped empty-response retry; `StubLlm::set_response` now returns real recovery content. Lib suite green (3921/0). |

## Removed (2026-06-08 cleanup)

Superseded agent-transcript dumps whose technical content is preserved above and in the canonical docs:

- `PROPOSED-FIX-BY-NOKO-FOR-BUG-subagent-worker-hang.md` — duplicated `BUG-subagent-worker-hang.md`.
- `LIST-OF-BUGS-BY-NOKO.md` — subagent entry duplicated above; `memory_write` entry preserved as a Fixed row.
- `BUGS-SUNBURST.md` — superseded by `BUG-workspace-concurrency-fixes-v1.1.0.md`.
- `PROPOSED-FIX-BY-BAUD-FOR-BUG-worker-compose-test.md` — both fixes already applied in-tree (compose context paths + `tests/mock_orchestrator/hub.py`).
