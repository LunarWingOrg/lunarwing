# Multi-Tenant systemd Parity — Rootless Podman, Health Pipeline & Self-Heal

**Status:** ✅ **Largely implemented** (merged `2b471720`, 2026-06-16) — WS1–4 + fold-ins A & C landed; **fold-in B (random PG passwords) landed on `…-random-pg-passwords`; fold-in D (backups) still outstanding.** See the *Implementation status* section below. *(Original status: "Proposed (approved, not yet implemented)".)*
**Branch:** `2026-06-16-vm-ic-2-feature-1.1.4-systemd` (merged into `…-unified`)
**Date:** 2026-06-15 (status updated 2026-06-16)
**Supersedes / closes:** the "Future: full systemd rootless support" section of
[`ROOTLESS_DEFAULT_INIT_GATING.md`](./ROOTLESS_DEFAULT_INIT_GATING.md), the deferred systemd-analog
in [`ROOTLESS_WORKER_OPENRC_UNITS.md`](./ROOTLESS_WORKER_OPENRC_UNITS.md), item **#2** of
[`IC_REPAIR_FOLLOWUPS.md`](./IC_REPAIR_FOLLOWUPS.md), and folds in
[`PER_TENANT_RANDOM_PG_PASSWORDS.md`](./PER_TENANT_RANDOM_PG_PASSWORDS.md).
**Primary files:** `ic/scripts/lunarwing-mt-admin.sh`, `ic-infrastructure-health-check/*`.
**Scope:** ops/provisioning scripts only — **no Rust/daemon changes.**

---

## ✅ Implementation status — 2026-06-16 (merged `2b471720`)

*Added after the original proposal. Verified against the merged tree (greps +
reads of the actual scripts, not the doc). Commits: WS1 `c8abd28e`, WS2
`a919de20`/`8b028205`, WS3 `ebb11cdf`, WS4 + shared engine `dd4ec7e4`, fold-in C
`e2d47f4a`, fold-in A `f42ef62c`.*

| Workstream / fold-in | Status | Evidence |
|---|---|---|
| **WS1** — systemd health/self-heal scheduler | ✅ **done** | `_install_health_systemd_timer()` + `lunarwing-mt-health.{service,timer}`; `health.env` → `LUNARWING_SERVICE_MANAGER=$INIT_SYSTEM`; case-dispatch + teardown in `ensure/remove_health_pipeline` |
| **WS2** — Quadlet supervision (PG + workers) | ✅ **done** | `render_pg_quadlet` / `render_worker_quadlet` / `podman_supports_quadlet`; `systemd && rootless` branch in `start_tenant_postgres`/`_nanocode`/`_pebble`; daemon `Requires=`/`After=lunarwing-pg-<t>.service` |
| **WS3** — health-systemd discovery breadth | ✅ **done** | `health-systemd.sh` per-tenant `list-unit-files 'lunarwing-*' 'xmpp-bridge-*' 'weechat-*'`, base-unit existence-gate on MT hosts, **plus** a `.State.Health` container probe for pg/workers (beyond the OpenRC leg) |
| **WS4** — self-heal parser correctness | ✅ **done** | `unit_tenant()` strips pg/worker/weechat infixes; `lunarwing-weechat-*` case; `sudo -n` consistency |
| **Fold-in A** — weechat rename | ✅ **done** | `lunarwing-weechat-<t>` on both inits |
| **Fold-in C** — status/doctor symmetry | ✅ **done** | `status_tenant` rows; doctor `podman ≥ 4.6 (Quadlet)` + per-tenant linger/`/run/user` checks |
| **Fold-in B** — random per-tenant PG passwords | ✅ **done** (`…-random-pg-passwords`) | `tenant_pg_password` (migration-safe) is the source of truth; `DATABASE_URL` + `POSTGRES_PASSWORD` (imperative `_ctr run` **and** the Quadlet) derive from it; `rotate-pg-password <name>` verb upgrades existing tenants. New tenants random; pre-existing keep `lunarwing` until rotated. |
| **Fold-in D** — backups subcommand | ❌ **NOT done** | no `backup` verb in dispatch, no `pg_dump` anywhere |

**Remaining work on this proposal:** fold-in **D** only (fold-in B landed on `…-random-pg-passwords`). The
*Docs to update / retire* checklist at the end is **not yet actioned** — its target
docs (`MULTITENANCY-PRODUCTION.md`, `TENANT-CONFIGURATION.md`, the `CLAUDE.md` MT
line, `ic-infrastructure-health-check/README.md`) may still carry the stale
"systemd just runs" framing; verify before relying on them.

> The per-workstream sections below are kept as the original (approved) design
> record — read them together with this status table.

---

## Context

LunarWing's multi-tenant (MT) stack — rootless-podman per-tenant **PostgreSQL**, the
**nanocode/pebble worker** containers, the **8-check infrastructure health pipeline**, and the
**self-heal/self-repair loop** — was built and tuned for **OpenRC (Gentoo)** hosts. This branch
brings those features to **systemd** hosts at parity.

A code audit (verified against the scripts, not the docs) pinned the gap to one structural
asymmetry: the OpenRC path uses **system-level services discoverable by an `/etc/init.d/` glob**,
whereas the systemd path uses **per-tenant user-scoped units** under `~/.config/systemd/user/`,
driven via `sudo -u <t> XDG_RUNTIME_DIR=… systemctl --user` (the `_systemctl_user` helper). That one
difference ripples through container supervision, scheduling, and health discovery.

### Verified findings

| Area | OpenRC (today) | systemd (today) |
|---|---|---|
| PG + workers | First-class `/etc/init.d/lunarwing-pg-<t>` + `lunarwing-<worker>-<t>`; daemon `need`s pg; boot-enabled | `render_tenant_systemd_units` emits **5** user units (proxy, weechat, weechat-adapter, xmpp-bridge, daemon) — **no pg unit, no worker units**. PG/workers are bare `podman run -d`; rootless **drops `--restart`**. Reboot → daemon returns but **PG never does** → boot-loop. |
| Health/self-heal scheduling | `ensure_health_pipeline` installs an fcron/cron `*/15` schedule of the pipeline | `ensure_health_pipeline` **early-returns** ("only wired for OpenRC so far"); generated `health.env` hardcodes `LUNARWING_SERVICE_MANAGER=openrc`. **Nothing ever runs** the checks. |
| Health discovery | `health-openrc.sh` globs `/etc/init.d/lunarwing-*` → finds pg, workers, proxy, adapter | `health-systemd.sh` discovers tenants from `ports.json` but probes a **hardcoded 2 units** (`lunarwing-<t>`, `xmpp-bridge-<t>`); even the already-supervised proxy + weechat units are invisible. |
| Self-heal engine | `rc-service` remediation | **Already systemd-capable** — `_systemd_user_restart`/`_systemd_user_active` (`sudo -u … systemctl --user restart`), auto-detects the manager, no `rc-update`. Needs **no rewrite** — only parser fixes, plus it must actually be *scheduled* and *fed a complete report*. |

**The #1 blocker is the scheduler, not the pg unit** — adding pg/worker units does nothing until the
pipeline is wired to run on systemd. And the self-heal engine being already-portable means the
heaviest-sounding thread is the smallest.

### Intended outcome

On a systemd MT host: PG + workers are boot-persistent, crash-restarted, health-discovered, and
self-healed; the health pipeline runs on a schedule; status/doctor surfaces tell the truth — at
parity with OpenRC, with the OpenRC and rootful-docker paths unchanged.

---

## Decisions

| Decision | Choice | Why |
|---|---|---|
| Health-pipeline scheduler | **Hybrid** — systemd timers on systemd, keep fcron on OpenRC | `Persistent=true` gives the same missed-run catch-up that justified fcron, **plus** `journalctl`/`list-timers` visibility (the surface the health checks already query), dependency ordering, jitter, and zero extra daemons. fcron stays on OpenRC (timers don't exist there; `cron.hourly` can't do `*/15` or replay). |
| Container supervision (rootless podman) | **Quadlet `.container`** (user-scoped) | Modern declarative podman-systemd integration; podman owns the generated `.service`; matches operator's existing rootless-podman workflow. |
| Scope/sequencing | **All four workstreams + all fold-ins, one branch** | Complete parity in a single reviewable change. |
| Fold-ins | weechat unit rename · random per-tenant PG passwords · status/doctor symmetry · backups subcommand | All surfaced by the audit; cheap to land alongside the core work. |

> Line anchors below are approximate (audit found script/doc anchors drift ±250–400 lines) — **navigate
> by function name.**

---

## Workstream 1 — Health/self-heal scheduler on systemd (the #1 blocker) — ✅ IMPLEMENTED

Implements `IC_REPAIR_FOLLOWUPS.md` item #2. In `ic/scripts/lunarwing-mt-admin.sh`:

1. **`ensure_health_pipeline`** — remove the `INIT_SYSTEM != openrc` early-return so the
   already-init-agnostic steps (script sync, report dir, `health.env`, launcher) run on systemd too.
2. Generated **`health.env`**: `LUNARWING_SERVICE_MANAGER=openrc` → `=$INIT_SYSTEM`.
3. Replace the unconditional `_install_health_cron` call with
   `case $INIT_SYSTEM in openrc) _install_health_cron;; systemd) _install_health_systemd_timer;; esac`.
4. **NEW `_install_health_systemd_timer()`** — write a **root, system-level**
   `/etc/systemd/system/lunarwing-mt-health.service` (`Type=oneshot`, `ExecStart=$HEALTH_LAUNCHER`)
   + `lunarwing-mt-health.timer` (`OnBootSec=5min`, `OnCalendar=*:0/${HEALTH_INTERVAL_MIN}`,
   `Persistent=true`, `WantedBy=timers.target`), then `daemon-reload` + `enable --now`. Model on the
   shipped `ic/systemd/lunarwing-watchdog.{service,timer}`. **System-level (not `--user`)** because one
   run remediates many tenants' user units via `sudo`.
5. Mirror teardown in **`remove_health_pipeline`** (disable + rm the timer/service on systemd).
6. Extend the **`doctor`** "health pipeline scheduled" check to also accept
   `systemctl is-enabled lunarwing-mt-health.timer`.

---

## Workstream 2 — Quadlet supervision for PG + workers (rootless podman) — ✅ IMPLEMENTED

**Reconciliation decision:** on **systemd + rootless podman only**, the Quadlet `.container` **owns
container creation** — strip the imperative `_ctr run -d` and let the generated `.service` create+run
from the `[Container]` spec. The **OpenRC** (pre-create + `podman start`) and **rootful-docker**
(`--restart unless-stopped`) paths are **unchanged**; new branches gate on
`INIT_SYSTEM==systemd && MT_ROOTLESS==true`.

Quadlet files live in the tenant's **`~/.config/containers/systemd/`** (created + chowned to the tenant,
like `render_tenant_systemd_units` already does for `~/.config/systemd/user`). The podman
user-generator runs at `systemctl --user daemon-reload` inside the tenant's lingering `systemd --user`
manager; `lunarwing-pg-<t>.container` → generated `lunarwing-pg-<t>.service`.

### Example `.container` (PostgreSQL)

```ini
# ~/.config/containers/systemd/lunarwing-pg-<t>.container
[Unit]
Description=LunarWing Postgres container (<t>)
After=network.target

[Container]
ContainerName=lunarwing-pg-<t>
Image=pgvector/pgvector:pg16
PublishPort=127.0.0.1:<pg_port>:5432
Volume=lunarwing-pg-<t>:/var/lib/postgresql/data    # plain ref — keeps the name reset_tenant_postgres removes
Environment=POSTGRES_USER=lunarwing
Environment=POSTGRES_PASSWORD=<random — fold-in B>
Environment=POSTGRES_DB=lunarwing
HealthCmd=pg_isready -U lunarwing -q
HealthInterval=10s
HealthStartPeriod=30s
Notify=healthy            # podman >= 5.0 only; omit below

[Service]
Restart=always
RestartSec=5
TimeoutStartSec=120

[Install]
WantedBy=default.target
```

Workers (`lunarwing-<worker>-<t>.container`) mirror this with the worker image,
`PublishPort=127.0.0.1:<wss>:<wss>`, `Volume=<workspace>:/workspace:z`,
`Environment=…HEALTH_PORT=8443…`, and `EnvironmentFile=<env_dir>/<worker>.env`. The token remap
(`AGENT_AUTH_TOKEN←GATEWAY_AUTH_TOKEN`, `TENSORZERO_API_KEY←LLM_API_KEY`) is written into that env file
at config time so **no secrets land in the `.container`**. The images bake a `HEALTHCHECK` on 8443
(`lunarcode4lunarwing/Dockerfile`, `pebble4lunarwing/Dockerfile`), which Quadlet inherits.

### Functions to add / change (`lunarwing-mt-admin.sh`)

| Function | Edit |
|---|---|
| **NEW** `render_pg_quadlet` | Idempotent; create+chown `~/.config/containers/systemd`; write the pg `.container`. |
| **NEW** `render_worker_quadlet <name> <worker> [port]` | Mirror `render_worker_openrc_unit`; write the worker `.container`. |
| **NEW** `podman_supports_quadlet` | `podman version` ≥ 4.4 gate. |
| `render_tenant_systemd_units` | Call the new renderers; add `After=`+`Requires=lunarwing-pg-<t>.service` to the **main daemon** unit (mirrors OpenRC `need`). Workers stay independent. Keep the 5 existing units verbatim. |
| `start_tenant_postgres` | systemd+rootless branch: `_ensure_tenant_image`/pre-pull → `render_pg_quadlet` → `_systemctl_user daemon-reload` → `start lunarwing-pg-<t>.service` → reuse the existing `pg_isready` loop via `_ctr exec`. |
| `start_tenant_nanocode` / `start_tenant_pebble` | systemd+rootless branch: skip `_ctr run`; ensure image + workspace + write mapped tokens to env file; call `_register_worker_unit`. |
| `_register_worker_unit` / `_deregister_worker_unit` | Add a systemd+rootless branch **before** the OpenRC early-return: render quadlet → `daemon-reload` → start / stop + rm `.container` + `daemon-reload` + `_ctr rm -f`. |
| `stop_tenant_systemd` / `uninstall_tenant_systemd` | Add pg + worker services to the stop loop; remove `.container` files + `daemon-reload`; `_ctr rm -f` worker containers on uninstall. |
| `stop_tenant_nanocode` / `stop_tenant_pebble` | Add systemd branch (`_systemctl_user stop …`). |
| `_systemctl_user` (hardening) | Also pass `HOME=$(getent passwd "$name")` so any podman invoked through the helper resolves the tenant rootless store. |

**Boot persistence:** linger (already enabled) + `[Install] WantedBy=default.target` in each
`.container` (generator emits the `default.target.wants` symlink at `daemon-reload`). Do **NOT**
`systemctl --user enable` generated units (it fails) — `[Install]` only.

**Rootless gating:** keep `MT_ROOTLESS=true` on systemd+podman (do **not** implement the rootful gate
from `ROOTLESS_DEFAULT_INIT_GATING.md`) — real units close the lifecycle gap that motivated the gate.

**Prereq + fallback:** Quadlet needs **podman ≥ 4.4** (`Notify=healthy` needs ≥ 5.0; below that, omit
and let the health pipeline read `inspect .State.Health.Status`). For podman < 4.4, degrade to a native
`~/.config/systemd/user/` `Type=simple` unit (`ExecStart=podman start -a …`) over a pre-created
container (the OpenRC model). Docker-on-systemd needs nothing (already survives via `--restart`).

---

## Workstream 3 — Health-check discovery breadth (`health-systemd.sh`) — ✅ IMPLEMENTED

- Replace the hardcoded 2-unit per-tenant probe with **enumeration of the tenant's
  `systemctl --user list-units 'lunarwing-*' 'xmpp-bridge-*'`** so it auto-discovers pg, workers,
  proxy, and weechat-adapter — mirroring the OpenRC glob.
- **Existence-gate** the base `UNITS_DEFAULT` (`lunarwing.service`, `xmpp-bridge.service`,
  `tensorzero-gateway.service`) the way `health-openrc.sh` does, so a pure-MT systemd host doesn't emit
  phantom criticals.
- Add a rootless container-health fallback for podman < 5.0 (no `Notify=`):
  `_ctr "$t" inspect -f '{{.State.Health.Status}}' lunarwing-<svc>-<t>`.

---

## Workstream 4 — Self-heal parser correctness (`lunarwing-self-heal.sh`) — ✅ IMPLEMENTED

Engine already systemd-capable; fix only:

- **`unit_tenant()`** — strip the worker/pg infix so `lunarwing-pg-<t>` → `<t>` (not `pg-<t>`) and
  `lunarwing-<worker>-<t>` → `<t>` (not `<worker>-<t>`), so `_systemd_user_restart` targets the right
  tenant bus.
- Add a case for the renamed **`lunarwing-weechat-<t>`** (fold-in A).
- **`sudo -n` consistency** — self-heal's user-restart uses `sudo -u` *without* `-n` while
  health-systemd uses `sudo -n -u`; align to `-n` so a non-interactive timer context can't hang on a
  password prompt.

---

## Fold-ins

- **A — `weechat-<t>` → `lunarwing-weechat-<t>` rename.** ✅ *Done.* On **both** inits
  (`render_tenant_systemd_units`, `render_tenant_openrc_units`, start/stop/enable lists, daemon
  `After=`/`Wants=`, and `tmux -L` socket refs). Makes weechat discoverable by the `lunarwing-*` glob
  and resolvable by self-heal.
- **B — Random per-tenant PG passwords.** ✅ *Done (`…-random-pg-passwords`) — `tenant_pg_password` + `rotate-pg-password`; migration-safe.* Add `tenant_pg_password` (`openssl rand -hex 24`); thread it
  into the PG `Environment=`/init env and `DATABASE_URL`; resolve **before first container init**
  (POSTGRES_PASSWORD only applies to an empty datadir). Store in the tenant env file (mode 0600).
  Optional `rotate-pg-password` verb. Uniform across OpenRC / systemd / docker.
- **C — status/doctor symmetry.** ✅ *Done.* `status_tenant`: add pg + worker (+ weechat/adapter) rows to both
  branches. `doctor`: the systemd "pipeline scheduled" check (W1.6) + "podman ≥ 4.4 (quadlet)" check +
  "tenant user manager active (linger)" check.
- **D — Backups subcommand.** ❌ *Not done — no `backup` verb / `pg_dump` exists.* Add a `backup` verb (`pg_dump` of each tenant's PG container via
  `_ctr exec`, to a host backup dir; init-agnostic). CLAUDE.md already instructs "back up the DB first"
  but no verb exists.

---

## Cross-cutting / teardown

- Every new unit/quadlet has a matching teardown in `stop_tenant_*` / `uninstall_tenant_*` /
  `remove_tenant` — no orphaned containers, volumes, `.container` files, or `default.target.wants` links.
- All `render_*` functions idempotent (safe to re-run on re-provision).
- Operation order within a tenant op: render+chown `.container` → `daemon-reload` → `start` (a
  missing/unreadable `.container` at reload yields "Unit not found").

---

## Verification

Exercise on a **systemd host with rootless podman ≥ 4.4** (the harness
`ic/scripts/lunarwing-xmpp-test-env.sh` auto-detects init):

1. **Provision** `add-tenant <t>` → `~/.config/containers/systemd/lunarwing-{pg,nanocode,pebble}-<t>.container`
   exist; `_systemctl_user <t> list-units 'lunarwing-*'` shows the generated `.service` units active.
2. **Ordering** — `systemctl --user show lunarwing-<t>.service -p Requires,After` includes
   `lunarwing-pg-<t>.service`.
3. **Boot persistence** — reboot (or `loginctl terminate-user <t>` + linger restart): PG + workers come
   back with the daemon; no DB boot-loop.
4. **Crash-restart** — `podman stop lunarwing-pg-<t>` → unit restarts (`Restart=always`).
5. **Scheduler** — `systemctl list-timers lunarwing-mt-health.timer` enabled; `systemctl start
   lunarwing-mt-health.service` then `journalctl -u lunarwing-mt-health` shows the health → self-heal run.
6. **Discovery + remediation** — kill the proxy/a worker → next run reports it degraded and self-heal
   restarts the correct **user** unit (not a system-level `systemctl restart`).
7. **Self-heal parser** — `unit_tenant lunarwing-pg-<t>` resolves to `<t>` (unit test in
   `ic-infrastructure-health-check/tests/`).
8. **Fold-ins** — random PG password in `DATABASE_URL` and accepted by the container; `backup` produces
   a restorable dump; `status`/`doctor` show all services, no phantom criticals.
9. **Teardown** — `remove-tenant <t>` leaves no containers/volumes/`.container` files/wants-symlinks.
10. **Regression** — run the existing self-heal matrix to confirm OpenRC behavior is unchanged.

---

## Docs to update / retire (follow-up)

- **Fix (stale):** `MULTITENANCY-PRODUCTION.md` (unit counts 3→5 / 3→6; the `podman generate systemd`
  punt; the "systemd just runs" health claim), `TENANT-CONFIGURATION.md` (systemd restart commands use
  wrong system-level/`.target` names — should be user-level `systemctl --user`), `CLAUDE.md` MT line
  (overstates systemd parity), `ic-infrastructure-health-check/README.md` (overstates discovery
  equivalence).
- **Aspirational → now implemented:** `ROOTLESS_DEFAULT_INIT_GATING.md`,
  `ROOTLESS_WORKER_OPENRC_UNITS.md` (systemd-analog), `IC_REPAIR_FOLLOWUPS.md` #2,
  `PER_TENANT_RANDOM_PG_PASSWORDS.md`.
- **Correct claims:** `ROOTLESS_WORKER_OPENRC_UNITS.md` says workers lack a baked HEALTHCHECK — both
  Dockerfiles have one (8443). `WORKER_HEALTHCHECK_PORT_MISMATCH.md` + `IC_REPAIR_FOLLOWUPS.md` line
  anchors drifted ±250–400 lines (content correct).
- **Stubs to consider deleting:** `SELF_REPAIR_IMPROVEMENTS.md`, `SELF_HEALING_IMPROVEMENTS_1.md`,
  `NANOCODE_WORKER_SECRETS.md` (already implemented).
- **Keep as OpenRC reference:** `MT-GENTOO-SETUP-AND-CHANGES-MADE.md`,
  `SELF_HEAL_DEPLOYMENT_WIRING.md`, `RELEASE-v1.1.3.md`.
