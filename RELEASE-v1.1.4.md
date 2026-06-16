# Release Notes for LunarWing v1.1.4 — Codename `Phoenix`

**Release Date:** TBD

> Codename *Phoenix*

## Overview

Per the release cadence (`docs/ops/RELEASE_CADENCE.md`), **even-numbered releases focus on features** — and v1.1.4 is a major feature release. Its centerpiece: the infrastructure **self-healing** system graduates from the long-standing v1.1.2 / v1.1.3 *Known Issue* — *"installed but dormant, not wired into provisioning, verified only by dry-run + unit tests"* — to **live, multi-tenant-aware, and enabled by default**. Bringing it up against real running services on a **Gentoo / OpenRC / Podman** multi-tenant host surfaced (and fixed) three real self-heal bugs that the mock-init test suite could never catch.

The second pillar is first-class **multi-tenant support on Gentoo / OpenRC / Podman**: the admin script now provisions, boot-persists, and self-heals tenants on a daemonless-container, non-systemd host — validated end-to-end including a real reboot.

This release directly closes the self-healing wiring gaps (G1/G2) and the "not validated against live services" caveat carried since v1.1.2, **for the OpenRC path**.

---

## Changes

### Self-Healing Infrastructure — Live, Multi-Tenant-Aware, Enabled by Default

The health-check → self-heal pipeline (`ic-infrastructure-health-check/`) is now wired into the multi-tenant admin tool and active by default, instead of shipping dormant.

- **Baked into `lunarwing-mt-admin.sh`** — a new `ensure_health_pipeline()` runs from `add_tenant` (gated `DEFAULT_HEALTH_ENABLED=true`). It idempotently syncs the pipeline scripts to `/usr/local/lib/lunarwing-health/`, writes a host config at `/etc/lunarwing/health.env` (mode `0600`, write-if-absent), installs a `/usr/local/sbin/lunarwing-mt-health` launcher, and schedules it every 15 min via **fcron/cron** (managed block) while ensuring the cron daemon is in the default runlevel.
- **Host-global by design** — the pipeline auto-discovers every tenant from `/etc/init.d/` + the `/etc/lunarwing/ports.json` registry, so **one** install covers all current and future tenants. New tenants are picked up automatically; no per-tenant duplication.
- **Opt-out + teardown** — `--no-health` on `add-tenant`/`add-tenants`, or `LUNARWING_MT_HEALTH_ENABLED=false` fleet-wide; `remove_tenant` retires the schedule when the last tenant is removed. `doctor` gained checks (pipeline scripts present, `curl`/`flock`, schedule installed).
- **Validated live on a real multi-tenant host:**
  - *Recovery* — stopping a tenant service triggers grace → restart → post-restart verify → recovered (proven on the proxy, bridge, and main daemon).
  - *Escalation* — retries/flapping → `mark_escalated` → **Gotify page** → escalated state persisted → no re-page. The full escalate→persist→notify flow is exercised by the chaos harness running the **real** self-heal script against a fail-on-restart init, and Gotify delivery was confirmed live (HTTP 200, real notification received).
- This closes the v1.1.3 *Known Issues* **G1** (installed-but-not-scheduled) and **G2** (not wired into provisioning) on OpenRC, and replaces the "dry-run/unit-tests only" caveat with live validation (see *Known Issues* for the remaining systemd-path and live-demo caveats).

### Health-Check Multi-Tenant Hardening

So a single host-global run behaves correctly across tenants and only pages on actionable events — all changes are opt-in env toggles that **leave single-instance behavior and the test suite unchanged**, set by mt-admin in `health.env`:

- **`SELF_HEAL_REMEDY_LOGICAL=false`** — remediate only the auto-discovered **per-tenant init units**, not the single-instance "logical" components (`gateway`/`xmpp`/`tensorzero`/`clickhouse`) whose base service names don't exist under MT. (Without this, a failing logical probe tried to restart a nonexistent base service and escalated forever.)
- **`HEALTH_XMPP_SERVER` / `HEALTH_MODELS_ENABLED` / `HEALTH_OMEMO_ENABLED`** — disable probes that are environmentally N/A host-globally (the xmpp probe was hardcoded to one server; models needs provider API keys; omemo has no host-level store), reporting *healthy/disabled* instead of false degraded/critical.
- **`HEALTHCHECK_NOTIFY=false`** — suppress the orchestrator's per-run notification; page **only** on self-heal escalation. Prevents 15-minute notification spam from cosmetically-degraded components.
- **`SELF_HEAL_MAX_REPORT_AGE`** — refuse to act on a stale report if the scheduler stalls. `find_latest_report` also fixed (`sort | tail` instead of an `xargs ls -t` empty-dir foot-gun).

### Multi-Tenant on Gentoo / OpenRC / Podman

The admin script's OpenRC path is now hardened for a daemonless container runtime:

- **Postgres on boot** — because Podman has no daemon to honor `--restart unless-stopped` under OpenRC, each tenant daemon's generated init script brings up its `lunarwing-pg-<tenant>` container in `start_pre` (and waits for `pg_isready`) before launching; idempotent on Docker.
- **Boot persistence** — `start_tenant_openrc` auto-runs `rc-update add` for the services that actually started, so the stack returns after a reboot with no manual steps.
- **Non-fatal optional channels** — weechat + adapter are started non-fatally, so a missing `aiohttp`/`weechat` no longer aborts the core stack. (Also fixes the prior `start-tenant` abort behavior.)
- Validated end-to-end, including a **full system reboot** (all three tenants auto-recovered: containers revived by `start_pre`, services started from the runlevel, gateways healthy).

### HTTP Webhook Hardening

The per-tenant env generator (`write_tenant_lunarwing_env`) now sets **`HTTP_HOST=127.0.0.1`** (it previously defaulted to `0.0.0.0`, exposing the webhook on all interfaces) and a generated per-tenant **`HTTP_WEBHOOK_SECRET`**, so the `http` channel starts cleanly and binds localhost-only — matching the "all HTTP services bind 127.0.0.1" policy.

### Documentation & Housekeeping

- **New** — `docs/ops/MT-GENTOO-SETUP-AND-CHANGES-MADE.md` (full Gentoo/OpenRC/Podman bring-up record), `docs/guides/GENTOO_PACKAGE_LIST.md` (packages for a live MT env), `docs/proposals/MT-WEECHAT-CONSISTENCY-AND-CHANNEL-PRUNING.md`, `docs/ops/SELF_REPAIR_IMPROVEMENTS_GENTOO.md`, `docs/ops/GOALS_1.1.4.md` (pre-release checklist).
- **Updated** — `docs/guides/MT-ADMIN-QUICKSTART.md` (OpenRC/Podman: optional host rustup, WeeChat-only deps, OpenRC `start-tenant` caveat, Podman-Postgres reboot note, localhost webhook); `docs/ops/MULTITENANCY-PRODUCTION.md` (Podman reboot note); `docs/ops/ROADMAP_2026.MD` (re-prioritization); `RELEASE-v1.1.3.md` relocated to `docs/ops/`.

---

## Bug Fixes

All four self-heal bugs below were found via **live** bring-up/testing on a real OpenRC multi-tenant host; the first is real-world-only (the mock chaos harness never forks a real daemon), and the others were the root cause of the long-failing `CH6`/`CH9`/`CH12` chaos assertions.

- **Self-heal lock-fd leak — self-heal wedged after its first restart.** `main()` opened the single-instance flock as fd 200 with no close-on-exec, so a restarted service's long-lived `supervise-daemon` **inherited fd 200** and held the lock forever; every later run exited *"another self-heal instance is running."* Fixed by closing fd 200 for the restart dispatch and all its children (`200>&-`).
- **Escalation Gotify pages never sent.** `send-notification.sh` had three bugs: jq referenced `$report_file` without `--arg` (compile error → script exited, no page), `.components[]`/`.alerts[]` were emitted as bare streams instead of being `join`'d, and the JSON payload was hand-interpolated so the message's literal newlines produced invalid JSON Gotify rejected. Now: pass `--arg`, `join` the arrays, build the payload with jq, and check the HTTP status.
- **Escalated state never persisted (re-escalated every tick).** `escalate_service` runs inside `remediate_component`, whose stdout is captured as the returned state JSON; the notifier's stdout was prepended to that JSON, so the next `prune_state` jq aborted under `set -e` **before** `save_state`, discarding `escalated:true`. Fixed by redirecting the notifier's stdout to stderr and making it non-fatal.
- **OpenRC-fatal env-file corruption (latent on systemd).** `write_tenant_lunarwing_env` wrote `lunarwing.env` via an *unquoted* heredoc containing a literal backtick `env`, so the shell executed `env` at file-write time and injected the whole environment into the file; systemd's `EnvironmentFile=` tolerates the junk, but OpenRC's `. source` **executes** it → the daemon failed to start. Fixed by replacing the backticks.

> Net test impact: the infra health-check chaos suite went from 33/3 → **36/0**, and the overall self-heal suite is now **180 pass / 0 fail**. The previously-failing `A2`/`N1` exit-code assertions were a **test-harness** bug (the `run_raw` helper set `RC` inside a command-substitution subshell, so the caller read a stale value — self-heal's exit codes were already correct); fixed by returning the exit code from `run_raw` and capturing it at the call sites.

---

## Documentation

- `docs/ops/MT-GENTOO-SETUP-AND-CHANGES-MADE.md` — Gentoo/OpenRC/Podman setup record (prereqs, fixes, boot persistence, self-heal integration, gotchas, tenant inventory).
- `docs/guides/GENTOO_PACKAGE_LIST.md` — packages for a live MT env on Gentoo/OpenRC (core, Podman + `iptables[nftables]` USE, `fcron`, build toolchain notes, optional WeeChat).
- `docs/proposals/MT-WEECHAT-CONSISTENCY-AND-CHANNEL-PRUNING.md` — WeeChat service-consistency + WASM channel pruning proposal.
- `docs/ops/SELF_REPAIR_IMPROVEMENTS_GENTOO.md`, `docs/ops/GOALS_1.1.4.md` — Gentoo self-repair notes; v1.1.4 pre-release checklist.
- `docs/guides/MT-ADMIN-QUICKSTART.md`, `docs/ops/MULTITENANCY-PRODUCTION.md`, `docs/ops/ROADMAP_2026.MD` — OpenRC/Podman updates and re-prioritization.

---

## Known Issues (not a complete list — see `docs/bugs` and `docs/proposals` for more)

- **Carried forward from v1.1.3** (see `docs/ops/RELEASE-v1.1.3.md`): XMPP inbound file transfer awaits live e2e validation and has no SSRF guard; the Multica bridge remains pre-release/experimental; the `/api/logs/download` endpoint has no UI button yet; and the `e2e_advanced_traces` bootstrap-greeting tests remain among the pre-existing env-dependent e2e failures.

---

## Upgrade Notes

1. **No new database migrations.** v1.1.4 adds no schema changes; existing migrations still run automatically on first startup. Back up your database before upgrading as a matter of course.
2. **Crate version bump to 1.1.4.** Per `docs/ops/GOALS_1.1.4.md`, bump the workspace + WASM channel crate versions from 1.1.3 → 1.1.4 as part of cutting the release.
3. **New host dependency for the health schedule (OpenRC).** A cron daemon is required for the self-heal schedule — `sys-process/fcron` (or `cronie`/`dcron`). See `docs/guides/GENTOO_PACKAGE_LIST.md` for the full package set.
4. **Self-healing is enabled by default for NEW tenants on OpenRC.** Existing deployments adopt it on the next `add-tenant`, or by running `ensure_health_pipeline` once. Opt out with `--no-health` (per tenant) or `LUNARWING_MT_HEALTH_ENABLED=false` (fleet). The pipeline pages **only on escalation** (`HEALTHCHECK_NOTIFY=false`). Put the Gotify URL/token in `/etc/lunarwing/health.env` (mode `0600`) — it is never committed to the repo. As this is a BRAND new feature, please take appropriate caution.
5. **Port schema v6 (from v1.1.3) still applies** — additive and non-disruptive; back up `/etc/lunarwing/ports.json` and dry-run on a copy before applying.

---

## Features and changes deferred to future releases

The full, canonical list lives in **`docs/ops/ROADMAP_2026.MD`** and respects the release cadence. Near-term highlights:

| Feature | Target |
|---------|--------|
| XMPP OMEMO MUC fallback fix | v1.1.5 |                                                                                        
| XMPP file transfer — remaining polish (live end-to-end validation, optional SSRF guard, further round of hardening) | v1.1.5 |
| Lunarvision K.E.R.S. system setup polishing | v1.1.5 |
| External Worker planned enhancements | v1.1.6 |
| Multica bridge and channel refinements and agent orchestration workflow improvements | v1.1.6 |
| Lunartica UI reskin | v1.1.6 |

---

## Release Cadence

*A brief note about release cadence.* LunarWing abides by a release cadence to organize `feature` and `polish` focused releases — even-numbered releases (like this one) focus on features. For details see `docs/ops/RELEASE_CADENCE.md`. Occasionally exceptions are made, but the goal is to stay within this paradigm.

## Testing

*In accordance with developer guidelines, a testing period precedes each release.*

*Testing for this release has **commenced**. The v1.1.4 pre-release checklist lives in `docs/ops/GOALS_1.1.4.md`; the full checklist is in `docs/ops/PRE-RELEASE-TESTING.md`; automated coverage is driven by `ic/scripts/release-test.sh` and `docs/guides/TESTING_GUIDE.md`. The health-check/self-heal work was tested live on a real OpenRC multi-tenant host (recovery, escalation, reboot, Gotify); the broader automated release-test sweep and the crate-version bump remain open checklist items.

*Once evaluation begins, no new changes besides urgent fixes will be accepted into staging during the evaluation period.*

