# Bug Tracker Index

This index covers all bug documents in `docs/bugs/`. Fixed bugs are retained for history with a
status banner at the top of each doc. Historical bug records and the 1.1.4 multi-tenant
pre-release issue logs live in [`history/`](history/README.md).

## Open

| Doc | Summary | Severity |
|-----|---------|----------|
| [`BUG-unbounded-mpsc-recv-in-spawned-tasks.md`](BUG-unbounded-mpsc-recv-in-spawned-tasks.md) | Two `agent_loop.rs` notification forwarders `recv().await` with no timeout | Medium |
| [`BUG-e2e-clipboard-copy-test.md`](BUG-e2e-clipboard-copy-test.md) | Headless Chromium clipboard permissions — skipped in CI | Low (env, non-blocker) |
| [`BUG-e2e-oauth-url-parameter-tests.md`](BUG-e2e-oauth-url-parameter-tests.md) | Fixture needs network/proxy to fetch WASM — skipped in CI | Low (env, non-blocker) |
| [`BUG-e2e-bootstrap-greeting-tests.md`](BUG-e2e-bootstrap-greeting-tests.md) | `bootstrap_greeting` not observed by the test rig (`e2e_advanced_traces.rs`) | Med (test-only) |
| [`BUG-ssh-git-bare-repo-head-mismatch.md`](BUG-ssh-git-bare-repo-head-mismatch.md) | `ssh_git` clone fails when bare repo HEAD points to non-existent branch (master/main mismatch) | Medium |
| [`BUG-ssh-git-null-ref-serialization.md`](BUG-ssh-git-null-ref-serialization.md) | `ssh_git` tool serializes null ref as literal string `"null"` | Medium |
| [`BUG-kawarimi-import-no-opencode.md`](BUG-kawarimi-import-no-opencode.md) | Kawarimi import script does not support `--with-opencode` | Low |
| [`BUG-opencode-worker-tilde-expansion.md`](BUG-opencode-worker-tilde-expansion.md) | Opencode worker does not expand `~` in workspace paths | Low |
| [`BUG-agent-loop-blocks-on-worker-jobs.md`](BUG-agent-loop-blocks-on-worker-jobs.md) | Agent loop blocks on synchronous (`wait=true`) external worker jobs | Medium (architectural) |
| [`BUG-external-worker-loadbalancer-failover-problem.md`](BUG-external-worker-loadbalancer-failover-problem.md) | External worker load-balancer failover problem | Medium |

## Fixed (retained for history)

| Doc | Resolution |
|-----|------------|
| [`BUG-subagent-worker-hang.md`](BUG-subagent-worker-hang.md) | Job watcher updates `ContextManager` (`job_manager.rs`); supervised WASM polling |
| [`BUG-daemon-stops-polling-xmpp-bridge.md`](BUG-daemon-stops-polling-xmpp-bridge.md) | Supervised polling loop respawns inner loop + `health_check()` (`wrapper.rs`) |
| [`BUG-engine-crate-test-failures.md`](BUG-engine-crate-test-failures.md) | `cargo test -p lunarwing_engine` green (271 passed, 0 failed) |
| [`BUG-rust-integration-test-harness-failures.md`](BUG-rust-integration-test-harness-failures.md) | `Arc::new(agent).run()` applied to all call sites; full test suite compiles |
| [`BUG-e2e-tool-execution-timeout.md`](BUG-e2e-tool-execution-timeout.md) | Pending-approval cleanup in `test_tool_approval.py` |
| [`MISSING-CONFIG-FOR-NANOCODE.md`](MISSING-CONFIG-FOR-NANOCODE.md) | Resolved 2026-06-14 — mt-admin generates nanocode external-worker config |

## Historical

Older bug records, resolved fixed items, and the 1.1.4 multi-tenant pre-release issue logs
(`SYSTEMD-MT-1.1.4-ISSUES.md`, `OPENRC-MT-1.1.4-ISSUES.md`) are in [`history/`](history/README.md).
