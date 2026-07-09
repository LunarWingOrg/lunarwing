# Bug Tracker Index

Reconciled against the code on **2026-07-09** (v1.1.9 cycle). Previous reconciliation: 2026-06-07
(v1.1.1). **2026-07-06 (item #15):** split the index — active bugs stay here, resolved bugs are
archived under [`history/`](history/README.md). **2026-07-09 (item #9):** reconciled all bug
statuses against the current tree; moved stale Fixed→Open and Open→Fixed entries; deleted junk
stub files (`BUG-external-worker-loadbalancer-failover-problem.md`, `BUG-mtadminprovisioner.md`,
`wf.toml`, `history/BUG-external-worker-test.md`); updated stale code references and paths.

**Open** = still reproducible in the current tree. **Fixed** = resolved; the doc is retained
for history with a status banner at the top. Fixed bugs live under [`history/`](history/).

## Open

| Doc | Summary | Severity |
|-----|---------|----------|
| [BUG-unbounded-mpsc-recv-in-spawned-tasks.md](BUG-unbounded-mpsc-recv-in-spawned-tasks.md) | Two `agent_loop.rs` notification forwarders `recv().await` with no timeout (lines 624, 752). The relay subsystem (3rd site) was removed in v1.1.1. | Medium |
| [BUG-agent-loop-blocks-on-worker-jobs.md](BUG-agent-loop-blocks-on-worker-jobs.md) | Agent loop blocks on synchronous (`wait=true`) external worker jobs — no async job registry for interleaving. Feature request / architectural improvement. | Medium |
| [BUG-opencode-worker-tilde-expansion.md](BUG-opencode-worker-tilde-expansion.md) | opencode worker does not expand `~` in workspace paths; creates literal `~` dir | Low |
| [BUG-ssh-git-bare-repo-head-mismatch.md](BUG-ssh-git-bare-repo-head-mismatch.md) | `ssh_git` clone fails when bare repo HEAD points to non-existent branch (master/main mismatch) | Low |
| [BUG-ssh-git-null-ref-serialization.md](BUG-ssh-git-null-ref-serialization.md) | `ssh_git` tool may serialize null `ref` as literal string `"null"` in the LLM serialization layer | Low |
| [BUG-e2e-clipboard-copy-test.md](BUG-e2e-clipboard-copy-test.md) | Headless Chromium clipboard permissions — skipped in CI | Low (env, non-blocker) |
| [BUG-e2e-oauth-url-parameter-tests.md](BUG-e2e-oauth-url-parameter-tests.md) | Fixture needs network/proxy to fetch WASM — skipped in CI | Low (env, non-blocker) |
| [BUG-e2e-bootstrap-greeting-tests.md](BUG-e2e-bootstrap-greeting-tests.md) | `bootstrap_greeting_fires` + `bootstrap_onboarding_clears_bootstrap`: static greeting not observed by the test rig. Pre-existing; unmasked by the compile fix. Not `StubLlm`/LLM-related. | Med (test-only) |

## Fixed (retained for history)

The following resolved bug docs remain in the active `bugs/` directory (not archived) because
they document design decisions or test infrastructure that is still referenced:

| Doc | Resolution |
|-----|------------|
| [MISSING-CONFIG-FOR-NANOCODE.md](MISSING-CONFIG-FOR-NANOCODE.md) | `mt-admin` now auto-generates nanocode + pebble + opencode `external_workers` config blocks |
| [BUG-kawarimi-import-no-opencode.md](BUG-kawarimi-import-no-opencode.md) | `import-tenant.sh` now accepts `--with-opencode` (line 60, wired into `build_args` at line 251) |
| [BUG-subagent-worker-hang.md](BUG-subagent-worker-hang.md) | Job watcher updates `ContextManager` (`job_manager.rs:529`); supervised WASM polling |
| [BUG-daemon-stops-polling-xmpp-bridge.md](BUG-daemon-stops-polling-xmpp-bridge.md) | Supervised polling loop respawns inner loop + `health_check()` (`wrapper.rs:2285`) |
| [BUG-engine-crate-test-failures.md](BUG-engine-crate-test-failures.md) | `cargo test -p lunarwing_engine` green (271 passed, 0 failed) |
| [BUG-rust-integration-test-harness-failures.md](BUG-rust-integration-test-harness-failures.md) | `Arc::new(agent).run()` applied (incl. the telegram e2e site that blocked compilation) |
| [BUG-e2e-tool-execution-timeout.md](BUG-e2e-tool-execution-timeout.md) | Pending-approval cleanup in `test_tool_approval.py` |

Older fixed bugs (workspace concurrency, WeeChat warnings, wasm-tools-not-found, OMEMO, WeeChat
secret access, and the two 1.1.4 MT pre-release issue logs) are archived under
[`history/`](history/README.md).

## Removed

- `BUG-external-worker-loadbalancer-failover-problem.md` — junk stub (contained only `#4`); deleted 2026-07-09.
- `BUG-mtadminprovisioner.md` — junk stub (5-line code-change note, not a bug report); deleted 2026-07-09.
- `wf.toml` — stray config file (single `actionlint;` line); deleted 2026-07-09.
- `history/BUG-external-worker-test.md` — junk stub (contained only `test`); deleted 2026-07-09.

Superseded agent-transcript dumps whose technical content is preserved in the canonical docs above:

- `PROPOSED-FIX-BY-NOKO-FOR-BUG-subagent-worker-hang.md` — duplicated `BUG-subagent-worker-hang.md`.
- `LIST-OF-BUGS-BY-NOKO.md` — subagent entry duplicated above; `memory_write` entry preserved as a Fixed row.
- `BUGS-SUNBURST.md` — superseded by `BUG-workspace-concurrency-fixes-v1.1.0.md`.
- `PROPOSED-FIX-BY-BAUD-FOR-BUG-worker-compose-test.md` — both fixes already applied in-tree.
