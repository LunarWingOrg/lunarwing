# Infrastructure Health Check & Self-Healing — v1.1.2

---

## Self-Heal 5-Part Proposal — Merged "best of both" (2026-06-08)

Two parallel implementations of the 5-part resilience proposal were built and
compared: `1.1.2-888-self-healing-improvements-8-sun` (claude) and
`1.1.2-999-self-healing-improvements-9-kumogakure` (kumogakure). This branch
(`1.1.2-333-self-healing-improvements-3`) is the **merge of the strongest parts
of each**, in `ic-infrastructure-health-check/lunarwing-self-heal.sh` (v1.2.0,
verified by `tests/test-self-heal.sh` — 28 dry-run/state assertions, all green).

**From the 888 implementation:** all five items incl. **multi-tenant** (host-level
root orchestrator — `sudo -u <user> systemctl --user` for systemd tenant units,
`rc-service` for OpenRC, plus `health-systemd.sh` per-tenant discovery), the real
**flapping-rate guard** (`restart_history` window → escalate), **cross-tick backoff
gating** (`next_attempt_at`, so the run never blocks on a long sleep), grounded
**verification** (re-runs the component `health-*.sh`), and the **`$STATE` fix**
(`escalate_service` takes the retry count explicitly — kumogakure's branch still
reports `retries: 0`).

**From kumogakure's implementation:** the cleaner **`compute_backoff`** (pure-bash,
input-validated, full jitter, `linear|exponential` strategy toggle), the six
**CLI flags** (`--backoff-base/-max/-strategy`, `--grace-checks`, `--prune-ttl`,
`--verify-health`), and the **report-as-truth recovery** (a service the report calls
healthy is cleared without round-tripping `check_service_active`).

**Fixed during the merge:** his `SERVICE_VERIFY_MAP` had hardcoded/incorrect probe
endpoints (dropped in favor of re-running `health-*.sh`); his backoff could yield a
0 s in-run settle (the merged settle is a fixed 5 s, separate from the jittered
cross-tick gate).

Caveat: verified on a dev host with services stopped (dry-run + state assertions);
live remediation against running tenant services still needs a real MT host.

---

## Self-Healing & Healthcheck Verification (item 4)

_Verified 2026-06-08 on branch `1.1.2-333-self-healing-improvements-3`._

### Rust — all green
- Full unit suite: **3940 passed, 0 failed**, 3 ignored.
- `self_repair` (stuck-job recovery + broken-tool rebuild): **12/12**.
- WASM channel polling supervisor (`channels/wasm/wrapper.rs` — dead-task / stalled-poll / shutdown-abort / manager `health_check_all`): **6/6**. This is the supervision that fixed the two High-severity hang bugs (subagent-worker-hang, daemon-stops-polling-xmpp).
- `routine_engine` incl. stuck-run sweeper module: **29/29**.
- **New regression coverage:** `ic/tests/stuck_lightweight_run_tests.rs` (3 tests). The lightweight stuck-run sweep query `list_stuck_lightweight_runs` previously had **zero** coverage in either backend.

### Bash scripts (`ic-infrastructure-health-check/`)
- All scripts pass `bash -n`.
- **Orchestrator** (`infrastructure-health-check.sh`): runs live, auto-detects the init system, 8 parallel checks, emits valid JSON report + Markdown summary, correct status aggregation and exit codes.
- **Self-heal** (`lunarwing-self-heal.sh`): dry-run verified across standard-component→service mapping, no-remedy skips (omemo/models), retry→escalation→Gotify notification, JSON state persistence, and systemd/openrc/launchd sub-unit remediation.

### Bug found, fixed & regression-guarded
- **`lunarwing-self-heal.sh` pass-2 jq precedence bug** (fix in commit `e997ec5d`): the init-system sub-unit filter aborted with `exit 5` ("Cannot index string with 'metrics'") because jq's `|` binds looser than `,`; the crash was masked by `2>/dev/null || true`, so **every systemd/openrc/launchd sub-unit failure was silently un-remediated**. Confirmed on a real generated health report. Fixed by fully parenthesizing each alternative; guarded by `ic-infrastructure-health-check/tests/test-self-heal.sh` (fails on the old filter, passes on the fix).

### Hardening / cleanup applied (this branch)
- **No more hardcoded `/tmp`** in `infrastructure-health-check.sh` — the parallel-check scratch files moved to a per-run `mktemp -d` (removes the multi-tenant collision risk; satisfies the repo's "never hardcode /tmp" rule).
- **`health-systemd.sh`** now monitors the real units (`lunarwing.service`, `xmpp-bridge.service`, `tensorzero-gateway.service`) instead of stale `ironclaw-xmpp-bridge.*` (which reported false "critical").
- **`send-notification.sh`** / **`health-ratelimit.sh`**: dropped hardcoded `$HOME/.ironclaw` paths in favour of the standard `LUNARWING_BASE_DIR` fallback chain.
- **Removed pre-fork POC cruft**: stale `icscripts/` (17 files), `icservices/` (3), and a duplicate top-level `ironclaw-watchdog.timer` — all unreferenced duplicates of canonical `ic/scripts/` + `ic/systemd/`. README scheduling instructions rewritten to a self-contained systemd-timer / cron setup.

### Not covered (follow-up)
- Live remediation against **running** services / a real multi-tenant deployment was not exercised — this verification ran on a dev host with services stopped, so the restart→verify→escalate path is covered only via dry-run + unit tests. (Tracks with the v1.1.8 "expansion of healthcheck tests for ClickHouse" item in the release notes.)
