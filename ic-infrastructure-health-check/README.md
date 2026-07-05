# LunarWing Infrastructure Health Check System

_Last updated: 2026-06-24 — self-heal watchdog v2.0.0; LunarVision check added._

Automated health monitoring and self-healing for LunarWing infrastructure.
Nine parallel component checks aggregate into a JSON report; a separate
watchdog reads that report and auto-remediates unhealthy services with a grace
period, exponential backoff, a flapping guard, post-restart verification, and
multi-tenant awareness.

## Architecture

```
cron-wrapper.sh
  ├── infrastructure-health-check.sh   (parallel checks → JSON report)
  │     ├── health-gateway.sh          (agent sessions: locks, orphans, oversized)
  │     ├── health-xmpp.sh             (XMPP bridge reachability + latency)
  │     ├── health-omemo.sh            (OMEMO key/bundle/session store)
  │     ├── health-ratelimit.sh        (throttle counters, queue depth)
  │     ├── health-clickhouse.sh       (query time, disk, memory)
  │     ├── health-tensorzero.sh       (proxy p50/p95, error rate, queue, GPU)
  │     ├── health-models.sh           (LLM provider APIs)
  │     ├── health-lunarvision.sh      (OCR + VL sidecar: health, metrics, VL status)
  │     └── health-{systemd,openrc,launchd}.sh  (service manager — one, auto-detected)
  │
  └── lunarwing-self-heal.sh           (reads report → restarts → verifies → escalates)
        └── send-notification.sh       (Gotify push notifications)
```

`cron-wrapper.sh` runs the two halves in sequence and always proceeds to
self-heal even if the health check fails. It auto-detects its own install
location, so it works from wherever this directory lives. Any arguments are
forwarded to `lunarwing-self-heal.sh` (e.g. `cron-wrapper.sh --dry-run`).

### Init-system auto-detection

`infrastructure-health-check.sh` and `lunarwing-self-heal.sh` both detect the
service manager and run exactly one of the three service checks — never both.
Detection order:

1. `LUNARWING_SERVICE_MANAGER` override — `systemd` | `openrc` | `launchd`.
   (Self-heal additionally honors the legacy `IRONCLAW_SERVICE_MANAGER` alias;
   the health-check orchestrator reads only `LUNARWING_SERVICE_MANAGER`.)
2. macOS (`uname -s` = `Darwin`) → `launchd`.
3. `/run/openrc/softlevel` present → `openrc`.
4. `/run/systemd/system` present → `systemd`.
5. Binary fallback: `rc-service`/`systemctl` presence.

If none match, the service check is skipped (logged as a warning) and the rest
of the report is still produced.

## Dependencies

### Required

| Dependency | Purpose | Install |
|------------|---------|---------|
| bash ≥ 4.0 | Associative arrays, `mapfile`, extended globbing | Pre-installed on most systems |
| jq | JSON parsing and generation | `apt install jq` / `brew install jq` / `apk add jq` |
| curl | HTTP health checks, Gotify notifications | Pre-installed on most systems |
| coreutils `timeout` | Per-check 30 s cap; bounded restart/notify/tenant probes | Pre-installed on Linux; `brew install coreutils` on macOS |

### Optional (per-check)

| Dependency | Used by | Install |
|------------|---------|---------|
| systemctl | health-systemd.sh, self-heal (systemd hosts) | Pre-installed on systemd systems |
| rc-service | health-openrc.sh, self-heal (OpenRC hosts) | Pre-installed on OpenRC systems |
| launchctl | health-launchd.sh, self-heal (macOS) | Pre-installed on macOS |
| sudo + podman | health-systemd.sh & self-heal (per-tenant **user** units + container health) | systemd multi-tenant hosts |
| clickhouse-client | health-clickhouse.sh, health-tensorzero.sh | ClickHouse docs |
| nc (netcat) | health-xmpp.sh (port reachability) | `apt install netcat-openbsd` / `brew install netcat` |
| nvidia-smi / rocm-smi | health-tensorzero.sh (GPU utilization) | NVIDIA driver / ROCm package |
| flock | lunarwing-self-heal.sh (single-instance lock) | util-linux (pre-installed on most Linux) |

> `timeout` is only *required* in spirit — every call site degrades gracefully
> when it is absent (notably macOS/launchd hosts without GNU coreutils), running
> the underlying command unbounded instead of failing.

### Not required (replaced)

| Previously needed | Replaced by |
|-------------------|-------------|
| bc | `awk` for float comparisons in health-tensorzero.sh |

## Quick Start

```bash
# 1. Make scripts executable
chmod +x ic-infrastructure-health-check/*.sh

# 2. Run manually (dry-run self-heal — restarts nothing)
cd ic-infrastructure-health-check
./infrastructure-health-check.sh
./lunarwing-self-heal.sh --dry-run

# 3. Schedule recurring runs — see "Cron / Timer Setup" below
```

## Component Checks

Every check writes a single JSON object to stdout (logs go to stderr) and exits
`0` healthy / `1` degraded / `2` critical. The orchestrator aggregates them.

| Component | Script | Inspects | Key metrics |
|-----------|--------|----------|-------------|
| gateway | health-gateway.sh | `$BASE/agents` session files | `active_sessions`, `stale_locks` (>10 min), `orphan_transcripts` (`*.jsonl` >10 MB), `oversized_sessions` (>500 KB) |
| xmpp | health-xmpp.sh | TCP reachability of the XMPP server + latency | `connected`, `latency_ms`, `error_count`, `active_sessions` |
| omemo | health-omemo.sh | OMEMO key/bundle/session store | `devices`, `bundles`, `sessions`, `recent_sessions` |
| ratelimit | health-ratelimit.sh | `$BASE/ratelimit` throttle logs + queue | `throttled_last_hour`, `queue_depth` |
| clickhouse | health-clickhouse.sh | ClickHouse responsiveness + resources | `query_time_ms`, `disk_pct`, `memory_pct` |
| tensorzero | health-tensorzero.sh | Proxy latency/errors (from ClickHouse) + GPU | `p50_ms`, `p95_ms`, `error_rate`, `queue_depth`, `gpu_utilization` |
| models | health-models.sh | OpenRouter / OpenAI / Anthropic / local LLM APIs | per-provider `status`, `latency_ms`, `last_error` |
| lunarvision | health-lunarvision.sh | OCR + VL sidecar `/health` and `/vision/metrics` | `service_status`, `ocr_available`, `vl_available`, `capabilities`, `latency_ms`, cache `hit_rate`, `rate_limited`, `avg_latency_ms` |
| systemd / openrc / launchd | health-{systemd,openrc,launchd}.sh | Service-manager unit state (incl. per-tenant) | `metrics.units` / `.services` / `.agents` |

A check that cannot reach its target generally reports `critical`; several
checks can instead be **disabled** so they report `healthy` with
`metrics.enabled = false` (see [Disabling individual checks](#disabling-individual-checks)).

## Environment Variables

### Core

| Variable | Default | Description |
|----------|---------|-------------|
| `LUNARWING_BASE_DIR` | `$HOME/.lunarwing` | Base directory for LunarWing data (reports, agents, stores) |
| `IRONCLAW_BASE_DIR` | (unset) | Legacy alias, consulted only if `LUNARWING_BASE_DIR` is unset; the ultimate fallback is `$HOME/.lunarwing` (not `~/.ironclaw`) |
| `LUNARWING_SERVICE_MANAGER` | auto-detect | Force init system: `systemd` \| `openrc` \| `launchd`. Self-heal also accepts the legacy `IRONCLAW_SERVICE_MANAGER` alias; the orchestrator does not |
| `HEALTHCHECK_NOTIFY` | `true` | `false` suppresses the orchestrator's per-run Gotify notify (e.g. MT hosts where only self-heal escalations should page) |
| `GOTIFY_URL` | `http://localhost:3000` | Gotify server URL (`send-notification.sh`) |
| `GOTIFY_TOKEN` | (empty) | Gotify app token — **empty disables all notifications** |
| `TMPDIR` | `/tmp` | Parent for the per-run scratch dir (`mktemp -d`) |

### Per-check tuning

| Variable | Used by | Default | Description |
|----------|---------|---------|-------------|
| `HEALTH_XMPP_SERVER` | health-xmpp.sh | `xmpp.sobe.world` | XMPP reachability target; **empty disables the probe** |
| `HEALTH_XMPP_PORT` | health-xmpp.sh | `5222` | XMPP port to probe |
| `HEALTH_OMEMO_ENABLED` | health-omemo.sh | `true` | Non-`true` disables (reports healthy/disabled) |
| `AGENT_DIR` | health-omemo.sh | `$BASE/agents` | Agent session directory |
| `OMEMO_STORE` | health-omemo.sh | `$BASE/omemo` | OMEMO key/bundle/session store |
| `RATELIMIT_DIR` | health-ratelimit.sh | `$BASE/ratelimit` | Rate-limit state directory |
| `HEALTH_MODELS_ENABLED` | health-models.sh | `true` | Non-`true` disables (reports healthy/disabled) |
| `HEALTH_LUNARVISION_ENABLED` | health-lunarvision.sh | `true` | Non-`true` disables (reports healthy/disabled) |
| `HEALTH_LUNARVISION_URL` | health-lunarvision.sh | `http://127.0.0.1:8088` | OCR + VL sidecar base URL |
| `HEALTH_LUNARVISION_TIMEOUT` | health-lunarvision.sh | `5` | curl timeout (seconds) for `/health` and `/vision/metrics` |
| `HEALTH_LUNARVISION_FETCH_METRICS` | health-lunarvision.sh | `true` | Also probe `/vision/metrics` for request counts, cache stats, rate limiting |
| `HEALTH_LUNARVISION_REQUIRE_VL` | health-lunarvision.sh | `false` | Degrade if the VL backend is not confirmed available |
| `HEALTH_LUNARVISION_LATENCY_DEGRADED_MS` | health-lunarvision.sh | `2000` | Health-endpoint latency threshold for `degraded` |
| `HEALTH_LUNARVISION_LATENCY_CRITICAL_MS` | health-lunarvision.sh | `5000` | Health-endpoint latency threshold for `critical` |
| `OPENROUTER_API_KEY` | health-models.sh | (empty) | OpenRouter key; unset → provider `unknown` (degraded) |
| `OPENAI_API_KEY` | health-models.sh | (empty) | OpenAI key; unset → provider `unknown` (degraded) |
| `ANTHROPIC_API_KEY` | health-models.sh | (empty) | Anthropic key; unset → provider `unknown` (degraded) |
| `UNITS` | health-systemd.sh | `lunarwing.service xmpp-bridge.service tensorzero-gateway.service` | Override the base systemd units to probe |
| `SERVICES` | health-openrc.sh | auto-discovered | Override the OpenRC services to probe (space-separated) |
| `INITD_DIR` | health-openrc.sh | `/etc/init.d` | Init-script directory scanned for tenant services |
| `HEALTH_OPENRC_STATUS_TIMEOUT` | health-openrc.sh | `8` | Per-unit `rc-service status` timeout (s); `0` disables |
| `AGENTS` | health-launchd.sh | auto-discovered | Override the launchd labels to probe |

> `$BASE` above is `${LUNARWING_BASE_DIR:-${IRONCLAW_BASE_DIR:-$HOME/.lunarwing}}`.

The full self-heal `SELF_HEAL_*` knobs are tabulated under
[Self-Healing → Tuning](#tuning-flags--env-vars).

### Disabling individual checks

On multi-tenant or specialised hosts a base-level probe can be a false positive
(no shared XMPP server, no host-level OMEMO store, no external provider keys).
Each of these reports `healthy` with `metrics.enabled = false` instead of a
spurious `critical`:

```bash
HEALTH_XMPP_SERVER=''        # skip the XMPP reachability probe
HEALTH_OMEMO_ENABLED=false   # skip the OMEMO store probe
HEALTH_MODELS_ENABLED=false  # skip the LLM-provider probe
HEALTH_LUNARVISION_ENABLED=false  # skip the OCR/VL sidecar probe
HEALTHCHECK_NOTIFY=false     # don't page on every per-run degrade (let self-heal escalations page instead)
```

Put these in a shared env file (e.g. `/etc/lunarwing/health.env`) loaded by the
timer/cron unit so every run picks them up.

## Report Output

Reports are saved to `$LUNARWING_BASE_DIR/workspace/reports/health/`:

- `YYYY-MM-DDTHH:MM:SSZ.json` — full machine-readable report
- `YYYY-MM-DDTHH:MM:SSZ-summary.md` — human-readable summary
- `health.log` — appended run log (also echoed to stderr)

Both `.json` and `-summary.md` files are rotated after 7 days
(`find -mtime +7 -delete`). Report filenames are ISO-8601, so lexical sort is
chronological — self-heal picks the newest by `sort | tail -1`.

Report shape:

```json
{
  "timestamp": "2026-06-16T12:00:00Z",
  "overall_status": "degraded",
  "components": [ { "component": "gateway", "status": "healthy", "metrics": {…} }, … ],
  "alerts":     [ { "component": "xmpp", "severity": "warning", "message": "xmpp is degraded" } ]
}
```

`overall_status` is the worst component status; a component reporting `unknown`
(timeout, crash, invalid JSON) degrades the overall result.

## Self-Healing

`lunarwing-self-heal.sh` (v2.0.0) reads the latest health report and:

1. **Maps** unhealthy logical components to base service names
   (`gateway → lunarwing`, …) and discovers per-tenant init sub-units from the
   service-manager report; resolves per-tenant systemd **user** units to the
   owning OS user via the tenant registry.
2. **Grace period** — waits for N consecutive unhealthy observations before the
   first restart (absorbs transient blips).
3. **Restarts**, then **verifies** recovery by re-running the component's own
   `health-*.sh` and parsing `.status` (falls back to `is-active`).
4. **Backs off** between failed attempts with exponential delay + full jitter
   (`linear` kill-switch available), scheduling the next attempt *across* ticks
   rather than sleeping in-run.
5. **Flapping guard** — a service restarted too many times inside the window is
   escalated, not looped.
6. **Escalates** via Gotify (bounded by a timeout) after max retries or on
   flapping.
7. **Tracks state** in `$LUNARWING_BASE_DIR/workspace/reports/self-heal/state.json`,
   clears any service the latest report calls healthy ("report as truth"), and
   auto-prunes stale, non-escalated entries.

A single-instance `flock` guard (fd 200) prevents overlapping runs; the lock fd
is closed across restarts so a long-lived `supervise-daemon` can't inherit and
wedge it.

### Component → service mapping

| Component | Base service (single-instance) | Verify script |
|-----------|--------------------------------|---------------|
| gateway | `lunarwing` | health-gateway.sh |
| xmpp | `xmpp-bridge` | health-xmpp.sh |
| tensorzero | `tensorzero-gateway` | health-tensorzero.sh |
| clickhouse | `clickhouse-server` | health-clickhouse.sh |
| omemo, ratelimit, models | _(none — feature/external, never remediated)_ | — |

On systemd the base names get a `.service` suffix; per-tenant sub-units
discovered from the service report are remediated as the tenant user.

```bash
# Test without restarting anything
./lunarwing-self-heal.sh --dry-run

# Tuning via flags
./lunarwing-self-heal.sh --max-retries 5 --grace-checks 2 \
    --backoff-strategy exponential --backoff-base 60 --backoff-max 3600 \
    --prune-ttl 86400 --verify-health true

# Restore the old fixed-delay behavior
./lunarwing-self-heal.sh --backoff-strategy linear --backoff-base 30

# Point at a specific report
./lunarwing-self-heal.sh --report /path/to/report.json
```

Self-heal exits `0` in normal operation (including lock contention and
"nothing to do"); it exits `1` only on a fatal error (no report found, report
is not valid JSON).

### Tuning (flags / env vars)

| Flag | Env var | Default | Description |
|------|---------|---------|-------------|
| `--max-retries N` | `SELF_HEAL_MAX_RETRIES` | 3 | Restart attempts before escalation |
| `--backoff N` | `SELF_HEAL_BACKOFF_SECONDS` | 5 | Fixed in-run settle wait after a restart, before verifying |
| `--backoff-base N` | `SELF_HEAL_BACKOFF_BASE` | 60 | Backoff base delay (1st retry) |
| `--backoff-max N` | `SELF_HEAL_BACKOFF_MAX` | 3600 | Backoff ceiling |
| `--backoff-strategy S` | `SELF_HEAL_BACKOFF_STRATEGY` | exponential | `exponential` (full jitter) or `linear` (returns base, no jitter) |
| `--grace-checks N` | `SELF_HEAL_GRACE_CHECKS` | 2 | Consecutive unhealthy observations before the first restart |
| `--prune-ttl S` | `SELF_HEAL_STATE_PRUNE_TTL` | 86400 | Prune non-escalated entries older than this; `0` (or `false`/`no`/`off`) disables |
| `--verify-health B` | `SELF_HEAL_VERIFY_HEALTH` | true | Re-run the component health check after a restart (`false` → `is-active` only) |
| `--report PATH` | — | latest | Act on a specific report instead of the newest in the report dir |
| `--dry-run` / `-n` | — | off | Log intended actions; never restart, notify, or write escalations |
| — | `SELF_HEAL_FLAP_MAX_RESTARTS` | 5 | Restarts within the window that mark a service flapping |
| — | `SELF_HEAL_FLAP_WINDOW_SECS` | 3600 | Flapping detection window (seconds) |
| — | `SELF_HEAL_HISTORY_MAX` | 20 | Cap on `restart_history[]` length (must be ≥ flap-max) |
| — | `SELF_HEAL_ESCALATE_TIMEOUT` | 30 | Timeout (s) around the notifier so a hung Gotify can't stall a tick |
| — | `SELF_HEAL_MAX_REPORT_AGE` | 0 | Refuse to act on a report older than this many seconds; `0` disables |
| — | `SELF_HEAL_REMEDY_LOGICAL` | true | `false` → remediate **only** discovered init sub-units, not logical base services (MT hosts) |
| — | `SELF_HEAL_STATE_DIR` | `<reports>/../self-heal` | State + lock + escalation directory |
| — | `SELF_HEAL_LOG` | `<state-dir>/actions.log` | Action log path |
| — | `SELF_HEAL_HEALTH_CHECK_DIR` | script dir | Where the `health-*.sh` verify scripts live |
| — | `SELF_HEAL_TENANTS_FILE` | see below | Multi-tenant registry for per-tenant remediation |

`SELF_HEAL_TENANTS_FILE` defaults to `$LUNARWING_BASE_DIR/tenants/ports.json`
when that file exists, otherwise `/etc/lunarwing/ports.json`. (The data-volume
path is preferred because on some platforms — e.g. Umbrel — `/etc/` is not
persistent across app updates.)

The self-heal state directory holds `state.json`, `actions.log`,
`self-heal.lock`, transient `escalation-*.json`, and (on corruption) a single
`state.json.corrupt` forensic copy.

> **Backoff is a cross-tick gate**, not an in-run sleep: a failed service's
> `next_attempt_at` is pushed out by `compute_backoff`, so the run never blocks
> and a flapping service is retried less often. The grace period is counted in
> *observations* (self-heal runs once per health-check tick).

> **Multi-tenant:** run as root with the registry present and self-heal
> remediates per-tenant units — `rc-service lunarwing-<tenant>` on OpenRC, and
> `sudo -n -u <user> … systemctl --user restart lunarwing-<tenant>.service` for
> systemd user units. `health-systemd.sh` discovers those per-tenant user units
> (and probes `podman inspect` health for container units), and
> `health-openrc.sh` auto-discovers tenant init scripts under `INITD_DIR`. On MT
> hosts set `SELF_HEAL_REMEDY_LOGICAL=false` so the watchdog doesn't try to
> restart non-existent base services.

## Cron / Timer Setup

### systemd (recommended for Linux)

Run `cron-wrapper.sh` on a user-level timer (adjust the path to where this
directory lives):

```bash
DIR="$(pwd)"   # run from inside ic-infrastructure-health-check/
mkdir -p ~/.config/systemd/user

cat > ~/.config/systemd/user/lunarwing-health-check.service <<EOF
[Unit]
Description=LunarWing infrastructure health check
[Service]
Type=oneshot
ExecStart=$DIR/cron-wrapper.sh
EOF

cat > ~/.config/systemd/user/lunarwing-health-check.timer <<EOF
[Unit]
Description=Run LunarWing health check every 30 min
[Timer]
OnBootSec=5min
OnUnitActiveSec=30min
Persistent=true
[Install]
WantedBy=timers.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now lunarwing-health-check.timer
systemctl --user list-timers lunarwing-health-check.timer
```

> The separate **service-level** watchdog that restarts `lunarwing.service`
> itself lives in the main repo: `ic/scripts/install-lunarwing-watchdog.sh`
> (auto-detects systemd/OpenRC/launchd). This directory's self-heal watchdog
> operates at the component/tenant level on top of that.

### crontab (fallback)

```bash
# Run every 30 minutes
*/30 * * * * /path/to/ic-infrastructure-health-check/cron-wrapper.sh
```

### launchd (macOS)

Create a plist in `~/Library/LaunchAgents/` whose `ProgramArguments` invoke
`cron-wrapper.sh`, with a `StartInterval` of 1800 (30 min).

## Exit Codes

`infrastructure-health-check.sh` (and each `health-*.sh`):

| Code | Meaning |
|------|---------|
| 0 | All components healthy |
| 1 | One or more components degraded (or `unknown`) |
| 2 | One or more components critical |

## Testing & Chaos Suite

The self-heal watchdog and the OpenRC probe have a test suite under `tests/`
(see `docs/proposals/CHAOS_ENGINEERING_TEST_PLAN.md` for the full matrix):

```bash
cd ic-infrastructure-health-check
bash tests/run-all.sh                       # all suites: regression → matrix → chaos → openrc
bash tests/run-all.sh matrix chaos          # pick a subset
bash tests/run-all.sh --list                # print suite names for CI introspection
bash tests/test-self-heal-matrix.sh         # dry-run unit matrix (sections A–O)
bash tests/chaos-harness.sh                 # end-to-end fault-injection (11 scenarios: CH1–CH6, CH9–CH13)
bash tests/test-health-openrc.sh            # health-openrc.sh probe scenarios (S1–S6)
```

| Suite | Script | What it does |
|-------|--------|--------------|
| `regression` | `test-self-heal.sh` | Original regression checks (jq precedence, backoff, grace, flapping, …). |
| `matrix` | `test-self-heal-matrix.sh` | The full A–O matrix in `--dry-run` against synthetic reports (~120 assertions). |
| `chaos` | `chaos-harness.sh` | Drives the **real** self-heal loop (kill → restart → verify → recover/escalate) against a mock init system. |
| `openrc` | `test-health-openrc.sh` | Exercises `health-openrc.sh` (discovery dedup, real exit-code capture, per-unit timeout, missing/stopped units). |
| `lunarvision` | `test-health-lunarvision.sh` | Exercises `health-lunarvision.sh` (mock curl, 68 assertions: reachability, HTTP codes, JSON parsing, VL availability logic, metrics integration, cache/rate-limit stats, capabilities inference, disabled mode). |
| — | `lib.sh` | Shared harness + the mock init system (sourced, not run directly). |

`run-all.sh` runs each suite in its own process, tallies per-suite
`N passed, M failed`, and exits non-zero if any suite fails.

**Safety.** The matrix is dry-run only and never triggers a real restart or the
real HTTP/component probes. The chaos and OpenRC harnesses run for real but
against a *mock* `systemctl`/`rc-service`/`sudo` shadowed onto `PATH`, so a
"restart" flips a sandbox file — no live unit is touched — and escalation runs
`send-notification.sh` with an empty `GOTIFY_TOKEN` so it never hits the
network. Prefer a dedicated test box over a live multi-tenant host regardless.

The pure-function harness (`src_fn` in `lib.sh`) sources everything up to the
`# HARNESS_ENTRY_POINT` sentinel in `lunarwing-self-heal.sh` to unit-test
functions like `compute_backoff` in isolation; if you move that sentinel, the
harness fails loudly with a pointer to fix it.

Requirements: `bash` + `jq` (everywhere), and `flock` for the locking test
(skipped gracefully if absent). The OpenRC and per-unit-timeout tests skip
gracefully when `timeout` is unavailable.
