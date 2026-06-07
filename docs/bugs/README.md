# Bug Tracker Index

Reconciled against the code on **2026-06-07** for the v1.1.1 release. **Open** = still
reproducible in the current tree. **Fixed** = resolved; the doc is retained for history with a
status banner at the top.

## Open

| Doc | Summary | Severity |
|-----|---------|----------|
| [BUG-unbounded-mpsc-recv-in-spawned-tasks.md](BUG-unbounded-mpsc-recv-in-spawned-tasks.md) | Two `agent_loop.rs` notification forwarders `recv().await` with no timeout (the 3rd relay site was removed in v1.1.1) | Medium |
| [BUG-e2e-clipboard-copy-test.md](BUG-e2e-clipboard-copy-test.md) | Headless Chromium clipboard permissions — skipped in CI | Low (env, non-blocker) |
| [BUG-e2e-oauth-url-parameter-tests.md](BUG-e2e-oauth-url-parameter-tests.md) | Fixture needs network/proxy to fetch WASM — skipped in CI | Low (env, non-blocker) |
| [MISSING-CONFIG-FOR-NANOCODE.md](MISSING-CONFIG-FOR-NANOCODE.md) | `mt-admin` doesn't auto-generate the nanocode `external_workers` config + token | Low |
| *(no doc)* `test_context_length_recovery_via_compaction_and_retry` | Unit test still fails (`dispatcher.rs:1892`, LLM call-count 3 vs 2); pre-existing, no runtime impact. Tracked in `RELEASE-v1.1.1.md` Known Issues | Low (test-only) |

## Fixed (retained for history)

| Doc | Resolution |
|-----|------------|
| [BUG-subagent-worker-hang.md](BUG-subagent-worker-hang.md) / [PROPOSED-FIX-BY-NOKO-…](PROPOSED-FIX-BY-NOKO-FOR-BUG-subagent-worker-hang.md) | Job watcher updates `ContextManager` (`job_manager.rs:529`); supervised WASM polling |
| [BUG-daemon-stops-polling-xmpp-bridge.md](BUG-daemon-stops-polling-xmpp-bridge.md) | Supervised polling loop respawns inner loop + `health_check()` (`wrapper.rs:2285`) |
| [BUG-engine-crate-test-failures.md](BUG-engine-crate-test-failures.md) | `cargo test -p lunarwing_engine` green (271 passed, 0 failed) |
| [BUG-rust-integration-test-harness-failures.md](BUG-rust-integration-test-harness-failures.md) | `Arc::new(agent).run()` applied (incl. the telegram e2e site that blocked compilation) |
| [BUG-e2e-tool-execution-timeout.md](BUG-e2e-tool-execution-timeout.md) | Pending-approval cleanup in `test_tool_approval.py` |
| [BUG-workspace-concurrency-fixes-v1.1.0.md](BUG-workspace-concurrency-fixes-v1.1.0.md) / [BUGS-SUNBURST.md](BUGS-SUNBURST.md) | Fixed in v1.1.0 (migration V21 + atomic workspace ops) |
| [WEECHAT-NO-SECRET-ACCESS.md](WEECHAT-NO-SECRET-ACCESS.md) | Channel messages resolve under the owner credential scope (`resolve_message_scope`, `wrapper.rs:768`) |
| [XMPP-OMEMO-BUG-TO-DO.md](XMPP-OMEMO-BUG-TO-DO.md) | OMEMO MUC fallback-spam / stuck-loop appear resolved; reopen if they recur |

## Proposals / notes (not bug reports)

- [PROPOSED-FIX-BY-BAUD-FOR-BUG-worker-compose-test.md](PROPOSED-FIX-BY-BAUD-FOR-BUG-worker-compose-test.md) — worker test-harness path fixes.
- [LIST-OF-BUGS-BY-NOKO.md](LIST-OF-BUGS-BY-NOKO.md) — both entries now fixed (see banner in that file).
