# WeeChat Channel Troubleshooting

## Pairing Approval

```bash
sudo -u <tenant> LUNARWING_BASE_DIR=/home/<tenant>/lunarwing/state \
  /home/<tenant>/lunarwing/ic/target/release/lunarwing pairing approve weechat XXXXXXX
```

### Example

*
```bash
sudo -u ruffles LUNARWING_BASE_DIR=/home/ruffles/lunarwing/state /home/ruffles/lunarwing/ic/target/release/lunarwing pairing approve weechat XXXXXXX
```


## Multi-Tenant Port Mismatch

In multi-tenant deployments, the weechat relay port is allocated in `/etc/lunarwing/ports.json` but **not** automatically written into the DB settings. When the channel is first configured via the agent's setup wizard, it saves whatever ports were typed at that time. If ports change or the tenant is recreated, the DB retains stale values.

### Symptoms

- Agent logs show `Connection refused` to wrong port (e.g., hitting 6680 instead of 6689, or 10002 instead of 10005)
- Adapter connects fine but agent can't read from it
- Capabilities.json edits have no effect after restart

### Root Cause

The WASM channel reads its config from two sources (in priority order):
1. **DB settings** — `extensions.weechat.setup_fields` row in the `settings` table (persisted from setup wizard)
2. **capabilities.json** — `config` section used as defaults when DB values are absent

The DB values always win. Editing capabilities.json alone won't fix a stale DB entry.

### Diagnosis

Check what the DB has stored:

> **PG password:** per-tenant PostgreSQL passwords are random (stored in
> `/home/<TENANT>/lunarwing/env/pg.secret`). Export it first; tenants created
> before this change still use `lunarwing` (the `${PG_PW:-lunarwing}` fallback):
>
> ```bash
> export PG_PW="$(sudo cat /home/<TENANT>/lunarwing/env/pg.secret 2>/dev/null || echo lunarwing)"
> ```

```bash
psql "postgresql://lunarwing:${PG_PW:-lunarwing}@127.0.0.1:<PG_PORT>/lunarwing" -c \
  "SELECT value FROM settings WHERE key = 'extensions.weechat.setup_fields';"
```

Compare against the tenant's allocated ports:

```bash
jq '.tenants.<TENANT>.ports' /etc/lunarwing/ports.json
```

### Fix: Update DB Settings

Update relay_url and ws_adapter_url to the correct ports:

```bash
psql "postgresql://lunarwing:${PG_PW:-lunarwing}@127.0.0.1:<PG_PORT>/lunarwing" -c "
UPDATE settings 
SET value = jsonb_set(
  jsonb_set(value::jsonb, '{relay_url}', '\"http://127.0.0.1:<WEECHAT_PORT>\"'),
  '{ws_adapter_url}', '\"http://127.0.0.1:<ADAPTER_PORT>\"'
)
WHERE key = 'extensions.weechat.setup_fields';
"
```

Then restart the tenant:

```bash
sudo ic/scripts/lunarwing-mt-admin.sh stop-tenant <name> && sudo ic/scripts/lunarwing-mt-admin.sh start-tenant <name>
```

## Relay Type: Must Be `api` (Not `weechat`)

The ws_adapter requires WeeChat 4.x+ `api` relay type. The older `weechat` protocol relay is incompatible.

### Symptoms

- WeeChat shows: `relay: authentication failed with client 1/weechat/127.0.0.1`
- Adapter connects but immediately disconnects
- Relay log shows `1/weechat/...` (not `1/api/...`)

### Fix

In WeeChat:

```
/relay del weechat <port>
/relay add api <port>
```

Verify with `/relay list` — you should see `api (port: XXXXX)`.

## Authentication Failures

### Symptoms

- WeeChat shows: `relay: authentication failed with client`
- Adapter reconnects in a loop every few seconds

### Fix

Ensure the `weechat_relay_password` secret in the DB matches WeeChat's configured password:

```
/set relay.network.password
```

Update the secret:

```bash
DATABASE_URL="postgresql://lunarwing:${PG_PW:-lunarwing}@127.0.0.1:<PG_PORT>/lunarwing" \
SECRETS_MASTER_KEY="<tenant master key from env>" \
python3 ic_sm/scripts_4_db/insert_secret_postgres.py weechat_relay_password "<password>"
```

## Boolean Deserialization Error

### Symptoms

```
Channel weechat failed to start: Failed to parse config: invalid type: string "false", expected a boolean
```

### Root Cause

The `setup_fields` DB row stores all values as strings. When fields like `verbose_drops` (which the WASM expects as a boolean) are present, serde rejects the string `"false"`.

### Fix

Remove the offending field from the DB — the WASM will use the serde default (`false`):

```bash
psql "postgresql://lunarwing:${PG_PW:-lunarwing}@127.0.0.1:<PG_PORT>/lunarwing" -c "
UPDATE settings 
SET value = value::jsonb - 'verbose_drops'
WHERE key = 'extensions.weechat.setup_fields';
"
```

If multiple boolean/numeric fields cause problems, keep only the string fields that matter:

```bash
psql "postgresql://lunarwing:${PG_PW:-lunarwing}@127.0.0.1:<PG_PORT>/lunarwing" -c "
UPDATE settings 
SET value = '{
  \"relay_url\": \"http://127.0.0.1:<WEECHAT_PORT>\",
  \"ws_adapter_url\": \"http://127.0.0.1:<ADAPTER_PORT>\",
  \"networks\": \"<your networks>\",
  \"dm_policy\": \"open\",
  \"group_policy\": \"open\",
  \"allow_from\": \"*\",
  \"connection_mode\": \"auto\"
}'::jsonb
WHERE key = 'extensions.weechat.setup_fields';
"
```

## Workspace State Cache

The WASM channel caches config values (relay_url, ws_adapter_url) in its workspace directory. If you change the DB or capabilities.json but the old values persist:

```bash
sudo rm -rf /home/<tenant>/lunarwing/state/workspace/channels/weechat/
```

Then restart the tenant.

## WeeChat Idle Disconnect

### Symptoms

- Adapter connects, works for 60 seconds, then disconnects
- Log shows: `WS disconnected — reconnecting in 5s (Server disconnected)`

### Fix

In WeeChat, disable the idle timeout:

```
/set relay.network.time_inactive 0
```

Note: this setting may not exist in all WeeChat versions. If you get "Option not found", the disconnect is likely caused by an auth mismatch instead.
