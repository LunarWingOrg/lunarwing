# Systemd Multi-Tenant / ICHC Issues — 1.1.4 First Real Pass

**Context.** The systemd multi-tenant path (rootless-podman Quadlets + per-tenant user
units + host-global ICHC/self-heal) has **not** been exercised as thoroughly as the
Gentoo/OpenRC path. This doc records issues found during the 1.1.4 pre-release pass on the
**Arch Linux** MT test VM (goals 5–8 in `docs/ops/GOALS_1.1.4.md`) and proposes fixes.

**Test VM facts.** systemd; rootless podman; tenants `summer`/`autumn`/`winter` (created on a
`1.1.4`-named branch but crate version still `1.1.3`, provisioned with
`LUNARWING_CONTAINER_RUNTIME=docker` → pg/nanocode/pebble run as **Docker** containers, not
systemd units). New tenant `springfeather` provisioned with
`LUNARWING_CONTAINER_RUNTIME=podman` to exercise the **new** Quadlet systemd-unit path.

**Status legend:** 🔴 open · 🟡 workaround applied, code fix pending · 🟢 fixed (code)

**Fix status (2026-06-17):** all six fixed in code on `1.1.4-staging-goals`, then a
6-agent adversarial review (see below) returned NO-GO and a second hardening pass
followed. ICHC test suite green at **229/229** (added F3 dry-run case, F5 `CH14`
crash-loop chaos case + `SubState` mock, and a new `tests/test-health-systemd.sh`,
14 cases). End-to-end re-validation by provisioning a brand-new tenant (goal 13) is
**deferred** ("later" per operator) — code is in place, live verification pending.

---

## Summary

| # | Severity | Area | Status |
|---|----------|------|--------|
| F1 | High | pg/worker image uses **short name** → rootless podman can't resolve without `unqualified-search-registries` | 🟢 FQ image via `PG_IMAGE` (override `LUNARWING_MT_PG_IMAGE`); host drop-in also applied |
| F2 | High | `add-tenant` pg **readiness gate races** on the Quadlet path → aborts mid-provision, leaving a half-baked tenant | 🟢 health-status gate, non-fatal (warn+continue, no `die`) |
| F3 | Medium | Freshly-added (rendered-but-not-started, `disabled`) units reported **critical**; live self-heal churns on unbuilt units | 🟢 enable/active-state gating → `skipped`; self-heal ignores `skipped` |
| F4 | Medium | `add-tenant` is **not idempotent/resumable** — a mid-flow failure can't be re-run (`already has ports allocated`) | 🟢 `ports_allocate` reuses existing block (resume) |
| F5 | Low–Med | self-heal `is-active` post-restart **verify false-positives** on a crash-looping (auto-restart) unit | 🟢 verify rejects `auto-restart`/`failed` substate |
| F6 | Medium | `remove-tenant --purge` **falsely reports user removal** — `userdel` races session teardown, failure swallowed | 🟢 terminate-user + wait + honest exit-code check |
| F7 | Low | `--with-wasm` build breaks on the `telegram` tool — `core2 0.4.0` is **yanked** (transitive via `glass_pumpkin`); Telegram is an unsupported channel | 🔴 open (upstream dep) |
| F8 | Medium | nanocode/pebble worker image build fails under podman — the build-RUN container's `apt` can't reach the internet (host has no IPv6 route; the default build network can't route IPv4 out) | 🟢 fixed — `--network=host` on the podman worker builds; both images now build (apt reaches the net via the host netns) |
| F9 | — | ~~`build-tenant` exits 0 on a worker-build failure~~ — **NOT a bug**: `build-tenant` `die`s (exit 1) and propagates correctly. The observed "exit 0" was a test-harness artifact (a trailing `echo "...$?"` in the background wrapper masked the real exit). | 🟢 invalid |
| F10 | Medium | `_ctr` runs `sudo -u <tenant>` without a tenant-traversable CWD → "cannot chdir" → the rootless pg readiness gate **always** times out (spurious 120s WARNING) | 🟢 fixed — `cd /` in `_ctr` (gate now ~3s, "ready via quadlet") |
| F11 | Low | nanocode worker image is **~6 GB**; per-tenant `save\|load` distribution into the rootless store is slow + disk-heavy and can fail under disk pressure (succeeded on retry) | 🟡 mitigated (retry); follow-up: trim the image / shared additionalimagestore |
| F12 | Medium | worker Quadlet emitted `KillMode=process` in `[Service]` → the Quadlet generator **rejected** the `.container` ("invalid KillMode") → no `.service` generated → workers never started (pg's quadlet has no `KillMode`, so it worked) | 🟢 fixed — removed `KillMode=process` from `render_worker_quadlet` |

---

## F1 — Short image name breaks rootless-podman pg/worker containers

**Symptom.** `add-tenant … LUNARWING_CONTAINER_RUNTIME=podman` fails starting per-tenant pg:
```
lunarwing-pg-springfeather.service … podman run … pgvector/pgvector:pg16 (exit 125)
Error: short-name "pgvector/pgvector:pg16" did not resolve to an alias and
       no unqualified-search registries are defined in "/etc/containers/registries.conf"
error: PostgreSQL for springfeather did not become ready
```

**Root cause.** `ic/scripts/lunarwing-mt-admin.sh` references the pg image by **short name**
`pgvector/pgvector:pg16`:
- line **1906** (imperative `_ctr run` path, used by docker/rootful)
- line **2129** (`Image=pgvector/pgvector:pg16` in the Quadlet `.container` generator)

Docker silently resolves short names against Docker Hub, so the existing docker tenants worked.
Rootless **podman** requires either an alias or `unqualified-search-registries`; this Arch host's
`/etc/containers/registries.conf` defines neither for `pgvector/pgvector`.

**Impact.** Any fresh 1.1.4 tenant on the rootless-podman/Quadlet path fails to provision on a
host without `unqualified-search-registries`. Also affects release-notes accuracy.

**Workaround applied (host).** Drop-in `/etc/containers/registries.conf.d/99-lunarwing-unqualified.conf`:
```
unqualified-search-registries = ["docker.io"]
```
Verified: `podman pull pgvector/pgvector:pg16` → `docker.io/pgvector/pgvector:pg16`.

**Proposed code fix.** Emit **fully-qualified** image names in the generator/run paths
(`docker.io/pgvector/pgvector:pg16`), so resolution is independent of host registry config and
runtime. FQ names bypass short-name resolution entirely (no host change needed). Centralize the
image in one variable (e.g. `PG_IMAGE="docker.io/pgvector/pgvector:pg16"`). Audit the
nanocode/pebble worker Dockerfiles' `FROM` lines for the same short-name hazard under
`podman build`.

**Release note.** Document the `unqualified-search-registries` requirement for operators on the
rootless-podman MT path (until FQ-name fix ships).

---

## F2 — `add-tenant` Postgres readiness gate races on the Quadlet path

**Symptom.** With the image present, `add-tenant` still aborts:
```
--- Starting PostgreSQL ---
error: PostgreSQL for springfeather did not become ready
```
…but the pg container is in fact **up and healthy**:
```
lunarwing-pg-springfeather | docker.io/pgvector/pgvector:pg16 | Up (healthy) | 127.0.0.1:10033->5432
unit: active/running, NRestarts=0
podman exec … pg_isready -U lunarwing  → exit 0   (works once settled)
```

**Root cause.** In `start_tenant_postgres()` (Quadlet branch, ~lines 1857–1872):
```sh
_systemctl_user "$name" start "lunarwing-pg-${name}.service"   # returns when container *running*, not when pg ready
while ! _ctr "$name" exec "$container_name" pg_isready -U lunarwing -q 2>/dev/null; do
    [[ $q_attempts -lt 90 ]] || die "PostgreSQL for $name did not become ready"
    sleep 1
done
```
The gate polls via `sudo -u <tenant> podman exec … pg_isready`. During the container's first-run
initdb cycle (temp server up→shutdown→real server) the `exec`-based probe fails for a window long
enough to exhaust the 90×1s budget on this host, even though the container's **own** healthcheck
(identical `pg_isready -U lunarwing -q`) reports `healthy` shortly after. The `die` then aborts
the **entire** provision before `render_tenant_systemd_units` and `ensure_health_pipeline` run.

**Impact.** Tenant left half-provisioned: ports allocated + pg running, but app units **not
rendered** and health pipeline **not installed**. Combined with F4, the operator can't simply
re-run. (Worked around manually here via `render-units` + sourcing `ensure_health_pipeline`.)

**Proposed code fix (pick one, ideally both):**
1. **Robust gate:** poll podman's built-in health instead of `exec` —
   `podman inspect -f '{{.State.Health.Status}}' <ctr>` until `healthy` (the Quadlet already
   defines the healthcheck), with a longer/clearer timeout; tolerate transient probe errors and
   verify the unit is `active` first. Avoids the exec-vs-initdb race.
2. **Don't abort the whole provision on a slow pg:** downgrade the pg-readiness timeout to a
   `warn` + continue (render units, install pipeline), or make pg-readiness a post-step the
   operator/self-heal can recover, so a slow first-boot doesn't strand the tenant.

---

## F3 — Freshly-added (not-yet-started) tenant flagged critical; self-heal churns

**Symptom.** Immediately after `add-tenant` (pipeline installed) but before `build`/`start`,
the new tenant's rendered units are `disabled`/inactive, and ICHC reports:
```
overall=CRITICAL  total_units=21
springfeather: lunarwing-* / xmpp-bridge-* = inactive/dead → critical   (pg = healthy)
```
The live `lunarwing-mt-health.timer` (15 min) then drives self-heal to repeatedly try to start
units whose binaries aren't built yet → guaranteed failures → backoff/escalation noise.
(summer/autumn/winter remain healthy and untouched — isolation is correct.)

**Live evidence (host pipeline, 22:15 timer fire).** With grace met (obs=2), self-heal acted on
springfeather's down units and successfully restarted **and verified healthy**
`lunarwing-weechat-springfeather`, `lunarwing-weechat-adapter-springfeather`, and
`xmpp-bridge-springfeather` (these don't require the Rust build), while recording
`lunarwing-springfeather.service` (main daemon — needs the unbuilt binary) at `retries=1` (backs
off → escalates at max-retries, then self-limits). Net effect: self-heal **partially "started" a
tenant the operator had only `add`-ed, not `start`-ed**, overriding operator intent — while also
demonstrating the live restart→verify→clear path on real units (the path Phase A only mocked).
This sharpens the fix: self-heal must not *start* units for a tenant that has never been
`start`-ed (gate on enabled-state and/or a per-tenant "started" marker), distinct from recovering
a unit that was up and crashed.

**Root cause.** `health-systemd.sh` classifies any enumerated unit that is `inactive/dead` as
`critical` regardless of whether it is **enabled**. A `disabled`/never-started unit being
inactive is the *expected* state for a tenant between `add-tenant` and `start-tenant` (and for any
unit an operator deliberately disabled). self-heal then treats these as remediable init sub-units.

**Impact.** Whole-host report flips to `critical` and self-heal wastes cycles (and may escalate)
on a tenant that is simply mid-provisioning. Misleading during the (long) build window.

**Proposed code fix.** Treat unit **enabled-state** as a gate: a unit that is `disabled`
(or `static`/never-enabled) and `inactive` is **not** critical (report `skipped`/`stopped`,
not `critical`); only `enabled` units that are `inactive`/`failed` are critical. Mirror this in
self-heal target selection (don't remediate disabled units). Alternatively, `add-tenant` should
enable+register the pipeline coverage for a tenant only after its first successful `start-tenant`.

---

## F4 — `add-tenant` is not idempotent / resumable

**Symptom.** After F2 aborts mid-flow, re-running the exact command fails:
```
error: tenant 'springfeather' already has ports allocated
```
(guard at `lunarwing-mt-admin.sh:617`).

**Impact.** No clean recovery from a partial provision; operator must `remove-tenant` (deallocate
+ uninstall) and start over, or hand-run internal functions (as done here). Brittle on exactly the
flaky path (F2) where resumability matters most.

**Proposed code fix.** Make `add-tenant` resumable: detect an existing tenant and skip
already-completed steps (clone/env/toolchains are already idempotent), or add `--resume`/`--force`
to continue from the failed step. At minimum, on failure print the precise resume command
(`render-units` + a pipeline-install verb).

**Related gap.** There is no standalone verb to (re)install the health pipeline
(`ensure_health_pipeline`); it only runs inside `add-tenant`. Consider exposing
`install-health`/`ensure-health` as a subcommand.

---

## F5 — self-heal post-restart verify can false-positive on a crash-looping unit

**Symptom.** At the 22:15 fire, self-heal logged `SUCCESS: xmpp-bridge-springfeather.service
healthy after restart` and cleared it from state, but the unit is actually in
`activating (auto-restart)` (crash-looping — its binary/config isn't ready).

**Root cause.** For per-tenant units without a dedicated health probe, self-heal's verify falls
back to `systemctl is-active --quiet`. A unit with `Restart=always` is briefly `active` between
crashes; a single `is-active` sample taken in that window reads as healthy, so the restart is
recorded successful and the unit is dropped from tracking — until the next 15-min cycle re-observes
it down.

**Impact.** Masks a crash-looping unit for a full cycle; inflates apparent success; bounces a unit
in/out of state. Low–Medium.

**Proposed fix.** Verify should require the unit to *stay* active across a short settle window
(re-check after `settle` seconds) and/or treat `SubState=auto-restart` (or an increasing
`NRestarts`) as not-healthy.

---

## F6 — `remove-tenant --purge` falsely reports user removal

**Symptom.** `remove-tenant <t> --purge` prints `removed user and home directory: <t>` for every
tenant, but the OS accounts and `/home/<t>` **persist** (verified via `getent passwd` / `ls`).
Running `userdel -r <t>` manually a moment later succeeds (rc=0, only a benign
`mail spool … not found` warning).

**Root cause.** In `remove_tenant_user()` (`lunarwing-mt-admin.sh` ~lines 829–840):
```sh
loginctl disable-linger "$name" 2>/dev/null || true
...
userdel --remove "$name" 2>/dev/null || true   # line 837
say "removed user and home directory: $name"     # line 838 — printed unconditionally
```
`userdel` runs immediately after `disable-linger`, while the tenant's `user@<uid>.service` and
processes are still tearing down, so `userdel` fails (user busy, exit 8). The error
(`2>/dev/null`) **and** the non-zero exit (`|| true`) are both swallowed, and the success line is
printed regardless — the operator believes the purge succeeded when the account remains.

**Impact.** Orphaned OS users + home dirs (cargo caches, rootless podman storage, repo clones)
accumulate silently across add/remove cycles → disk leaks and UID/port-reuse surprises.
Misleading output hides it.

**Proposed fix.** Before `userdel`: `loginctl terminate-user "$name"` and wait for the user
manager to stop (poll until `/run/user/<uid>` is gone), then `userdel -r` and **check the exit
code**, retrying/forcing as needed and reporting honestly on failure (don't print success
unconditionally). Treat the `mail spool not found` warning as benign.

---

## Adversarial review (post-fix) — 2026-06-17

A 6-agent adversarial review of the F1–F6 commit returned **NO-GO** and caught follow-on
issues; all were fixed in a second pass:

- **F4-A [HIGH] data loss** — removing the `ports_allocate` guard exposed the non-idempotent
  `write_tenant_lunarwing_env`, which regenerated `SECRETS_MASTER_KEY` (the AES-256-GCM vault
  key — orphaning the tenant's encrypted DB secrets) and rotated `GATEWAY_AUTH_TOKEN` /
  `HTTP_WEBHOOK_SECRET` / `RELAY_PASSWORD` / `XMPP_BRIDGE_TOKEN` on any re-add. **Fixed:** the
  env writer now PRESERVES every existing secret when `lunarwing.env` exists (generates only on
  first write), making resume genuinely safe and the F4 idempotency claim true.
- **F4-B [HIGH]** — `XMPP_PASSWORD` re-minted on resume. **Fixed:** preserve the existing value
  when no `--xmpp-password` is supplied.
- **F3-A [MED] outage masking** — a down `generated` Quadlet pg/worker was classified
  `skipped`, hiding a real outage. **Fixed:** classification now also keys on whether the tenant
  is *started* (primary daemon active) — a down unit on a started tenant is `critical`; only a
  not-started tenant's disabled/generated unit is `skipped`.
- **F3-B [MED] failure bias** — the unconditional `UnitFileState` probe downgraded to `skipped`
  on a timeout and doubled per-unit round-trips. **Fixed:** probe is now lazy (only in the
  inactive branch); an enabled/empty/unknown enable-state fails LOUD as `critical`. (Gotcha:
  `systemctl show --value` returns CANONICAL order, not `-p` order — folding `UnitFileState`
  into the main 4-prop show would have shifted `NRestarts`; kept separate deliberately.)
- Nits also fixed: self-heal `SKIP:` breadcrumb for skipped units; honest F6 message (no longer
  claims "home directory" when `userdel` exits nonzero); F2 warning wording; and **F1-aux** —
  fully-qualified the worker Dockerfile `FROM` lines (`lunarcode4lunarwing`, `pebble4lunarwing`,
  `codex4lunarwing`) so rootless `build-workers` doesn't need `unqualified-search-registries`.
- **New test:** `tests/test-health-systemd.sh` (14 cases) closes the health-systemd coverage
  gap the review flagged. F1/F2/F5/F6 were reviewed **commit-ready**.

Accepted residual nits (scoped, low risk): F5's `failed` verify-arm only covers the inter-sample
race; with `VERIFY_HEALTH=true` a momentarily-healthy crash-looper can still record one SUCCESS,
backstopped by the flapping guard.

## E2E validation (fresh tenant `springfeather`) — 2026-06-18

Provisioned a brand-new 1.1.4 tenant on the Arch systemd VM with the F1 registries
workaround **removed** (so the FQ-image code fix alone must carry it): clean `add` →
`build` → `start` → ICHC. Result: **all-green core tenant** (goal: fix + verify).

- **F1 ✓** — `docker.io/pgvector/pgvector:pg16` pulled and pg came up healthy with no
  registries drop-in.
- **F2 ✓** — `add-tenant` hit the gate timeout (fresh pull + F10) but **warned and
  continued** instead of aborting; pg converged.
- **F3 ✓** — between `add` and `start`, the not-started units reported `skipped`,
  overall `healthy`, and self-heal logged "nothing to do" (no churn / no auto-start).
- **F1-aux ✓** — `FROM docker.io/oven/bun:debian` resolved + pulled without the drop-in.
- After `start-tenant`: all **6 core units** (`pg`, daemon, `proxy`, `weechat`,
  `weechat-adapter`, `xmpp-bridge`) `active/running/healthy`; ICHC overall **healthy**.
- **F10 fixed + validated** — re-run `start-tenant` after the `_ctr` `cd /` fix: pg gate
  passes in ~3 s (`PostgreSQL ready via quadlet`), no spurious 120 s warning.

New issues surfaced: **F7, F8, F10, F11, F12** (F9 investigated → **invalid**). After
fixing **F8** (`--network=host`) the worker images built; bringing the workers *up* then
surfaced **F11** (6 GB nanocode image / `save\|load` distribution under disk pressure —
succeeded on retry) and **F12** (worker Quadlet `KillMode=process` rejected by the
generator → no `.service`). With F8 + F12 fixed (and the images distributed), the **full
tenant is all-green: 8/8 units healthy** — `pg`, `proxy`, daemon, `weechat`,
`weechat-adapter`, `xmpp-bridge`, **nanocode**, **pebble**. Only F7 (telegram, unsupported)
and the F11 image-size follow-up remain.

## Validation plan for the fixes

1. Implement F1 (FQ image) + F2 (robust gate) + F3 (enabled-state gating) + F4 (resumable add) +
   F5 (settle-window verify) + F6 (honest purge).
2. `remove-tenant springfeather` and delete the pg volume to restore the **fresh** failure
   conditions, then `add-tenant springfeather` (podman) — expect a clean, complete provision
   (pg gate passes, units rendered, pipeline installed) with no host registries workaround needed.
3. `build-tenant springfeather --with-wasm --with-nanocode --with-pebble` → `start-tenant`.
4. Re-run ICHC: expect all springfeather units `healthy`, overall `healthy`.
5. Confirm F3: between add and start, the new tenant no longer flips the report to `critical`.
