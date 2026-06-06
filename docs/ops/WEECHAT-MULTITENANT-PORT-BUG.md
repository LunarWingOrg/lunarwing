# WeeChat Multi-Tenant Port Binding Bug

**Summary**: WeeChat works for one tenant, silently fails for the rest. The in-process WASM channel ignores per-tenant adapter and relay ports, always polling the hardcoded defaults from `weechat.capabilities.json`.

**Status: FIXED** (branch `1.1.1-222-weechat-mulitenant-port-fix-2`). The fix is a generic, capability-declared env-source mechanism — see [Resolution](#resolution). A second blocker (per-tenant relay password) that the port bug was masking is also fixed; see [The Password Is the Second Blocker](#the-password-is-the-second-blocker). Existing tenants must be backfilled — see [Backfill for Existing Tenants](#backfill-for-existing-tenants).

## Symptom

- The `ws_adapter.py` process connects to WeeChat and buffers messages successfully. The adapter's `/api/health` endpoint shows `ws_connected: true` and `buffered_buffers > 0` even on broken tenants.
- LunarWing itself receives no IRC messages for most tenants.
- Only approximately one tenant works — the one whose allocated port block happens to match the hardcoded defaults (weechat relay on 9001, adapter on 6681).
- Auth/password errors may appear in logs but are a red herring (see below).

## Root Cause

The WASM weechat channel's `relay_url` and `ws_adapter_url` come **only** from the static `config` block in `weechat.capabilities.json`:

```json
// ironclaw_weechat_wss/weechat_relay/weechat.capabilities.json:105-107
"config": {
    "relay_url": "http://127.0.0.1:9001",
    "ws_adapter_url": "http://127.0.0.1:6681",
    ...
}
```

These defaults are loaded via `cap_file.config_json()` (`ic/src/channels/wasm/loader.rs:119`) and persisted to the workspace by `on_start` (`ironclaw_weechat_wss/weechat_relay/src/lib.rs:295-298`). They are **never** overridden with per-tenant values.

### Why the adapter side looks healthy

The adapter (`ws_adapter.py`) is a standalone Python process. It reads `RELAY_URL`, `ADAPTER_PORT`/`WEECHAT_ADAPTER_PORT`, and `RELAY_PASSWORD` directly from the tenant's environment file (`lunarwing.env`) at startup (`ws_adapter.py:468-480`). So it binds to the correct per-tenant ports:

- WeeChat relay: `127.0.0.1:<base+5>`
- Adapter HTTP: `127.0.0.1:<base+9>`

### Why the WASM side is broken

The WASM channel runs **inside** the LunarWing process. Its config injection path (`ic/src/channels/wasm/setup.rs:154-218`) only injects:

- `tunnel_url`
- `webhook_secret`
- `owner_id`
- Telegram `bot_username`
- DB setup-field overrides (from `extensions.<channel>.setup_fields`)
- Channel-specific secrets (via `inject_channel_secrets_into_config`, setup.rs:465)

`inject_channel_secrets_into_config` has a match arm for `"xmpp"` but falls through to `_ => return` for all other channels including weechat. There is **no code path** that reads `WEECHAT_ADAPTER_PORT` or `RELAY_URL` from the environment and injects them into the weechat channel config.

### Net result

Every tenant's in-process WASM polls `http://127.0.0.1:6681` regardless of the tenant's actual adapter port. Only the tenant whose allocated port block happens to land on weechat=9001 / adapter=6681 works by coincidence.

## Data Flow

```
                    ┌── CORRECT ──┐
                    │             │
lunarwing.env ──────┤             ├──► ws_adapter.py ──► WeeChat relay (base+5)
  RELAY_URL         │             │    binds to base+9
  WEECHAT_ADAPTER_PORT           │
                    │             │
                    └── MISSING ──┘

                    ┌── WRONG ───┐
                    │            │
weechat.capabilities.json        │
  config.relay_url: :9001        ├──► WASM channel ──► polls :6681 (hardcoded)
  config.ws_adapter_url: :6681   │
                    │            │
                    └────────────┘
```

Per-tenant port allocation (from `WEECHAT-SERVICES.md`):

| Offset | Port name | Service |
|--------|-----------|---------|
| +5 | `weechat` | WeeChat relay API |
| +9 | `weechat_adapter` | WS adapter HTTP endpoint |

## The Password Is the Second Blocker

The original analysis called the password a "red herring." That is only true *while the port bug dominates*. Once the port is corrected, the password becomes the next hard failure for every mt-admin tenant.

Here is why. Nothing in the host injects `relay_password` into the WASM config, so it deserializes to `""`. The WASM builds its adapter auth header itself — `make_auth_headers` produces `Authorization: Basic base64("plain:" + relay_password)` (`ironclaw_weechat_wss/weechat_relay/src/lib.rs:1323`). With an empty password it sends `Basic base64("plain:")`.

The adapter uses **one** password (`RELAY_PASSWORD`) for two purposes:

1. Authenticating the adapter → WeeChat relay connection (`make_auth_header`).
2. Authenticating **incoming** WASM requests (`check_auth`, `ws_adapter.py:93-99`).

`check_auth` returns `True` only when `state.relay_password` is empty *or* the incoming header equals `make_auth_header(RELAY_PASSWORD)`. `mt-admin` generates a non-empty `RELAY_PASSWORD` for **every** tenant (`lunarwing-mt-admin.sh`), so `check_auth` requires a matching header — which the WASM (empty password) cannot produce. Result: once the port is right, the adapter returns `401`/`403` instead of data.

So the complete fix must inject **both** the per-tenant URLs *and* `relay_password`. The URLs flow through the generic env-source mechanism (`RELAY_URL`, `WS_ADAPTER_URL`); the password flows through the secrets-injection path with an env fallback to `RELAY_PASSWORD` (see [Resolution](#resolution)).

## Diagnosis (Read-Only)

For each tenant, compare the adapter port in the env file against the hardcoded default:

```bash
# The only tenant that matches 6681 is the one that works.
grep '^WEECHAT_ADAPTER_PORT=' /etc/lunarwing/tenants/<name>/lunarwing.env
```

Verify the adapter is healthy (it will be, even on broken tenants):

```bash
curl -s http://127.0.0.1:<base+9>/api/health
# {"status":"ok","ws_connected":true,"buffered_buffers":3,...}
```

Check LunarWing's logs for the WASM channel startup — it will log the hardcoded defaults:

```
WeeChat Relay channel starting, relay at http://127.0.0.1:9001
Connection mode: auto (ws_adapter: http://127.0.0.1:6681, poll interval: 3000ms)
```

## Resolution

The implemented fix is a **generic, capability-declared env-source mechanism** — a generalized form of [Option A](#option-a-inject-env-into-weechat-config-in-core-setup) that avoids hardcoding weechat into core code.

**1. A setup field can declare an env source.** `ToolFieldSetupSchema` gains an optional `env` key (`ic/src/tools/wasm/capabilities_schema.rs`). The weechat capabilities declare it for the two URL fields:

```json
{ "name": "relay_url",      "optional": true, "env": "RELAY_URL" }
{ "name": "ws_adapter_url", "optional": true, "env": "WS_ADAPTER_URL" }
```

**2. The host resolves env-sourced fields at startup.** `load_channel_setup_field_overrides` (`ic/src/channels/wasm/setup.rs`) — already the generic resolver for setup fields — now adds an env tier after the existing DB tiers (saved `setup_fields`, then `setting_path`, then `env`). The resolved values are merged into the channel config via `update_config` before `on_start`, overriding the capabilities defaults.

**3. The env tier is gated to first-party channels.** `channel_env_config_allowed()` restricts env-sourcing to bundled channels (`bundled_channel_names()`). This is a **security boundary**: without it, a malicious third-party capabilities file could declare `"env": "SECRETS_MASTER_KEY"` and exfiltrate host secrets into its own config.

**4. The relay password is injected too** (see [The Password Is the Second Blocker](#the-password-is-the-second-blocker)). `inject_channel_secrets_into_config` gains a weechat arm mapping `relay_password` ← secret `weechat_relay_password`, with an env fallback to `RELAY_PASSWORD`. The password uses the **secrets** path (not `env`-sourced fields, which are non-secret by contract).

**5. `mt-admin` writes a full adapter URL.** `write_tenant_env` now emits `WS_ADAPTER_URL=http://127.0.0.1:<base+9>` so the env-source mechanism receives a complete URL (no port→URL templating needed in core). `RELAY_URL` and `RELAY_PASSWORD` were already written.

Single-tenant and harness deployments do not set these env vars, so the channel cleanly falls back to the capabilities defaults (`:9001`/`:6681`) — no regression.

## Fix Options (Considered)

The implemented Resolution above is the generic form of Option A.

### Option A: Inject env into weechat config in core setup

Add a weechat-specific branch in `register_channel` (`ic/src/channels/wasm/setup.rs`) that reads `RELAY_URL` and `WEECHAT_ADAPTER_PORT` from the environment and injects them into the channel's `config_updates` before `on_start` is called. Optionally also inject `relay_password` from `RELAY_PASSWORD`.

This mirrors the existing pattern used for XMPP in `inject_channel_secrets_into_config` (setup.rs:465).

**Pros**:
- Single source of truth (the env file already has the correct values).
- No per-tenant DB state to manage.
- Works automatically for all existing and future tenants after a restart.

**Cons**:
- Touches core LunarWing code (`ic/src/channels/wasm/setup.rs`), which is outside `ic/openclaw-ports/`.
- Requires a unit test and `FEATURE_PARITY.md` check per AGENTS.md.

### Option B: Per-tenant DB setup_fields

Write `extensions.weechat.setup_fields` into each tenant's settings store during `add-tenant` / `render-units` in `lunarwing-mt-admin.sh`. The existing `load_channel_setup_field_overrides` function (`ic/src/channels/wasm/setup.rs:401`) already reads this setting and applies it to `config_updates`.

The setting would contain:

```json
{
  "relay_url": "http://127.0.0.1:<base+5>",
  "ws_adapter_url": "http://127.0.0.1:<base+9>"
}
```

**Pros**:
- No Rust code changes — script and docs only.
- Lower risk; no core code touched.

**Cons**:
- Every existing tenant needs the setting backfilled manually (or via a migration script).
- New tenants depend on `add-tenant` writing the setting correctly.
- Two sources of truth (env file + DB setting) that can drift.

### Option C: Have the WASM read its own adapter URL from the adapter

The WASM already pulls `dm_policy`, `group_policy`, `allow_from`, and `networks` from the adapter's `/api/config` endpoint on each poll (`ironclaw_weechat_wss/weechat_relay/src/lib.rs:644-675`). In theory, `ws_adapter_url` could also be discovered this way.

**Pros**:
- Self-configuring; no external injection needed.

**Cons**:
- **Not viable alone**: `ws_adapter_url` is the value that's wrong, so the WASM can't reach the adapter to discover the correct URL. This is a chicken-and-egg problem.
- Could work as a complement to Option A or B (use the injected URL for initial contact, then refresh from `/api/config`), but cannot be the sole fix.

## Backfill for Existing Tenants

After deploying the new `lunarwing` binary, each existing tenant needs three things: the updated capabilities file (which now declares the `env` sources), the new `WS_ADAPTER_URL` env var, and a restart so `on_start` re-runs with the injected values.

```bash
# 0. Pre-flight (read-only): confirm each tenant's env agrees with its
#    registry ports BEFORE touching anything. A FAIL means a *wrong existing*
#    value that patch-env will NOT overwrite — fix it by hand first.
sudo ic/scripts/lunarwing-weechat-preflight.sh          # all tenants
sudo ic/scripts/lunarwing-weechat-preflight.sh <name>   # one tenant

# 1. Reinstall the WeeChat channel so the tenant's installed
#    weechat.capabilities.json gains the new `env` field declarations.
#    (The .wasm binary is unchanged; only the capabilities sidecar matters.)
sudo ic/scripts/lunarwing-mt-admin.sh install-wasm <name>

# 2. Backfill WS_ADAPTER_URL (and RELAY_URL if missing) into lunarwing.env.
#    Idempotent — skips vars already present.
sudo ic/scripts/lunarwing-mt-admin.sh patch-env <name>

# 3. Restart the tenant so on_start re-executes with the corrected
#    relay_url, ws_adapter_url, and relay_password.
sudo ic/scripts/lunarwing-mt-admin.sh restart-tenant <name>
```

For the whole fleet, use `install-wasm-all`, `patch-env-all`, then restart each tenant.

**Verify** the channel picked up the right values — the startup log should show the tenant's ports, not `:9001`/`:6681`:

```
WeeChat Relay channel starting, relay at http://127.0.0.1:<base+5>
Connection mode: auto (ws_adapter: http://127.0.0.1:<base+9>, poll interval: 3000ms)
```

## Cross-References

- [WEECHAT-SERVICES.md](WEECHAT-SERVICES.md) — Service architecture, port allocation, env vars, troubleshooting
- [MT-ADMIN-QUICKSTART.md](../guides/MT-ADMIN-QUICKSTART.md) — Multi-tenant admin operations
- [MULTITENANCY-PRODUCTION.md](MULTITENANCY-PRODUCTION.md) — General multi-tenant setup
