# Testing Guide for b4 release checklist start
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
