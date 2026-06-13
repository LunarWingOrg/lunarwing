# Proposed Follow-up Tests for Self-Healing Test Suite

*Drafted after P1/P2/P3 review items landed (commit `9c0c16ff` on `2026-06-14-chaos-baud`)*

The current matrix (`test-self-heal-matrix.sh`, sections A–N) + chaos harness (`chaos-harness.sh`, CH1–CH13) cover ~107 dry-run assertions + 11 mock-init scenarios. These follow-ups target real-world failure modes those don't cover yet.

---

## Section O — Concurrency Safety

| ID | Scenario | Fault Inject | Expected Behavior |
|----|----------|-------------|-------------------|
| O1 | Two simultaneous runs | Two instances racing on same `state.json` | One waits on `flock`, no corruption |
| O2 | Nested/concurrent `sudo` calls | Second instance starts while first holds flock | `WARNING: another self-heal instance is running; exiting` |
| O3 | SIGTERM during locked section | Kill mid-execution while holding lock | Lock released on exit, next run proceeds cleanly |

## Section P — State Corruption Recovery

| ID | Scenario | Fault Inject | Expected Behavior |
|----|----------|-------------|-------------------|
| P1 | Truncated `state.json` | `echo -n "{lunarwing":' > state.json` (incomplete JSON) | Recover: start with empty state, log warning |
| P2 | Valid-but-malformed jq structure | `{"lunarwing":{"consecutive_unhealthy":"seven"}}` | Recover: cast or reset to 0, continue |
| P3 | Stale `restart_history` timestamps | History contains dates 6 months in past/future | Filter window correctly, no crash |
| P4 | Mixed types in `restart_history` | History contains strings like `"abc"` instead of epochs | Skip bad entries, log warning |
| P5 | State file written by another agent | Different schema version inside state.json | Detect version mismatch, log + reset |

## Section Q — Report Staleness & Time Handling

| ID | Scenario | Fault Inject | Expected Behavior |
|----|----------|-------------|-------------------|
| Q1 | Report timestamp 30+ min old | `touch -d '@(now-1800)' report.json` | Self-heal still acts (no staleness check currently — *consider adding one*) |
| Q2 | Clock skew / future report | Report has future timestamp | Handles gracefully, no panic |
| Q3 | Report missing required component keys | `{"status":"degraded"}` without `component`, `metrics` | Warns and skips, no crash |
| Q4 | Report has unknown top-level keys | `{"components":[],"unknown_key":null}` | Ignores extras, no crash |
| Q5 | Empty `components` array | `{"components":[]}` | No-op, exit 0, no warnings |

## Section R — Escalation Path Edge Cases

| ID | Scenario | Fault Inject | Expected Behavior |
|----|----------|-------------|-------------------|
| R1 | `send-notification.sh` missing | No script on disk | Logs warning, no crash, still marks escalated in state |
| R2 | Escalation script non-executable | Script exists but `-x` not set | Falls back to WARNING log, no crash |
| R3 | Escalation script exits non-zero | Script exits 1 | Logs warning, keeps state escalated |
| R4 | Escalation rate-limited | Same escalation triggered repeatedly across cron ticks | Only one notification per `FLAP_WINDOW_SECS` (consider adding) |
| R5 | Escalation script blocks/hangs | Script sleeps 60s | self-heal times out script gracefully (consider adding timeout) |

## Section S — Flap Detection Boundary Cases

| ID | Scenario | Fault Inject | Expected Behavior |
|----|----------|-------------|-------------------|
| S1 | Exactly `FLAP_MAX_RESTARTS` | 5 restarts at t=0,10,...50 in 3600s window | Does NOT escalate (threshold is `>`, not `>=`) |
| S2 | `FLAP_MAX_RESTARTS+1` | 6 restarts in window | Escalates immediately |
| S3 | Restarts spanning multiple windows | 3 in first hour, 3 in second hour | Each window counted separately, no escalation |
| S4 | Very long flap window | `FLAP_WINDOW_SECS=86400` (24h) | Still detects clustering correctly |
| S5 | `FLAP_MAX_RESTARTS=0` (escalate immediately) | Any restart | Escalates on first cycle (degenerate config validation) |

---

## Implementation Notes

- All tests fit the existing sandbox framework (`sb()`, `run_dry()`, `run_chaos()`)
- **O** tests need a background `flock` holder + race timing
- **P** tests need explicit malformed `state.json` seeding before invocation
- **Q** tests need `touch -d` tricks (BSD vs GNU portability matters)
- **R** tests need fake `send-notification.sh` that fails, hangs, or counts invocations
- **S** tests need time-skewed `restart_history` entries and explicit `FLAP_*` env

---

## Priorities

| Priority | Items | Rationale |
|----------|-------|-----------|
| **P0** | O1, P1, R1 | Crash-proofing under concurrency and missing tools — basic robustness |
| **P1** | Q1, Q2, Q3 | Report validity edge cases — common in real deployments |
| **P2** | P2, P3, P4, R2, R3 | Malformed state recovery — corruption tolerance |
| **P3** | S1–S5, P5, Q4, Q5 | Boundary precision + nice-to-have |
| **P4** | R4, R5 | Requires self-heal feature additions (rate limit + timeout) |

---

## Potential Self-Heal Improvements Surfaced by These Tests

1. **Staleness check** (Q1): Refuse to act on reports older than `MAX_REPORT_AGE` (env tunable)
2. **State schema version** (P5): Add `_meta.version` to state.json, migrate or reset on mismatch
3. **Escalation rate limit** (R4): Track last escalation epoch per service, suppress within `FLAP_WINDOW_SECS`
4. **Escalation script timeout** (R5): Wrap `send-notification.sh` in `timeout 10`

---

— Baud 🦄
