# Chaos Engineering Test Plan — LunarWing Self-Healing v1.2.0

*Drafted by Baud, 2026-06-10*

## 1. Scope

This test plan covers the **lunarwing-self-heal.sh** watchdog (v1.2.0) and its interaction with the `infrastructure-health-check.sh` report pipeline. It does **not** test the health-check probes themselves (separate concern) — only how the self-healer reacts to the reports those probes generate.

### Guardrails

- All tests run in **`--dry-run`** mode to avoid mutating live services.
- Each test uses a sandboxed temporary directory (`mktemp -d`) with synthetic:
  - `report.json` (health-check output)
  - `state.json` (pre-seeded or empty)
  - fake health-check scripts (e.g. `health-gateway.sh` that echo `{"status":"critical"}`)
- Assertions validate **stderr output**, **state.json mutations**, and **exit codes**.
- Tests extend `ic-infrastructure-health-check/tests/test-self-heal.sh`.

---

## 2. Test Matrix

### A. Report Discovery & Init

| ID | Scenario | Fault Inject | Expected Behavior |
|----|----------|-------------|-------------------|
| A1 | No report found | Empty report dir | `die "no health-check report found"` (exit 1) |
| A2 | Malformed report | Invalid JSON in report file | `die "report is not valid JSON"` (exit 1) |
| A3 | Summary-only report | Only `*-summary*` files in dir | No report found (excludes summary files) |
| A4 | Explicit `--report` flag | Valid report path given | Uses specified report, not auto-discovery |

### B. Target Selection & Service Mapping

| ID | Scenario | Fault Inject | Expected Behavior |
|----|----------|-------------|-------------------|
| B1 | Gateway degraded | `{"component":"gateway","status":"degraded"}` | Targets `lunarwing` |
| B2 | XMPP degraded | `{"component":"xmpp","status":"critical"}` | Targets `xmpp-bridge` |
| B3 | TensorZero degraded | `{"component":"tensorzero","status":"critical"}` | Targets `tensorzero-gateway` |
| B4 | ClickHouse degraded | `{"component":"clickhouse","status":"critical"}` | Targets `clickhouse-server` |
| B5 | No-remedy component (omemo) | `{"component":"omemo","status":"critical"}` | Skipped, logged |
| B6 | No-remedy component (ratelimit) | `{"component":"ratelimit","status":"critical"}` | Skipped, logged |
| B7 | No-remedy component (models) | `{"component":"models","status":"critical"}` | Skipped, logged |
| B8 | Unknown component | `{"component":"gibberish","status":"degraded"}` | Skipped with WARNING log |
| B9 | Multiple unhealthy components | 3 degraded components | All 3 targeted in order |

### C. Init-System Sub-Unit Remediation

| ID | Scenario | Fault Inject | Expected Behavior |
|----|----------|-------------|-------------------|
| C1 | systemd sub-unit critical | `{"component":"systemd","metrics":{"units":[{name:"clickhouse-server.service",status:"critical"}]}}` | `systemctl restart clickhouse-server.service` |
| C2 | systemd sub-unit healthy | `{"component":"systemd","metrics":{"units":[{name:"lunarwing-watchdog.service",status:"healthy"}]}}` | Not restarted |
| C3 | OpenRC service critical | `{"component":"openrc","metrics":{"services":[{name:"clickhouse-server",status:"critical"}]}}` | `rc-service clickhouse-server restart` |
| C4 | launchd agent unhealthy | `{"component":"launchd","metrics":{"agents":[{name:"com.lunarwing.gateway",status:"degraded"}]}}` | `launchctl stop/start com.lunarwing.gateway` |
| C5 | Mixed init systems | systemd + openrc sub-units both unhealthy | Both targeted via their respective manager |
| C6 | Healthy sub-unit overrides logical degraded | Logical component degraded + init-system says healthy | **Not** remediated (init-system takes precedence) |

### D. Per-Tenant Systemd User Units

| ID | Scenario | Fault Inject | Expected Behavior |
|----|----------|-------------|-------------------|
| D1 | Tenant proxy degraded | Report marks `ironclaw-proxy-<tenant>` critical, registry has tenant user | `sudo -u <tenant> systemctl --user restart` |
| D2 | Tenant bridge degraded | Report marks `xmpp-bridge-<tenant>` critical, registry has tenant user | `sudo -u <tenant> systemctl --user restart` |
| D3 | Tenant user unknown | Report marks tenant service critical, no registry entry | Falls through to system `systemctl restart` |
| D4 | TENANTS_FILE missing | No ports.json on disk | Tenant resolution fails gracefully (no crash) |

### E. Grace Period

| ID | Scenario | Fault Inject | Expected Behavior |
|----|----------|-------------|-------------------|
| E1 | First observation (grace=2) | `consecutive_unhealthy=0` → 1 | `GRACE: 1/2`; no restart |
| E2 | Second observation (grace=2) | `consecutive_unhealthy=1` → 2 | Restart fires (grace met) |
| E3 | Single-check grace (grace=1) | First observation | Restart fires immediately |
| E4 | Healthy in between | unhealthy → healthy → unhealthy | Streak resets; new grace period |

### F. Backoff & Retry Spacing

| ID | Scenario | Fault Inject | Expected Behavior |
|----|----------|-------------|-------------------|
| F1 | Exponential backoff, attempt=1 | First retry after grace | `next_attempt_at` in [0, base] range |
| F2 | Exponential backoff, attempt=3 | Third retry | `next_attempt_at` ≈ base*4 ± jitter |
| F3 | Backoff gate active | `now < next_attempt_at` | `BACKOFF` logged, no restart |
| F4 | Linear strategy | `--backoff-strategy linear` | Deterministic `next_attempt_at = base` |
| F5 | Attempt > 20 (overflow guard) | Pre-seeded `retries=25` | Capped to `BACKOFF_MAX` (3600), no loop blowup |
| F6 | Jitter uses urandom for large delays | `BACKOFF_MAX > 32767` | Uses `/dev/urandom`, not `$RANDOM` |
| F7 | Invalid attempt value | Non-numeric attempt | Returns 0, no crash |

### G. Max Retries & Escalation

| ID | Scenario | Fault Inject | Expected Behavior |
|----|----------|-------------|-------------------|
| G1 | Max retries reached | `retries=3` (default max), still unhealthy | `mark_escalated`, escalation notification |
| G2 | Already escalated | `state[svc].escalated=true` | `SKIP: already escalated`, no restart |
| G3 | Escalation report written | Escalation triggered | JSON report created at `SELF_HEAL_STATE_DIR/` |
| G4 | `send-notification.sh` missing | Escalation, no script | WARNING logged, no crash |

### H. Flapping Guard

| ID | Scenario | Fault Inject | Expected Behavior |
|----|----------|-------------|-------------------|
| H1 | 5 restarts in 1h window | `restart_history` with 5 recent timestamps | `FLAPPING: escalating instead` |
| H2 | 4 restarts in window (below threshold) | `restart_history` with 4 timestamps | Restart proceeds (not flapping) |
| H3 | 5 restarts but old (outside window) | `restart_history` with timestamps > `FLAP_WINDOW_SECS` old | Restart proceeds |
| H4 | restart_history capped at 20 | Pre-seeded 25 entries | History trimmed to 20 |

### I. Post-Restart Verification

| ID | Scenario | Fault Inject | Expected Behavior |
|----|----------|-------------|-------------------|
| I1 | Verify passes (healthy) | `health-gateway.sh` returns `{"status":"healthy"}` | `SUCCESS`, state cleared |
| I2 | Verify fails (critical) | `health-gateway.sh` returns `{"status":"critical"}` | Retry count bumped, backoff scheduled |
| I3 | Verify fails (degraded) | `health-gateway.sh` returns `{"status":"degraded"}` | Retry count bumped, backoff scheduled |
| I4 | Verify inconclusive | `health-gateway.sh` returns `{"status":"unknown"}` | Falls back to `is-active` |
| I5 | Verify disabled | `--verify-health false` | Skips health-check script, uses `is-active` only |
| I6 | Health-check script missing | `HEALTH_CHECK_DIR` has no script | Falls back to `is-active` |
| I7 | Health-check script not executable | Script exists but not `+x` | Falls back to `is-active` |

### J. Restart Failure

| ID | Scenario | Fault Inject | Expected Behavior |
|----|----------|-------------|-------------------|
| J1 | `restart_service` fails | Service manager returns non-zero | Retry bumped, backoff scheduled |
| J2 | Unknown service manager | `SERVICE_MANAGER=unknown` | WARNING logged, no crash |

### K. State Recovery & Pruning

| ID | Scenario | Fault Inject | Expected Behavior |
|----|----------|-------------|-------------------|
| K1 | Report says healthy now | Previously tracked service, now `status:healthy` | `clear_service_state` — `RECOVERED` logged |
| K2 | TTL pruning | Entry untouched > 24h, not escalated | Pruned from state.json |
| K3 | TTL pruning disabled | `--prune-ttl 0` | No entries pruned |
| K4 | Escalated entry preserved | Entry is escalated, past TTL | NOT pruned |
| K5 | Currently unhealthy preserved | Entry is unhealthy, past TTL | NOT pruned |

### L. Concurrency & Locking

| ID | Scenario | Fault Inject | Expected Behavior |
|----|----------|-------------|-------------------|
| L1 | Concurrent instance detected | `flock` fails | `WARNING: another self-heal instance is running; exiting` |
| L2 | Normal single run | No lock contention | Runs to completion |

### M. Dry-Run Mode

| ID | Scenario | Fault Inject | Expected Behavior |
|----|----------|-------------|-------------------|
| M1 | `--dry-run` flag | Any unhealthy target | Logs `[DRY-RUN]` messages, no actual restarts |
| M2 | State mutations in dry-run | `--dry-run` with unhealthy service | State IS updated (tracking still works) |

### N. CLI Argument Validation

| ID | Scenario | Fault Inject | Expected Behavior |
|----|----------|-------------|-------------------|
| N1 | Unknown flag | `--bogus` | `die "unknown arg"` |
| N2 | `--help` | `--help` | Prints usage, exits 0 |
| N3 | All flags parsed | Multiple flags | All config overrides applied |

---

## 3. Service Manager Coverage

| Manager | Target Tests |
|---------|-------------|
| systemd (system) | B1–B9, F, G, H, I, J, K, L, M, N |
| systemd (user/tenant) | C, D |
| OpenRC | C3, C5 |
| launchd | C4 |

---

## 4. Chaos Harness (Future)

Once the test matrix above is validated, the next step is a **chaos test runner** that:

1. **Injects faults** into a real environment (kill processes, block ports, corrupt config, fill disk)
2. **Runs health-check** to produce the report
3. **Runs self-heal** (non-dry-run) and captures the outcome
4. **Verifies recovery**: service active, health-check passes
5. **Verifies no collateral damage**: other services unaffected
6. **Scores**: pass/fail with timing metrics

### Initial Chaos Scenarios

| ID | Fault | Recovery Criterion | Max Recovery Time |
|----|-------|-------------------|-------------------|
| C1 | `kill` gateway process | Gateway restarts and responds | 30s |
| C2 | Block HTTP port (gateway) | Process restarts, port rebinds | 30s |
| C3 | `kill` xmpp-bridge | Bridge restarts | 30s |
| C4 | `kill` TensorZero gateway | TensorZero restarts | 30s |
| C5 | ClickHouse crash | ClickHouse restarts | 60s |
| C6 | Corrupt env file (missing key) | Grace period → escalation (not auto-recoverable) | 2x grace checks |
| C7 | DNS failure | Services degrade, escalation after retries | 3x backoff cycle |
| C8 | Disk full (tmp) | State write fails, graceful degradation | N/A (escalation) |
| C9 | Port conflict (two services on same port) | First fails, escalation | 2x grace + retries |
| C10 | Tenant service crash | Tenant user-unit restarts | 30s |
| C11 | Tenant service crash (other tenants healthy) | Only affected tenant remediated | 30s |
| C12 | Rapid flapping (kill-loop) | Flap detection → escalation, no endless loop | 1x flap window |
| C13 | Transient blip (1s hiccup) | No restart (grace period absorbs) | N/A |

---

## 5. Test Execution Plan

### Phase 1: Unit-level (current)
- Extend `test-self-heal.sh` with matrix tests A–N above
- All run in dry-run with synthetic reports
- **Target**: >40 passing tests (currently ~15)

### Phase 2: Integration
- Run self-heal against real containers with controlled faults
- Verify end-to-end: health-check → report → self-heal → recovery
- **Target**: All chaos scenarios C1–C13 pass

### Phase 3: Multi-tenant
- Spin up 2+ tenants, inject faults independently
- Verify blast-radius isolation
- **Target**: C11 specifically validates no cross-tenant remediation

---

## 6. Success Criteria

| Metric | Target |
|--------|--------|
| Unit tests passing | 40+ |
| False positive rate | 0 (grace period + init-system verification) |
| Recovery time (single service) | <30s |
| Flapping detection | No more than `FLAP_MAX_RESTARTS` in window |
| No collateral damage | Adjacent services untouched during remediation |
| Escalation reliability | Notification sent on max retries |

---

## 7. Test Plan Checklist

- [ ] A1–A4: Report discovery & init
- [ ] B1–B9: Target selection & service mapping
- [ ] C1–C6: Init-system sub-unit remediation
- [ ] D1–D4: Per-tenant systemd user units
- [ ] E1–E4: Grace period
- [ ] F1–F7: Backoff & retry spacing
- [ ] G1–G4: Max retries & escalation
- [ ] H1–H4: Flapping guard
- [ ] I1–I7: Post-restart verification
- [ ] J1–J2: Restart failure
- [ ] K1–K5: State recovery & pruning
- [ ] L1–L2: Concurrency & locking
- [ ] M1–M2: Dry-run mode
- [ ] N1–N3: CLI argument validation
