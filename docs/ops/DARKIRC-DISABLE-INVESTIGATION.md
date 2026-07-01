# DarkIRC Services Created Despite Disabled Flag — Investigation

**Date:** 2026-07-01
**Status:** Root cause identified — stale provisioning script defaults
**Severity:** Low (noise/crash-loop on affected tenants; no data or security impact)

## Problem

DarkIRC services (`lunarwing-darkirc-<tenant>.service` and
`lunarwing-darkirc-adapter-<tenant>.service`) are being created and started on
tenants where DarkIRC was never explicitly enabled. These services fail
immediately because the `darkirc` binary (`/usr/local/bin/darkirc`) is not
built/present, producing crash-loop noise in systemd.

## Summary of Root Cause

The `lunarwing-mt-admin.sh` script correctly guards all DarkIRC unit creation,
env writing, and service starting behind the `tenant_darkirc_enabled` function,
which reads `enable_darkirc` from `/etc/lunarwing/ports.json`.

**However**, the old fleet provisioning orchestrator script
`ic/scripts/lunarwing-mt-provision-openrc.sh` ships with `ENABLE_DARKIRC=true`
hardcoded in its CONFIG block (line 55). This script was used to provision
tenants on OpenRC hosts (Gentoo), and it passes `--enable-darkirc` to
`add-tenants` unconditionally:

```bash
# lunarwing-mt-provision-openrc.sh, line 55 + 238
ENABLE_DARKIRC=true                 # DarkIRC daemon + adapter
...
[[ "$ENABLE_DARKIRC" == true ]] && flags+=(--enable-darkirc)
```

This flips `enable_darkirc: true` in the port registry for every tenant
provisioned through that script. Once the registry says `true`,
`mt-admin.sh` behaves correctly — it renders DarkIRC units, env files, and
config, then starts the services. The services crash because `darkirc` was
never built, but from mt-admin's perspective DarkIRC was intentionally enabled.

A systemd equivalent of this provisioning script (`lunarwing-mt-provision-systemd.sh`)
is referenced in comments but does not exist in the repo; the same pattern may
have been used in a now-deleted variant or an ad-hoc command.

## Detailed Findings

### mt-admin.sh Guard Coverage (all correct)

Every DarkIRC-sensitive code path in `lunarwing-mt-admin.sh` is gated on
`tenant_darkirc_enabled "$name"`:

| Function | Line (approx) | Guard | Correct? |
|---|---|---|---|
| `write_tenant_lunarwing_env` | DARKIRC_ADAPTER_URL/SECRET block | `tenant_darkirc_enabled` | Yes |
| `write_tenant_darkirc_adapter_env` | Called only from `add_tenant` inside `if enable_darkirc == true` | `enable_darkirc` in-memory flag | Yes |
| `generate_darkirc_config` | Called only from `add_tenant` inside same guard | Same | Yes |
| `patch_tenant_env` | DARKIRC env block | `tenant_darkirc_enabled` | Yes |
| `render_tenant_systemd_units` | DarkIRC adapter + daemon unit files | `tenant_darkirc_enabled` | Yes |
| `render_tenant_openrc_units` | DarkIRC adapter + daemon init scripts | `tenant_darkirc_enabled` | Yes |
| `start_tenant_systemd` | enable_list + imperative start | `tenant_darkirc_enabled` | Yes |
| `start_tenant_openrc` | rc-service start calls | `tenant_darkirc_enabled` | Yes |
| `status_tenant` | Service list display | `tenant_darkirc_enabled` | Yes |

### Unconditional References (harmless)

The `stop_tenant_systemd`, `stop_tenant_openrc`, `uninstall_tenant_systemd`,
and `uninstall_tenant_openrc` functions list DarkIRC services in their
iteration loops **without** a guard. This is intentional and harmless — they
check `is-active` / file existence before acting, so a non-existent service is
silently skipped. No units are created by these paths.

### The Provisioning Script

`ic/scripts/lunarwing-mt-provision-openrc.sh` is a fleet-level orchestrator
that wraps `mt-admin.sh` across multiple phases (provision, build, configure,
start, verify). Its CONFIG block hardcodes:

```
ENABLE_DARKIRC=true
BUILD_DARKIRC=true
```

When Phase 1 runs `mt add-tenants "$TENANTS" --enable-darkirc ...`, this sets
`enable_darkirc: true` in the port registry for every tenant. All subsequent
mt-admin operations (render-units, start-tenant, restart-tenant, status) then
see DarkIRC as enabled and create/start the services accordingly.

The script is marked `COMPLETELY UNTESTED` in its header, and was adapted from
a systemd variant that no longer exists in the repo.

### No Other Code Path Creates DarkIRC Units

- `create-tenant.sh` and all `create-tenant-<name>.sh` wrapper scripts do NOT
  pass `--enable-darkirc`.
- `upgrade-tenant.sh` and all `upgrade-tenant-<name>.sh` scripts do NOT touch
  DarkIRC.
- Port registry migrations (v2 through v10) do NOT touch `enable_darkirc`.
- The `ports_allocate` resume path reconciles the flag one-directionally
  (false → true only); it never silently downgrades.

## How to Confirm on Your Machine

```bash
# 1. Check which tenants have enable_darkirc: true in the registry
sudo jq '.tenants | to_entries[] | {name: .key, enable_darkirc: .value.enable_darkirc}' /etc/lunarwing/ports.json

# 2. Check for stale darkirc unit files
for t in $(sudo jq -r '.tenants | keys[]' /etc/lunarwing/ports.json); do
    echo "=== $t ==="
    ls /home/$t/.config/systemd/user/lunarwing-darkirc-* 2>/dev/null || echo "  (no unit files)"
done

# 3. Check systemd state
for t in $(sudo jq -r '.tenants | keys[]' /etc/lunarwing/ports.json); do
    echo "=== $t ==="
    sudo -u "$t" XDG_RUNTIME_DIR=/run/user/$(id -u "$t") \
        systemctl --user list-units 'lunarwing-darkirc-*' --all --no-pager 2>/dev/null || true
done
```

## Remediation

### For Affected Tenants

If a tenant has `enable_darkirc: true` but should not, disable it:

1. **Flip the registry flag** (manual — mt-admin has no `disable-darkirc`
   command; the flag is one-directional by design):

   ```bash
   sudo jq '.tenants["<tenant>"].enable_darkirc = false' /etc/lunarwing/ports.json > /tmp/ports.tmp \
       && sudo mv /tmp/ports.tmp /etc/lunarwing/ports.json
   ```

2. **Remove the stale services** (stop + disable + delete unit files):

   ```bash
   sudo -u <tenant> XDG_RUNTIME_DIR=/run/user/$(id -u <tenant>) \
       systemctl --user stop lunarwing-darkirc-<tenant>.service lunarwing-darkirc-adapter-<tenant>.service 2>/dev/null || true

   sudo -u <tenant> XDG_RUNTIME_DIR=/run/user/$(id -u <tenant>) \
       systemctl --user disable lunarwing-darkirc-<tenant>.service lunarwing-darkirc-adapter-<tenant>.service 2>/dev/null || true

   rm -f /home/<tenant>/.config/systemd/user/lunarwing-darkirc-<tenant>.service
   rm -f /home/<tenant>/.config/systemd/user/lunarwing-darkirc-adapter-<tenant>.service

   sudo -u <tenant> XDG_RUNTIME_DIR=/run/user/$(id -u <tenant>) \
       systemctl --user daemon-reload
   ```

3. **Re-render the main daemon unit** to drop the darkirc dependency wiring:

   ```bash
   sudo ic/scripts/lunarwing-mt-admin.sh render-units <tenant>
   sudo ic/scripts/lunarwing-mt-admin.sh restart-tenant <tenant>
   ```

### For the Provisioning Script

Update `ic/scripts/lunarwing-mt-provision-openrc.sh` CONFIG defaults to match
mt-admin's own defaults:

```bash
ENABLE_DARKIRC=false                # DarkIRC daemon + adapter (opt-in; matches mt-admin default)
BUILD_DARKIRC=false                 # Build darkirc daemon binary (opt-in)
```

This prevents future fleet provisioning runs from silently enabling DarkIRC on
all tenants. If a deployment genuinely wants DarkIRC, the operator flips it in
the CONFIG block before running — same as every other feature toggle in that
script.

## Related Files

- [`DARKIRC-MULTITENANT.md`](DARKIRC-MULTITENANT.md) — DarkIRC multitenant operations runbook
- [`MULTITENANCY-PRODUCTION.md`](MULTITENANCY-PRODUCTION.md) — Production multi-tenant deployment
- `ic/scripts/lunarwing-mt-admin.sh` — Multi-tenant admin script (guards are correct)
- `ic/scripts/lunarwing-mt-provision-openrc.sh` — Fleet provisioning orchestrator (root cause)
- `ic/scripts/test-mt-admin-darkirc-flag.sh` — Regression test for the flag-flip behavior
