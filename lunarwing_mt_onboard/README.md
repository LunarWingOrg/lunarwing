# lunarwing_mt_onboard

Interactive multi-tenant onboarding CLI for LunarWing. Implements the multi-tenant
onboarding work tracked for LunarWing 1.1.9.

## Overview

Guides an operator through the full provisioning lifecycle for a new tenant:

1. Tenant identity and port allocation
2. Secrets generation (gateway token, PG password, SECRETS_MASTER_KEY)
3. LLM provider configuration
4. XMPP and Gotify channel setup
5. External worker selection (nanocode, pebble, opencode)
6. Build (with live log output)
7. Start and post-start verification

The CLI is a **thin wrapper** around `ic/scripts/lunarwing-mt-admin.sh` — it
does not duplicate provisioning logic. `mt-admin` remains the source of truth
for port allocation, env rendering, and service units.

It also provides an `upgrade` subcommand for in-place upgrades of existing
multi-tenant installs. That path is a thin wrapper around
`ic/scripts/upgrade-preflight.sh` and `ic/scripts/upgrade-tenant-version.sh`.

## Requirements

- Python 3.10+
- `rich` and `questionary` (see `requirements.txt`)
- Root/sudo (the underlying `mt-admin.sh` requires root)

## Install

```bash
pip install -r lunarwing_mt_onboard/requirements.txt
```

## Usage

### Interactive

```bash
sudo python3 -m lunarwing_mt_onboard
```

### Resume a saved session

```bash
sudo python3 -m lunarwing_mt_onboard --resume /path/to/tenant.json
```

### Non-interactive (CI / bulk provisioning)

```bash
sudo python3 -m lunarwing_mt_onboard \
  --non-interactive \
  --resume tenant.json \
  --save result.json
```

Flags:

| Flag | Description |
|------|-------------|
| `--non-interactive` | Skip all prompts; requires `--resume` |
| `--accept-defaults` | Accept default values for any unspecified fields |
| `--resume FILE` | Load a previously saved `TenantConfig` JSON |
| `--save FILE` | Save the collected config to JSON before provisioning |
| `--skip-build` | Only run `add-tenant` |
| `--skip-start` | Run `add-tenant` + `build-tenant`, skip `start-tenant` |

### In-place tenant upgrade

Upgrade mode is dry-run by default. It is intended for existing PostgreSQL,
rootful-Docker tenants on older 1.1.x releases such as 1.1.6, 1.1.7, and 1.1.8.
The underlying shell scripts remain the authority for compatibility checks and
will stop on unsupported layouts.

Interactive dry-run:

```bash
sudo python3 -m lunarwing_mt_onboard upgrade
```

Non-interactive dry-run:

```bash
sudo python3 -m lunarwing_mt_onboard upgrade \
  --tenant ruffles \
  --target v1.1.9 \
  --non-interactive
```

Apply an upgrade after reviewing the dry-run/preflight output:

```bash
sudo python3 -m lunarwing_mt_onboard upgrade \
  --tenant ruffles \
  --target v1.1.9 \
  --apply \
  --yes \
  --non-interactive
```

Upgrade flags:

| Flag | Description |
|------|-------------|
| `--tenant NAME` | Existing tenant to upgrade |
| `--target TAG` | Exact release tag such as `v1.1.9`; empty uses the script default |
| `--source-version-override TAG` | Override source-version detection, for example `v1.1.7` |
| `--apply` | Execute the upgrade; omitted means dry-run |
| `--no-preflight` | Skip `upgrade-preflight.sh` |
| `--force` | Continue even if preflight fails |
| `--yes` | Forward non-interactive confirmation to the shell upgrade script |

## Module layout

```
lunarwing_mt_onboard/
├── __init__.py        # package marker, __version__
├── __main__.py        # `python3 -m lunarwing_mt_onboard` entry
├── cli.py             # interactive prompts + argparse
├── config.py          # TenantConfig dataclass, JSON serialization
├── provisioner.py     # subprocess wrapper around mt-admin.sh
├── upgrade.py         # subprocess wrapper around upgrade scripts
├── upgrade_cli.py     # interactive upgrade prompts + display
├── secrets.py         # master-key generation + validation
├── verify.py          # post-start health checks
├── tests.py           # unit tests (config, secrets, validation)
├── upgrade_tests.py   # unit tests for in-place upgrades
└── requirements.txt   # rich, questionary
```

## Testing

```bash
# Unit tests (no root required)
bash ic/scripts/test-mt-onboard.sh

# Or directly
PYTHONPATH=. python3 -c "
import unittest
from lunarwing_mt_onboard import tests
unittest.TextTestRunner(verbosity=2).run(
    unittest.TestLoader().loadTestsFromModule(tests)
)
"
```

## Configuration file format

`TenantConfig` JSON example:

```json
{
  "name": "ruffles",
  "gateway_host": "127.0.0.1",
  "docker_group": true,
  "enable_darkirc": false,
  "xmpp_enabled": true,
  "xmpp_jid": "ruffles@xmpp.localhost",
  "xmpp_password": "",
  "xmpp_allow_from": [],
  "gotify_enabled": false,
  "gotify_url": "",
  "gotify_title": "",
  "workers": ["nanocode", "opencode"],
  "toolchains": false,
  "tensorzero_url": "http://192.168.1.157:3000/openai/v1",
  "llm_model": "tensorzero::function_name::FrontierCODE",
  "llm_api_key": "",
  "secrets_master_key": "",
  "no_ssh": false,
  "no_health": false
}
```

## Design proposal

See `docs/proposals/MT-ONBOARDING-CLI.md` for the full design rationale,
including the deferral of the Phase 2 web UI.
