# Baud's Assessment — LunarWing Chaos Engineering Test Suite

> **Branch:** `2026-06-13-chaos-cmc-baud`
> **Date:** 2026-06-13
> **Scope:** `ic-infrastructure-health-check/tests/` — lib.sh, test-self-heal-matrix.sh, chaos-harness.sh, run-all.sh
> **Ref:** docs/proposals/CHAOS_ENGINEERING_TEST_PLAN.md

---

> **Maintainer addendum — 2026-06-16 (status update; Baud's review below is unchanged).**
> The recommendations in this review have since been implemented:
> - **P1 — `src_fn` fragility:** a `# HARNESS_ENTRY_POINT` sentinel now marks the
>   extraction boundary in `lunarwing-self-heal.sh`; `lib.sh:_ensure_body` checks
>   for it and aborts with a clear message if it ever moves.
> - **P1 — mock `sudo` drift:** the mock now documents the exact expected
>   invocations and warns loudly on any unrecognized flag instead of passing it
>   through.
> - **P2 — `restart_history` cap:** exposed as `SELF_HEAL_HISTORY_MAX` (default 20).
> - **P3 — CI introspection:** `run-all.sh --list` prints the suite names.
>
> The suite has also grown since this review: the unit matrix now spans
> **sections A–O (~120 assertions)**, and a fourth suite —
> `test-health-openrc.sh` (`openrc`, scenarios S1–S6, covering `health-openrc.sh`
> discovery/exit-code/timeout behavior) — is registered in `run-all.sh`'s order
> (`regression → matrix → chaos → openrc`). The numbers in Baud's text below
> reflect the suite as of 2026-06-13.

---

## TL;DR

The suite is well-architected, thorough (~107 dry-run assertions + 11 e2e chaos scenarios), and safe to run anywhere (dry-run + mock init system + `GOTIFY_TOKEN=''`). Four layers are cleanly separated: shared harness, unit matrix, chaos harness, and aggregate runner. The commit message and plan doc are honest about intentional divergences from the original matrix.

Three things I'd watch for: `src_fn`'s body-extraction fragility, the mock `sudo` parser's hand-rolled argv walker, and the `restart_history` cap of 20 being undiscoverable without reading the source.

---

## Architecture

### Four-Layer Stack

```
lib.sh                          ← shared: assertions, sandbox, drivers, mocks
├── test-self-heal-matrix.sh    ← Phase 1: dry-run unit matrix, A–N (~107 assertions)
├── chaos-harness.sh            ← Phase 2/3: end-to-end, mock init, CH1–CH13
└── run-all.sh                  ← aggregate: regression → matrix → chaos, tallies results
```

### `lib.sh` (~250 lines) — Shared Harness

**Assertions:** Clean API — `ok`/`bad` for manual, `assert_contains`/`assert_absent`/`assert_eq`/`assert_ne`/`assert_range` for declarative, `finish` to print tally and yield exit status. Using `set -uo pipefail` (not `-e`) so assertion functions can capture non-zero without aborting the suite is the right call.

**Sandbox:** `sb()` creates a `mktemp -d` subdirectory under `$ROOT`, auto-cleaned via `trap EXIT`. The `LUNARWING_BASE_DIR` convention means self-heal state lives in `<sb>/self-heal/`.

**Drivers:**
- `run_dry` — always `--dry-run`, `--backoff 0` for speed. Pins `GOTIFY_TOKEN=''` so escalation can't reach the network.
- `run_raw` — no injected flags, captures exit code in global `RC`. Used for arg-parse and exit-code tests (N1–N3).
- `src_fn` — **clever but fragile.** Extracts everything before `main "$@"` into a temp file, then sources it in a subshell with positional args cleared. This lets you unit-test `compute_backoff`, `unit_tenant`, etc. in isolation. But if `lunarwing-self-heal.sh` ever moves `main` or changes its top-level structure, this breaks silently. Consider adding a sentinel comment marker to make the extraction less brittle.

**Mock Init System (`mk_mockbin`):** Fake `systemctl`, `rc-service`, `sudo`, and per-component health scripts all driven by files under `<sb>/svcstate/`. This is the right abstraction — restarts flip files, not real services. The `systemctl` mock correctly handles `--user` recursion, `is-active`, and `restart`. The `sudo` mock hand-rolls an argv walker to strip `-n`, `-u <user>`, `env`, and `VAR=VAL` before exec. This works for the current invocation patterns but is prone to drift if `lunarwing-self-heal.sh` adds new sudo flags.

### `test-self-heal-matrix.sh` (~470 lines, Sections A–N)

**Coverage:** 107+ assertions across 14 sections. Every cell of the A–N matrix from the test plan is populated, with explicit cross-references to plan IDs. Cases like A1/A3 use the CWD-pinning trick to avoid `find | xargs ls -t` resolving a stray file — this is documented in the commit message but not in the source. Worth an inline comment.

**Notable test patterns:**
- **G3 (escalation report capture):** Runs non-dry so the write path executes, uses a fake `send-notification.sh` to capture the escalation report before the script deletes it. Smart — tests the real notification plumbing without sending anything.
- **H4 (restart_history cap at 20):** Seeds 25 entries, forces verify-fail, asserts the trim. But the cap value (20) is not documented in the plan or the source — it's a magic number you only know by reading `lunarwing-self-heal.sh`.
- **I4–I7 (verify fallbacks):** Covers inconclusive → `is-active`, `--verify-health false`, missing script, non-executable script. This is where most real-world bugs live, so having four fallback paths here is solid.

**Intentional divergences from plan (documented in plan's implementation-status):**
- C5: Single-manager model (a host runs one init system, not mixed)
- C6: Cross-key precedence (logical key `lunarwing` vs init-unit key `lunarwing.service` don't suppress each other)
- J1 → CH9: Restart failure moved to chaos harness
- CH7 → CH6: DNS failure modeled by stuck-service escalation
- CH8: Disk full skipped (out of scope for mock harness)

### `chaos-harness.sh` (~150 lines, 11 scenarios)

**Phase 2/3 — real runs against mock init:** These are the scenarios the dry-run matrix can't cover:

| ID | What it tests |
|----|---------------|
| CH1–CH5 | Per-component recovery paths (gateway, xmpp-bridge, tensorzero, clickhouse) |
| CH6 | Stuck service → escalation after max retries |
| CH9 | Restart command failure → escalation (no infinite loop) |
| CH10 | Tenant unit crash → remediated as tenant user |
| CH11 | Multi-tenant blast-radius isolation |
| CH12 | Flapping guard → cap at threshold |
| CH13 | Transient blip absorbed by grace |

**Loop scenarios (CH6, CH9, CH12):** Simulates cron ticks by invoking `run_chaos` repeatedly. Backoff base is 0 so retries aren't gated across simulated ticks. This is the right way to test stateful behavior — you can't do it in a single dry-run invocation.

**CH11 (blast-radius isolation):** The highest-stakes scenario. One tenant down, one healthy — asserts only the affected tenant restarts. If this breaks in production, you restart everyone's services on every tick. Good that it's here.

**Safety:** Every `run_chaos` call uses `GOTIFY_TOKEN=''` so escalation short-circuits before any network call. The commit message explicitly warns: "intentionally not run on this live MT host."

### `run-all.sh` (~60 lines)

Simple aggregate orchestrator. Three suites in order: `regression` → `matrix` → `chaos`. Each suite runs in its own bash process, output captured, per-suite tallies extracted from the `N passed, M failed` line. ANSI color summary at the end. Exit code propagates correctly.

---

## Strengths

1. **Safety-first by design.** Dry-run for the matrix, mock init for chaos, no-token for escalation. Can run on any host without risk.
2. **Clean separation.** `lib.sh` is the only shared dependency; the two test files don't leak into each other.
3. **Deterministic fixtures.** Synthetic reports, seeded state, fake health scripts. Every test starts from a known baseline.
4. **Honest documentation.** The commit message and plan doc explicitly call out divergences, skipped items, and known footguns (CWD xargs, find_latest_report edge case).
5. **CI-ready.** `run-all.sh` exits non-zero on any failure; the runner supports subset selection (`bash run-all.sh matrix chaos`).
6. **Pure-function harness (`src_fn`).** Lets you unit-test individual bash functions without executing the whole script. Used for `compute_backoff` and `unit_tenant` — the right approach for deterministic math.

---

## Risks & Observations

### 🔴 `src_fn` fragility

`src_fn` extracts everything before the line `main "$@"`. If `lunarwing-self-heal.sh`:
- Moves `main` to a different line pattern
- Wraps `main` in a function that's called differently
- Adds code after `main` that needs to run before function calls

...the extraction silently produces a broken body and tests start failing with cryptic errors. **Suggestion:** Add a sentinel comment (e.g., `# HARNESS_ENTRY_POINT`) around the extraction boundary, or switch to sourcing the full script with an early `exit` guard.

### 🟡 Mock `sudo` parser

The mock `sudo` walks argv with a `while`/`case` loop. It strips `-n`, `-u <user>`, `env`, and `VAR=VAL`. If `lunarwing-self-heal.sh` ever adds:
- `sudo -i`
- `sudo -E`
- `sudo --preserve-env=VAR`
- `sudo -g <group>`

...the mock will pass them through to the fake `systemctl`, which will treat them as service names. This could cause test failures that look like real failures but are just mock drift. **Suggestion:** Document the expected sudo invocation pattern in a comment, or make the mock stricter (fail on unrecognized flags).

### 🟡 Magic number: `restart_history` cap = 20

In H4, the test asserts `restart_history` is trimmed to 20 entries. But 20 is not mentioned in `CHAOS_ENGINEERING_TEST_PLAN.md` or anywhere visible in the test suite. It's a hardcoded constant in `lunarwing-self-heal.sh`. If the script changes this value, H4 will break with a confusing failure. **Suggestion:** Expose this as a tunable `SELF_HEAL_HISTORY_MAX` (or read it from the script) so the test doesn't hardcode the same number.

### 🟢 Minor: CWD-pinning in A1/A3

The `find | xargs ls -t` footgun is documented in the commit message but not in the test source. A future maintainer won't know why those tests `cd` into an empty directory. **Suggestion:** Inline comment in A1/A3 explaining the xargs edge case.

---

## Recommendations

| Priority | Item |
|----------|------|
| **P1** | Stabilize `src_fn` with a sentinel marker or guard the extraction with a check |
| **P1** | Document the expected `sudo` invocation pattern so mock drift is obvious |
| **P2** | Expose `restart_history` cap as a tunable or read it from the script under test |
| **P2** | Add inline comment for A1/A3 CWD-pinning |
| **P3** | Consider adding a `--list` or `--dry-run-dump` mode to `run-all.sh` for CI introspection |

---

## Overall Verdict

**Ship it.** The suite is solid: comprehensive coverage, safe to run anywhere, well-documented divergences, and a clean four-layer architecture. The three risks above are manageable and can be addressed in follow-up commits without blocking the initial merge.

The real win here is the *process* — a documented test plan, a runnable matrix, an end-to-end chaos harness, and an aggregate runner. That's production-grade infrastructure testing. Nice work.

— Baud 🐴
