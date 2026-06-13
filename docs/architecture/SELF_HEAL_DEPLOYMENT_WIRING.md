# Infrastructure Self-Healing — Deployment & Provisioning Wiring

**Date:** 2026-06-13
**Status:** Reference (as-is) — documents current behavior, not a proposal
**Related:** `ic-infrastructure-health-check/README.md`, `docs/ops/MULTITENANCY-PRODUCTION.md`, `docs/proposals/CHAOS_ENGINEERING_TEST_PLAN.md`

## Summary

The infrastructure health-check + self-heal pipeline (`ic-infrastructure-health-check/`)
is a **host-level** facility installed by a **separate, manual** step. It is
**not** part of tenant provisioning: creating a tenant with
`lunarwing-mt-admin.sh add-tenant` installs none of it. Once set up at the host
level it covers all tenants automatically (registry / init-scan discovery), so
it is intentionally a once-per-host concern, not a per-tenant one.

Two caveats matter in practice (see [Gaps](#known-gaps)):

1. The watchdog installer **copies** the self-heal scripts but does **not
   schedule** them; there is no shipped health-check timer unit.
2. Therefore a freshly provisioned host has self-healing **dormant** until
   someone separately installs the watchdog *and* schedules the health cron.

## Two distinct "watchdogs" (don't conflate them)

| | Service-level watchdog | Infrastructure self-heal |
|---|---|---|
| Code | `ic/scripts/lunarwing-watchdog*.sh` | `ic-infrastructure-health-check/lunarwing-self-heal.sh` |
| Scope | Restarts the base `lunarwing.service` if down | Reads health-check reports, remediates any unhealthy component/unit (incl. per-tenant), with grace / backoff / flap-guard / escalation |
| Scheduled by | `lunarwing-watchdog.timer` (enabled by the installer) | **Nothing by default** — see Gaps |
| Unit | `ic/systemd/lunarwing-watchdog.{service,timer}`; `ExecStart=/usr/local/sbin/lunarwing-watchdog` | (no shipped unit) |

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

`ic/scripts/install-lunarwing-watchdog.sh` (run as root, **once per host**;
auto-detects systemd / OpenRC / launchd) is the only installer that touches the
self-heal pieces. On systemd it:

- installs + `enable --now`s `lunarwing-watchdog.timer` and the
  `lunarwing-watchdog.service` → `/usr/local/sbin/lunarwing-watchdog`
  (the **service-level** watchdog), and
- *conditionally* (the "D-1" block) copies the self-heal pieces into place:
  - `lunarwing-self-heal.sh` → `/usr/local/sbin/lunarwing-self-heal`
  - `cron-wrapper.sh`        → `/usr/local/sbin/lunarwing-health-cron`

The OpenRC path mirrors this. **Note what is absent:** the installer does not
create or enable any timer/cron for `lunarwing-health-cron`. The watchdog timer
it enables runs `/usr/local/sbin/lunarwing-watchdog`, i.e. the service-level
watchdog — not the health → self-heal pipeline.

Scheduling `cron-wrapper.sh` is a **manual** step, documented in
`ic-infrastructure-health-check/README.md` ("Cron / Timer Setup": a user-level
systemd timer, an hourly `cron.hourly` drop-in, or a crontab line).

## Multi-tenant provisioning does NOT install it

`lunarwing-mt-admin.sh add-tenant <name>` performs exactly these steps
(`add_tenant()`):

1. Allocate a port block (registry)
2. Create the tenant OS user
3. Clone the tenant repo
4. Write env files (lunarwing / bridge / proxy / gotify)
5. Start the per-tenant PostgreSQL container
6. Render the per-tenant init units (`lunarwing-<name>`, `xmpp-bridge-<name>`,
   `lunarwing-proxy-<name>`, weechat adapter, …)

Neither `lunarwing-mt-admin.sh` nor `ic/scripts/setup-instance.sh` references
`watchdog`, `self-heal`, `health-check`, or `cron-wrapper`. Tenant lifecycle and
host-level self-healing are deliberately separate concerns.

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

Self-healing is **off** until a host operator, **once**, does both:

1. `sudo ic/scripts/install-lunarwing-watchdog.sh` — installs the service-level
   watchdog and drops the self-heal / health-cron scripts into `/usr/local/sbin`.
2. Schedules `cron-wrapper.sh` (the health → self-heal loop) on a timer/cron per
   the health-check README.

After that, every current and future tenant on the host is covered automatically;
adding or removing tenants requires no self-heal changes.

## Known gaps

- **G1 — self-heal installed but not scheduled.** `install-lunarwing-watchdog.sh`
  copies `lunarwing-self-heal` and `lunarwing-health-cron` to `/usr/local/sbin`
  but enables no timer for them, and the repo ships no health-check
  `.timer`/`.service` unit. Running the installer alone leaves the pipeline
  dormant. A follow-up could ship a `lunarwing-health-check.{service,timer}`
  (calling `lunarwing-health-cron`) and have the installer enable it.
- **G2 — no provisioning hook.** There is no `mt-admin` flag (e.g.
  `--with-self-heal`) or host-bootstrap step that runs the watchdog installer, so
  the host-level setup is easy to forget when standing up a new MT box.

These are recorded as observations, not commitments.
