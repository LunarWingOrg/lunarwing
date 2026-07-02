## Status (2026-07-02)

Polish + repo-doc pass addressed:
- `build-tenant --with-opencode` now threads through `build_tenant` (banner + consistency) instead of building separately.
- `build_opencode_worker` carries the `--network=host`/`--format docker` rationale comments (F8/O4) matching nanocode/pebble.
- opencode upstream pinned to release tag via `OPENCODE_REF` build arg (default `v1.17.13`); overridable.
- `opencode4lunarwing/README.md` CLI invocation corrected (uses `TASK_PROMPT` env).
- `migrate-ports-v10-to-v11.sh` brought to parity with v8/v9/v10 standalone migrators: strict `version < 10` gate, timestamped backup, collision-uniqueness validation, rollback hint.
- Repo-level docs updated: `README.md` (Opencode Worker bullet, v11 schema ref, worker-type count), `docs/README.md` (index parenthetical + worker-dir list), `docs/ops/WORKER-CONTAINERS.md` (Opencode + Pebble sections), `docs/ops/MULTITENANCY-PRODUCTION.md` (build flags, configure-opencode, extended port block, v11 schema, dir layout, OpenRC brace list, command reference), `docs/guides/MT-ADMIN-QUICKSTART.md` (prereq + extended port map), `docs/ops/TENANT-CONFIGURATION.md` (systemd/OpenRC unit lists + extended port table), `docs/ops/ROADMAP_2026.md` (opencode row marked shipped-early v1.1.8), `docs/ops/GOALS_1.1.8.md` (item #8 marked done).

## Remaining follow-ups

- Live end-to-end test: build `lunarwing-worker-opencode:latest`, run the smoke profile, spin up a tenant, verify the orchestrator connects and a task round-trips.
- Update `docs/ops/NANOCODE-MULTITENANT.md` version drift ("current is v5" → v11) if that doc is refreshed.
- `opencode_task_executor.ts:119-128` — `part.tool`/`part.state.output` access should be smoke-verified post-build against the v2 SDK types.

## OpenRC / Gentoo compatibility (2026-07-02)

The opencode integration in `lunarwing-mt-admin.sh` itself was complete across every OpenRC path (worker loops, start/stop/render/register, doctor, status). Three opencode-specific regressions were found and fixed in the self-heal infrastructure that the admin script provisions units for:

- `ic-infrastructure-health-check/health-openrc.sh` — `unit_tenant()` now strips the `opencode-` prefix (was falling through, misclassifying stopped opencode workers as `skipped` instead of `critical`, so self-heal never restarted them).
- `ic-infrastructure-health-check/lunarwing-self-heal.sh` — `unit_tenant()` now handles `lunarwing-opencode-*` before the generic catch-all (was resolving to a bogus tenant, routing systemd restarts to system-scope where they fail for user-Quadlet units).
- `ic-infrastructure-health-check/health-systemd.sh` — deep container-health probe now includes `lunarwing-opencode-*` (was only triggering for pg/nanocode/pebble, so a Running-but-wedged opencode container reported healthy).
- `docs/ops/MT-GENTOO-SETUP-AND-CHANGES-MADE.md` — worker image line now mentions opencode.

## Rootless Podman compatibility (2026-07-02)

Audited fleet-wide (nanocode/pebble/opencode share identical launch patterns). Findings:

- **SSH agent socket SELinux label (FIXED, fleet-wide):** all worker launch sites (imperative `_ctr run` for nanocode/pebble/opencode + the Quadlet `render_worker_quadlet`) mounted the SSH agent socket without a `:z` SELinux label. On SELinux-Enforcing Fedora hosts, `container_t` is denied access to the tenant-home-labeled socket, breaking SSH/git-push from workers despite the 0666 socket mode. Added `:z` to all four socket mount sites.
- **Workspace file ownership (DEFERRED, by design):** the workers run as non-root `USER` (system accounts via `useradd -r`, unpredictable UIDs). Under rootless userns, files written to `/workspace` appear owned by a host subuid. `--userns=keep-id` does NOT fix this for non-root `USER` directives (it maps the host user to a *different* container UID than the process runs as); only `keep-id:uid=<fixed-container-uid>` would, which requires pinning the container UID in all three Dockerfiles. The current `chmod 777` on the workspace dir is the working workaround (DAC permits access regardless of owner). Deferring the UID-pinning + `keep-id:uid=` change as a larger, separate hardening pass since it touches all three worker images.

References: [Red Hat — rootless userns modes](https://www.redhat.com/en/blog/rootless-podman-user-namespace-modes), [Podman — `--userns` docs](https://docs.podman.io/en/v4.6.1/markdown/options/userns.container.html), [Podman #25919 — rootless bind-mount SELinux](https://github.com/containers/podman/issues/25919).
