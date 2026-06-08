# BUG: mt-admin doesn't auto-generate the nanocode external-worker config

**Status:** Open
**Severity:** Low — one-time manual step per tenant; no runtime impact once configured.
**Affects:** Multi-tenant tenants that want the `nanocode` external worker.

## Description

When a tenant is created with `ic/scripts/lunarwing-mt-admin.sh`, the daemon's `config.toml`
is **not** populated with the nanocode external-worker block (or its auth token). Until it is
added by hand, `create_job(mode: "nanocode")` has nothing to route to and the agent never logs
`External workers configured: nanocode` on startup.

## Workaround

Add the block manually to `config.toml` under the tenant's `LUNARWING_BASE_DIR` (must live
under the existing `[sandbox]` section — TOML disallows duplicate table headers):

```toml
[[sandbox.external_workers]]
name = "nanocode"
url = "ws://localhost:9090/ws/agent"
timeout_ms = 300000
```

See the worker docs in `lunarcode4lunarwing/CLAUDE.md` and the secrets-passing design in
`docs/proposals/NANOCODE_WORKER_SECRETS.md`.

## Fix (proposed)

Have `lunarwing-mt-admin.sh` emit the `[[sandbox.external_workers]]` block (and provision the
auth token) when a tenant opts into the nanocode worker.

## Files

- `ic/scripts/lunarwing-mt-admin.sh` — tenant provisioning
- `ic/src/config/sandbox.rs` — `ExternalWorkerConfig` (resolves `[[sandbox.external_workers]]`)
