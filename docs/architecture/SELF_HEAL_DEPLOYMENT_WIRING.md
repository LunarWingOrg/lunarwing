# Infrastructure Self-Healing — Deployment & Provisioning Wiring

**Date:** 2026-06-13 (updated 2026-07-09)
**Status:** Reference (as-is) — documents current behavior, not a proposal
**Related:** `ic-infrastructure-health-check/README.md`, `docs/ops/MULTITENANCY-PRODUCTION.md`, `docs/internal/history/proposals/CHAOS_ENGINEERING_TEST_PLAN.md`

## Summary

The infrastructure health-check + self-heal pipeline (`ic-infrastructure-health-check/`)
is a **host-level** facility that covers all tenants automatically (registry /
init-scan discovery). As of v1.1.9, `lunarwing-mt-admin.sh add-tenant` calls
`ensure_health_pipeline()` which installs the pipeline scripts, writes a config
env file, and schedules the pipeline (systemd timer or OpenRC cron) in one step.
It can be opted out with `--no-health`.

The watchdog installer (`install-lunarwing-watchdog.sh`) is a separate,
manually-run host-level step focused on the **service-level watchdog** (restarts
`lunarwing.service` if down). It also copies the self-heal scripts into
`/usr/local/sbin` but does **not** schedule them — that scheduling is now handled
by the `add-tenant` `ensure_health_pipeline()` flow.

## Two distinct "watchdogs" (don't conflate them)

| | Service-level watchdog | Infrastructure self-heal |
|---|---|---|
| Code | `ic/scripts/lunarwing-watchdog*.sh` | `ic-infrastructure-health-check/lunarwing-self-heal.sh` |
| Scope | Restarts the base `lunarwing.service` if down | Reads health-check reports, remediates any unhealthy component/unit (incl. per-tenant), with grace / backoff / flap-guard / escalation |
| Scheduled by | `lunarwing-watchdog.timer` (enabled by the installer) | `lunarwing-mt-health.timer` / managed cron (scheduled by `add-tenant` via `ensure_health_pipeline()`) |
| Unit | `ic/systemd/lunarwing-watchdog.{service,timer}`; `ExecStart=/usr/local/sbin/lunarwing-watchdog` | `lunarwing-mt-health.{service,timer}` (systemd) or managed fcron/crontab entry (OpenRC) |

The self-heal pipeline is the subject of the chaos test suite in
`ic-infrastructure-health-check/tests/`.

## The health → self-heal pipeline

`cron-wrapper.sh` is the entry point that runs the full loop:

```
cron-wrapper.sh
  ├── infrastructure-health-check.sh   → writes JSON report to
  │       $LUNARWING_BASE_DIR/workspace/reports/health/<ts>.json
  │       (runs health-{gateway,xmpp,…}.sh + health-{systemd,openrc,launchd}.sh)
  └── lunarwing-self-heal.sh            → reads the latest report, remediates
```

Health-check failures don't abort the run — `cron-wrapper.sh` always proceeds to
self-heal so a partial report can still drive remediation.

## How it actually gets onto a host

There are two installation paths:

### Path 1: `mt-admin.sh add-tenant` (primary, automatic)

`lunarwing-mt-admin.sh add-tenant <name>` calls `ensure_health_pipeline()` as part
of tenant provisioning (unless `--no-health` is passed). This function:

1. Copies the pipeline scripts from `ic-infrastructure-health-check/` to a stable
   lib dir (`$HEALTH_LIB_DIR`) that survives repo/worktree moves.
2. Creates the host-level report/state dir.
3. Writes a config env file (`/etc/lunarwing/health.env`, mode 0600) if absent —
   includes `LUNARWING_BASE_DIR`, `LUNARWING_SERVICE_MANAGER`, tenant registry
   path, and MT-hardening flags. If the file already exists, only the
   `LUNARWING_SERVICE_MANAGER` line is reconciled (preserving operator edits).
4. Writes a launcher script that sources the env file and execs `cron-wrapper.sh`.
5. Schedules the launcher:
   - **systemd**: installs + enables `lunarwing-mt-health.{service,timer}`
     (default: every 15 min, configurable via `LUNARWING_MT_HEALTH_INTERVAL_MIN`).
   - **OpenRC**: installs a managed `fcron`/`crontab` entry (managed block).

Because the pipeline is host-global and auto-discovers tenants, the scheduling
is idempotent — subsequent `add-tenant` calls re-run `ensure_health_pipeline()`
without duplicating the schedule.

### Path 2: `install-lunarwing-watchdog.sh` (manual, complementary)

`ic/scripts/install-lunarwing-watchdog.sh` (run as root, **once per host**;
auto-detects systemd / OpenRC / launchd) is the installer for the **service-level
watchdog**. On systemd it:

- installs + `enable --now`s `lunarwing-watchdog.timer` and the
  `lunarwing-watchdog.service` → `/usr/local/sbin/lunarwing-watchdog`
  (the **service-level** watchdog), and
- *conditionally* (the "D-1" block) copies the self-heal pieces into place:
  - `lunarwing-self-heal.sh` → `/usr/local/sbin/lunarwing-self-heal`
  - `cron-wrapper.sh`        → `/usr/local/sbin/lunarwing-health-cron`

The OpenRC path mirrors this. **Note:** the watchdog installer does **not**
create or enable a timer for the health-cron — that scheduling is now handled by
the `add-tenant` `ensure_health_pipeline()` flow (Path 1 above). On hosts where
`add-tenant` hasn't run, scheduling `cron-wrapper.sh` remains a **manual** step
documented in `ic-infrastructure-health-check/README.md`.

## Multi-tenant provisioning now installs it

`lunarwing-mt-admin.sh add-tenant <name>` calls `ensure_health_pipeline()` as
the final step of tenant provisioning (unless `--no-health` is passed). The full
`add_tenant()` flow:

1. Allocate a port block (registry)
2. Create the tenant OS user
3. Clone the tenant repo
4. Write env files (lunarwing / bridge / proxy / gotify)
5. Start the per-tenant PostgreSQL container
6. Render the per-tenant init units (`lunarwing-<name>`, `xmpp-bridge-<name>`,
   `lunarwing-proxy-<name>`, weechat adapter, …)
7. **Call `ensure_health_pipeline()`** — installs + schedules the host-global
   health-check → self-heal pipeline (covers all tenants automatically).

`ic/scripts/setup-instance.sh` (the deprecated single-instance helper) does not
reference the health pipeline — it predates the MT integration.

## Coverage model — one host install covers all tenants

Self-heal is host-wide and discovers tenants on its own, so it should **not** be
installed per tenant:

- **systemd:** `health-systemd.sh` probes per-tenant *user* units by reading the
  tenant registry (`ports.json`) and querying each tenant user's `--user` bus.
- **OpenRC:** `health-openrc.sh` auto-discovers `lunarwing-*`, `xmpp-bridge-*`,
  and `lunarwing-proxy-*` services by scanning `/etc/init.d/` — no config needed
  (`docs/ops/MULTITENANCY-PRODUCTION.md` § Health Checks).
- **Remediation:** `lunarwing-self-heal.sh` maps each unhealthy unit back to its
  owning tenant via the registry and restarts it on that user's bus
  (`sudo -u <user> systemctl --user restart …`) or via `rc-service` on OpenRC.

## Net effect on a fresh MT host

When provisioning a tenant via `lunarwing-mt-admin.sh add-tenant` (the default,
no `--no-health`), the host-global health-check → self-heal pipeline is installed
and scheduled in one step: the operator does not need to separately schedule it.
The pipeline auto-discovers all current and future tenants, so adding or removing
tenants requires no self-heal changes.

The watchdog installer (`install-lunarwing-watchdog.sh`) remains a separate,
manually-run step for the **service-level watchdog** (restarts `lunarwing.service`
if down). It also copies the self-heal scripts but does not schedule them —
that is handled by `add-tenant`. On hosts that have not run `add-tenant` (e.g.
single-instance setups), the operator must schedule the pipeline manually per
`ic-infrastructure-health-check/README.md`.

## Historical gaps (resolved in v1.1.9)

The following gaps were documented before `ensure_health_pipeline()` was added
to `add-tenant`:

- **G1 — self-heal installed but not scheduled.** `install-lunarwing-watchdog.sh`
  copies `lunarwing-self-heal` and `lunarwing-health-cron` to `/usr/local/sbin`
  but enables no timer for them. **Resolved:** `add-tenant` now calls
  `ensure_health_pipeline()` which schedules the pipeline via systemd timer
  or OpenRC cron.
- **G2 — no provisioning hook.** There was no `mt-admin` flag or host-bootstrap
  step that ran the watchdog installer or scheduled the health pipeline.
  **Resolved:** `add-tenant` now calls `ensure_health_pipeline()` automatically;
  `--no-health` can opt out.
