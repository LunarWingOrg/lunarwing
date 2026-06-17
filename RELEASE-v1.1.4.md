# Release Notes for LunarWing v1.1.4 — Codename `Phoenix`

**Release Date:** TBD

> Codename *Phoenix*

## Overview

Per the release cadence (`docs/ops/RELEASE_CADENCE.md`), **even-numbered releases focus on features** — and v1.1.4 is a major feature release. Its centerpiece: the infrastructure **self-healing** system graduates from the long-standing v1.1.2 / v1.1.3 *Known Issue* — *"installed but dormant, not wired into provisioning, verified only by dry-run + unit tests"* — to **live, multi-tenant-aware, and enabled by default**.

The second pillar is **multi-tenant supervision parity across both init systems**. v1.1.4 lands first-class multi-tenancy on **Gentoo / OpenRC / Podman** *and* brings the **systemd / rootless-Podman** path up to parity: per-tenant Postgres and worker containers are now supervised (OpenRC service units, or systemd **Quadlet** `.container` units), boot-persistent, health-monitored, and self-healed on both inits. Bringing the pipeline up against real running services surfaced (and fixed) several self-heal bugs that the mock-init test suite could never catch.

The third pillar is **operational hardening of the multi-tenant fleet**: per-tenant random PostgreSQL passwords (replacing the shared default), `pg_dump`/`pg_restore` backup/restore verbs, localhost-only HTTP webhook binding, and a set of opt-in health-check toggles so a single host-global run behaves correctly across tenants and pages only on actionable events.

This release closes the self-healing wiring gaps (**G1/G2**) and the *"not validated against live services"* caveat carried since v1.1.2, **on both the OpenRC and the systemd paths**.

---

## Changes

### Self-Healing Infrastructure — Live, Multi-Tenant-Aware, Enabled by Default

The health-check → self-heal pipeline (`ic-infrastructure-health-check/`) is now wired into the multi-tenant admin tool and active by default, instead of shipping dormant — **on both OpenRC and systemd**.

- **Baked into `lunarwing-mt-admin.sh`** — a new `ensure_health_pipeline()` runs from `add-tenant`/`add-tenants` (gated `DEFAULT_HEALTH_ENABLED=true`). It idempotently syncs the pipeline scripts to `/usr/local/lib/lunarwing-health/`, writes a host config at `/etc/lunarwing/health.env` (mode `0600`, write-if-absent), installs a `/usr/local/sbin/lunarwing-mt-health` launcher, and schedules it every 15 min. The schedule mechanism branches on the init system: **fcron/cron** (managed block, cron daemon ensured in the default runlevel) on OpenRC, or a system-level **`lunarwing-mt-health.timer`** (`OnCalendar=*:0/N`, `OnBootSec=5min`, `Persistent=true`) on systemd, installed by `_install_health_systemd_timer()`.
- **Host-global by design** — the pipeline auto-discovers every tenant from `/etc/init.d/` (OpenRC) or `systemctl --user list-unit-files` (systemd) plus the `/etc/lunarwing/ports.json` registry, so **one** install covers all current and future tenants. New tenants are picked up automatically; no per-tenant duplication.
- **Opt-out + teardown** — `--no-health` on `add-tenant`/`add-tenants`, or `LUNARWING_MT_HEALTH_ENABLED=false` fleet-wide; `remove-tenant` retires the schedule when the last tenant is removed. `doctor` gained checks for both inits (pipeline scripts present, `curl`/`flock`, the cron schedule **or** `systemctl is-enabled lunarwing-mt-health.timer`, and Podman ≥ 4.6 / linger readiness on systemd).
- **Validated live on a real multi-tenant host:**
  - *Recovery* — stopping a tenant service triggers grace → restart → post-restart verify → recovered (proven on the proxy, bridge, main daemon, and rootless Postgres container).
  - *Escalation* — retries/flapping → `mark_escalated` → **Gotify page** → escalated state persisted → no re-page. The full escalate→persist→notify flow is exercised by the chaos harness running the **real** self-heal script against a fail-on-restart init, and Gotify delivery was confirmed live (HTTP 200, real notification received).
- This closes the v1.1.3 *Known Issues* **G1** (installed-but-not-scheduled) and **G2** (not wired into provisioning), and replaces the "dry-run/unit-tests only" caveat with live validation (see *Known Issues* for remaining gaps).

### systemd Multi-Tenant Parity — Quadlet Supervision, Health Scheduling, Remediation

The v1.1.3 *Known Issue* singled out the **systemd path** as the remaining gap. v1.1.4 closes it. The full systemd MT-parity workstream (WS1–WS4) and its fold-ins (A–D) are merged (see `docs/proposals/MT_SYSTEMD_PARITY.md`).

- **Quadlet `.container` supervision for rootless Postgres + workers (WS2)** — per-tenant Postgres and `nanocode`/`pebble` worker containers are now supervised via Quadlet `.container` units under `~/.config/containers/systemd/` on systemd + rootless Podman (new `render_pg_quadlet()`, `render_worker_quadlet()`, `podman_supports_quadlet()` with a ≥ 4.6 floor, `_wait_user_manager()`). Quadlet owns container creation on this path; the rootful-Docker and OpenRC paths are unchanged. The main daemon's `Requires=`/`After=` is wired to `lunarwing-pg-<tenant>.service` where a Quadlet exists, and boot persistence comes from `[Install] WantedBy=default.target` + linger.
- **Restart policy + crash-loop guard (WS2 follow-up)** — PG/worker Quadlets use `Restart=on-failure` (respects graceful `podman stop` rather than fighting it) with `StartLimitIntervalSec=300` / `StartLimitBurst=5`, mirroring OpenRC's `respawn_max`/`respawn_period`. A crash-looping container lands in `failed` for the health sweep + escalation backstop.
- **Broadened systemd health discovery (WS3)** — `health-systemd.sh` now mirrors the OpenRC discovery breadth: it enumerates **all** per-tenant `lunarwing-*` / `xmpp-bridge-*` / `lunarwing-weechat-*` user units (PG, workers, proxy, weechat + adapter, daemon, Quadlet-generated units) with bounded probes (`timeout -k 2 5`) and a container health probe (`podman inspect … .State.Health.Status`) that catches running-but-wedged containers. Base system-level units are existence-gated so MT hosts don't emit phantom criticals.
- **Self-heal systemd remediation parity (WS4)** — `unit_tenant()` strips service-type infixes (`pg`/`nanocode`/`pebble`/`weechat-adapter`/`weechat`) so `lunarwing-pg-<t>` resolves to `<t>`; the restart path runs `reset-failed` before `restart` to recover start-limited units; user-scoped helpers use `sudo -n -u` (non-interactive in timer context); and restart banners are redirected to stderr so they can't corrupt the captured state JSON.
- **Status/doctor symmetry (fold-in C)** — `status-tenant` now shows PG + worker (+ weechat/adapter) rows on **both** inits, and `doctor` gained the systemd health-timer, Podman ≥ 4.6, and per-tenant linger / `/run/user` checks.

### Rootless Podman — Per-Tenant Postgres & Workers (OpenRC)

The OpenRC path moves from rootful, root-owned containers to **rootless per-user** containers with dedicated supervised units (`docs/proposals/ROOTLESS_WORKER_OPENRC_UNITS.md`):

- **Rootless Postgres (Stage A)** — new `MT_ROOTLESS` flag (default `true` for Podman, `false` for Docker; override via `LUNARWING_MT_ROOTLESS`), a `_ctr()` helper that runs container ops as the tenant user (`HOME`/`XDG_RUNTIME_DIR` set), and `ensure_rootless_prereqs()` for idempotent subuid/subgid allocation, runtime-dir creation, and `podman system migrate`. Each tenant gets a dedicated `lunarwing-pg-<t>` OpenRC unit and a **named** data volume `lunarwing-pg-<t>:/var/lib/postgresql/data` (fixing the prior no-volume gap). Linger gating is now capability-based (`command -v loginctl`) for OpenRC + elogind.
- **Rootless workers (Stage A.2)** — `nanocode`/`pebble` worker ops route through `_ctr()`, and `_ensure_tenant_image()` distributes root-store images into each tenant's rootless store via `podman save | load`.
- **Workers promoted to OpenRC services** — `lunarwing-nanocode-<t>` / `lunarwing-pebble-<t>` units (modeled on the PG unit) with a health-aware `status()` that checks both *container running* and the `/health` endpoint, so workers are now boot-enabled, health-monitored, and self-healed.
- **Automatic boot persistence** — each tenant daemon's generated init script brings up its `lunarwing-pg-<t>` container in `start_pre` (waiting on `pg_isready`) before launching, and `start-tenant` auto-runs `rc-update add … default` for the services that actually started — so the stack returns after a reboot with **no manual steps**. (This supersedes the standalone `lunarwing-pg.openrc` boot service, now removed.)
- **Non-fatal optional channels** — weechat + adapter start non-fatally, so a missing `aiohttp`/`weechat` no longer aborts the core stack.

### Worker Quadlet / Unit Hardening

- **Health checks for worker Quadlets** — `render_worker_quadlet()` now emits `HealthCmd` (curl against the worker's `/health` port), `HealthInterval=15s`, `HealthTimeout=5s`, `HealthRetries=3`, `HealthStartPeriod=30s`, bringing workers to parity with the PG Quadlet so a *dead agent inside a running container* is detected.
- **`TimeoutStartSec=120`** so cold image pulls don't trip the systemd default (90 s), and **`KillMode=process`** so the container's own children shut down cleanly (orphaned temp-file cleanup).
- **IPv4 loopback** — the worker `HealthCmd` uses `http://127.0.0.1:<port>/health` (not `localhost`) to avoid an IPv6 (`::1`) resolution miss when the worker binds IPv4-only.
- **Graceful stop** — `--time 30` on both `_wk stop` and `_pg stop`, granting containers 30 s to drain on SIGTERM before SIGKILL. (Rationale: `docs/proposals/SYSTEMD_QUADLET_IMPROVEMENTS.md`.)

### Per-Tenant PostgreSQL Secrets & Backup/Restore

- **Per-tenant random passwords (fold-in B)** — replaces the shared fixed PG password `lunarwing` with per-tenant random hex sourced from a `0600` tenant-owned `env/pg.secret` (generated once, reused for restart stability). **Migration-safe**: an already-initialized tenant's password is preserved (parsed from `DATABASE_URL`); only fresh tenants get a random one. The password is passed via a transient `0600 --env-file` (never on `/proc/<pid>/cmdline`). New **`rotate-pg-password <name>`** verb performs an `ALTER ROLE` over the container socket and updates `pg.secret` + `DATABASE_URL`.
- **Backup/restore verbs (fold-in D)** — `backup-tenant <name>` / `backup-all` (`pg_dump -Fc`, atomic `.partial`+rename, `umask 077`, prune to `LUNARWING_MT_BACKUP_KEEP` most-recent, default 7), `list-backups [name]`, and `restore-tenant <name> <file> --yes` (`pg_restore --single-transaction --clean --if-exists`). Restore is **destructive** and fail-closed: it requires `--yes`, a `PGDMP`-header preflight, a running PG container, and verification that the tenant daemon is stopped. Backups are root-owned `0600` in a `0700` dir; init- and runtime-agnostic (via `_ctr`).

### Health-Check Multi-Tenant Hardening

So a single host-global run behaves correctly across tenants and only pages on actionable events — all changes are opt-in env toggles set by mt-admin in `health.env` that **leave single-instance behavior unchanged**:

- **`SELF_HEAL_REMEDY_LOGICAL=false`** — remediate only the auto-discovered **per-tenant init units**, not the single-instance "logical" components (`gateway`/`xmpp`/`tensorzero`/`clickhouse`) whose base service names don't exist under MT (otherwise a failing logical probe tried to restart a nonexistent base service and escalated forever).
- **`HEALTH_XMPP_SERVER` / `HEALTH_XMPP_PORT` / `HEALTH_MODELS_ENABLED` / `HEALTH_OMEMO_ENABLED`** — make the XMPP probe configurable (empty disables it, replacing a hardcoded server) and disable probes that are environmentally N/A host-globally (models needs provider keys; omemo has no host-level store), reporting *healthy/disabled* instead of false degraded/critical.
- **`HEALTHCHECK_NOTIFY=false`** — suppress the orchestrator's per-run notification; page **only** on self-heal escalation. Prevents 15-minute notification spam from cosmetically-degraded components.
- **`SELF_HEAL_MAX_REPORT_AGE`** (0 = off) — refuse to act on a stale report if the scheduler stalls. **`SELF_HEAL_ESCALATE_TIMEOUT`** (30 s) bounds the Gotify call. **`HEALTH_OPENRC_STATUS_TIMEOUT`** (8 s) bounds each per-unit `rc-service status` so one wedged tenant can't consume the whole orchestration budget.

### HTTP Webhook Hardening

The per-tenant env generator (`write_tenant_lunarwing_env`) now sets **`HTTP_HOST=127.0.0.1`** (it previously defaulted to `0.0.0.0`, exposing the webhook on all interfaces) and a generated per-tenant **`HTTP_WEBHOOK_SECRET`**, so the `http` channel starts cleanly and binds localhost-only — matching the "all HTTP services bind 127.0.0.1" policy.

### New Operator Verbs (mt-admin)

| Verb | Purpose |
|------|---------|
| `render-units <name>` | Re-render a tenant's systemd/OpenRC units from the current generator **without** touching secrets/env or restarting (systemd renderer daemon-reloads internally). `status()`/health changes apply immediately; run-command changes need a restart. |
| `rotate-pg-password <name>` | Generate + apply a new per-tenant PostgreSQL password (`ALTER ROLE`); prompts for a restart. |
| `backup-tenant <name>` / `backup-all` | `pg_dump -Fc` to `$LUNARWING_MT_BACKUP_DIR`, pruned to `LUNARWING_MT_BACKUP_KEEP`. |
| `list-backups [name]` | List existing dumps. |
| `restore-tenant <name> <file> --yes` | `pg_restore --single-transaction` (destructive; fail-closed). |

### Documentation & Housekeeping

- **Crate version bump to 1.1.4** — all release-tracking crates (the `lunarwing` daemon, `lunarwing_common`/`_engine`/`_skills`/`_safety`, the xmpp-bridge, and the WASM channels `multica`/`telegram`/`xmpp`/`darkirc`/`weechat-relay`) are at `1.1.4`; the workspace compiles clean and the binary reports `1.1.4`.
- **License alignment** — `ic/bridges/xmpp-bridge/Cargo.toml` moved from `MIT OR Apache-2.0` to `AGPL-3.0-or-later`, matching the repo-wide policy.
- **XMPP custom-bridge reference rewritten** — `docs/reference/custom_bridges/XMPP.md` goes from a 2-line stub to a full reference (architecture, build/run, `/v1` HTTP API, env vars, reconnect backoff, WASM channel fields, systemd/OpenRC coupling).
- **Health-check docs synced to the current scripts** — `ic-infrastructure-health-check/README.md` corrects the state path (`reports/self-heal/state.json`), documents the new self-heal env vars and per-check disable knobs, clarifies service-manager auto-detection, adds a component→service mapping table, and adds the OpenRC test suite.
- **New docs** — `docs/ops/MT-GENTOO-SETUP-AND-CHANGES-MADE.md`, `docs/guides/GENTOO_PACKAGE_LIST.md`, `docs/guides/QUICK_BUILD.md`, `docs/ops/SELF_REPAIR_IMPROVEMENTS_GENTOO.md`, `docs/ops/GOALS_1.1.4.md`, and proposals: `MT_SYSTEMD_PARITY.md`, `PER_TENANT_RANDOM_PG_PASSWORDS.md`, `ROOTLESS_WORKER_OPENRC_UNITS.md`, `ROOTLESS_PODMAN_CONTAINER_SUPERVISION_GAP.md`, `ROOTLESS_DEFAULT_INIT_GATING.md` (superseded), `SYSTEMD_QUADLET_IMPROVEMENTS.md`, `MT-WEECHAT-CONSISTENCY-AND-CHANNEL-PRUNING.md`, `OPENRC_ACCURATE_REPORT_16_JUNE_2026.md`, `IC_REPAIR_FOLLOWUPS.md`, `CARGO_TESTS_FIX.md`, `LUNARVISION_POLISHING.md`, `FUNDING.JSON.MD`.
- **Updated** — `docs/guides/MT-ADMIN-QUICKSTART.md`, `docs/ops/MULTITENANCY-PRODUCTION.md`, `docs/ops/TENANT-CONFIGURATION.md`, the libSQL/IronClaw migration guides (read the PG password from env with a `lunarwing` fallback for legacy tenants), and `docs/ops/ROADMAP_2026.MD` (re-prioritization).

---

## Bug Fixes

The self-heal bugs below were found via **live** bring-up/testing on a real OpenRC multi-tenant host; the lock-fd leak is real-world-only (the mock chaos harness never forks a real daemon), and several were the root cause of the long-failing `CH6`/`CH9`/`CH12` chaos assertions.

- **Self-heal lock-fd leak — self-heal wedged after its first restart.** `main()` opened the single-instance flock as fd 200 with no close-on-exec, so a restarted service's long-lived `supervise-daemon` **inherited fd 200** and held the lock forever; every later run exited *"another self-heal instance is running."* Fixed by closing fd 200 for the restart dispatch and all its children (`200>&-`).
- **Escalation Gotify pages never sent.** `send-notification.sh` had three bugs: jq referenced `$report_file` without `--arg` (compile error → script exited, no page), `.components[]`/`.alerts[]` were emitted as bare streams instead of being `join`'d, and the JSON payload was hand-interpolated so literal newlines produced invalid JSON Gotify rejected. Now: pass `--arg`, `join` the arrays, build the payload with jq, and check the HTTP status.
- **Escalated state never persisted (re-escalated every tick).** `escalate_service` runs inside `remediate_component`, whose stdout is captured as the returned state JSON; the notifier's stdout was prepended to that JSON, so the next `prune_state` jq aborted under `set -e` **before** `save_state`, discarding `escalated:true`. Fixed by redirecting the notifier's stdout to stderr and making it non-fatal.
- **Corrupt `state.json` crashed the tick.** `load_state()` now detects a jq parse failure (and rejects empty/whitespace/non-object content), renames the bad file to a single-slot `state.json.corrupt` for forensic inspection, logs a warning, and returns a fresh `{}` so the tick completes — instead of crashing under `set -e` and losing `escalated:true`.
- **Hung Gotify could block the whole orchestration.** The escalation notifier is now wrapped in `timeout $SELF_HEAL_ESCALATE_TIMEOUT` (default 30 s, falling back to a bare call where GNU `timeout` is absent), so a stalled endpoint can't consume the tick deadline for other tenants.
- **OpenRC health-check misclassified down units.** `health-openrc.sh` was discarding the real `rc-service status` exit code with `|| true`, so an ambiguous-but-down unit read as *started/healthy* and was never remediated. Now it captures the real exit code, adds a per-unit `timeout`, dedups discovery, and drops the always-zero `pid` field. A new `test-health-openrc.sh` (21 assertions) covers each fix.
- **PostgreSQL "running-but-wedged" read as healthy.** The `lunarwing-pg-<t>` unit `status()` now requires **both** `State.Running` **and** `pg_isready` (was: running only), on both inits — closing a false-healthy hole that let a degraded DB escape self-heal. (Applies to newly rendered units; existing units upgrade on `render-units`/re-provision.)
- **OpenRC-fatal env-file corruption (latent on systemd).** `write_tenant_lunarwing_env` wrote `lunarwing.env` via an *unquoted* heredoc containing a literal backtick `env`, so the shell executed `env` at file-write time and injected the whole environment into the file; systemd's `EnvironmentFile=` tolerates the junk, but OpenRC's `. source` **executes** it → the daemon failed to start. Fixed by replacing the backticks.
- **`find_latest_report` empty-dir foot-gun.** Replaced `xargs ls -t` (which, with no matches, `ls`-ed the CWD and returned the wrong file) with `sort | tail -1`; ISO-8601 report names sort chronologically, so this is equivalent and safe.

> **Test impact.** The self-heal suite is now **188 pass / 0 fail** (regression 28, matrix 124, chaos 36), with the infra health-check chaos leg green at **36/0** (from 33/3). The OpenRC leg adds a new **`test-health-openrc.sh` (21 assertions)**, all green, and the workspace lib unit tests pass (**3944** lib tests). The previously-failing `A2`/`N1` exit-code assertions were a **test-harness** bug (the `run_raw` helper set `RC` inside a command-substitution subshell, so the caller read a stale value — self-heal's exit codes were already correct); fixed by returning the exit code from `run_raw` and capturing it at the call sites.

---

## Documentation

- `docs/proposals/MT_SYSTEMD_PARITY.md` — systemd MT-parity plan + implementation-status table (WS1–WS4, fold-ins A–D, commit SHAs).
- `docs/ops/MT-GENTOO-SETUP-AND-CHANGES-MADE.md` — Gentoo/OpenRC/Podman setup record (prereqs, fixes, boot persistence, self-heal integration, gotchas, tenant inventory).
- `docs/guides/GENTOO_PACKAGE_LIST.md` — packages for a live MT env on Gentoo/OpenRC (core, Podman + `iptables[nftables]` USE, `fcron`, build toolchain, optional WeeChat); `docs/guides/QUICK_BUILD.md` — minimal build steps.
- `docs/proposals/ROOTLESS_WORKER_OPENRC_UNITS.md`, `ROOTLESS_PODMAN_CONTAINER_SUPERVISION_GAP.md`, `ROOTLESS_DEFAULT_INIT_GATING.md` (superseded by systemd-rootless Quadlet support), `SYSTEMD_QUADLET_IMPROVEMENTS.md`, `PER_TENANT_RANDOM_PG_PASSWORDS.md` — rootless/Quadlet/secrets design notes.
- `docs/proposals/MT-WEECHAT-CONSISTENCY-AND-CHANNEL-PRUNING.md` — WeeChat service-consistency + WASM channel pruning proposal.
- `docs/proposals/OPENRC_ACCURATE_REPORT_16_JUNE_2026.md`, `IC_REPAIR_FOLLOWUPS.md`, `docs/ops/SELF_REPAIR_IMPROVEMENTS_GENTOO.md`, `docs/ops/GOALS_1.1.4.md` — self-heal verification, follow-up triage, and the v1.1.4 pre-release checklist.
- `docs/reference/custom_bridges/XMPP.md`, `ic-infrastructure-health-check/README.md`, `docs/ops/TENANT-CONFIGURATION.md` — operator references rewritten/synced to the current code.
- `docs/proposals/CARGO_TESTS_FIX.md`, `LUNARVISION_POLISHING.md`, `FUNDING.JSON.MD` — tracked future work.
- **Updated** — `docs/guides/MT-ADMIN-QUICKSTART.md`, `docs/ops/MULTITENANCY-PRODUCTION.md`, `docs/reference/TENANT-CONFIGURATION.md`, the IronClaw→MT migration guides, and `docs/ops/ROADMAP_2026.MD`.

---

## Known Issues (not a complete list — see `docs/bugs` and `docs/proposals` for more)

- **Rootless container supervision gap (crash-recovery latency).** On rootless Podman, per-tenant containers (`lunarwing-pg-<t>`, workers) are health-monitored but not *parent-supervised*, so a crash *after* `start()` returns is only recovered by the next 15-minute self-heal sweep (~30 min worst case with `GRACE_CHECKS=2`) rather than in seconds. The proposed `podman wait` babysitter (`docs/proposals/ROOTLESS_PODMAN_CONTAINER_SUPERVISION_GAP.md`) is **deferred** — see *Deferred* below.
- **WeeChat health-glob flap (fold-in A follow-up).** Now that the per-tenant WeeChat unit is renamed `lunarwing-weechat-<t>`, an optional/stopped weechat backend matches the health-discovery glob and can report critical (and flap/escalate if auto-restart is attempted). Workaround: only render/enable weechat units for tenants that actually use it; a per-tenant gate is a planned follow-up.
- **`podman save | load` image distribution is slow.** Seeding worker images into each tenant's isolated rootless store (`nanocode` ~6 GB, `pebble` ~195 MB) takes minutes per tenant per image; a shared read-only `additionalimagestore` is a future optimization.
- **A few non-critical cargo tests fail** (tracked in `docs/proposals/CARGO_TESTS_FIX.md`), and the `e2e_advanced_traces` bootstrap-greeting tests remain among the pre-existing, env-dependent e2e failures (2 failures, unrelated to the version bump).
- **Carried forward from v1.1.3** (see `docs/releases/RELEASE-v1.1.3.md`): XMPP inbound file transfer awaits live e2e validation and has no SSRF guard; the Multica bridge remains pre-release/experimental; and the `/api/logs/download` endpoint has no UI button yet.

---

## Upgrade Notes

1. **No new database migrations.** v1.1.4 adds no schema changes; existing migrations still run automatically on first startup. Back up your database before upgrading as a matter of course.
2. **Crate versions are at 1.1.4** (already bumped in this release). No action required beyond rebuilding from the tag.
3. **Self-healing is enabled by default for NEW tenants on both OpenRC and systemd.** Existing deployments adopt it on the next `add-tenant`, or by running `ensure_health_pipeline` once. Opt out with `--no-health` (per tenant) or `LUNARWING_MT_HEALTH_ENABLED=false` (fleet). The pipeline pages **only on escalation** (`HEALTHCHECK_NOTIFY=false`). Put the Gotify URL/token in `/etc/lunarwing/health.env` (mode `0600`) — it is never committed to the repo. As this is a brand-new default, take appropriate caution.
4. **New host dependency for the health schedule.** OpenRC needs a cron daemon (`sys-process/fcron`, or `cronie`/`dcron`); systemd uses the generated `lunarwing-mt-health.timer` (verify with `systemctl status lunarwing-mt-health.timer`). See `docs/guides/GENTOO_PACKAGE_LIST.md`.
5. **Rootless Podman.** `MT_ROOTLESS` defaults to `true` on Podman (`false` on Docker; override with `LUNARWING_MT_ROOTLESS`). The host needs `newuidmap`/`newgidmap` as setuid binaries and populated `/etc/subuid`/`/etc/subgid` (auto-allocated by `ensure_rootless_prereqs` if missing). On **systemd + rootless Podman**, container supervision requires **Podman ≥ 4.6** (Quadlet); older versions fall back to imperative container lifecycle.
6. **Per-tenant PostgreSQL passwords.** New tenants get a random password in `…/env/pg.secret` (`0600`). Existing tenants keep `lunarwing` until rotated with `rotate-pg-password <name>` (requires a tenant restart). The migration guides now read the password from env with a `lunarwing` fallback for legacy tenants.
7. **New env vars / verbs.** `LUNARWING_MT_BACKUP_DIR` (default `/var/lib/lunarwing-backups`), `LUNARWING_MT_BACKUP_KEEP` (default 7; 0 = keep all), `LUNARWING_SERVICE_MANAGER` (auto-detected; set in `health.env` for self-heal dispatch). New verbs: `render-units`, `rotate-pg-password`, `backup-tenant`/`backup-all`/`list-backups`, `restore-tenant … --yes`. Apply generator changes to existing tenants with `render-units <name>` (no restart for `status()`/health changes).
8. **HTTP webhook now binds localhost.** Re-run `add-tenant` to regenerate `lunarwing.env` with `HTTP_HOST=127.0.0.1` + `HTTP_WEBHOOK_SECRET`, or add those two lines manually to existing env files.
9. **OpenRC `start-tenant` and WeeChat.** If `weechat`/`aiohttp` are missing, optional channels are now skipped non-fatally rather than aborting the core stack; install the deps (or start core services directly) if you want WeeChat.
10. **Port schema v6 (from v1.1.3) still applies** — additive and non-disruptive; back up `/etc/lunarwing/ports.json` and dry-run on a copy before applying.

---

## Features and changes deferred to future releases

The full, canonical list lives in **`docs/ops/ROADMAP_2026.MD`** and respects the release cadence. Near-term highlights:

| Feature | Target |
|---------|--------|
| Rootless `podman wait` supervision babysitter (near-instant container crash recovery) | v1.1.5 |
| Per-tenant WeeChat health-glob gate (fix fold-in A flap) | v1.1.5 |
| XMPP OMEMO MUC fallback fix | v1.1.5 |
| XMPP file transfer — remaining polish (live end-to-end validation, optional SSRF guard, further hardening) | v1.1.5 |
| Lunarvision K.E.R.S. system setup polishing | v1.1.5 |
| External Worker planned enhancements | v1.1.6 |
| Multica bridge / channel refinements and agent-orchestration workflow improvements | v1.1.6 |
| Lunartica UI reskin | v1.1.6 |

---

## Release Cadence

*A brief note about release cadence.* LunarWing abides by a release cadence to organize `feature` and `polish` focused releases — even-numbered releases (like this one) focus on features. For details see `docs/ops/RELEASE_CADENCE.md`. Occasionally exceptions are made, but the goal is to stay within this paradigm.

## Testing

*In accordance with developer guidelines, a testing period precedes each release.*

*Testing for this release has **commenced**. The v1.1.4 pre-release checklist lives in `docs/ops/GOALS_1.1.4.md`; the full checklist is in `docs/ops/PRE-RELEASE-TESTING.md`; automated coverage is driven by `ic/scripts/release-test.sh` and `docs/guides/TESTING_GUIDE.md`.*

*Completed so far: the crate-version bump + `cargo test` sweep (3944 lib unit tests pass; 2 pre-existing `e2e_advanced_traces` failures), the self-heal/health-check unit + chaos suites (188/0 self-heal, 36/0 chaos, new 21-assertion OpenRC health suite), and live validation of the health-check/self-heal pipeline on a real multi-tenant host (recovery, escalation, reboot, Gotify) on both inits. Still open: the cross-VM tenant add/upgrade matrix (existing + fresh systemd/OpenRC VMs), a live in-place upgrade of a production tenant > v1.1.0, and the broader automated `release-test.sh` sweep.*

*Once evaluation begins in earnest, no new changes besides urgent fixes will be accepted into staging during the evaluation period.*
