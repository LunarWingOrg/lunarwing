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

1. Maps unhealthy components to init services (e.g., gateway -> lunarwing)
2. Attempts restart (max 3 retries by default)
3. Applies fixed backoff between retries
4. Escalates via Gotify notification after max retries
5. Tracks state in $LUNARWING_BASE_DIR/workspace/reports/health/state.json

```bash
# Test without restarting anything
./lunarwing-self-heal.sh --dry-run

# Custom retry limit and backoff
./lunarwing-self-heal.sh --max-retries 5 --backoff 60

# Point at a specific report
./lunarwing-self-heal.sh --report /path/to/report.json
```

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
