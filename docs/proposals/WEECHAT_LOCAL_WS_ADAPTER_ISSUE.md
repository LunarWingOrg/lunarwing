# Issue: FIXED in 1.1.0 🎉

## When utilizing a multi-tenant environment setup, the local http port for ADAPTER_PORT in the ws_adapter.py script

* is not configurable ✅ NOW CONFIGURABLE
* is not designated a port in the port registry ✅ NOW `weechat_adapter` in ports.json v5
* must be manually changed in the python source code prior to running ✅ NOW reads `WEECHAT_ADAPTER_PORT` from env

## Fix Summary (2026-06-01)

1. **Port registry v5 migration**: `reserved_3` → `weechat_adapter` in `/etc/lunarwing/ports.json`
2. **Admin script**: `write_tenant_lunarwing_env()` now writes `WEECHAT_ADAPTER_PORT=<port>` to `lunarwing.env`
3. **Admin script**: `patch_tenant_env()` backfills the env var for existing tenants
4. **ws_adapter.py**: Already supported `ADAPTER_PORT` env var; now also checks `WEECHAT_ADAPTER_PORT`
5. **Admin script**: Updated `ports_list()`, `status_tenant()`, `list_tenants()`, and `add_tenant()` summary to display the adapter port

## Usage

After port registry migration, each tenant's `lunarwing.env` gets:
```
WEECHAT_ADAPTER_PORT=10009
```

The ws_adapter.py is started with:
```bash
source /home/<tenant>/lunarwing/env/lunarwing.env
python3 ws_adapter.py --port $WEECHAT_ADAPTER_PORT
```
