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

## Validation status

- **Teardown → clean slate:** ✓ both tenants + all images removed; 22 GB reclaimed; health
  pipeline retired; no orphans.
- **Fresh provision `snapfeather`:** ✓ completed after the O1 workaround (clone on
  `1.1.4-staging-goals` @ `7746fff3`, pg up on `127.0.0.1:10003`, 6 core units rendered,
  health fcron `*/15`).
- **Full 8/8 build (`--with-wasm --with-nanocode --with-pebble`):** _in progress._
- **`start-tenant` + ICHC all-green:** _pending build._
</content>
</invoke>
