# Bug Tracker Index

Reconciled against the code on **2026-06-07** (v1.1.1). **2026-06-08:** pruned superseded
agent-transcript dumps (their content lives in the canonical docs below + this index), added
`BUG-LAPSE.md`, and trimmed `WEECHAT-NO-SECRET-ACCESS.md`. **2026-06-19 (docs reorg):** indexed
four previously-untracked docs — `BUG-WEECHAT-WARNINGS.md` (Open),
`BUG-FIXED-wasm-tools-not-found-on-build.md` (Fixed), and the two 1.1.4 MT issue logs (new
section below). **2026-07-06 (item #15):** split the index — active bugs stay here, resolved
bugs are archived under [`history/`](history/README.md).

**Open** = still reproducible in the current tree. **Fixed** = resolved; the doc is retained
for history with a status banner at the top. Fixed bugs live under [`history/`](history/).

## Open

| Doc | Summary | Severity |
|-----|---------|----------|
| [BUG-unbounded-mpsc-recv-in-spawned-tasks.md](BUG-unbounded-mpsc-recv-in-spawned-tasks.md) | Two `agent_loop.rs` notification forwarders `recv().await` with no timeout (the 3rd relay site was removed in v1.1.1) | Medium |
| [BUG-e2e-clipboard-copy-test.md](BUG-e2e-clipboard-copy-test.md) | Headless Chromium clipboard permissions — skipped in CI | Low (env, non-blocker) |
| [BUG-e2e-oauth-url-parameter-tests.md](BUG-e2e-oauth-url-parameter-tests.md) | Fixture needs network/proxy to fetch WASM — skipped in CI | Low (env, non-blocker) |
| [MISSING-CONFIG-FOR-NANOCODE.md](MISSING-CONFIG-FOR-NANOCODE.md) | `mt-admin` doesn't auto-generate the nanocode `external_workers` config + token | Low |
| [BUG-e2e-bootstrap-greeting-tests.md](BUG-e2e-bootstrap-greeting-tests.md) | `bootstrap_greeting_fires` + `bootstrap_onboarding_clears_bootstrap`: static greeting not observed by the test rig (`e2e_advanced_traces.rs:834/874`). Pre-existing; unmasked by the compile fix. Not `StubLlm`/LLM-related. | Med (test-only) |

## Fixed (retained for history)

The following resolved bug docs remain in the active `bugs/` directory (not archived) because
they document design decisions or test infrastructure that is still referenced:

| Doc | Resolution |
|-----|------------|
| [BUG-subagent-worker-hang.md](BUG-subagent-worker-hang.md) | Job watcher updates `ContextManager` (`job_manager.rs:529`); supervised WASM polling |
| [BUG-daemon-stops-polling-xmpp-bridge.md](BUG-daemon-stops-polling-xmpp-bridge.md) | Supervised polling loop respawns inner loop + `health_check()` (`wrapper.rs:2285`) |
| [BUG-engine-crate-test-failures.md](BUG-engine-crate-test-failures.md) | `cargo test -p lunarwing_engine` green (271 passed, 0 failed) |
| [BUG-rust-integration-test-harness-failures.md](BUG-rust-integration-test-harness-failures.md) | `Arc::new(agent).run()` applied (incl. the telegram e2e site that blocked compilation) |
| [BUG-e2e-tool-execution-timeout.md](BUG-e2e-tool-execution-timeout.md) | Pending-approval cleanup in `test_tool_approval.py` |
| [BUG-agent-loop-blocks-on-worker-jobs.md](BUG-agent-loop-blocks-on-worker-jobs.md) | Resolved |
| [BUG-kawarimi-import-no-opencode.md](BUG-kawarimi-import-no-opencode.md) | Resolved |
| [BUG-opencode-worker-tilde-expansion.md](BUG-opencode-worker-tilde-expansion.md) | Resolved |
| [BUG-ssh-git-bare-repo-head-mismatch.md](BUG-ssh-git-bare-repo-head-mismatch.md) | Resolved |
| [BUG-ssh-git-null-ref-serialization.md](BUG-ssh-git-null-ref-serialization.md) | Resolved |

Older fixed bugs (workspace concurrency, WeeChat warnings, wasm-tools-not-found, OMEMO, WeeChat
secret access, and the two 1.1.4 MT pre-release issue logs) are archived under
[`history/`](history/README.md).

## Removed (2026-06-08 cleanup)

Superseded agent-transcript dumps whose technical content is preserved above and in the canonical docs:

- `PROPOSED-FIX-BY-NOKO-FOR-BUG-subagent-worker-hang.md` — duplicated `BUG-subagent-worker-hang.md`.
- `LIST-OF-BUGS-BY-NOKO.md` — subagent entry duplicated above; `memory_write` entry preserved as a Fixed row.
- `BUGS-SUNBURST.md` — superseded by `BUG-workspace-concurrency-fixes-v1.1.0.md`.
- `PROPOSED-FIX-BY-BAUD-FOR-BUG-worker-compose-test.md` — both fixes already applied in-tree (compose context paths + `tests/mock_orchestrator/hub.py`).
