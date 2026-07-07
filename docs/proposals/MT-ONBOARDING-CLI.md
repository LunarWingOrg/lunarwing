# MT Onboarding CLI — Interactive Multi-Tenant Provisioning

**Date:** 2026-07-06
**Status:** Design proposal, pending review
**Target:** New directory `lunarwing_mt_onboard/` at repo root
**Origin:** Item #11 of `docs/ops/GOALS_1.1.9.md` — enhance onboarding process for new users and fresh tenants with an interactive CLI application.

## Goal

Replace the manual, error-prone sequence of `add-tenant → build-tenant → start-tenant → tokens` with a single interactive CLI that guides the operator through the **full provisioning lifecycle**:

1. Tenant identity and port allocation
2. Secrets generation (gateway token, PG password, SECRETS_MASTER_KEY)
3. LLM provider configuration
4. XMPP and Gotify channel setup
5. External worker selection (nanocode, pebble, opencode)
6. Build (with progress + snapshot fallback for mirror issues)
7. Start and post-start verification

A web UI (SSE-driven real-time build logs) is deferred to a future phase. CLI ships first.

The same CLI now also exposes an `upgrade` subcommand for existing tenants that
need an in-place move from older 1.1.x releases such as 1.1.6, 1.1.7, and
1.1.8. That mode remains a thin wrapper over the existing shell upgrade tools
instead of duplicating upgrade logic in Python.

## Recommendation Summary

| Decision | Choice | Rationale |
|---|---|---|
| Language / framework | **Python 3** + `questionary` + `rich` | `questionary` for structured prompts (text, select, confirm, password, path) with validation; `rich` for tables, spinners, progress bars, and live status. No web deps needed. |
| Integration model | **Thin wrapper** over `lunarwing-mt-admin.sh` subcommands | Avoids duplicating provisioning logic; mt-admin remains the source of truth for port allocation, env rendering, and service units. |
| Secrets integration | Call into `ic_sm/scripts_4_db/` (AES-256-GCM encrypt + insert into PG) | Reuses existing keychain-or-env key resolution, HKDF key derivation, and UUID- or legacy-`user_id`-aware insert logic. |
| Legacy deprecation | `setup-instance.sh` prints a banner pointing to the new tool | Clean signal without breaking existing automation. |
| Install surface | Standalone `lunarwing_mt_onboard/` directory at repo root, optional, not bundled | Can be run directly as `python3 -m lunarwing_mt_onboard` or via an entry script. Released alongside the binary but does not ship inside it. |
| Web UI | Phase 2 (not in this proposal) | Adds `http.server` + vanilla JS or a tiny Rust/Node server. Deferred until CLI is stable. |

## In-place upgrade mode

`python3 -m lunarwing_mt_onboard upgrade` drives the existing in-place upgrade
tooling with an interactive or non-interactive wrapper. The Python layer gathers
operator intent, prints a clear summary, streams script output, and displays the
phase result table. The shell scripts remain the source of truth for upgrade
gates and host compatibility:

- `ic/scripts/upgrade-preflight.sh` performs the read-only readiness check.
- `ic/scripts/upgrade-tenant-version.sh` performs the dry-run or apply phase.

Upgrade mode is dry-run by default. The wrapper only forwards `--apply` when the
operator explicitly chooses apply mode or passes `--apply` on the command line.

```bash
# Interactive dry-run
sudo python3 -m lunarwing_mt_onboard upgrade

# Non-interactive dry-run for a tenant currently on v1.1.6, v1.1.7, or v1.1.8
sudo python3 -m lunarwing_mt_onboard upgrade \
  --tenant ruffles \
  --target v1.1.9 \
  --non-interactive

# Apply after reviewing dry-run/preflight output
sudo python3 -m lunarwing_mt_onboard upgrade \
  --tenant ruffles \
  --target v1.1.9 \
  --apply \
  --yes \
  --non-interactive
```

The underlying upgrade script is PostgreSQL/rootful-Docker oriented. The wrapper
does not second-guess those checks; it runs preflight first by default and stops
before the upgrade if preflight reports a blocking failure. Operators can pass
`--force` to continue past a failed preflight, matching the shell script's
explicit override model.

For the lower-level operational runbook, see
`docs/ops/MT-LEGACY-UPGRADE-NOTES.md`.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                 lunarwing_mt_onboard/                    │
│                                                         │
│   cli.py              # entrypoint, questionary prompts │
│   config.py           # dataclass for tenant config     │
│   provisioner.py      # thin wrapper around mt-admin    │
│   secrets.py          # ic_sm adapter for key gen +     │
│                       #   encrypted PG insert            │
│   verify.py           # post-start health checks        │
│   __main__.py         # `python3 -m` support            │
│   requirements.txt    # questionary, rich, cryptography,│
│                       #   psycopg2-binary                │
│                                                         │
│   Future (Phase 2):                                     │
│   web/                  # SSE-driven build log UI       │
└─────────────────────────────────────────────────────────┘
```

### Interaction flow

```
$ sudo python3 -m lunarwing_mt_onboard
 [WARNING] Running as non-root. sudo is required for mt-admin.
           Re-run with: sudo python3 -m lunarwing_mt_onboard

? Tenant name (lowercase, e.g. 'ruffles')  anthony
? Gateway bind host  0.0.0.0
? Enable XMPP bridge?  Yes
  ? XMPP JID  anthony@xmpp.example.com
  ? XMPP password  [hidden]
  ? Extra allowed DM senders (comma-separated)  cmc@xmpp.example.com
? Enable Gotify notifications?  Yes
  ? Gotify URL  https://gotify.example.com/
  ? Gotify title override  anthony
? External workers (select all that apply)
  ● nanocode (NanoGPT)
  ● pebble (Rust harness)
  ● opencode (sst/opencode)
? Include Rust/Go/C++ toolchains in workers? (increases image size ~5GB)  Yes
? LLM provider configuration
  ? TensorZero upstream URL  http://192.168.1.157:3000/openai/v1
  ? LLM model  tensorzero::function_name::FrontierCODE
  ? LLM API key  [hidden]
? Secrets master key (leave blank to auto-generate a 32-byte hex)  [hidden]

Selected allocation summary (ports.json v11):
  base_port       10010
  gateway         10010
  nanocode_wss    10017
  pebble_wss      10018
  opencode_wss    20007

Proceed with add-tenant?  [yn]  y

─── Provisioning phase ───
[ansi green]add-tenant anthony --docker-group --xmpp-jid ...[/]
[progress bar / spinner, 30s–3min]

─── Build phase ───
[ansi green]build-tenant anthony --with-wasm --with-nanocode --with-pebble --with-opencode --with-toolchains[/]
[live build log with progress bar, 10–60 min per worker image]

─── Start phase ───
[ansi green]start-tenant anthony[/]
[dependency graph: pg → daemon → workers, waits for /health]

─── Verification phase ───
  ✓ gateway reachable on 0.0.0.0:10010
  ✓ nanocode worker: 1 running, /health 200
  ✓ pebble worker:   1 running, /health 200
  ✓ opencode worker: 1 running, /health 200
  ✓ SSH agent:       1 key loaded
  ✓ XMPP bridge:     connected

[ansi green]anthony is live![/]
  Gateway token:  abc123...  (copy to web UI auth header)
  Next: tunnel SSH to 127.0.0.1:10010, or open directly.
```

### Key behaviors

- All prompts are **skippable** via `--accept-defaults` / `--non-interactive` flags for automation (CI smoke test, bulk provisioning).
- Port allocation logic calls `mt-admin.sh list-tenants` to display the current port map and confirm before proceeding.
- Build failures trigger a retry prompt with a link to the log file (mirror fallback is handled by the Dockerfiles, but SSH / network blips are not).
- Post-start verification runs only after all selected units report healthy; a failed check prints a diagnostic command (e.g. `rc-service lunarwing-anthony status`).

## Module responsibilities

### `cli.py` — operator interaction

- Single `questionary.form()` or sequential `questionary.text()` / `questionary.select()` calls.
- Validates tenant name against `[a-z0-9-]` regex (mt-admin's `sanitize_name`).
- Confirms overwrites: refuses to re-create an existing tenant unless `--force` is passed.
- Renders a final summary table (`rich.table.Table`) and asks for confirmation before any destructive action.

### `config.py` — tenant configuration dataclass

```python
@dataclass
class TenantConfig:
    name: str
    gateway_host: str = "127.0.0.1"
    xmpp_jid: str | None = None
    xmpp_password: str | None = None
    xmpp_allow_from: list[str] = field(default_factory=list)
    gotify_url: str | None = None
    gotify_title: str | None = None
    workers: list[WorkerType] = field(default_factory=list)
    toolchains: bool = False
    tensorzero_url: str = "http://192.168.1.157:3000/openai/v1"
    llm_model: str = "tensorzero::function_name::FrontierCODE"
    llm_api_key: str | None = None
    secrets_master_key: str | None = None
```

Serializes to a JSON file for repeat runs: `config.to_json()` → `anthony.tenant.json`. The `--resume anthony.tenant.json` flag reloads a previous session.

### `provisioner.py` — subprocess orchestration

- Calls `mt-admin.sh add-tenant`, `build-tenant`, `start-tenant` via `subprocess.run()` with `stdout/stderr` captured.
- For the build phase, pipes stdout through `rich.live.Live` to show a scrolling build log with a progress spinner.
- Retries `apt-get update` calls (the snapshot fallback handles transient mirror issues; we add one retry for TCP/SSH failures).
- Returns a `ProvisionResult` with per-phase status, exit codes, and log paths.

### `upgrade.py` / `upgrade_cli.py` — in-place upgrade wrapper

- Captures upgrade intent in `UpgradeConfig`: tenant, target tag, source-version
  override, dry-run/apply mode, preflight, force, and auto-confirm flags.
- Builds argv for `upgrade-preflight.sh` and `upgrade-tenant-version.sh` without
  placing secrets on the command line.
- Defaults to dry-run and only includes `--apply` when explicitly requested.
- Runs preflight before upgrade by default and stops on preflight failure unless
  `--force` is set.
- Reuses the existing result-table display pattern and post-apply verification.

### `secrets.py` — key generation + encrypted PG insert

Two modes:

1. **Auto-generate** (default): calls `os.urandom(32).hex()` and writes the key to `env/pg.secret` (0600) and `env/lunarwing.env`.

2. **Reuse existing** (Kawarimi / migration): reads `SECRETS_MASTER_KEY` from keychain / env, then:
   - Derives per-tenant encryption key via HKDF (same as `ic_sm/scripts_4_db/insert_secret_pg.py`).
   - Inserts into `secrets` table via `psycopg2` with the tenant's `LUNARWING_OWNER_ID` scope.

The secrets module reuses the keying logic from `ic_sm/scripts_4_db/` but wraps it in a small class to keep the CLI code clean.

### `verify.py` — post-start checks

- Polls `/health` on every worker container for up to 90 seconds.
- Checks `rc-service lunarwing-<t> status` shows "started", not "crashed".
- Optionally pings the worker's WebSocket `/ws/agent` endpoint and expects a `ready` envelope.
- Prints a final colored summary table and the gateway token.

## Website / Web UI (Phase 2, not in this PR)

After CLI stabilizes, add `lunarwing_mt_onboard/web/`:

- A tiny `http.server` subprocess that serves a single-page vanilla-JS UI.
- SSE endpoint streams the build log to a browser so the operator can close the terminal.
- Optional: renders the port map as an interactive node graph.

This is deliberately out of scope for the current proposal — CLI first.

## Integration with `setup-instance.sh` (item #12)

`ic/scripts/setup-instance.sh` prints a deprecation banner at the top and exits immediately:

```bash
echo "--------------------------------------------------------------------"
echo "DEPRECATED: setup-instance.sh is deprecated as of v1.1.9."
echo ""
echo "Please migrate to the new interactive onboarding CLI:"
echo "  sudo python3 -m lunarwing_mt_onboard"
echo ""
echo "See docs/proposals/MT-ONBOARDING-CLI.md for migration notes."
echo "--------------------------------------------------------------------"
exit 0
```

This preserves backward compatibility for any existing scripts that source it, while directing operators to the new tool.

## Tests / Verification

- `python3 -m unittest discover` for prompt validation and JSON serialization.
- `bash scripts/test-mt-onboard.sh` runs a full non-interactive provisioning of a throwaway tenant using a pre-seeded ports registry, verifies `add-tenant` succeeds, runs `remove-tenant --purge`, and asserts the port block returns to the free pool.
- `bash ic/scripts/test-mt-onboard.sh` also checks upgrade config/argv tests and
  parses `upgrade --tenant <name> --target v1.1.9 --non-interactive --no-preflight`.
- Manual smoke test: install on the Gentoo box, provision `anthony`, verify XMPP connects + Gotify fires on a synthetic alert.

## Out-of-scope

- Kawarimi import / export flows (handled by `export-tenant.sh` / `import-tenant.sh`).
- WASM tool / channel installation beyond the `--with-wasm` flag.
- Cross-host migration of an existing tenant; upgrade mode covers same-host
  in-place upgrades only.
- Phase 2 web UI.

## Docs to update

- `docs/ops/MULTITENANCY-PRODUCTION.md` — replace the manual `add-tenant → build-tenant → start-tenant` walkthrough with a reference to the CLI.
- `docs/guides/TESTING_GUIDE.md` — add a smoke-test section for the CLI.
- `README.md` — update "Instance Setup" section to reference the CLI.
- `CHANGELOG.md` — note the new tool.

## Migration path (operator)

1. Stop existing tenants exported via Kawarimi.
2. Re-import using `import-tenant.sh` (legacy path, unchanged).
3. For new tenants, `sudo python3 -m lunarwing_mt_onboard`.
4. Unwrap secrets from old `~/.ironclaw` paths by pointing the CLI at the tenant's `env/pg.secret` during the next re-provisioning cycle.
