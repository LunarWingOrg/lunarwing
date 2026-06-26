---
plan name: rootless-podman-babysitter
plan description: Implement podman wait babysitter for OpenRC rootless container supervision
plan status: finished (needs review of full implementation)
---

## Idea
Implement the "podman wait" babysitter pattern (Option 1 from ROOTLESS_PODMAN_CONTAINER_SUPERVISION_GAP.md) to provide docker-parity crash recovery for rootless Podman containers on OpenRC. This adds supervised babysitter units alongside existing per-tenant container units (lunarwing-pg-<t>, lunarwing-nanocode-<t>, lunarwing-pebble-<t>) that block on `podman wait` and respawn on container exit via OpenRC's supervise-daemon. Also fixes the PG status() false-healthy bug by making it run pg_isready instead of just checking State.Running.

## Implementation
- Create helper script ic/scripts/lunarwing-ctr-babysit.sh with podman start + podman wait logic
- Install helper to /usr/local/sbin/ via ensure_babysitter_helper() in lunarwing-mt-admin.sh (decoupled from watchdog installer)
- Add render_container_babysitter_unit() function to lunarwing-mt-admin.sh for generating -sup OpenRC units
- Wire babysitter units into tenant lifecycle (start_tenant_openrc, stop_tenant_openrc, uninstall_tenant_openrc)
- Update PG container unit status() to use pg_isready health check instead of State.Running only
- Add babysitter unit registration to _register_worker_unit for nanocode/pebble workers
- Test with fault injection: kill container, verify sub-2-second recovery via supervise-daemon
- Update ROADMAP_2026.md to mark feature as implemented in v1.1.7

## Required Specs
<!-- SPECS_START -->
<!-- SPECS_END -->
