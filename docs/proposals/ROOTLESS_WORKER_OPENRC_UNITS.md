# Proposal: Promote nanocode/pebble workers to OpenRC services

*Drafted 2026-06-15, after the rootless-Postgres migration (Stage A / A.2).*

## Problem

`nanocode` and `pebble` external workers are plain podman containers created
imperatively by `start_tenant_nanocode` / `start_tenant_pebble` (`podman run -d`
via `_ctr`). They are **not OpenRC services**. Consequences:

- **Invisible to the health pipeline.** `health-openrc.sh` auto-discovers
  `/etc/init.d/lunarwing-*` units; the workers have no init script, so nothing
  observes them.
- **No self-heal remediation.** A crashed worker is never detected or restarted.
- **No boot-persistence.** `--restart unless-stopped` is a no-op under rootless
  podman (no daemon to honor it) and was dropped for the rootless path in A.2 —
  so a rootless worker has *nothing* keeping it up across a reboot or crash.
- **The `/health` endpoint (8443, internal) and the WS port are unmonitored.**
  The worker serves `/health` → 200 and a WS bridge on its `*_wss` port, but the
  container has no baked podman HEALTHCHECK and nothing external probes it.

Postgres was already promoted to a dedicated unit (`lunarwing-pg-<t>`) during the
rootless migration. This proposal extends the **same pattern** to the workers.

## Proposal

Render dedicated per-worker OpenRC units `lunarwing-nanocode-<t>` /
`lunarwing-pebble-<t>` in `render_tenant_openrc_units`, modeled directly on the
`lunarwing-pg-<t>` unit:

- **Rootless-aware run helper** (run podman as the tenant via
  `sudo -u <t> env HOME=… XDG_RUNTIME_DIR=/run/user/<uid> podman …`) — identical
  to the pg unit's `_pg()`.
- **`start()`** — `podman start` the (already-created) container, then wait until
  it's healthy (WS port listening / `/health` 200).
- **`stop()`** — `podman stop`.
- **`status()`** — *health-aware*: report **`started`** when the container is
  running **and** healthy (WS port reachable or `/health` 200), **`stopped`**
  otherwise. **Must emit the OpenRC `started`/`stopped` wording (not `running`)**
  so `health-openrc.sh`'s `grep started|stopped` parser classifies it — this is
  the lesson from the pg `status()` fix (commit `660839f7`).
- **Conditional rendering** — only emit the unit when the worker is actually
  configured for the tenant (the `nanocode.env` / `pebble.env` or the
  `[[sandbox.external_workers]]` entry exists), since workers are optional.

## Benefits (all three at once)

| Gap today | Fixed by the unit |
|---|---|
| Not in health report | Auto-discovered by `health-openrc.sh` glob `/etc/init.d/lunarwing-*` |
| No crash recovery | Self-heal remediates via `rc-service restart` |
| No boot-persistence | Unit is boot-enabled (replaces the dropped `--restart`) |

## Design details

- **Container creation stays** in `start_tenant_nanocode/pebble` (`run -d` via
  `_ctr`); `_ensure_tenant_image` handles image distribution. The unit's
  `start()` just `podman start`s + health-waits, exactly like the pg unit (whose
  container is created by `start_tenant_postgres`).
- **Dependency.** Workers are *independent* of the daemon — the daemon connects
  *to* them on-demand as external workers (`ws://localhost:<wss>/ws/agent`), so
  there is no hard `need` in either direction. Start them in
  `start_tenant_openrc` and boot-enable; `after lunarwing-<t>` is optional.
- **Health signal.** The worker has no baked podman HEALTHCHECK, so `status()`
  must actively check: the published WS port reachable on loopback + a
  `/ws/agent` → 401 (server up, auth enforced) is a solid liveness signal; an
  internal `podman exec curl 127.0.0.1:8443/health` is the deeper check.
- **Lifecycle wiring** (mirror the pg unit): add `lunarwing-nanocode-<t>` /
  `lunarwing-pebble-<t>` to `start_tenant_openrc` (start + boot-enable *when
  configured*), `stop_tenant_openrc`, `uninstall_tenant_openrc`, and the
  `status_tenant` display.

## Out of scope / follow-ups

- **systemd analog.** The systemd leg renders no pg *or* worker unit; a
  quadlet/user-unit story is needed there — see
  `ROOTLESS_DEFAULT_INIT_GATING.md`.
- **Docker (rootful) path.** Under docker the workers keep
  `--restart unless-stopped` (the daemon honors it); this unit pattern is
  podman/OpenRC-specific.

## Validation plan (mirror the pg validation)

1. Render units for a tenant with nanocode/pebble configured; confirm
   `/etc/init.d/lunarwing-{nanocode,pebble}-<t>` exist and `sh -n` clean.
2. `rc-service lunarwing-nanocode-<t> start` → container up, `status: started`.
3. Health check discovers the unit and reports it healthy.
4. **Fault-inject:** kill the container out from under OpenRC → `status` reports
   `stopped` → health `critical` → self-heal `RESTART_OK` → recovered. (Exactly
   the cycle proven for `lunarwing-pg-zeus`.)
