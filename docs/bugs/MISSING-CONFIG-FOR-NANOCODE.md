# BUG: mt-admin doesn't auto-generate the nanocode external-worker config

**Status:** Resolved (2026-06-14)
**Severity:** Low — one-time manual step per tenant; no runtime impact once configured.
**Affects:** Multi-tenant tenants that want the `nanocode` external worker.

## Description

When a tenant was created with `ic/scripts/lunarwing-mt-admin.sh`, the daemon's `config.toml`
was **not** populated with the nanocode external-worker block (or its auth token). Until it was
added by hand, `create_job(mode: "nanocode")` had nothing to route to and the agent never logged
`External workers configured: nanocode` on startup.

## Fix

`lunarwing-mt-admin.sh` now emits the `[[sandbox.external_workers]]` block automatically:

- **`add-tenant`** writes it to `<state_dir>/config.toml` (the tenant's `LUNARWING_BASE_DIR`)
  right after the env files, using the tenant's allocated `nanocode_wss` port and the tenant's
  `GATEWAY_AUTH_TOKEN` as the worker auth token.
- **`patch-env` / `patch-env-all`** retrofit the block onto tenants created before this fix.

The generator (`ensure_external_worker_config`) is idempotent — re-runs skip a worker that is
already present — and the block survives the daemon's own `config.toml` writers (e.g. `/model`),
which load-modify-save the whole settings struct.

Generated block (port and token are per-tenant):

```toml
[[sandbox.external_workers]]
name = "nanocode"
url = "ws://127.0.0.1:<nanocode_wss>/ws/agent"
auth_token = "<tenant GATEWAY_AUTH_TOKEN>"
timeout_ms = 300000
```

### Why these values

- **`url`** points at `127.0.0.1:<nanocode_wss>/ws/agent`, the per-tenant port that
  `start_tenant_nanocode` binds (`-p 127.0.0.1:<port>:<port>`, `WS_PATH=/ws/agent`).
  The `9090` in the standalone worker docs is the single-tenant default — multi-tenant uses
  the allocated `nanocode_wss` port from `/etc/lunarwing/ports.json`.
- **`auth_token`** mirrors `GATEWAY_AUTH_TOKEN` because the worker container is launched with
  `AGENT_AUTH_TOKEN=<GATEWAY_AUTH_TOKEN>`; the daemon presents it as the WebSocket `Bearer`.

After the worker image is built (`build-tenant <name> --with-nanocode`) and the tenant is
(re)started, `create_job(mode: "nanocode")` routes to the running container with no manual config.

## Verification

- `ic/src/config/sandbox.rs` — `external_worker_config_matches_mt_admin_output` and
  `external_worker_config_supports_multiple_workers` assert the exact TOML the script emits
  deserializes into routable `ExternalWorkerConfig`s.

## Files

- `ic/scripts/lunarwing-mt-admin.sh` — `ensure_external_worker_config`, wired into
  `add_tenant` and `patch_tenant_env`
- `ic/src/config/sandbox.rs` — `ExternalWorkerConfig` (resolves `[[sandbox.external_workers]]`)
- `ic/src/settings.rs` — `ExternalWorkerSettings` (TOML/JSON serialization)

## Follow-up

`pebble` — the other external worker (`pebble_wss` port, identical WS protocol and
`AGENT_AUTH_TOKEN=GATEWAY_AUTH_TOKEN` launch) — is now wired the same way: `add_tenant` and
`patch_tenant_env` also call `ensure_external_worker_config "$name" "pebble" "pebble_wss"`, so a
tenant's `config.toml` gets both `[[sandbox.external_workers]]` blocks. The
`external_worker_config_supports_multiple_workers` test in `ic/src/config/sandbox.rs` covers a
combined nanocode + pebble config.
