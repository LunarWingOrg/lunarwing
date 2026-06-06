# WeeChat Multi-Tenant Port Binding Bug

**Summary**: WeeChat works for one tenant, silently fails for the rest. The in-process WASM channel ignores per-tenant adapter and relay ports, always polling the hardcoded defaults from `weechat.capabilities.json`.

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

## Why the Password Is a Red Herring

The WASM channel receives `{}` (empty JSON object) as its `config_json` from the host (`ironclaw_weechat_wss/weechat_relay/src/lib.rs:292`). This means `relay_password` deserializes to `""` (empty string). The WASM sends requests with no `Authorization` header to the adapter. The adapter's `check_auth` (`ws_adapter.py:93-99`) allows unauthenticated requests when `relay_password` is empty — but the **blocking failure is the wrong port**, not auth. Even if auth were configured correctly, the WASM would still be polling the wrong port.

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

## Fix Options

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

Regardless of which fix is chosen, existing tenants need their WASM channel to pick up the correct ports. After applying the fix:

```bash
# Re-render units (picks up any script changes)
sudo ic/scripts/lunarwing-mt-admin.sh render-units <name>

# Restart the tenant (stops and starts all services in dependency order)
sudo ic/scripts/lunarwing-mt-admin.sh restart-tenant <name>
```

This causes `on_start` to re-execute with the corrected `relay_url` and `ws_adapter_url`.

## Cross-References

- [WEECHAT-SERVICES.md](WEECHAT-SERVICES.md) — Service architecture, port allocation, env vars, troubleshooting
- [MT-ADMIN-QUICKSTART.md](../guides/MT-ADMIN-QUICKSTART.md) — Multi-tenant admin operations
- [MULTITENANCY-PRODUCTION.md](MULTITENANCY-PRODUCTION.md) — General multi-tenant setup
