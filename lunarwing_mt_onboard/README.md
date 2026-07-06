# lunarwing_mt_onboard

Interactive multi-tenant onboarding CLI for LunarWing. Implements item #11 of
`docs/ops/GOALS_1.1.9.md`.

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

## Module layout

```
lunarwing_mt_onboard/
├── __init__.py        # package marker, __version__
├── __main__.py        # `python3 -m lunarwing_mt_onboard` entry
├── cli.py             # interactive prompts + argparse
├── config.py          # TenantConfig dataclass, JSON serialization
├── provisioner.py     # subprocess wrapper around mt-admin.sh
├── secrets.py         # master-key generation + validation
├── verify.py          # post-start health checks
├── tests.py           # unit tests (config, secrets, validation)
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
