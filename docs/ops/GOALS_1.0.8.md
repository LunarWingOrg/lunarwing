# PRE-RELEASE CHECKLIST

___
**Open TODOs (1.0.8~) — Feature Release**
1. [ ] first iteration of reflex compiler added to staging
2. [ ] Run automated testing scripts. number 11 is related to this.
3. [ ] need a full extensive test using my testing_guide and other testing scripts. can also try docs/guides/TESTING_GUIDE.md and ic/scripts/release-test.sh
4. [ ] additional testing scripts to help test multiple things very quickly:
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
* 
* 
5. [ ] Complete tests of everything that was changed since 1.0.7 (might help if we generate release notes first)
6. [ ] Write up release notes for v1.0.8 explaining all changes since v1.0.7
7. [ ] Create a new branch to correspond with release
8. [ ] Create GH release tag and add release notes to it like other releases already have
