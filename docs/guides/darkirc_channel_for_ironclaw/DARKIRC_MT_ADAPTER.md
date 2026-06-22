# DarkIRC Multitenant Adapter (Adapter-Only Milestone)

> **Reviewed 2026-06-21** — Reviewed against implementation in `ic/scripts/lunarwing-mt-admin.sh` and corrected. The shared-daison limitation was removed (per-tenant daemons implemented in Tasks 9-16). The `DARKIRC_ADAPTER_URL` env var wiring is now complete via the `env` field in `darkirc.capabilities.json`.

This document covers the **adapter-only milestone** for DarkIRC multitenant integration in LunarWing.

**Status**: Implementation complete (Tasks 1-16). QA scenarios documented but not yet executed.

**Status note**: The adapter-only milestone (Tasks 1-7) originally targeted a *shared daemon* model. During implementation, the daemon phase (Tasks 9-16) was completed in the same branch, so the full per-tenant stack — dedicated darkirc daemon + dedicated adapter per tenant — is already in place. This document describes the adapter layer specifically; see the daemon plan for daemon-level details.

## Architecture

### Topology

Each tenant gets a dedicated DarkIRC daemon and adapter. The daemon is per-tenant because DarkIRC uses ChaCha keypairs for P2P encryption — sharing a daemon would mean sharing keys, which defeats the purpose.

```
Tenant A                                 Tenant B
┌──────────────────────┐        ┌──────────────────────┐
│ lunarwing-darkirc-$A         │        │ lunarwing-darkirc-$B         │
│   (per-tenant daemon, IRC)   │        │   (per-tenant daemon, IRC)   │
│   (ChaCha keypair, P2P)      │        │   (ChaCha keypair, P2P)      │
│           ↓ IRC              │        │           ↓ IRC              │
│ lunarwing-darkirc-adapter-$A │        │ lunarwing-darkirc-adapter-$B │
│   ↓ HTTP                     │        │   ↓ HTTP                     │
│ lunarwing-$A                 │        │ lunarwing-$B                 │
└──────────────────────┘        └──────────────────────┘
```

### Components

1. **Port Registry v6.1** (Task 1)
   - Adds `darkirc_adapter` port to extended port range
   - Each tenant gets a unique adapter port (e.g., 6660, 6670, 6680)
   - Migration preserves existing port allocations

2. **Adapter Environment** (Task 2)
   - `write_tenant_darkirc_adapter_env()` generates `$TENANT_ENV_DIR/darkirc-adapter.env`
   - Contains: `DARKIRC_HOST=127.0.0.1`, `DARKIRC_PORT=$darkirc_irc_port` (the tenant's own daemon IRC port from the registry), `DARKIRC_NICK=$TENANT-bridge`, `DARKIRC_USER=$TENANT`, `DARKIRC_REALNAME=LunarWing DarkIRC Bridge ($TENANT)`, `ADAPTER_HOST=127.0.0.1`, `ADAPTER_PORT=$darkirc_adapter_port`, `ADAPTER_SECRET=$TOKEN`, `ADAPTER_LOG_LEVEL=INFO`
   - The `ADAPTER_SECRET` is read back from `lunarwing.env` (`DARKIRC_ADAPTER_SECRET`) so it is preserved on re-run; a new token is generated only when absent
   - `DARKIRC_ADAPTER_SECRET` is injected into `lunarwing.env` for the WASM channel side

3. **Systemd Unit** (Task 3)
   - `lunarwing-darkirc-adapter-$TENANT.service` in `~$TENANT/.config/systemd/user/`
   - Type: simple, Restart: on-failure, RestartSec: 5
   - EnvironmentFile: `$TENANT_ENV_DIR/darkirc-adapter.env`
   - ExecStart: `/usr/bin/python3 $REPO_DIR/darkirc_channel_for_ironclaw/darkirc/adapter/darkirc_adapter.py`

4. **OpenRC Unit** (Task 4)
   - `/etc/init.d/lunarwing-darkirc-adapter-$TENANT`
   - supervisor-daemon with respawn
   - `depend()`: need net, after firewall, before lunarwing-$TENANT

5. **Lifecycle Integration** (Task 5)
   - `start-tenant`: enables + starts adapter service before main lunarwing daemon
   - `stop-tenant`: stops adapter service
   - `remove-tenant`: stops + disables + deletes unit + removes env files
   - `status-tenant`: reports adapter service status (systemd: `is-active`, OpenRC: `status`)

6. **Gateway Env Wiring** (Task 6)
   - `DARKIRC_ADAPTER_URL` and `DARKIRC_ADAPTER_SECRET` injected into `lunarwing.env`
   - Gateway reads these to route channel requests to the correct adapter
   - Idempotent: patch-env adds missing vars without overwriting existing ones

7. **Health Pipeline** (Task 7)
   - Adapter exposes `GET /health` endpoint
   - Returns: `{"status": "ok|error", "irc_connected": bool, "irc_nick": str, "queue_size": int}`
   - Gateway `/api/gateway/status` probes adapter health and reports in `channel_health.darkirc`
   - Watchdog (`lunarwing-self-heal.sh`) extracts adapter services and monitors them
   - Escalation chain: adapter failure → gateway reports unhealthy → watchdog restarts service

### Service Dependencies

Systemd ordering (from `lunarwing-$TENANT.service`):
```
After=... lunarwing-darkirc-adapter-$TENANT.service
Wants=... lunarwing-darkirc-adapter-$TENANT.service
```

This ensures the adapter starts before the main LunarWing daemon, so the gateway can immediately connect to it.

### Per-Tenant Daemon Isolation

Each tenant gets a dedicated DarkIRC daemon (`lunarwing-darkirc-$TENANT`) with its own:
- IRC listen port (`darkirc_irc` from port registry)
- JSON-RPC port (`darkirc_rpc` from port registry)
- P2P datastore and hostlist (under `$state_dir/darkirc/datastore/`)
- Config file (`darkirc_config.toml`, auto-generated by `generate_darkirc_config()`)

**ChaCha keypairs for DM encryption** are configured inline in the TOML under `[contact."nickname"]` sections, not in a separate file. Each contact section contains:
- `dm_chacha_public` — the contact's public key (obtained out-of-band)
- `my_dm_chacha_secret` — the tenant's secret key for decrypting messages from this contact
- `my_dm_chacha_public` — the tenant's public key (counterpart to the secret)

Keypairs are generated via `darkirc --gen-chacha-keypair` and must be placed inline in the TOML. As of the current darkfi version used by LunarWing, the daemon does not consume a separate keypair file — the keypair belongs in the `[contact]` section. The `generate_darkirc_config()` function currently generates a placeholder `darkirc_keypair.yaml` file as a convenience, but this file is not read by the daemon; the keypair must be inline in the TOML. Contacts are not auto-populated; the user configures them manually since they require out-of-band key exchange.

The adapter connects to its tenant's daemon on `127.0.0.1:$darkirc_irc_port`, not a shared port.

## QA Scenarios

**Status**: These scenarios document what should be tested. They have NOT been executed yet. Evidence files will be created when the scenarios are run.

### Task 1: Port Registry Migration

**Scenario 1.1**: Existing tenant gets `darkirc_adapter` port
```bash
# Preconditions: Port registry at v6 with existing tenants
# Steps:
jq '.tenants["<name>"].extended_ports' /etc/lunarwing/ports.json > /tmp/before.json
sudo lunarwing-mt-admin.sh doctor  # triggers migration
jq '.tenants["<name>"].extended_ports | has("darkirc_adapter")' /etc/lunarwing/ports.json
jq '.tenants["<name>"].extended_ports | has("reserved_0")' /etc/lunarwing/ports.json

# Expected: darkirc_adapter present, reserved_0 absent
# Evidence: .sisyphus/evidence/task-1-existing-tenant-port.txt
```

**Scenario 1.2**: New tenant gets `darkirc_adapter` in allocation
```bash
# Preconditions: Port registry at v6.1+
# Steps:
sudo lunarwing-mt-admin.sh add-tenant testdarkirc1
jq '.tenants.testdarkirc1.extended_ports' /etc/lunarwing/ports.json

# Expected: darkirc_adapter present and non-null
# Evidence: .sisyphus/evidence/task-1-new-tenant-port.txt
```

### Task 2: Adapter Environment Generation

**Scenario 2.1**: Env file has correct adapter port
```bash
# Preconditions: Tenant created with darkirc_adapter port
# Steps:
write_tenant_darkirc_adapter_env testdarkirc1
source $(tenant_env_dir testdarkirc1)/darkirc-adapter.env
echo $ADAPTER_PORT
ports_get testdarkirc1 darkirc_adapter

# Expected: Ports match
# Evidence: .sisyphus/evidence/task-2-adapter-port.txt
```

**Scenario 2.2**: Secret preserved on re-run
```bash
# Preconditions: darkirc-adapter.env already exists
# Steps:
grep ADAPTER_SECRET $(tenant_env_dir testdarkirc1)/darkirc-adapter.env > /tmp/before
write_tenant_darkirc_adapter_env testdarkirc1
grep ADAPTER_SECRET $(tenant_env_dir testdarkirc1)/darkirc-adapter.env > /tmp/after
diff /tmp/before /tmp/after

# Expected: No diff (secret unchanged)
# Evidence: .sisyphus/evidence/task-2-secret-preserved.txt
```

### Task 3: Systemd Unit

**Scenario 3.1**: Systemd unit file rendered correctly
```bash
# Preconditions: Tenant created, adapter env generated
# Steps:
sudo lunarwing-mt-admin.sh add-tenant testdarkirc1
ls -la $(tenant_home testdarkirc1)/.config/systemd/user/lunarwing-darkirc-adapter-testdarkirc1.service
grep ExecStart $(tenant_home testdarkirc1)/.config/systemd/user/lunarwing-darkirc-adapter-testdarkirc1.service
grep EnvironmentFile $(tenant_home testdarkirc1)/.config/systemd/user/lunarwing-darkirc-adapter-testdarkirc1.service

# Expected: File exists, ExecStart points to darkirc_adapter.py, EnvironmentFile points to darkirc-adapter.env
# Evidence: .sisyphus/evidence/task-3-systemd-unit.txt
```

### Task 4: OpenRC Unit

**Scenario 4.1**: OpenRC init script rendered correctly
```bash
# Preconditions: Tenant created
# Steps:
sudo lunarwing-mt-admin.sh add-tenant testdarkirc1
stat -c '%a' /etc/init.d/lunarwing-darkirc-adapter-testdarkirc1
grep 'supervisor=' /etc/init.d/lunarwing-darkirc-adapter-testdarkirc1
grep 'before lunarwing-testdarkirc1' /etc/init.d/lunarwing-darkirc-adapter-testdarkirc1

# Expected: File exists, executable (755), supervisor=supervise-daemon, depend() includes before lunarwing-testdarkirc1
# Evidence: .sisyphus/evidence/task-4-openrc-unit.txt
```

### Task 5: Lifecycle Integration

**Scenario 5.1**: start-tenant starts adapter
```bash
# Preconditions: Tenant created, units rendered
# Steps:
sudo lunarwing-mt-admin.sh start-tenant testdarkirc1
systemctl --user -M testdarkirc1@ is-active lunarwing-darkirc-adapter-testdarkirc1.service
curl -sf http://127.0.0.1:$(ports_get testdarkirc1 darkirc_adapter)/health | jq .status

# Expected: Service active, health returns "ok"
# Evidence: .sisyphus/evidence/task-5-start-tenant.txt
```

**Scenario 5.2**: stop-tenant stops adapter
```bash
# Preconditions: Tenant running
# Steps:
sudo lunarwing-mt-admin.sh stop-tenant testdarkirc1
systemctl --user -M testdarkirc1@ is-active lunarwing-darkirc-adapter-testdarkirc1.service

# Expected: Service inactive
# Evidence: .sisyphus/evidence/task-5-stop-tenant.txt
```

### Task 6: Gateway Environment Wiring

`DARKIRC_ADAPTER_URL` and `DARKIRC_ADAPTER_SECRET` are written to `$TENANT_ENV_DIR/lunarwing.env` by `write_tenant_darkirc_adapter_env()`. The WASM channel consumes them using the same env-var-reading pattern as WeeChat (`relay_url`/`RELAY_URL`) and XMPP (`xmpp_password`/`XMPP_PASSWORD`):

- `adapter_url` in `darkirc_channel_for_ironclaw/darkirc/darkirc.capabilities.json` declares `"env": "DARKIRC_ADAPTER_URL"`, so `ic/src/channels/wasm/setup.rs` injects the per-tenant URL into the channel config at runtime.
- `DARKIRC_ADAPTER_SECRET` is injected as a credential via the `darkirc_adapter_secret` secret mapping in the capabilities file; the fallback in `setup.rs` reads any `DARKIRC_*` prefixed env var.

**Scenario 6.1**: add-tenant writes DARKIRC_ADAPTER_URL
```bash
# Preconditions: Tenant created
# Steps:
grep DARKIRC_ADAPTER_URL $(tenant_env_dir testdarkirc1)/lunarwing.env
echo "Expected: http://127.0.0.1:$(ports_get testdarkirc1 darkirc_adapter)"

# Expected: URL present and correct
# Evidence: .sisyphus/evidence/task-6-env-url.txt
```

**Scenario 6.2**: patch-env adds missing vars
```bash
# Preconditions: Existing tenant missing DARKIRC_ADAPTER_URL
# Steps:
sed -i '/DARKIRC_ADAPTER_URL/d' $(tenant_env_dir testdarkirc1)/lunarwing.env
sudo lunarwing-mt-admin.sh patch-env testdarkirc1
grep DARKIRC_ADAPTER_URL $(tenant_env_dir testdarkirc1)/lunarwing.env

# Expected: Var re-added
# Evidence: .sisyphus/evidence/task-6-patch-env.txt
```

### Task 7: Health Pipeline

**Scenario 7.1**: Adapter health endpoint reaches gateway status
```bash
# Preconditions: Tenant running with darkirc adapter, Gateway running
# Steps:
curl -sf http://127.0.0.1:$(ports_get testdarkirc1 darkirc_adapter)/health | jq .status
curl -sf -H "Authorization: Bearer $TOKEN" http://127.0.0.1:$(ports_get testdarkirc1 gateway)/api/gateway/status | jq '.channel_health.darkirc'

# Expected: /health returns "ok", gateway reports darkirc healthy
# Evidence: .sisyphus/evidence/task-7-health-chain.txt
```

**Scenario 7.2**: Adapter down is detected
```bash
# Preconditions: Adapter running, then stopped
# Steps:
systemctl --user -M testdarkirc1@ stop lunarwing-darkirc-adapter-testdarkirc1.service
sleep 10  # wait for health check cycle
curl -sf -H "Authorization: Bearer $TOKEN" http://127.0.0.1:$(ports_get testdarkirc1 gateway)/api/gateway/status | jq '.channel_health.darkirc.healthy'

# Expected: healthy == false, error contains reason
# Evidence: .sisyphus/evidence/task-7-down-detected.txt
```

## Summary

The adapter-only milestone delivers:
- Per-tenant adapter services with unique ports
- Full lifecycle management (start/stop/remove)
- Health monitoring via gateway and watchdog
- Gateway environment wiring for channel routing

**Next phase**: Tasks 9-18 implement per-tenant DarkIRC daemon isolation, eliminating the shared daemon limitation.
