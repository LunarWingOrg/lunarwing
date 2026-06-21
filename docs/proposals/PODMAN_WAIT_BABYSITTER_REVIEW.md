# Review — Podman-Wait Babysitter (`origin/1.1.6-babysitter`)

**Status:** Read-only inspection notes — NOT cherry-picked. Captured for later.
**Date:** 2026-06-21
**Branch reviewed:** `origin/1.1.6-babysitter` (3 commits on `staging`: `a767c726`, `2a637854`, `86f55aee` "finished a first attempt …").
**Reviewed against:** `origin/staging`; the branch's own `docs/proposals/PODMAN_WAIT_BABYSITTER.md`, `docs/specs/podman-wait-babysitter.md`, `docs/plans/rootless-podman-babysitter.md`; and the original gap doc `docs/proposals/ROOTLESS_PODMAN_CONTAINER_SUPERVISION_GAP.md`.
**Method:** multi-agent read-only inspection (impl map + intent/spec + adversarial correctness → synthesis).

---

## Verdict

**Maturity: early-incomplete — a clever, sound-core "first attempt," not yet validated.** The mechanism is genuinely good and not a rewrite candidate; the gaps are integration/packaging footguns plus one make-or-break unverified correctness question. **Do not cherry-pick as-is.**

**Scope (important):** the feature is gated `INIT_SYSTEM == openrc && MT_ROOTLESS == true`. It is a **no-op on systemd** (Quadlet `Restart=on-failure` already supervises containers) and a **no-op on rootful Docker** (`--restart unless-stopped`). So it only helps the **OpenRC + rootless-Podman** leg (the Gentoo VMs), never the Arch/systemd/Docker hosts.

---

## What it implements

Closes the gap where rootless-Podman per-tenant containers (`lunarwing-pg-<t>`, `nanocode`/`pebble` workers) are health-monitored but **not parent-supervised**, so a crash after `start()` returns is only recovered by the ~15-min self-heal sweep (~30 min worst case).

- **`ic/scripts/lunarwing-ctr-babysit.sh`** (NEW, 26 lines, `/bin/sh`, `set -eu`): one arg = container name → `podman start "$ctr" || true` (idempotent ensure-up) → `exec podman wait "$ctr"` (block until the container exits). **No loop in the script** — OpenRC's `supervise-daemon` is the loop: container dies → `podman wait` returns → supervised process exits → respawn re-runs `podman start`. Net: **~seconds crash recovery** vs ~15-30 min, using only OpenRC + podman primitives (mirrors how the Rust binary units are already supervised).
- **`ic/scripts/lunarwing-mt-admin.sh`** (+103): three new functions — `render_container_babysitter_unit`, `_register_babysitter`, `_deregister_babysitter` — all early-returning unless openrc+rootless. Each supervisable container gets a sidecar OpenRC unit `/etc/init.d/<container>-sup` (`supervisor="supervise-daemon"`, `command=/usr/local/sbin/lunarwing-ctr-babysit`, `command_user=<t>:<t>`, `respawn_delay=2 respawn_max=10 respawn_period=120`, `start_pre()` that `checkpath`s `/run/user/<uid>` and exports `HOME`/`XDG_RUNTIME_DIR`). Wired into `start_tenant_openrc`, `stop_tenant_openrc` (stops `-sup` **before** its container), `uninstall_tenant_openrc`, `status_tenant`, the boot-enable loop, and worker registration (`_register_worker_unit`, lines 1911/2021). Container units themselves are unchanged.
- **`ic/scripts/install-lunarwing-watchdog.sh`** (+9): the OpenRC leg installs the helper to `/usr/local/sbin/lunarwing-ctr-babysit` (0755 root:root) and removes it on cleanup.

Supervised set = exactly `{pg, nanocode, pebble}`.

---

## What's solid

- Core `podman start` + `exec podman wait` + supervise-daemon respawn design is correct; helper is shellcheck-clean, `set -eu`, validates its arg.
- **Restart-storm protection is bounded:** `respawn_delay=2 / max=10 / period=120`, with the */15 self-heal sweep as documented backstop after the cap (no unbounded hot-loop).
- **Main stop paths get ordering right:** `stop_tenant_openrc` stops the `-sup` units before the containers, so the babysitter does not fight an intentional stop; `stop/restart/remove` and `upgrade-tenant.sh` (rootful → no `-sup`) avoid the resurrection race.
- **Clean separation:** `podman wait` is a pure observer — stopping `-sup` kills only the wait client, never the container; the container unit keeps sole `stop()` ownership.
- Correct gating; `_deregister_babysitter` keys off the unit file existing (cleans up even if the rootless flag later changed).

---

## Spec-coverage

| Acceptance criterion | Status | Note |
|---|---|---|
| Docker-parity ~5s crash recovery, OpenRC+podman only, no systemd | **Met** | By design (`podman start`+`exec podman wait`+respawn). |
| Original container units unchanged; babysitter owns liveness only | **Met** | Diff doesn't touch container `start/stop/status()`. |
| Inert outside target leg (openrc && rootless) | **Met** | All three functions gated. |
| Non-goals (rootful-docker, systemd-rootless legs) unaffected | **Met** | Gated out. |
| Sweep preserved as backstop (not replaced) | **Met** | `health-openrc.sh` glob `/etc/init.d/lunarwing-*` discovers `-sup`. |
| Fault-injection: kill container → `-sup` recovers in ~seconds | **Partial** | Mechanism present, **not validated**; the plan's own "kill container, verify recovery" item is undone; no chaos/regression test added. |
| Rootless env (`HOME`/`XDG_RUNTIME_DIR`) correctly threaded to the supervised child | **Partial** | Structurally present, **unverified** — see the make-or-break finding. |
| Full lifecycle wiring (render/start/stop/uninstall/status), idempotent | **Partial** | Main paths correct; gaps: `_deregister_worker_unit` ordering bug + dead code; no symmetric per-tenant PG deregister; PG render-vs-start asymmetry with workers. |
| Helper installed 0755 + removed on cleanup | **Partial** | Works, but only via the **watchdog** installer — install-coupling footguns below. |
| PG `status()` uses `pg_isready` (not just `State.Running`) | **Met — but already on `staging`** | The branch claims this as part of the feature; the diff has **zero** `pg_isready` changes — overstated scope. |
| Regression coverage (chaos-harness + self-heal-matrix cases) | **Missing** | Not added. |

---

## Findings

### Medium
1. **Env-threading unverified (the make-or-break).** This is the *first* place mt-admin supervises a rootless-podman command **directly** (`command_user` + `start_pre` export of `HOME`/`XDG_RUNTIME_DIR`) instead of the proven `sudo -u <t> env …` wrapper used everywhere else. If `supervise-daemon` resets `HOME` on the setuid switch (version-dependent), the helper's bare `podman` can't find the tenant store → `-sup` crash-loops to `respawn_max` → container left unsupervised. No fallback, no `output_log`/`error_log` to diagnose. **Needs a real OpenRC/rootless host test.**
2. **Install coupling — helper can go silently absent.** mt-admin renders `-sup` units that `exec /usr/local/sbin/lunarwing-ctr-babysit`, but the **only** installer of that binary is `install_openrc_watchdog()`. On an upgrade where add-tenant/render runs without re-running the watchdog installer, the helper is missing → `-sup` fails ENOENT → recovery silently reverts to the 15-min sweep, and self-heal churns on the broken unit. No existence guard.
3. **Watchdog uninstall removes a shared helper.** `cleanup_openrc_watchdog()` now `rm -f`s `/usr/local/sbin/lunarwing-ctr-babysit` — a shared dependency of **every** tenant's `-sup` unit. Reinstalling/removing the (independent) watchdog silently breaks crash supervision for all tenants. Ownership belongs with mt-admin, or removal should be guarded on "no `-sup` units remaining."
4. **`_deregister_worker_unit` stop-order bug (latent).** It stops the worker container **before** the `-sup` → `podman wait` returns → respawn brings the container back up → then `-sup` is stopped → orphaned, unsupervised container. The correct order is used in `stop_tenant_openrc`. **Currently dead code (zero call sites)**, so it's a trap for whoever wires worker removal next, not a live bug.

### Low
1. **`podman stop` footgun (undocumented):** once `-sup` is active, a manual `podman stop`/`kill` is reverted in ~2s; cold backup/maintenance must stop the `-sup` unit first. Behavioral change, not in any runbook.
2. **Self-heal overlap:** babysitter + the */15 sweep are two uncoordinated recovery loops on the same container. Bounded (respawn caps; sweep re-arms only every ~15 min), not destructive, but a self-heal `restart` can cause an extra respawn.
3. **Boot start race:** `lunarwing-pg-<t>` and `…-sup` are both enabled with no ordering, so both `podman start` concurrently at boot. Errors swallowed → benign, but fragile (the `-sup` unit could `use`/`after` the container unit).
4. **Doc/comment misstatements:** the helper comment says `exec podman wait` exits "with the container's exit code" — `podman wait` actually exits 0 and prints the code to stdout (works anyway via respawn). No `output_log`/`error_log` on the unit (failures invisible). Spec says `/usr/local/bin`; impl uses `/usr/local/sbin`.

---

## Stray (unrelated) changes bundled on the branch

1. **RELEASE-v1.1.5 note relocation** — deletes the 5-line stub `docs/RELEASE-NOTE-v1.1.5.md` and adds a fresh **201-line `docs/releases/RELEASE-v1.1.5.md`** (Kawarimi). Verified **not** a git rename (staging has no such file). Real, useful release-docs work, but **zero connection to the babysitter** — scope creep, not corruption. Should land on its own docs commit/PR.
2. **New `docs/ops/GOALS_1.1.6.md`** — 16-line checklist, codename "Unknown," all items unchecked, no mention of the babysitter. Harmless; confirms 1.1.6 goals weren't updated for this feature.

Both should be excluded from any eventual babysitter cherry-pick so the feature lands cleanly scoped.

---

## Done vs TODO

**Done:** the helper; the 3 mt-admin functions + gating; full lifecycle wiring (start/stop/uninstall/status/boot-enable); worker registration; installer hooks; restart caps; the proposal/spec/plan docs.

**TODO (its own plan's items, unmet):** fault-injection validation; decouple helper install from the watchdog (+existence guard); verify env threading on a real host (add a fallback + logs); fix `_deregister_worker_unit` ordering; reconcile path/mechanism docs (`/sbin` vs `/bin`, installer-only vs render-systemd/launchd); correct the "pg_isready fix" overstatement (already on staging); update `GOALS_1.1.6.md`/`ROADMAP_2026.md`; document the `podman stop` operator caveat; split the stray RELEASE/GOALS docs out.

---

## Critical path to "pick-worthy"

1. **Verify env-threading on a real OpenRC/rootless host (the gate):** kill `lunarwing-pg-<t>`, confirm `-sup` revives it in ~2s **and** that `HOME`/`XDG_RUNTIME_DIR` survive supervise-daemon's setuid. Add a fallback (the `sudo -u <t> env …` wrapper) + `output_log`/`error_log` if it doesn't.
2. **Move the helper install under mt-admin** with an existence guard before wiring `-sup` units; stop the watchdog uninstall from nuking it.
3. **Fault-injection test** + fix `_deregister_worker_unit` ordering while it's cheap.
4. **Split the stray RELEASE-v1.1.5 / GOALS docs** onto their own commit.

Items 2–4 are mechanical; item 1 is the real gate. Validation belongs on a Gentoo/OpenRC VM, not a systemd/Docker host.

---

## Open questions for the owner

1. Does `supervise-daemon` preserve the `start_pre`-exported `HOME` across its setuid to the tenant, or clobber it? (Make-or-break; nothing on the branch validates it.)
2. Where should the helper binary be owned/installed — mt-admin (render-time, guarded) rather than the watchdog subsystem?
3. Which is canonical: `/usr/local/sbin` (impl) vs `/usr/local/bin` (spec); watchdog-installer-only (impl) vs render-systemd/launchd + packaging (spec)?
4. Require fault-injection + chaos/self-heal regression cases before cherry-pick?
5. Fix `_deregister_worker_unit`'s stop-order now (dead code) to avoid a latent orphan trap?
6. Split the RELEASE/GOALS docs out so the feature lands cleanly scoped?
7. Document the "supervised container can't be `podman stop`'d directly" operator caveat?
