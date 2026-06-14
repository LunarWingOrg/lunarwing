# Port Schema v2 Migration Guide

## Overview

This migration script converts the legacy `ports.json` format to the new v2 tenant-block schema. The new format eliminates the "reserved ports" problem by using per-tenant port blocks with service offsets.

## When to Run

- **Before v1.1.3 release** - Migrate existing tenants to v2 format
- **When adding new tenants** - New tenants should use v2 format from the start
- **After port exhaustion** - If you're running out of reserved port slots

## Prerequisites

- Backup of current `ports.json` (script creates one automatically)
- All LunarWing services stopped or in maintenance mode
- `python3` and `jq` installed (optional but recommended)

## Usage

```bash
cd /path/to/lunarwing/scripts
./migrate-ports-to-v2.sh
```

## What the Script Does

1. **Creates a backup** - Timestamped backup saved to `../ic/config/ports.json.bak.YYYYMMDDHHMMSS`
2. **Analyzes current config** - Detects existing tenant assignments and block size
3. **Converts to v2 format** - Maps legacy ports to new tenant-block structure
4. **Validates** - Checks for port collisions before completing
5. **Logs results** - Detailed output in `../logs/port-migration.log`

## Rollback

If issues occur:

```bash
# Stop services
sudo systemctl stop lunarwing-*

# Restore backup
cp ../ic/config/ports.json.bak.YYYYMMDDHHMMSS ../ic/config/ports.json

# Restart services
sudo systemctl start lunarwing-*
```

## v2 Schema Format

### Legacy Format (Before)
```json
{
  "starforce": {
    "gateway": 10000,
    "websocket": 10001,
    "telemetry": 10002
  },
  "ruffles": {
    "gateway": 10010,
    "websocket": 10011,
    "telemetry": 10012
  }
}
```

### v2 Format (After)
```json
{
  "schema_version": "v2",
  "migrated_at": "2026-06-17T12:00:00Z",
  "tenants": {
    "starforce": {
      "schema_version": "v2",
      "base_port": 10000,
      "block_size": 10,
      "service_offsets": {
        "gateway": 0,
        "websocket": 1,
        "telemetry": 2,
        "adapter": 3,
        "worker": 4,
        "debug": 5,
        "metrics": 6,
        "health": 7,
        "reserved_1": 8,
        "reserved_2": 9
      }
    },
    "ruffles": {
      "schema_version": "v2",
      "base_port": 10010,
      "block_size": 10,
      "service_offsets": {
        "gateway": 0,
        "websocket": 1,
        "telemetry": 2,
        "adapter": 3,
        "worker": 4,
        "debug": 5,
        "metrics": 6,
        "health": 7,
        "reserved_1": 8,
        "reserved_2": 9
      }
    }
  }
}
```

## Service Offsets

Each tenant gets a block of 10 ports. Services are assigned offsets within that block:

| Service | Offset | Port (if base=10000) |
|---------|--------|---------------------|
| gateway | 0 | 10000 |
| websocket | 1 | 10001 |
| telemetry | 2 | 10002 |
| adapter | 3 | 10003 |
| worker | 4 | 10004 |
| debug | 5 | 10005 |
| metrics | 6 | 10006 |
| health | 7 | 10007 |
| reserved_1 | 8 | 10008 |
| reserved_2 | 9 | 10009 |

## Benefits

1. **No more port exhaustion** - Each tenant gets their own block
2. **Scalable** - Add tenants, not reserved slots
3. **Collision-proof** - Tenant isolation prevents conflicts
4. **Backward compatible** - Existing tenants keep same ports

## Troubleshooting

### "No tenants found in port configuration"
- Check that `ports.json` exists and is valid JSON
- Verify the file path in the script is correct

### "Port collision detected"
- Review the validation output
- Check for duplicate base ports in the original config
- Restore from backup and manually resolve conflicts

### "Schema version is not v2"
- Migration failed partway through
- Restore from backup and re-run the script

## Future Work

- v1.2.0: Deprecate legacy schema format
- Self-healing architecture (v1.1.6+) will rely on tenant isolation

## Contact

Issues? Open an issue in the LunarWing repository or reach out to the maintainers.
