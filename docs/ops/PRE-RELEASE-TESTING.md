# Pre-Release Testing

## Current `cargo test` status (reconciled 2026-06-07)

- The default `cargo test` suite **compiles and runs** again — a stale `Agent::run()` call in
  `tests/e2e_telegram_message_routing.rs` (missing the `self: Arc<Self>` wrap) had been breaking the
  whole test build; now fixed.
- **Lib unit suite: green — 3921 passed / 0 failed / 3 ignored.** The previously-failing
  `test_context_length_recovery_via_compaction_and_retry` is fixed (stub returned an empty success,
  tripping the empty-response retry → an extra LLM call).
- **Known remaining failures** (all test-only; tracked in `docs/bugs/README.md`):
  - `e2e_advanced_traces::bootstrap_greeting_fires` and `…::bootstrap_onboarding_clears_bootstrap` —
    the static bootstrap greeting isn't arriving in the test rig. Pre-existing; only surfaced once
    the compile blocker was fixed (the binary never built before). Needs investigation.
  - `e2e_*` clipboard / OAuth-URL Playwright tests — environment-specific (headless clipboard perms /
    network), skipped in CI; not blockers.
- The `--features integration` tier still needs a running PostgreSQL and has not been run here.

---

[ ] need a full extensive test using my testing_guide and other testing scripts. can also try docs/guides/TESTING_GUIDE.md and ic/scripts/release-test.sh
[ ] additional testing scripts to help test multiple things very quickly:
* Here's the rest of the test landscape:
Script	What It Tests
ic/scripts/release-test.sh ✅	Gateway API, WebSocket, core subsystems
ic/scripts/lunarwing-xmpp-test-env.sh	Full stack: Postgres, TensorZero proxy, XMPP bridge, daemon, WASM tools
tests/runner.py	All 4 worker types (Codex, Nanocode, Built-in, Sandbox) in Docker isolation
ic/tests/e2e/	Playwright browser tests against live instance
cargo test	Rust unit + integration tests
ic/scripts/check-boundaries.sh	Architecture boundary violations (no direct DB driver usage outside src/db/, etc.)
ic/scripts/coverage.sh	Generates HTML coverage report via cargo-llvm-cov
If you want "60%+ of everything" in one shot:
# 1. Full integration harness (XMPP + daemon + WASM)
ic/scripts/lunarwing-xmpp-test-env.sh up

# 2. Worker matrix (all 4 workers)
cd tests && python runner.py --mode smoke

# 3. Rust core
cd ic && cargo test --all-features

# 4. Gateway smoke (you already have this)
ic/scripts/release-test.sh
The lunarwing-xmpp-test-env.sh is the big one — it spins up the whole stack. That + release-test.sh + cargo test gives you the widest net before a release.
