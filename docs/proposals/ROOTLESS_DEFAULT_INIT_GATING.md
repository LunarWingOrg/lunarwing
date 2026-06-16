# Proposal: Gate the rootless default to podman + OpenRC

*Drafted 2026-06-15, after the rootless-Postgres migration (Stage A / A.2).*

## Current behavior

`ensure_container_runtime` sets `MT_ROOTLESS` by **runtime only**:

```
podman → MT_ROOTLESS=true   (any init system)
docker → MT_ROOTLESS=false
override: LUNARWING_MT_ROOTLESS
```

So **podman-on-systemd also defaults to rootless**.

## Gap

The rootless **lifecycle** is only wired for **OpenRC**:

- `render_tenant_openrc_units` renders the dedicated `lunarwing-pg-<t>` unit (and,
  per `ROOTLESS_WORKER_OPENRC_UNITS.md`, will render worker units), runs prereq
  provisioning (`ensure_rootless_prereqs`), and boot-enables everything.
- `render_tenant_systemd_units` renders **no pg or worker unit at all**.

Therefore on **systemd + podman**, mt-admin would create rootless containers
(via `_ctr` → `sudo -u <t>` + `XDG_RUNTIME_DIR=/run/user/<uid>`) that have **no
supervising unit** and **no `--restart`** (dropped for rootless) → they do **not
survive reboot** and aren't self-healed.

> Note: rootful podman-on-systemd was *already* unsupervised — podman has no
> daemon to honor `--restart` regardless of init system — so podman-on-systemd
> was never a fully-supported MT target. This proposal just makes that explicit
> instead of silently producing non-persistent rootless containers.

## Proposal

Default rootless **only** for podman **+ OpenRC** (the fully-wired combo):

```sh
elif [[ "$CONTAINER_RT" == "podman" && "$INIT_SYSTEM" == "openrc" ]]; then
  MT_ROOTLESS="true"
else
  MT_ROOTLESS="false"
fi
```

- **docker** → rootful (unchanged).
- **podman + systemd** → rootful by default; opt into rootless explicitly with
  `LUNARWING_MT_ROOTLESS=true`, accepting the lifecycle gap, until the systemd
  rootless lifecycle is wired.

Implementation note: `ensure_init_system` must run before (or inside)
`ensure_container_runtime` so `INIT_SYSTEM` is populated when the default is
computed.

## Future: full systemd rootless support

To let rootless default `true` on podman+systemd too, wire
`render_tenant_systemd_units` to emit a per-tenant **user-scoped** pg (and worker)
unit — a quadlet `~/.config/containers/systemd/lunarwing-pg-<t>.container` or
`podman generate systemd` output — started via the existing `_systemctl_user`
helper. Linger (already enabled, capability-gated) keeps `/run/user/<uid>` alive
across boot, so the container comes back. Once that exists, drop the
`&& INIT_SYSTEM == openrc` guard.

## Risk if not done

Low today (the only live podman leg is OpenRC), but it's a foot-gun: a future
podman-on-systemd host would get rootless containers that vanish on reboot with
no obvious signal. One-line guard removes the trap.
