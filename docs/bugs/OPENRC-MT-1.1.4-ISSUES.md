# OpenRC Multi-Tenant / ICHC Issues — 1.1.4 First Real Fresh-Machine Pass

**Context.** The OpenRC/Gentoo multi-tenant path (rootless-podman + per-tenant OpenRC init
scripts + host-global ICHC/self-heal via fcron) is the **experimental leg** (see
`docs/ops/MULTITENANCY-PRODUCTION.md`; the systemd leg was hardened first in
`docs/bugs/SYSTEMD-MT-1.1.4-ISSUES.md`). This doc records the 1.1.4 pre-release pass on the
**Gentoo/OpenRC/podman** host `eris` (goals 6 & 8 in `docs/ops/GOALS_1.1.4.md`): a **full
teardown to a clean slate** (all tenants + all images removed) followed by a **fresh
provision** of tenant `snapfeather`.

**Test host facts.** Gentoo, OpenRC (PID1=init), **rootless podman 5.8.2**, elogind provides
`loginctl`/linger. Branch `1.1.4-staging-goals` @ `7746fff3` (carries all systemd F1–F12 fixes).
Tenants `zeus`/`creamheart` (uids 1000/1001) torn down with `remove-tenant --purge`; fresh
tenant `snapfeather` provisioned — and **reused creamheart's uid 1001**, which surfaced O1.

**Status legend:** 🔴 open · 🟡 workaround applied, code fix pending · 🟢 fixed (code)

---

## Summary

| # | Severity | Area | Status |
|---|----------|------|--------|
| O1 | **High** | `remove-tenant --purge` leaves stale rootless runtime at `/run/user/<uid>`; a new tenant that **reuses the freed uid** can't start podman → `add-tenant` dies at pg creation (exit 125) → half-baked tenant | 🟡 workaround (`rm` stale `pause.pid`); 2-part code fix proposed |
| O2 | Low–Med | `add-tenant`'s pg readiness gate (F2) warns-and-continues on a *readiness* race, but a pg **creation** failure (`podman run` exit 125) still `die`s the whole provision | 🔴 note |
| O3 | Low | Host `/` mount propagation is `private` (not `rshared`); rootless podman warns `"/" is not a shared mount` on every invocation (non-fatal here) | 🔴 note (host/ops) |
| O4 | Low | `podman build` produces **OCI**-format worker images, so the Dockerfile `HEALTHCHECK` is dropped (`HEALTHCHECK is not supported for OCI image format`). Harmless on OpenRC (worker health = init-unit status + in-container `/health` probe), but the image's baked healthcheck is gone | 🔴 note |
| O5 | **Medium** | On OpenRC the self-heal pipeline **auto-starts a tenant that was `add`-ed but not yet `start`-ed** (F3-analog): it restarted snapfeather's proxy/daemon/weechat/adapter/xmpp-bridge mid-build, overriding operator intent. The systemd F3 enabled-state/started-gate is not mirrored in `health-openrc.sh` | 🔴 open |

### Positive findings (regressions NOT observed on OpenRC)

- **F6 honest purge ✓** — `remove-tenant --purge` removed both OS users **and** home dirs
  cleanly (no orphaned `getent passwd` / `/home/<t>` entries). The F6 systemd fix's behaviour
  holds on OpenRC (no `loginctl`-race false success).
- **F1 FQ image ✓ (by code)** — `PG_IMAGE` defaults to fully-qualified
  `docker.io/pgvector/pgvector:pg16` and every worker Dockerfile `FROM` is FQ; pg pulled +
  ran rootless with the registries drop-in redundant.
- **F4 resume ✓** — after O1 aborted mid-provision, re-running `add-tenant snapfeather`
  cleanly resumed: clone skipped ("repo already cloned"), `health.env` preserved, ports
  reused, pg started, units rendered, health pipeline installed.
- **Health pipeline retire/reinstall ✓** — removing the last tenant retired the fcron
  schedule + launcher; adding `snapfeather` reinstalled it (`*/15`, fcron enabled) and
  preserved the operator-set `/etc/lunarwing/health.env` (Gotify token).

---

## O1 — Stale rootless runtime on uid reuse breaks a fresh tenant's podman

**Symptom.** Fresh `add-tenant snapfeather` (uid 1001, previously creamheart's) aborts:
```
--- Starting PostgreSQL ---
creating PostgreSQL container lunarwing-pg-snapfeather on port 10003
level=warning msg="\"/\" is not a shared mount, this could cause issues … rootless containers"
Error: cannot re-exec process to join the existing user namespace
```
`add-tenant` exits **125** before rendering units or installing the health pipeline → tenant
left half-baked (user + ports + repo + env present; **no units, no health coverage**).

**Root cause.** `ensure_rootless_prereqs()` creates the runtime dir manually:
```sh
install -d -m 0700 -o "$name" -g "$name" "/run/user/$uid"     # ~line 762
```
Because this dir is created by `install -d` (not by a login session), **elogind/logind does
not own it**. On teardown, `remove_tenant_user()` runs `loginctl disable-linger` +
`loginctl terminate-user` and then waits `while [[ -d /run/user/$uid ]]` (≤10 s) — but
`terminate-user` only tears down sessions elogind tracks, so the manually-created
`/run/user/<uid>` is **never removed**; the wait simply times out and the dir (with podman's
`libpod/tmp/pause.pid`) survives.

When the freed uid is reused, the new tenant's rootless podman reads the **stale**
`pause.pid` (here pid `2530`, long dead). With `/` mounted `private` (O3), podman's re-exec to
(re)create the rootless user namespace fails: *"cannot re-exec process to join the existing
user namespace."* Verified the chain live:
- `/run/user/1001/libpod/tmp/pause.pid` dated `01:41` (creamheart-era), contents `2530`,
  pid not alive.
- `sudo -u snapfeather XDG_RUNTIME_DIR=/run/user/1001 podman ps` → reproduced the error.
- `rm -f /run/user/1001/libpod/tmp/pause.pid` → `podman ps` succeeds → re-run `add-tenant`
  completes fully.

**Why systemd didn't hit it.** The Arch systemd pass provisioned `springfeather` on a *fresh*
uid (no reuse); the stale-runtime path is specific to **uid reuse after a purge**, which the
OpenRC fresh-machine teardown→re-add exercises directly.

**Workaround applied (host).** `rm -f /run/user/<uid>/libpod/tmp/pause.pid` then resume
`add-tenant`.

**Proposed code fix (two parts, defence in depth):**
1. **Teardown hygiene** — in `remove_tenant_user()` (purge branch), after
   `loginctl terminate-user` + the wait, explicitly remove the manually-created runtime dir:
   `rm -rf "/run/user/$uid"` (guarded on purge + a sane uid). elogind won't remove it because
   it never owned it.
2. **Provision robustness (primary)** — in `ensure_rootless_prereqs()`, right after creating
   `/run/user/$uid`, clear any pre-existing stale rootless state for the (possibly reused) uid
   — at minimum `rm -f /run/user/$uid/libpod/tmp/pause.pid`; optionally a full
   `podman system migrate` as the tenant. This makes a reused uid start clean regardless of how
   the previous holder was removed.

---

## O2 — pg *creation* failure escapes the F2 warn-and-continue gate

**Observation.** F2 (systemd pass) downgraded a pg **readiness** timeout to warn+continue so a
slow first boot doesn't strand the tenant. But an outright pg **creation** failure — the
`_ctr run … podman run` call returning non-zero (exit 125 in O1) — still `die`s `start_tenant_postgres`
and aborts the whole provision before unit render / health install. The robustness F2 added for
the readiness race does not cover the create-call itself.

**Note / proposed.** Either broaden the non-fatal handling to the create call (warn + continue,
let unit render + self-heal converge pg), or make `add-tenant` resumable past the pg step (F4
resume *did* work once O1 was cleared, so resumability is the lighter lift). Low–Med: the
operator can resume after fixing the underlying cause.

---

## O3 — Host `/` is `private`, not `rshared`

**Observation.** `findmnt -no PROPAGATION /` = `private`. Rootless podman warns
`"/" is not a shared mount …` on every invocation. Non-fatal on this host (containers run), but
it is the second half of O1's failure (the re-exec needs to set up mount propagation) and a
documented rootless-podman recommendation.

**Note / proposed (host/ops).** Document `mount --make-rshared /` (and persisting it) as a
rootless-podman MT prerequisite for OpenRC hosts in `docs/guides/GENTOO_PACKAGE_LIST.md` /
the MT production guide. No daemon code change.

---

## O4 — podman OCI worker images drop the Dockerfile HEALTHCHECK

**Observation.** Both worker image builds warn `HEALTHCHECK is not supported for OCI image
format and will be ignored. Must use "docker" format`. Podman defaults to OCI; the
`HEALTHCHECK` directive in `pebble4lunarwing/Dockerfile` (and nanocode) is therefore not baked
into the image.

**Impact / note.** Low. On OpenRC the worker's health is determined by the init unit's
`status()` (`_wk_healthy` → container running + in-container `curl 127.0.0.1:<hp>/health`), not
the image's `HEALTHCHECK`, so ICHC/self-heal are unaffected. But anyone running the image
directly (or under a runtime that honours `HEALTHCHECK`) gets no built-in health. Optional fix:
build worker images with `--format docker` when the runtime is podman, or document that the
baked healthcheck is intentionally unused under MT.

---

## O5 — self-heal auto-starts an add-ed-but-not-started tenant (OpenRC F3-analog)

**Symptom.** Between `add-tenant snapfeather` and a later `start-tenant`, the host-global
self-heal pipeline (fcron `*/15`) **started the tenant on its own**. Live evidence from
`self-heal/actions.log`:
```
05:15:00Z GRACE   target=lunarwing-proxy-snapfeather            obs=1/2
05:15:01Z GRACE   target=lunarwing-snapfeather                  obs=1/2
05:15:01Z GRACE   target=lunarwing-weechat-adapter-snapfeather  obs=1/2
05:15:01Z GRACE   target=lunarwing-weechat-snapfeather          obs=1/2
05:15:01Z GRACE   target=xmpp-bridge-snapfeather                obs=1/2
05:30:00Z RESTART_BEGIN target=lunarwing-proxy-snapfeather  component=openrc retries=0
05:30:05Z RESTART_OK    target=lunarwing-proxy-snapfeather
05:30:05Z RESTART_BEGIN target=lunarwing-snapfeather …            → RESTART_OK
… (weechat-adapter, weechat, xmpp-bridge all RESTART_OK)
```
At 05:30 the operator had only `add`-ed + was still `build`-ing snapfeather — never ran
`start-tenant`. self-heal started 5 of its units anyway.

**Root cause.** `health-openrc.sh` auto-discovers per-tenant units by scanning `/etc/init.d`
and classifies any discovered-but-stopped unit as remediable, **without** the systemd F3 gate
(F3 treats a not-yet-`start`-ed tenant's units as `skipped`, keyed on the tenant being
"started" / its primary daemon active). On OpenRC the units are rendered by `add-tenant` but
only `rc-update add`-ed (enabled) by `start_tenant_openrc`; self-heal remediates them before
that, overriding operator intent.

**Why it "worked" here.** The daemon binary finished building (~05:27) just before the 05:30
restart, so the starts succeeded. Had the build been slower, self-heal would have tried to
start `lunarwing-snapfeather` before its binary existed → restart failure / crash-loop churn
(exactly the F3 concern).

**Proposed fix.** Mirror the systemd F3 gate in `health-openrc.sh` / self-heal target
selection: a per-tenant unit that is **not in the default runlevel** (never `rc-update add`-ed)
and stopped is `skipped` (not critical, not remediated); only remediate units for a tenant
whose primary daemon (`lunarwing-<name>`) is enabled/started. Equivalently, gate on a
per-tenant "started" marker written by `start_tenant_openrc`.

**Note.** F7-analog confirmed benign: the `--with-wasm` build's `telegram` *tool* failed
(`core2 0.4.0` yanked via `glass_pumpkin`/`grammers-crypto`); the WASM builder logged
`FAIL telegram` and **continued** (the telegram *channel* + all other tools/channels built and
installed). Matches systemd F7 (telegram unsupported).

---

## Validation status — COMPLETE ✓ (goal #6: fresh OpenRC tenant, 8/8 all-green)

- **Teardown → clean slate:** ✓ both tenants + all images removed; 22 GB reclaimed; health
  pipeline retired; **no F6 orphans**.
- **Fresh provision `snapfeather`:** ✓ completed after the O1 workaround (clone on
  `1.1.4-staging-goals` @ `7746fff3`, pg up on `127.0.0.1:10003`, units rendered,
  health fcron `*/15`, `health.env` preserved).
- **Full 8/8 build (`--with-wasm --with-nanocode --with-pebble`):** ✓ real exit 0 — daemon
  (2043 crates), all 5 WASM channels + 5 tools installed (telegram tool skipped per F7),
  nanocode (5.95 GB) + pebble worker images built (F8 `--network=host` worked).
- **`start-tenant`:** ✓ real exit 0 — worker images distributed into snapfeather's rootless
  store via `save|load` (F11 path), containers created, OpenRC worker units registered.
- **ICHC:** ✓ **overall healthy** (gateway/xmpp/omemo/ratelimit/clickhouse/tensorzero/models/
  **openrc** all healthy); self-heal "nothing to do"; no alerts.
- **8/8 units `started`:** pg · proxy · xmpp-bridge · daemon · weechat · weechat-adapter ·
  **nanocode** · **pebble**.
- **Gateway auth:** ✓ `200` with token, `401` without, `200` unauth `/api/health`; version
  `1.1.4`; 8 channels enabled + healthy.
- **Port policy:** ✓ all listeners bound `127.0.0.1` only (gateway/http/bridge/postgres/proxy/
  nanocode-wss/pebble-wss/weechat-adapter; pg + workers via rootless `passt`).

**Minor note.** `logs/lunarwing.log` is 0 bytes under OpenRC `supervise-daemon` (daemon stdout
is routed elsewhere); DB-connected + migrated is confirmed indirectly by the daemon serving
authenticated `/api/gateway/status` with all channels healthy.
</content>
</invoke>
