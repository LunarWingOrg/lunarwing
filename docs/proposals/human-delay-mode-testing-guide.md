# Human Delay Mode - Testing Guide

> **Last updated: 2026-07-09.** Supervised mode (`--supervised`) shipped in v1.1.9.
> Phase 2 features (timeout expiration, gate pipeline full integration, modify UI) remain planned.

## Quick Start

### Prerequisites

You need a Rust environment with Cargo. Minimum recommended (as of v1.1.9):

```bash
rustc >= 1.92  # MSRV for LunarWing
cargo >= 1.92
```

Check your version:
```bash
rustc --version
cargo --version
```

If you need to install Rust: https://rustup.rs

---

## Running Tests

### 1. Navigate to the LunarWing repo

```bash
cd /path/to/lunarwing/ic
```

### 2. Compilation Check (fastest, no test execution)

```bash
cargo check
```

This validates all code compiles without building binaries or running tests. Good for quick feedback.

**Expected**: No errors. Warnings are OK.

### 3. Run All Tests

```bash
cargo test --lib
```

The `--lib` flag runs library tests only (no integration/e2e tests). Faster than full test suite.

**Expected**: All tests pass. You may see some ignored tests (known incomplete features).

### 4. Run Tests with Output

To see `println!` / `eprintln!` output during tests:

```bash
cargo test --lib -- --nocapture
```

### 5. Run Specific Test Module

```bash
cargo test supervised_mode
```

Runs only tests matching "supervised_mode" (if any exist after Phase 2).

### 6. Run Tests for Specific Crate

```bash
# Engine crate only
cargo test -p lunarwing_engine

# Types crate only  
cargo test -p lunarwing_types

# Router crate only
cargo test -p lunarwing_router
```

---

## Testing the Supervised Mode Feature

### Prerequisites: Build the Binary First

```bash
cargo build --release --bin lunarwing
```

This produces `./target/release/lunarwing`.

### Test 1: Supervised Mode via Env Var

```bash
# Start with supervised mode enabled
AGENT_SUPERVISED_MODE=true ./target/release/lunarwing

# In another terminal - create a thread
./target/release/lunarwing thread create

# Try a tool request (e.g., search)
# Expected: Tool pauses, waits for approval
```

### Test 2: Supervised Mode via CLI Flag

```bash
./target/release/lunarwing --supervised
```

### Test 3: Supervised Mode Override Auto-Approve

1. Start agent with supervised mode: `AGENT_SUPERVISED_MODE=true ./target/release/lunarwing`
2. Request a tool normally on auto-approve list (e.g., `tool_search`, `web_fetch`)
3. **Expected**: Tool pauses anyway (supervised overrides auto-approve)

### Test 4: Approval Flow

```bash
# List pending approvals
./target/release/lunarwing gate list

# Approve
./target/release/lunarwing gate approve <gate_id>

# Reject
./target/release/lunarwing gate reject <gate_id>
```

### Test 5: Verify Timeout Config Flows

1. Start supervised thread with custom timeout:
   ```bash
   AGENT_SUPERVISED_MODE=true SUPERVISED_TIMEOUT_SECS=60 ./target/release/lunarwing
   ```
2. Create thread, check context has correct timeout value
3. Note: Timeout auto-expiration not wired yet (Phase 2)

---

## Common Issues

### Issue: `error: cannot find crate`

Make sure you're in the `ic/` subdirectory, not the repo root.

```bash
cd /path/to/lunarwing/ic
cargo check
```

### Issue: `error: linker 'cc' not found`

You need a C compiler. On Debian/Ubuntu:

```bash
sudo apt install build-essential
```

On macOS:

```bash
xcode-select --install
```

### Issue: Compilation errors on `ThreadExecutionContext` or `GateContext`

This means the Phase 1 struct updates aren't applied. Check that you're on the correct branch:

```bash
git checkout human-delay-mode-phase-1-baud
git pull origin human-delay-mode-phase-1-baud
cargo check
```

### Issue: Tests fail with "missing field" errors

The test files need the new struct fields. If pulling fresh changes, run:

```bash
cargo test --lib 2>&1 | grep "missing field"
```

If you see missing field errors, the test constructors need updating. Check the Phase 1 docs for the list of files that were updated.

### Issue: Slow compilation on first run

Normal. Rust compiles all dependencies on first build. Subsequent runs use cached compilation and are much faster.

---

## Testing Workflow

### Recommended workflow for code changes:

```bash
# 1. Make your changes

# 2. Compile check (fast)
cargo check

# 3. Run tests
cargo test --lib

# 4. If tests pass, run full check
cargo build --release --bin lunarwing

# 5. Manual test if applicable
AGENT_SUPERVISED_MODE=true ./target/release/lunarwing
```

### Pre-commit checklist:

- [ ] `cargo check` passes
- [ ] `cargo test --lib` passes  
- [ ] Code changes match the design in Phase 1/2 docs
- [ ] New tests added for new behavior

---

## Where to Find Help

- LunarWing docs: `docs/`
- Phase 1 implementation: `docs/proposals/human-delay-mode-phase1-test-checklist.md`
- Phase 2 plan: `docs/proposals/human-delay-mode-phase2-plan.md`
- OpenClaw Discord channel (if set up): ask the agent team

---

## Current Status (as of Phase 1)

| Test | Status | Notes |
|------|--------|-------|
| Compilation | ✅ Should pass | If branch has Phase 1 applied |
| Unit tests | ✅ Should pass | Test constructors updated |
| Supervised mode flag | ✅ Implemented | `AGENT_SUPERVISED_MODE` env var |
| CLI `--supervised` | ✅ Implemented | Global flag |
| Gate pause | ✅ Implemented | Inline check in `effect_adapter.rs` |
| Auto-approve override | ✅ Implemented | Supervised wins |
| Timeout expiration | ⏳ Phase 2 | Not wired yet |
| Gate pipeline integration | ⏳ Phase 2 | Only inline path active |
| Modify UI | ⏳ Phase 2 | Not implemented yet |