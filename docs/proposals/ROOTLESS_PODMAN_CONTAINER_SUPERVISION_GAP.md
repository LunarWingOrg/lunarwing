# Proposal: Close the rootless-podman container *supervision* gap (OpenRC leg)

*Drafted 2026-06-16, on the experimental rootless-podman + OpenRC multi-tenant
leg (the `eris` deploy). Companion to
[`ROOTLESS_WORKER_OPENRC_UNITS.md`](../internal/history/proposals/ROOTLESS_WORKER_OPENRC_UNITS.md)
and the self-healing series (archived under
[`../internal/history/proposals/`](../internal/history/proposals/)).*

> **Status:** proposal / analysis. **OpenRC leg: still open.** The systemd leg has
> since closed the equivalent gap (see Status update below).
> **Scope:** rootless podman + OpenRC only. The rootful-docker leg is unaffected
> (docker's `--restart unless-stopped` already covers it).
> **TL;DR:** Per-tenant containers (`lunarwing-pg-<t>`, `lunarwing-nanocode-<t>`,
> `lunarwing-pebble-<t>`) have OpenRC units and *are* health-monitored, but on the
> OpenRC leg they are **not supervised**. A container that crashes after `start()`
> returns is only recovered by the `*/15` self-heal sweep — worst case **~30
> minutes** of downtime, versus ~5 seconds for the supervised Rust binaries. There
> is also a false-healthy hole in the Postgres unit's `status()`.

---

## ✅ Status update — 2026-06-16 (post-merge `2b471720`)

The **systemd leg has since closed this exact gap** via **Quadlet `.container`
units** (`render_pg_quadlet` / `render_worker_quadlet` in `lunarwing-mt-admin.sh`,
commits `a919de20` / `8b028205`, WS2 of [`MT_SYSTEMD_PARITY.md`](../internal/history/proposals/MT_SYSTEMD_PARITY.md), archived):
on systemd + rootless podman the Quadlet-generated `.service` owns the container
lifecycle with **`Restart=on-failure`** + a start-limit, and the PG Quadlet adds
**`HealthCmd=pg_isready`** — i.e. systemd-native supervision *and* a real DB-level
health probe (the §4 fix below, on that leg).

**The OpenRC leg is unchanged** — the `/etc/init.d/lunarwing-pg-<t>` / worker units
are still the unsupervised `start`/`stop`/`status` shape described below, and the
PG `status()` still checks only `.State.Running`. **So this gap is now confirmed
OpenRC-specific**, and the recommended fixes here (the `podman wait` babysitter in
§6 Option 1, and the `pg_isready` check in §4) remain the open path for OpenRC.
There is no Quadlet on OpenRC, so the OpenRC solution must be expressed in OpenRC
terms (`supervise-daemon` / `podman wait`), exactly as §6 describes.

*Tangential rename:* the weechat unit is now `lunarwing-weechat-<t>` (was
`weechat-<t>`) and `unit_tenant()` in `lunarwing-self-heal.sh` was expanded to
resolve the `pg`/`nanocode`/`pebble`/`weechat[-adapter]` prefixes correctly. The
container unit names referenced below (`lunarwing-pg-<t>` etc.) are unchanged.

---

## 1. Background: two very different unit shapes

`ic/scripts/lunarwing-mt-admin.sh` renders two structurally different kinds of
OpenRC unit, and the containers got the weaker one.

### 1a. Foreground-binary units — *supervised* ✅

The Rust binaries — main daemon `lunarwing-<t>`, `xmpp-bridge-<t>`,
`lunarwing-proxy-<t>`, `lunarwing-weechat-adapter-<t>` — are generated with a
real supervisor:

```sh
command="${lunarwing_command}"
command_args="${lunarwing_args}"
pidfile="${lunarwing_pidfile}"
supervisor="supervise-daemon"                      # mt-admin.sh:2126
respawn_delay="${lunarwing_respawn_delay}"          # :2128  (default 5)
respawn_max="${lunarwing_respawn_max}"              # :2129  (default 5)
respawn_period="${lunarwing_respawn_period}"        # :2130  (default 60)
```

`supervise-daemon` **forks the binary as its own child and babysits it.** If the
process dies, it is respawned in ~5 s, locally, with *no* health-check in the
loop — up to 5 times per 60 s before OpenRC gives up and marks the unit
`crashed`. (Same pattern at `:2190` xmpp, `:2252` proxy, `:2357` weechat-adapter.)

### 1b. Container units — *not supervised* ❌

`lunarwing-pg-<t>` (`mt-admin.sh:2033-2094`) and the worker units rendered by
`render_worker_openrc_unit` (`:280-354`) have **no `command=`, no `pidfile`, and
no `supervisor=`.** They are hand-rolled `start()` / `stop()` / `status()`
functions:

```sh
start() {
    ...
    _pg start "${pg_container}" >/dev/null 2>&1 || { eend 1 "container start failed"; return 1; }
    # wait for pg_isready, then return                 # mt-admin.sh:2068-2075
}
```

`start()` runs `podman start <ctr>` **detached**, waits for readiness, and
returns. The moment it returns, OpenRC marks the service `started` and **walks
away.** There is no process for `supervise-daemon` to watch — `podman start`
returned immediately, and the container runs under the *tenant's* rootless conmon
process tree (owned by the tenant UID), not as a child of OpenRC.

The worker units are the same shape (`render_worker_openrc_unit`,
`_register_worker_unit` at `:358-366`, which advertises them as
"health-monitored, self-healed, boot-persistent" — accurate, but **not**
*supervised*).

---

## 2. The gap: nothing recovers a crashed container locally

For rootless containers, **all three** of the usual auto-restart mechanisms are
off — two of them deliberately and correctly:

| Mechanism | State on the rootless/OpenRC leg | Why |
|-----------|----------------------------------|-----|
| `supervise-daemon` respawn | **Not wired** for container units | `podman start` is detached; there's no foreground child to supervise (§1b) |
| Podman `--restart unless-stopped` | **Deliberately disabled** | No podman daemon under rootless to honor a restart policy. Correctly dropped for the rootless path (`mt-admin.sh:1599-1600`, `:1695-1696`, `:1752-1755`) |
| Podman native healthcheck restart | **Cannot fire** | Rootless podman schedules `--health-cmd` via *transient systemd timers*, which **do not exist on a systemd-less OpenRC host** |

That leaves exactly **one** recovery path: the host self-heal pipeline
(`ic-infrastructure-health-check/infrastructure-health-check.sh` →
`health-openrc.sh` → `lunarwing-self-heal.sh`), which runs on the **fcron `*/15`
schedule**.

The recovery chain works like this:

1. `health-openrc.sh` auto-discovers `/etc/init.d/lunarwing-*` units
   (`health-openrc.sh:11-36`) and runs `rc-service <svc> status`.
2. That calls the unit's `status()`, which for containers does a
   `podman inspect`/health probe and emits `started`/`stopped`
   (PG: `mt-admin.sh:2085-2093`; workers: `:345-351`).
3. `health-openrc.sh` parses the wording (`grep started|stopped`, `:80-90`) and
   reports `critical` for a stopped unit.
4. `lunarwing-self-heal.sh` reads the report and restarts via
   `rc-service <svc> restart` (`:230-237`).

It works — but only **once every 15 minutes**, and only after the grace period.

---

## 3. The latency math — it's worse than 15 minutes

The self-heal engine applies a **grace period of `GRACE_CHECKS=2`** consecutive
unhealthy observations before the *first* restart
(`lunarwing-self-heal.sh:45`, logic at `:591-595`). On a `*/15` tick:

```
t+0min    container crashes
t+~15min  tick #1  → obs=1 < 2  → GRACE: defer ("unhealthy 1/2 observation(s)")
t+~30min  tick #2  → obs=2      → RESTART
```

**Worst case ≈ 30 minutes of a dead container before the first restart attempt.**
Best case ~15 min (if the crash happens to land just before a tick). Compare the
supervised binaries: **~5 seconds.**

### Blast radius: silent degradation, not a clean outage

The main daemon declares `need ... lunarwing-pg-<t>` (`mt-admin.sh:2136`). In
OpenRC, `need` governs **start/stop ordering only** — it is *not* a runtime link.
So if Postgres dies at runtime:

- The PG container is down (and stays down up to ~30 min, per above).
- The main daemon stays `started` — `supervise-daemon` keeps the *binary* alive —
  but every DB query fails.

The tenant is **silently degraded**, which is harder to notice than a clean down.
(Secondary effect: if the daemon itself crash-loops because the DB is gone, it
can burn through `respawn_max=5 / respawn_period=60` and get marked `crashed`,
at which point self-heal eventually restarts *it* too — extra churn.)

---

## 4. Secondary bug: Postgres `status()` is false-healthy-prone

The PG unit's `status()` checks **only** container liveness:

```sh
status() {
    if [ "$(_pg inspect -f '{{.State.Running}}' "${pg_container}" 2>/dev/null)" = "true" ]; then
        einfo "${pg_container}: started"; return 0          # mt-admin.sh:2089-2090
    fi
    einfo "${pg_container}: stopped"; return 3
}
```

A container can be **`Running` but with Postgres wedged / not accepting
connections** (OOM inside, stuck recovery, corrupted shutdown). `status()` then
reports `started`, `health-openrc.sh` parses it as healthy, and **self-heal never
fires.** The PG unit's own `start()` already knows how to test this — it loops on
`pg_isready` (`:2070`). The worker units do it right via `_wk_healthy`
(`:317-320`: `State.Running` **AND** an in-container `/health` curl).

**Fix:** make PG `status()` run `pg_isready -U lunarwing -q` (the same check
`start()` uses) instead of trusting `State.Running`. ~2 lines.

---

## 5. Why this is specifically a *rootless + OpenRC* problem

It's worth being precise about why the easy answers don't apply here:

- **Quadlet (`.container` units)** — the canonical modern way to run rootless
  podman containers as supervised, boot-persistent services — is **systemd-only.**
  No Quadlet on OpenRC.
- **`podman generate systemd` / `--sdnotify`** — systemd-only.
- **Podman healthchecks** — scheduled by transient systemd timers; **inert on
  OpenRC** unless you invoke `podman healthcheck run <ctr>` yourself.
- **`--restart` policies** — need the (rootful) podman/docker daemon; no-op
  rootless.

So on this leg the supervision *must* be expressed in OpenRC terms. The good news
is OpenRC's `supervise-daemon` plus podman's own blocking primitives
(`podman wait`, `podman start -a`/`run`) compose cleanly into a real supervisor.

---

## 6. Fix options (ranked)

### Option 1 — Event-driven `podman wait` babysitter ⭐ (recommended)

Give each container a tiny **supervised** OpenRC unit whose foreground command
blocks on the container's lifetime. `podman wait <ctr>` blocks until the
container exits, then returns its exit code. Run that under `supervise-daemon`:
when the container exits, `podman wait` returns, the supervised command exits,
`supervise-daemon` respawns it, and on respawn it `podman start`s the container
again.

Result: **near-instant crash detection + restart, zero polling, no systemd, no
15-minute latency** — the same liveness guarantee the Rust binaries already have.

Sketch (`/etc/init.d/lunarwing-pg-<t>-sup`, or fold into the existing unit):

```sh
#!/sbin/openrc-run
# Supervised babysitter: blocks on `podman wait`, respawns on container exit.
supervisor="supervise-daemon"
command="/bin/sh"
command_args="-c 'exec lunarwing-ctr-babysit ${pg_container}'"
command_user="${pg_user}:${pg_user}"            # rootless: run as the tenant
respawn_delay=2 respawn_max=10 respawn_period=120

start_pre() {
    # rootless env must be present for the supervised child
    checkpath -d -m 0700 -o "${pg_user}:${pg_user}" "/run/user/${pg_uid}"
    export HOME="${pg_home}" XDG_RUNTIME_DIR="/run/user/${pg_uid}"
}
```

…where the helper is roughly:

```sh
# lunarwing-ctr-babysit <container>
ctr="$1"
podman start "$ctr" >/dev/null 2>&1 || true       # ensure up on (re)spawn
exec podman wait "$ctr"                            # block until it exits → exit code
```

**Caveats / details to nail down:**
- Thread the rootless env (`HOME`, `XDG_RUNTIME_DIR=/run/user/<uid>`) to the
  supervised child. `command_user` sets uid/gid but not the env — export it in
  `start_pre` or wrap in `sudo -u <t> env …` (consistent with the existing
  `_pg()`/`_wk()` helpers).
- Crash-loop containment: `respawn_max`/`respawn_period` so a container that
  exits instantly doesn't hot-loop. After the cap, OpenRC marks it `crashed` →
  the `*/15` self-heal + escalation path still catches it as the backstop.
- Keep the existing health-aware `status()` (it's what `health-openrc.sh` reads),
  but liveness recovery no longer *depends* on the sweep.

### Option 2 — Run the container in the foreground under `supervise-daemon`

Change the container units themselves to a supervised foreground run:

```sh
command="${pg_runtime}"
command_args="run --rm --replace --name ${pg_container} <args...> <image>"
supervisor="supervise-daemon"
respawn_delay=5 respawn_max=5 respawn_period=60
```

`--replace` reconciles the existing named container; foreground keeps conmon in
the foreground so `supervise-daemon` can watch and respawn it. Conceptually the
cleanest (OpenRC supervises the container directly), but: (a) the rootless env
must reach `supervise-daemon`'s child, (b) foreground mode changes log routing
(podman logs → `output_log`/`error_log`), and (c) named-volume / data ownership
behavior under `--rm` needs verification. More invasive than Option 1.

### Option 3 — Cheap mitigations if the detached model is kept (interim)

- **Per-unit grace override:** set `GRACE_CHECKS=1` *for container units* — an
  exited container is unambiguously dead; there's no value in waiting a second
  tick. (Self-heal grace is global today; this needs a per-target override or a
  separate self-heal invocation for container units.)
- **Dedicated fast liveness cron:** a `*/1`–`*/2` job that probes only container
  liveness (separate from the full `*/15` sweep), cutting worst-case from ~30 min
  to ~1–2 min with no architectural change.

These reduce latency but never reach the ~5 s the binaries get; they're a stopgap.

### Option 4 — Fix PG `status()` (do regardless) ⭐

Make `lunarwing-pg-<t>`'s `status()` run `pg_isready` (mirror `start()`'s check)
instead of `State.Running`. Closes the false-healthy hole in §4. Tiny, safe, and
independent of which supervision option is chosen.

---

## 7. Recommendation

**Adopt Option 1 (`podman wait` babysitter) + Option 4 (`pg_isready` in
`status()`).**

- Option 1 gives the rootless/OpenRC leg **docker-parity crash recovery**
  (seconds, not tens of minutes) using only OpenRC + podman primitives — no
  systemd dependency, which is the whole point of this leg.
- Option 4 closes the "running but wedged" blind spot for the most critical
  container (the DB).
- The `*/15` self-heal sweep remains as the **backstop / escalation path** (it
  still handles the post-`respawn_max` `crashed` state, flapping → escalation,
  and Gotify paging) — we are *adding* a fast local loop, not replacing the slow
  global one.

Apply the same babysitter to the workers (`render_worker_openrc_unit`); their
`_wk_healthy` check already distinguishes "running" from "healthy," so they only
need the supervision layer, not the `status()` fix.

---

## 8. Verification / how to reproduce

On a tenant (rootless/OpenRC), kill a container out from under OpenRC and time
recovery:

```sh
# As the tenant (or via the _pg/_wk helper):
podman kill lunarwing-pg-<t>          # hard-stop, bypassing rc-service stop
date                                  # mark t0
# Watch: rc-service lunarwing-pg-<t> status   → reports stopped immediately,
#        but recovery waits for the */15 sweep + GRACE_CHECKS=2 (~15–30 min).
tail -f <base>/workspace/self-heal/actions.log
```

Expected today: a `GRACE` log line on the first tick, a `RESTART_BEGIN` on the
second. With Option 1 in place: container restarts within seconds, no sweep
needed.

### Suggested regression coverage

Extend the self-heal harness with a container-specific scenario:
- `ic-infrastructure-health-check/tests/chaos-harness.sh` — add "kill rootless
  container, assert recovered within N seconds (supervised) vs N minutes (sweep)."
- `ic-infrastructure-health-check/tests/test-self-heal-matrix.sh` — add a
  false-healthy case: container `Running` but `pg_isready` failing, assert
  `status()` reports `stopped`/`critical` after the Option 4 fix.

---

## 9. Code reference index

| Concern | Location |
|---------|----------|
| Supervised binary unit (main daemon) | `ic/scripts/lunarwing-mt-admin.sh:2098-2161` (`supervisor` @ `:2126`, respawn @ `:2116-2118`/`:2128-2130`) |
| Supervised binary units (xmpp / proxy / weechat-adapter) | `:2190`, `:2252`, `:2357` |
| PG container unit (unsupervised) | `:2033-2094` — `start()` `:2062-2076`, `status()` `:2085-2093` (State.Running only @ `:2089`), `pg_isready` in start @ `:2070` |
| Worker container unit renderer | `:280-354` — `_wk_healthy` (Running AND `/health`) `:317-320`, `start()` `:322-336`, `status()` `:345-351` |
| Worker unit registration ("health-monitored, self-healed, boot-persistent") | `_register_worker_unit` `:358-366` |
| `--restart` no-op under rootless | `:1599-1600` (nanocode), `:1695-1696` (pebble), `:1752-1755` (pg) |
| `need lunarwing-pg-<t>` (ordering, not runtime) | `:2136` |
| OpenRC service auto-discovery | `ic-infrastructure-health-check/health-openrc.sh:11-36` |
| OpenRC status wording parser | `health-openrc.sh:80-90` |
| Self-heal grace period (`GRACE_CHECKS=2`) | `ic-infrastructure-health-check/lunarwing-self-heal.sh:45`, logic `:591-595` |
| Self-heal OpenRC restart | `lunarwing-self-heal.sh:230-237` |
| Self-heal init-system detection | `lunarwing-self-heal.sh:145-161` |
| Schedule | fcron `*/15` (per MT-admin self-heal wiring) |

---

## 10. Relationship to other docs

- [`ROOTLESS_WORKER_OPENRC_UNITS.md`](../internal/history/proposals/ROOTLESS_WORKER_OPENRC_UNITS.md) — created
  the worker units this proposal then supervises. That doc closed the
  *visibility* gap (units exist, sweep can see them); this one closes the
  *latency/supervision* gap (recover in seconds, not on the next sweep).
- The self-healing series (`SELF_HEALING_IMPROVEMENTS_1/2.md`, archived under
  [`../internal/history/proposals/`](../internal/history/proposals/)) — the
  sweep-based engine that remains the backstop here.
- The broader in-flight review (Map → Recommend → Verify → Synthesize) over the
  whole OpenRC health-check + self-heal + rootless-podman system is expected to
  surface adjacent items (podman storage hygiene, XDG_RUNTIME_DIR-in-cron
  correctness, observability/alert dedup); cross-reference its output when it
  lands and fold any overlapping verdicts into §6 here.
