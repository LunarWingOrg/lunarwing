# LunarWing Infrastructure Health Check System

## Updated June 5 2026

Automated health monitoring and self-healing for LunarWing/IronClaw infrastructure.

## Architecture

```
cron-wrapper.sh
  +-- infrastructure-health-check.sh   (parallel checks -> JSON report)
  |     +-- health-gateway.sh          (WebSocket gateway)
  |     +-- health-xmpp.sh             (XMPP bridge)
  |     +-- health-omemo.sh            (OMEMO encryption)
  |     +-- health-ratelimit.sh        (rate limiting)
  |     +-- health-clickhouse.sh       (ClickHouse DB)
  |     +-- health-tensorzero.sh       (TensorZero proxy)
  |     +-- health-models.sh           (LLM provider APIs)
  |     +-- health-{systemd,openrc,launchd}.sh  (service manager)
  |
  +-- lunarwing-self-heal.sh           (reads report -> restarts -> escalates)
        +-- send-notification.sh       (Gotify push notifications)
```

## Dependencies

### Required

| Dependency | Purpose | Install |
|------------|---------|---------|
| bash >= 4.0 | Associative arrays, mapfile, extended globbing | Pre-installed on most systems |
| jq | JSON parsing and generation | apt install jq / brew install jq / apk add jq |
| curl | HTTP health checks, Gotify notifications | Pre-installed on most systems |

### Optional (per-check)

| Dependency | Used by | Install |
|------------|---------|---------|
| systemctl | health-systemd.sh | Pre-installed on systemd systems |
| rc-service | health-openrc.sh | Pre-installed on OpenRC systems |
| launchctl | health-launchd.sh | Pre-installed on macOS |
| clickhouse-client | health-clickhouse.sh, health-tensorzero.sh | ClickHouse docs |
| nc (netcat) | health-xmpp.sh (port check fallback) | apt install netcat-openbsd / brew install netcat |
| nvidia-smi | health-tensorzero.sh (GPU metrics) | NVIDIA driver package |
| flock | lunarwing-self-heal.sh (concurrent run guard) | util-linux package (pre-installed on most Linux) |

### Not required (replaced)

| Previously needed | Replaced by |
|-------------------|-------------|
| bc | awk for float comparisons in health-tensorzero.sh |

## Quick Start

```bash
# 1. Make scripts executable
chmod +x ic-infrastructure-health-check/*.sh

# 2. Run manually (dry-run self-heal)
cd ic-infrastructure-health-check
./infrastructure-health-check.sh
./lunarwing-self-heal.sh --dry-run

# 3. Schedule recurring runs — see "Cron / Timer Setup" below
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| LUNARWING_BASE_DIR | $HOME/.lunarwing | Base directory for LunarWing data |
| IRONCLAW_BASE_DIR | $HOME/.ironclaw | Fallback base directory |
| GOTIFY_URL | http://localhost:3000 | Gotify server URL |
| GOTIFY_TOKEN | (empty) | Gotify app token (empty = skip notifications) |
| OPENROUTER_API_KEY | (empty) | OpenRouter API key for model health checks |
| OPENAI_API_KEY | (empty) | OpenAI API key |
| ANTHROPIC_API_KEY | (empty) | Anthropic API key |
| RATELIMIT_DIR | auto-detected | Rate limit session directory |

## Report Output

Reports are saved to $LUNARWING_BASE_DIR/workspace/reports/health/ as:
- YYYY-MM-DDTHH:MM:SSZ.json — full machine-readable report
- YYYY-MM-DDTHH:MM:SSZ-summary.md — human-readable summary

Old reports are automatically rotated after 7 days.

## Self-Healing

The self-heal script reads the latest health report and:

1. Maps unhealthy components to init services (e.g., gateway -> lunarwing), and
   resolves per-tenant units to the owning OS user (multi-tenant).
2. Waits for a **grace period** (N consecutive unhealthy checks) before acting,
   then restarts and **verifies** recovery by re-running the component's health check.
3. On repeated failure, spaces retries with **exponential backoff + jitter**
   (`linear` toggle available); a **flapping** service is escalated, not looped.
4. Escalates via Gotify notification after max retries (or on flapping).
5. Tracks state in `$LUNARWING_BASE_DIR/workspace/reports/health/state.json`,
   clears services the report says are healthy, and auto-prunes stale entries.

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

### Tuning (flags / env vars)

| Flag | Env var | Default | Description |
|------|---------|---------|-------------|
| `--max-retries N` | `SELF_HEAL_MAX_RETRIES` | 3 | Restart attempts before escalation |
| `--backoff N` | `SELF_HEAL_BACKOFF_SECONDS` | 5 | Fixed in-run settle wait before verifying |
| `--backoff-base N` | `SELF_HEAL_BACKOFF_BASE` | 60 | Backoff base delay (1st retry) |
| `--backoff-max N` | `SELF_HEAL_BACKOFF_MAX` | 3600 | Backoff ceiling |
| `--backoff-strategy S` | `SELF_HEAL_BACKOFF_STRATEGY` | exponential | `exponential` (full jitter) or `linear` |
| `--grace-checks N` | `SELF_HEAL_GRACE_CHECKS` | 2 | Consecutive unhealthy checks before first restart |
| `--prune-ttl S` | `SELF_HEAL_STATE_PRUNE_TTL` | 86400 | Prune non-escalated entries older than this; 0 disables |
| `--verify-health B` | `SELF_HEAL_VERIFY_HEALTH` | true | Re-run the component health check after a restart |
| — | `SELF_HEAL_FLAP_MAX_RESTARTS` | 5 | Restarts within the window that mark a service flapping |
| — | `SELF_HEAL_FLAP_WINDOW_SECS` | 3600 | Flapping detection window (seconds) |
| — | `SELF_HEAL_TENANTS_FILE` | /etc/lunarwing/ports.json | Multi-tenant registry for per-tenant remediation |

> **Backoff is a cross-tick gate**, not an in-run sleep: a failed service's
> `next_attempt_at` is pushed out by `compute_backoff`, so the run never blocks
> and a flapping service is retried less often. The grace period is counted in
> *observations* (self-heal runs once per ~30-min health-check tick).

> **Multi-tenant:** run as root with the registry present and self-heal remediates
> per-tenant units — `rc-service lunarwing-<tenant>` on OpenRC, and
> `sudo -u <user> systemctl --user restart lunarwing-<tenant>.service` for systemd
> user units. `health-systemd.sh` discovers those per-tenant units the same way.

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
> (auto-detects systemd/OpenRC/launchd).

### crontab (fallback)

```bash
# Run every 30 minutes
*/30 * * * * /path/to/ic-infrastructure-health-check/cron-wrapper.sh
```

### launchd (macOS)

Create a plist in ~/Library/LaunchAgents/ pointing to cron-wrapper.sh.

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | All components healthy |
| 1 | One or more components degraded |
| 2 | One or more components critical |

## Testing & Chaos Suite

The self-heal watchdog has a test suite under `tests/` (see
`docs/proposals/CHAOS_ENGINEERING_TEST_PLAN.md` for the full matrix):

```bash
cd ic-infrastructure-health-check
bash tests/run-all.sh                 # regression + unit matrix + chaos
bash tests/run-all.sh matrix chaos    # pick suites: regression | matrix | chaos
bash tests/test-self-heal-matrix.sh   # dry-run unit matrix (A1–N3)
bash tests/chaos-harness.sh           # end-to-end fault-injection scenarios
```

| Suite | What it does |
|-------|--------------|
| `test-self-heal.sh` | Original regression checks (jq precedence, backoff, grace, flapping, …). |
| `test-self-heal-matrix.sh` | The full A–N matrix in `--dry-run` against synthetic reports. ~115 assertions. |
| `chaos-harness.sh` | Drives the **real** self-heal loop (kill → restart → verify → recover/escalate) against a mock init system. |
| `lib.sh` | Shared harness + the mock init system (sourced, not run directly). |

**Safety.** The matrix is dry-run only and never triggers a real restart or the
real HTTP/component health probes. The chaos harness runs self-heal for real but
against a *mock* `systemctl`/`rc-service`/`sudo` shadowed onto `PATH`, so a
"restart" flips a sandbox file — no live unit is touched — and escalation runs
`send-notification.sh` with an empty `GOTIFY_TOKEN` so it never hits the network.
Prefer a dedicated test box over a live multi-tenant host regardless.

Requirements: `bash` + `jq` (everywhere), and `flock` for the locking test
(skipped gracefully if absent).
