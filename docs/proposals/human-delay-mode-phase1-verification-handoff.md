# Human Delay Mode — Phase 1 Verification Handoff

**Purpose**: Capture the state of Phase 1 ("supervised mode") verification so it can be
resumed later. Created mid-verification on branch `human-delay-mode-phase-1-baud`.

**TL;DR**: Phase 1 is functionally verified. Steps 1–4 of the test plan are **done and
green**. Two follow-ups remain: a manual smoke test (Step 5, optional) and documentation
corrections (Step 6). Details below.

---

## What was verified (DONE)

| Step | What | Result |
|------|------|--------|
| 0 | Rust toolchain available | ✅ Rust 1.94 in user env (project MSRV is 1.92) |
| 1 | `cargo check` compiles | ✅ Compiles. Only 2 pre-existing warnings in `src/orchestrator/external_worker.rs` (unrelated dead fields) |
| 2 | `cargo test --lib` passes | ✅ Green after fixes (see below) |
| 3 | `cargo clippy` — no NEW warnings | ✅ Baseline diff vs `origin/staging` was EMPTY → Phase 1 added zero new clippy warnings |
| 4 | Supervised-mode behavior tests | ✅ 3 new tests added and passing |

### Fixes applied during verification (uncommitted working-tree changes)

These were genuine Phase 1 oversights surfaced by actually running the tests:

1. **`ic/src/gate/approval.rs`** — test helper `ctx()` was missing the new
   `supervised_mode` / `supervised_timeout_secs` fields on `GateContext`. Added (defaults
   `false` / `300`). *(This was a compile error blocking `cargo test`.)*
2. **`ic/crates/lunarwing_engine/src/gate/pipeline.rs`** — same missing-field fix on the
   `test_ctx()` helper.
3. **`ic/src/cli/snapshots/lunarwing__cli__tests__help_output_without_import.snap`** and
   **`...long_help_output_without_import.snap`** — accepted updated `insta` snapshots so
   the CLI help text includes the new `--supervised` flag. (The snapshots also picked up a
   pre-existing-stale `reflex` command line inherited from `staging`.)
4. **`ic/src/bridge/effect_adapter.rs`** — added 3 supervised-mode unit tests (Step 4):
   - `supervised_mode_overrides_auto_approve` — auto-approved tool still pauses under supervision
   - `supervised_mode_gates_never_approval_tool` — a `Never`-tier tool pauses under supervision
   - `supervised_mode_disabled_preserves_auto_approve` — no regression when supervision off

> **NOTE**: As of writing, these changes are **uncommitted**. Commit them to
> `human-delay-mode-phase-1-baud` when resuming.

### Known unrelated test failures (NOT Phase 1 — pre-existing on `staging`)

`cargo test --lib` shows 3 failures that are inherited from `staging` and touch none of the
branch's files (verified via `git diff --name-only $(git merge-base HEAD origin/staging)..HEAD`):

- `agent::reflex::tests::test_reflex_router_fuzzy_match_extra_words`
- `agent::reflex::tests::test_reflex_router_fuzzy_promotion_is_input_specific`
- `channels::xmpp::omemo::store::tests::migration_preserves_legacy_device_id`

These should be filed/handled separately by their owners; they are not Phase 1 blockers.

### Environment notes for whoever resumes

- Rust must be ≥ 1.92 (edition 2024). User env has 1.94. There is **no `rust-toolchain.toml`** pin.
- `cargo clippy --all ... --all-features` floods with lints from the **vendored**
  `ic/vendor/libsignal-protocol-sys` crate. To check only our code, scope it:
  ```bash
  cargo clippy -p lunarwing -p lunarwing_engine -p lunarwing_common \
               -p lunarwing_safety -p lunarwing_skills --all-features
  ```
- `cargo test` accepts only **one** positional filter. Use a shared prefix, e.g.
  `cargo test --lib supervised_mode`.

---

## REMAINING WORK

### Step 3 leftover — `cargo fmt --check`

Not yet run. Expected clean (new code follows existing style). From `ic/`:

```bash
cargo fmt --check
```

If it reports a diff, run `cargo fmt` to fix.

### Step 5 — Manual smoke test (OPTIONAL / deferred)

**Status**: Not done. Lower priority now that Step 4 verifies the gating behavior in
automated tests.

**Important caveat — the existing testing guide is inaccurate.** `docs/proposals/
human-delay-mode-testing-guide.md` and the phase1 checklist describe CLI commands that
**do not exist**:

- ❌ `lunarwing gate list` / `lunarwing gate approve <id>` / `lunarwing gate reject <id>`
- ❌ `lunarwing thread create`

There is **no `gate` or `thread` subcommand** in `ic/src/cli/mod.rs`. Supervised approval
surfaces as an interactive `GatePaused` in the running agent / REPL, not via standalone CLI
commands. Any manual test must use the real interactive/REPL approval path.

**What a real manual smoke test should cover** (using actual surfaces):

1. Build: `cargo build --release --bin lunarwing`
2. Start supervised: `AGENT_SUPERVISED_MODE=true ./target/release/lunarwing`
   (or the global `--supervised` flag)
3. Drive a tool request through the interactive/REPL path and confirm it **pauses for
   approval even for an auto-approve-listed tool** (the override behavior).
4. Document the **actual** approval UX observed (resume/approve mechanism), and update the
   testing guide to match reality.

Prerequisite: a configured agent (LLM provider + a channel/REPL), so this is heavier than
the unit tests. Defer until that environment is set up.

### Step 6 — Correct documentation inaccuracies

**Status**: Not done. Recommended before starting Phase 2 so it builds on accurate ground.

The three existing human-delay docs contain claims proven wrong during verification. Fix:

1. **Wrong crate paths.** Docs reference `lunarwing_types/src/thread.rs` and a
   `lunarwing_router` crate. Reality:
   - `ThreadConfig` lives in **`ic/crates/lunarwing_engine/src/types/thread.rs`**
   - Router/env-var integration is in **`ic/src/bridge/router.rs`** (not a `lunarwing_router` crate)
   - The inline supervised check is in **`ic/src/bridge/effect_adapter.rs`** (~line 521)
   - The gate-pipeline early-exit is in **`ic/src/gate/approval.rs`** (~line 54)

2. **Nonexistent CLI commands.** Remove/replace `lunarwing gate list/approve/reject` and
   `lunarwing thread create` references (see Step 5 caveat).

3. **`ApprovalGate::evaluate()` is NOT wired into production.** The phase1 checklist implies
   the structured gate pipeline is active. In fact `ApprovalGate` has **zero call sites
   outside `gate/approval.rs`** — only the inline `effect_adapter.rs` path runs. This is
   already a Phase 2 task ("Gate Pipeline Full Integration"), but the Phase 1 doc should
   stop implying it's active.

4. **"All existing tests pass" was false at handoff.** The phase1 checklist claimed existing
   tests passed; in reality there were 2 missing-field compile errors + 2 stale CLI
   snapshots (now fixed — see "Fixes applied" above). Update the checklist's status to
   reflect the actual verification outcome.

### Bonus finding for Phase 2 (supervision propagation gap)

`ic/crates/lunarwing_engine/src/executor/scripting.rs` (~line 1116) builds a child research
thread's `ThreadConfig` via `..ThreadConfig::default()`, so a child thread inherits
`supervised_mode = false` **regardless of the parent's setting**. If a parent is supervised,
its spawned child threads currently are NOT. Decide in Phase 2 whether supervision should
propagate to child threads.

---

## Resume checklist

- [ ] Commit the uncommitted Phase 1 verification fixes (4 files listed above)
- [ ] Run `cargo fmt --check` (Step 3 leftover)
- [ ] (Optional) Perform manual smoke test once a configured agent env exists (Step 5)
- [ ] Correct the three human-delay docs (Step 6, items 1–4)
- [ ] Update `human-delay-mode-phase1-test-checklist.md` "Success Criteria" with real results
- [ ] Then proceed to `human-delay-mode-phase2-plan.md`
