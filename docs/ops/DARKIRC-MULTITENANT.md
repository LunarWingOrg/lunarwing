# DarkIRC Multitenant Operations Runbook

Guide for deploying, migrating, operating, and troubleshooting DarkIRC in a production multi-tenant LunarWing environment.

DarkIRC support in multi-tenant mode uses a per-tenant stack:

```text
LunarWing WASM channel
  -> darkirc adapter HTTP API on 127.0.0.1:<darkirc_adapter>
  -> tenant darkirc daemon IRC port on 127.0.0.1:<darkirc_irc>
  -> darkirc P2P network / seeds / optional Tor hidden service
```

Each tenant gets its own daemon, adapter, ports, config, datastore, logs, and adapter secret. The daemon is not shared across tenants because DarkIRC DM encryption depends on per-identity ChaCha key material.

For adapter architecture and QA scenarios, see [DarkIRC Multitenant Adapter](../guides/darkirc_channel_for_ironclaw/DARKIRC_MT_ADAPTER.md). For general multi-tenant operations, see [Production Multi-Tenant Deployment](MULTITENANCY-PRODUCTION.md).

## Prerequisites

- Production multi-tenancy is already managed with `ic/scripts/lunarwing-mt-admin.sh`.
- `jq` is installed for `/etc/lunarwing/ports.json` migrations and inspection.
- Python 3 is available for `darkirc_adapter.py`.
- The DarkFi/DarkIRC source tree exists outside the LunarWing repo.
- The operator knows where that external source tree lives.

Do not vendor DarkFi/DarkIRC source into the LunarWing repository. The admin script builds from an external source path.

## Port Registry Requirements

DarkIRC requires schema v7 in `/etc/lunarwing/ports.json`.

| Schema | Adds | Script |
|--------|------|--------|
| v6 | `extended_range`, `extended_base`, `extended_ports.reserved_0..reserved_9` | `ic/scripts/migrate-ports-v6.sh` |
| v6.1 | `extended_ports.darkirc_adapter` from `reserved_0` | `ic/scripts/migrate-ports-v6.1.sh` |
| v7 | `extended_ports.darkirc_irc` and `extended_ports.darkirc_rpc` from `reserved_1` and `reserved_2` | `ic/scripts/migrate-ports-v7.sh` |

New tenants created after these changes already receive all three DarkIRC ports. Existing tenants need the migrations.

### Inspect Current Schema

```bash
jq -r '.version // 0' /etc/lunarwing/ports.json
```

Check one tenant:

```bash
jq '.tenants["<TENANT>"].extended_ports' /etc/lunarwing/ports.json
```

Expected DarkIRC fields:

```json
{
  "darkirc_adapter": 20010,
  "darkirc_irc": 20011,
  "darkirc_rpc": 20012
}
```

The exact numbers depend on the tenant's base port. Existing primary ports are not moved.

### Migrate a Live Registry

Run migrations in order from the repo root:

```bash
sudo ic/scripts/migrate-ports-v6.sh
sudo ic/scripts/migrate-ports-v6.1.sh
sudo ic/scripts/migrate-ports-v7.sh
```

Each script:

- accepts `PORTS_REGISTRY=/path/to/copy.json` for dry runs on a copy;
- requires root only when operating on `/etc/lunarwing/ports.json`;
- writes a timestamped backup next to the registry;
- validates port uniqueness before replacing the registry;
- swaps the new registry into place atomically.

Dry-run against a copy first:

```bash
cp -p /etc/lunarwing/ports.json /tmp/ports.darkirc-test.json
PORTS_REGISTRY=/tmp/ports.darkirc-test.json ic/scripts/migrate-ports-v6.sh
PORTS_REGISTRY=/tmp/ports.darkirc-test.json ic/scripts/migrate-ports-v6.1.sh
PORTS_REGISTRY=/tmp/ports.darkirc-test.json ic/scripts/migrate-ports-v7.sh
jq '.tenants | to_entries[] | {tenant: .key, extended_ports: .value.extended_ports}' /tmp/ports.darkirc-test.json
```

### Inline Migration via Admin Script

`lunarwing-mt-admin.sh` also contains inline migration functions:

- `ports_migrate_v6`
- `ports_migrate_v6_1`
- `ports_migrate_v7`

The top-level `ports_migrate()` dispatcher runs them in order. This means normal admin-script flows can bring stale registries forward, while the standalone scripts remain available for explicit operator-controlled upgrades.

## Configure the DarkIRC Source Path

`build-darkirc` does not hardcode a DarkFi source path. It resolves the source in this order:

1. per-tenant `/home/<TENANT>/lunarwing/env/lunarwing.env` value:
   ```bash
   DARKIRC_SOURCE=/path/to/darkfi
   ```
2. host environment value:
   ```bash
   export LUNARWING_MT_DARKIRC_SOURCE=/path/to/darkfi
   ```

Prefer the per-tenant env file when tenants may use different DarkFi checkouts or revisions.

Set it for one tenant:

```bash
sudo install -d -m 700 -o <TENANT> -g <TENANT> /home/<TENANT>/lunarwing/env
sudo sh -c 'grep -q "^DARKIRC_SOURCE=" /home/<TENANT>/lunarwing/env/lunarwing.env || printf "\nDARKIRC_SOURCE=/path/to/darkfi\n" >> /home/<TENANT>/lunarwing/env/lunarwing.env'
sudo chown <TENANT>:<TENANT> /home/<TENANT>/lunarwing/env/lunarwing.env
sudo chmod 600 /home/<TENANT>/lunarwing/env/lunarwing.env
```

For a fleet-wide source path during a build session:

```bash
sudo LUNARWING_MT_DARKIRC_SOURCE=/path/to/darkfi \
  ic/scripts/lunarwing-mt-admin.sh build-darkirc --tenant <TENANT>
```

## Provision or Backfill a Tenant

For new tenants, `add-tenant` allocates DarkIRC ports and renders the DarkIRC env/config files as part of the tenant setup flow.

```bash
sudo ic/scripts/lunarwing-mt-admin.sh add-tenant <TENANT> --docker-group
```

For an existing tenant after migration, patch the env/config files:

```bash
sudo ic/scripts/lunarwing-mt-admin.sh patch-env <TENANT>
```

This backfills DarkIRC-related values in `lunarwing.env`, writes `darkirc-adapter.env`, and renders `darkirc_config.toml` from templates.

## Build DarkIRC

Build and install the external DarkIRC daemon for one tenant:

```bash
sudo ic/scripts/lunarwing-mt-admin.sh build-darkirc --tenant <TENANT>
```

If using a fleet-wide source override:

```bash
sudo LUNARWING_MT_DARKIRC_SOURCE=/path/to/darkfi \
  ic/scripts/lunarwing-mt-admin.sh build-darkirc --tenant <TENANT>
```

The build uses the external DarkFi checkout and installs the daemon into the tenant's LunarWing layout. It does not copy DarkFi source into the LunarWing repo.

## Install WASM Channel Artifacts

Build tenant binaries and WASM artifacts, then install the channel into the tenant state directory:

```bash
sudo ic/scripts/lunarwing-mt-admin.sh build-tenant <TENANT> --with-wasm
sudo ic/scripts/lunarwing-mt-admin.sh install-wasm <TENANT>
```

The DarkIRC channel capabilities file declares env-backed adapter settings. The tenant's `lunarwing.env` supplies:

```bash
DARKIRC_ADAPTER_URL=http://127.0.0.1:<darkirc_adapter>
DARKIRC_ADAPTER_SECRET=<generated-secret>
```

Do not paste the secret into tickets, logs, or chat. Treat it like any other tenant credential.

## Generated Files

For tenant `<TENANT>`, the admin script manages:

| File | Purpose |
|------|---------|
| `/home/<TENANT>/lunarwing/env/lunarwing.env` | Main daemon env, including `DARKIRC_ADAPTER_URL`, `DARKIRC_ADAPTER_SECRET`, and optional `DARKIRC_SOURCE` |
| `/home/<TENANT>/lunarwing/env/darkirc-adapter.env` | Adapter env rendered from `ic/scripts/templates/darkirc-adapter.env.template` |
| `/home/<TENANT>/lunarwing/state/darkirc/darkirc_config.toml` | Daemon config rendered from `ic/scripts/templates/darkirc_config.toml.template` |
| `/home/<TENANT>/lunarwing/state/channels/darkirc.capabilities.json` | WASM channel capabilities installed by `install-wasm` |
| `/home/<TENANT>/lunarwing/logs/` | Tenant daemon, adapter, and service logs |

The template placeholders use `__UPPERCASE__` form, not shell `${VAR}` form. Secrets are generated at runtime and are not stored in templates.

## Service Lifecycle

`start-tenant`, `stop-tenant`, `restart-tenant`, and `status` include DarkIRC services.

```bash
sudo ic/scripts/lunarwing-mt-admin.sh start-tenant <TENANT>
sudo ic/scripts/lunarwing-mt-admin.sh status <TENANT>
sudo ic/scripts/lunarwing-mt-admin.sh restart-tenant <TENANT>
sudo ic/scripts/lunarwing-mt-admin.sh stop-tenant <TENANT>
```

### systemd

Per-tenant user units:

```text
lunarwing-darkirc-<TENANT>.service
lunarwing-darkirc-adapter-<TENANT>.service
```

Check status and logs:

```bash
sudo -u <TENANT> XDG_RUNTIME_DIR=/run/user/$(id -u <TENANT>) \
  systemctl --user status lunarwing-darkirc-<TENANT>.service

sudo -u <TENANT> XDG_RUNTIME_DIR=/run/user/$(id -u <TENANT>) \
  systemctl --user status lunarwing-darkirc-adapter-<TENANT>.service

sudo -u <TENANT> XDG_RUNTIME_DIR=/run/user/$(id -u <TENANT>) \
  journalctl --user -u lunarwing-darkirc-<TENANT>.service --no-pager -n 80

sudo -u <TENANT> XDG_RUNTIME_DIR=/run/user/$(id -u <TENANT>) \
  journalctl --user -u lunarwing-darkirc-adapter-<TENANT>.service --no-pager -n 80
```

### OpenRC

Per-tenant system services:

```text
lunarwing-darkirc-<TENANT>
lunarwing-darkirc-adapter-<TENANT>
```

Check status and logs:

```bash
sudo rc-service lunarwing-darkirc-<TENANT> status
sudo rc-service lunarwing-darkirc-adapter-<TENANT> status

tail -80 /home/<TENANT>/lunarwing/logs/darkirc.log
tail -80 /home/<TENANT>/lunarwing/logs/darkirc-adapter.log
```

## Verify End-to-End

### 1. Check Ports

```bash
sudo ic/scripts/lunarwing-mt-admin.sh list-tenants
jq '.tenants["<TENANT>"].extended_ports | {darkirc_adapter, darkirc_irc, darkirc_rpc}' /etc/lunarwing/ports.json
```

### 2. Check Config Render

```bash
sudo test -s /home/<TENANT>/lunarwing/state/darkirc/darkirc_config.toml
sudo test -s /home/<TENANT>/lunarwing/env/darkirc-adapter.env
```

Confirm the rendered config uses tenant ports:

```bash
sudo grep -E '^(irc_listen|rpc_listen|listen)' /home/<TENANT>/lunarwing/state/darkirc/darkirc_config.toml
sudo grep -E '^(DARKIRC_PORT|ADAPTER_PORT)=' /home/<TENANT>/lunarwing/env/darkirc-adapter.env
```

Do not print `ADAPTER_SECRET`.

### 3. Check Adapter Health

```bash
adapter_port=$(jq -r '.tenants["<TENANT>"].extended_ports.darkirc_adapter' /etc/lunarwing/ports.json)
curl -sf "http://127.0.0.1:${adapter_port}/health" | jq .
```

Expected shape:

```json
{
  "status": "ok",
  "irc_connected": true,
  "irc_nick": "<TENANT>-bridge",
  "queue_size": 0
}
```

### 4. Check Gateway Channel Health

Get the gateway port and token:

```bash
gateway_port=$(jq -r '.tenants["<TENANT>"].ports.gateway' /etc/lunarwing/ports.json)
token=$(sudo grep -s '^GATEWAY_AUTH_TOKEN=' /home/<TENANT>/lunarwing/env/lunarwing.env | cut -d= -f2-)
```

Query status:

```bash
curl -sf -H "Authorization: Bearer ${token}" \
  "http://127.0.0.1:${gateway_port}/api/gateway/status" \
  | jq '.channel_health.darkirc'
```

Do not print the token in shared logs.

## DarkIRC Channels, Seeds, and Contacts

The generated `darkirc_config.toml` includes baseline channel and seed configuration. Edit it as the tenant when needed:

```bash
sudo -u <TENANT> editor /home/<TENANT>/lunarwing/state/darkirc/darkirc_config.toml
```

Restart DarkIRC services after edits:

```bash
sudo ic/scripts/lunarwing-mt-admin.sh restart-tenant <TENANT>
```

### Contacts and DM Keypairs

DarkIRC contact key material belongs inline under `[contact."nickname"]` sections in the TOML. The daemon does not consume a separate generated keypair file.

A contact section should include the contact's public key and the tenant's own keypair for that contact. Exchange public keys out of band before enabling private DMs.

## Tor / Hidden Service Options

DarkIRC can be paired with Tor in multiple ways. Choose one deliberately; the admin script does not currently provision Tor hidden services automatically.

| Option | When to use | Notes |
|--------|-------------|-------|
| SOCKS5 outbound-only | Tenant only needs to reach onion peers | Configure DarkIRC to use a local Tor SOCKS listener if supported by the selected DarkFi build/config. |
| Static `torrc` hidden service | Stable inbound onion identity per tenant | Create a per-tenant hidden service directory, bind it to the tenant's DarkIRC P2P port, and protect the private key directory. |
| Arti ephemeral onion | Experimental or temporary identities | Useful for testing; not a replacement for a stable production onion identity. |

Operational rules:

- keep Tor hidden-service private keys out of the repo;
- store tenant-specific Tor state under the tenant's state directory or another root-owned protected path;
- document onion addresses per tenant in an operator-only inventory;
- restart only the affected tenant after changing Tor routing.

## Troubleshooting

### `build-darkirc` fails with missing source path

Set `DARKIRC_SOURCE` in the tenant env or pass `LUNARWING_MT_DARKIRC_SOURCE` for the build command.

```bash
grep -s '^DARKIRC_SOURCE=' /home/<TENANT>/lunarwing/env/lunarwing.env
```

If empty, add the source path or export the fleet-wide override.

### `darkirc_irc` or `darkirc_rpc` is missing

The registry is stale or migration was incomplete.

```bash
jq -r '.version // 0' /etc/lunarwing/ports.json
jq '.tenants["<TENANT>"].extended_ports' /etc/lunarwing/ports.json
```

Run:

```bash
sudo ic/scripts/migrate-ports-v6.sh
sudo ic/scripts/migrate-ports-v6.1.sh
sudo ic/scripts/migrate-ports-v7.sh
```

Then re-run:

```bash
sudo ic/scripts/lunarwing-mt-admin.sh patch-env <TENANT>
```

### Adapter health returns `irc_connected: false`

Check that the tenant daemon is running and that `DARKIRC_PORT` in `darkirc-adapter.env` matches the tenant's `darkirc_irc` port.

```bash
jq -r '.tenants["<TENANT>"].extended_ports.darkirc_irc' /etc/lunarwing/ports.json
sudo grep -s '^DARKIRC_PORT=' /home/<TENANT>/lunarwing/env/darkirc-adapter.env
```

Then check daemon logs before restarting.

### WASM channel cannot reach adapter

Verify `DARKIRC_ADAPTER_URL` points at the tenant's adapter port:

```bash
jq -r '.tenants["<TENANT>"].extended_ports.darkirc_adapter' /etc/lunarwing/ports.json
sudo grep -s '^DARKIRC_ADAPTER_URL=' /home/<TENANT>/lunarwing/env/lunarwing.env
```

Confirm the capabilities file is installed and contains the DarkIRC channel metadata:

```bash
sudo test -s /home/<TENANT>/lunarwing/state/channels/darkirc.capabilities.json
```

Run `install-wasm` again if artifacts are missing.

### Secret mismatch between WASM channel and adapter

Regenerate or patch env files with the admin script rather than editing one side by hand:

```bash
sudo ic/scripts/lunarwing-mt-admin.sh patch-env <TENANT>
sudo ic/scripts/lunarwing-mt-admin.sh restart-tenant <TENANT>
```

If manual repair is unavoidable, ensure the adapter service receives `ADAPTER_SECRET` and the main daemon receives `DARKIRC_ADAPTER_SECRET` with the same value. Do not print the value while comparing; use fingerprints or length checks.

### Port collision warning during migration

The standalone migration scripts leave the live registry untouched and print the candidate temp file path. Inspect the candidate and current registry, then resolve the stale or manually edited port entry before re-running the migration.

```bash
jq '[.tenants[] | ((.ports // {}) | to_entries[] | .value), ((.extended_ports // {}) | to_entries[] | .value)] | group_by(.) | map(select(length > 1))' /etc/lunarwing/ports.json
```

### OpenRC service starts but exits immediately

Check conf.d/init script paths and tenant ownership:

```bash
sudo rc-service lunarwing-darkirc-<TENANT> status
sudo rc-service lunarwing-darkirc-adapter-<TENANT> status
ls -l /etc/init.d/lunarwing-darkirc-<TENANT> /etc/init.d/lunarwing-darkirc-adapter-<TENANT>
ls -ld /home/<TENANT>/lunarwing /home/<TENANT>/lunarwing/env /home/<TENANT>/lunarwing/state
```

Fix ownership only for files that should belong to the tenant. Keep system init scripts root-owned.

## Rollback

### Port Registry Rollback

Each migration prints a backup path. To roll back immediately:

```bash
sudo cp /etc/lunarwing/ports.json.bak.<TIMESTAMP> /etc/lunarwing/ports.json
```

Restart affected tenants after rollback if services were already rendered or started with migrated ports.

### Disable DarkIRC for One Tenant

Stop the DarkIRC services while leaving the main tenant stack intact.

Systemd:

```bash
sudo -u <TENANT> XDG_RUNTIME_DIR=/run/user/$(id -u <TENANT>) \
  systemctl --user stop lunarwing-darkirc-adapter-<TENANT>.service lunarwing-darkirc-<TENANT>.service
```

OpenRC:

```bash
sudo rc-service lunarwing-darkirc-adapter-<TENANT> stop
sudo rc-service lunarwing-darkirc-<TENANT> stop
```

If the WASM channel is installed but the adapter is down, channel health will report degraded/unhealthy until either the service is restored or the channel is removed from the tenant's installed channels.

## Operator Checklist

For each production tenant:

- [ ] `/etc/lunarwing/ports.json` is schema v7.
- [ ] `darkirc_adapter`, `darkirc_irc`, and `darkirc_rpc` exist under `.extended_ports`.
- [ ] `DARKIRC_SOURCE` is set in tenant env or `LUNARWING_MT_DARKIRC_SOURCE` is supplied during builds.
- [ ] `build-darkirc --tenant <TENANT>` completed.
- [ ] `build-tenant <TENANT> --with-wasm` completed.
- [ ] `install-wasm <TENANT>` completed.
- [ ] `darkirc_config.toml` and `darkirc-adapter.env` exist and use tenant ports.
- [ ] `DARKIRC_ADAPTER_URL` exists in `lunarwing.env`.
- [ ] Adapter secret is present on both daemon env and adapter env sides without being exposed in logs.
- [ ] `start-tenant <TENANT>` starts daemon, adapter, and main LunarWing service.
- [ ] Adapter `/health` returns `status: ok` and `irc_connected: true`.
- [ ] Gateway status reports DarkIRC channel health.
- [ ] Tor/hidden-service plan is documented if onion connectivity is required.
