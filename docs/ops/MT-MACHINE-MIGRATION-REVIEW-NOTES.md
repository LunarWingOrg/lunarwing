# MT Machine-Migration Tooling — Adversarial Review Notes

**Scope:** the machine-migration tooling — `ic/scripts/export-tenant.sh`,
`ic/scripts/import-tenant.sh`, and the runbook `docs/ops/MT-MACHINE-MIGRATION.md`.
**Companion:** `docs/ops/MT-MACHINE-MIGRATION.md` (the runbook) and
`docs/ops/MT-1.1.4-UPGRADE-TOOLING-REVIEW-NOTES.md` (the in-place tooling's review).
**Status:** all findings below are **fixed** (in the migration-tooling review-fix
commit, `4d1943cd`, now in history via PR #65). This doc is a reference in case the
tooling is revisited.

**Post-review validation (2026-06-20):** the full `export → import → start` cutover has
since been **live-validated end-to-end on a production tenant** (the migrated tenant
came up operational on the new host; OMEMO encrypted-chat and `SECRETS_MASTER_KEY`
secret continuity were not separately spot-checked).

## Review method

One multi-agent adversarial pass (4 lenses: export correctness, import
ordering/correctness, the SECRETS_MASTER_KEY/OMEMO/cutover lens, and
cross-cutting/runbook accuracy) produced 33 raw findings that deduped to ~12 distinct
issues. The per-finding verification phase **partially hit a session limit**, so the
remaining verdicts were completed by hand against the code before fixing. Several
verifiers *downgraded* severities from the lens-assigned levels (noted below); all
were fixed regardless because the migration handles `SECRETS_MASTER_KEY` and the OMEMO
store and the cost of fixing was low.

The single biggest change was **reframing export as the start of cutover** (it now
quiesces the writers before snapshotting) — see HIGH-1.

---

## HIGH

### HIGH-1. Live + early state snapshot → torn OMEMO store and stale/lost data
`export-tenant.sh` originally required only the PG container to be up and tarred
`state/` (incl. the OMEMO `state/xmpp` store) while the daemon + xmpp-bridge were
**running**, at Procedure step 1 — with cutover happening *later*. Two problems: (a)
the OMEMO double-ratchet store (per-file atomic writes, no cross-file transaction —
`ic/src/channels/xmpp/omemo/store.rs`) could be tarred mid-write → torn/inconsistent →
encrypted XMPP fails to load on the new host; (b) anything written to the DB or OMEMO
store **between export and cutover** is silently lost, and the OMEMO ratchet drifts
past the snapshot.
**Fix:** export now **stops the tenant's daemon + xmpp-bridge** before snapshotting
(PostgreSQL stays up only for `pg_dump`), init-agnostically (systemd-user / OpenRC),
with a `--no-quiesce` escape that still verifies the daemon is down. Export is now
explicitly the **start of cutover**, so the snapshot is both consistent and final.
*(Verifiers rated the torn-store aspect partial/low; the export-time-vs-cutover
data-loss aspect is the load-bearing reason for the fix.)*

### HIGH-2. `SECRETS_MASTER_KEY` value on `grep` argv + unsound verification
The post-inject check was `grep -qxF "$(grep '^SECRETS_MASTER_KEY=' manifest)" "$ENVF"`:
it put the secret VALUE on `grep`'s argv (readable via `/proc/<pid>/cmdline` for the
brief grep), and if the inner grep found nothing it became `grep -F ""` which matches
**any** line → a false PASS.
**Fix:** compare command-substituted lines (`man_key`/`live_key`, values never on
argv) and require non-empty + exact equality before restore.

### HIGH-3. `set -e` abort when the LAST carried key is missing
`extract_keys` used `[[ -n "$line" ]] && printf …` as the loop body; if the final key
was absent, the `[[ ]]` returned non-zero as the function's last command → under
`set -e` the whole export aborted.
**Fix:** use the `if [[ -n "$line" ]]; then printf …; fi` form (in `copy_key`);
functionally verified surviving `set -e` with a missing last key.

### HIGH-4. `LLM_BASE_URL` carried verbatim clobbers the new host's proxy port
The default `LLM_BASE_URL` is `http://127.0.0.1:<proxy_port>/v1` — host-specific (the
new host allocates its own proxy port). Carrying it overwrote the new host's correct
value → LLM calls fail after cutover.
**Fix:** carry `LLM_BASE_URL` **only when it is not a loopback URL**
(`127.0.0.1`/`localhost` are skipped; a deliberate custom/gateway endpoint is carried).
*(Policy decision: skip loopback, carry everything else.)*

### HIGH-5. libSQL source → silent empty PostgreSQL import
For a non-postgres source, export skipped `pg_dump` ("DB travels in state.tar.gz") but
the new host's `add-tenant` hardcodes `DATABASE_BACKEND=postgres` and import skipped
`restore-tenant` → the daemon booted on an empty Postgres, losing all data silently.
**Fix:** both scripts now **refuse a non-postgres tenant** with a clear message rather
than risk a silent empty import (a libSQL DB file would need a manual copy + libSQL
target).

---

## MEDIUM

### MED-1. Whole-state restore clobbers host-specific `state/config.toml`
`add-tenant` writes `state/config.toml` with the **new** host's external-worker WSS
ports (`ensure_external_worker_config`). Restoring the whole old `state/` overwrote it
with the old host's ports → workers misrouted.
**Fix:** exclude `state/config.toml` from the export tar **and** defensively on
import restore.

### MED-2. Stale v1.1.0 `.wasm` artifacts persist past `install-wasm`
`install-wasm` copies but never cleans, so old `state/tools/*.wasm` +
`state/channels/*.wasm` carried in the tar lingered alongside the fresh v1.1.4 builds
→ version/ABI skew.
**Fix:** exclude `*.wasm` from the export tar (and on import restore); `install-wasm`
lays down fresh v1.1.4 artifacts.

### MED-3. Intra-host token mismatch (config.toml worker-auth vs carried gateway token)
Carrying `GATEWAY_AUTH_TOKEN` while `add-tenant` had already written `config.toml`'s
worker `auth_token` from the *throwaway* token produced an inconsistency.
**Fix:** intra-host tokens (gateway / bridge / webhook / relay) are **not carried** —
the new host mints fresh, self-consistent ones. Gateway-UI and external-webhook
clients re-authenticate after cutover (documented). Only values that must match the
source are carried (`SECRETS_MASTER_KEY`, XMPP identity, operator config).

### MED-4. `--start --yes` bypassed the same-JID double-login guard
The cutover confirmation used `confirm()`, which `--yes` short-circuits — so
`--start --yes` could start the new daemon while the old one still held the same XMPP
JID (two logins conflict).
**Fix:** the start gate is **not** satisfied by `--yes`; it requires `--old-stopped`
for an unattended start, otherwise prompts interactively.

### MED-5. Runtime auto-detection was podman-first
Export defaulted to podman whenever the binary existed, ignoring which runtime
actually owned the container → a docker-backed source with podman also installed got a
misleading "container not running".
**Fix:** probe **both** podman and docker for the actual container; honor
`LUNARWING_CONTAINER_RUNTIME`; clearer error when truly absent.

### MED-6. `pg_dump` hardcoded role/db `lunarwing`  *(verifier: not-a-bug; fixed defensively)*
A genuine pre-rename source could have role/db named `ironclaw`. The verifier rated
this **not-a-bug** for the lunarwing-named instances in scope, but it was fixed anyway
for robustness: export **parses role + db from the source `DATABASE_URL`** (in-process
parameter expansion — the password never reaches argv) and records them in `meta.txt`.

---

## LOW

- **`inject_keys` dropped a manifest line lacking a trailing newline** + **CRLF/trailing
  whitespace carried verbatim.** Fixed: `while IFS= read -r line || [[ -n "$line" ]]`
  and CR-stripping in both `copy_key` (export) and `inject_keys` (import).
- **Import used the unsanitized tenant name** for paths/getent/chown while mt-admin
  sanitizes internally. Fixed: import sanitizes the name to `[a-z0-9-]` up front.
- **Dry-run skips the read-only preflight checks; dump validation is header-only.**
  Accepted as documented behavior: `--dry-run` validates the *plan*, not the outcome;
  the real confidence comes from the throwaway-tenant rehearsal. The PGDMP-header +
  non-zero-size check is a cheap sanity gate, not a full integrity verify.
- **`add-tenant` can exit 0 with PG not yet ready, then import restores.** Mitigated by
  `restore_tenant_postgres`'s own "PG must be running" gate (it dies rather than
  restoring into a down DB).

---

## Post-review fixes (found in use)

### PR-1. Gateway/HTTP bind address not carried → reset to `127.0.0.1` on the new host
Found during real use: `export-tenant.sh`'s carry list omitted `GATEWAY_HOST`/`HTTP_HOST`,
so on import `add-tenant` wrote the hardcoded `127.0.0.1` default and nothing overrode
it — an operator who had bound the gateway to `0.0.0.0` (for remote access) on the old
host came up localhost-only on the new host and had to hand-edit. Same clobber class as
HIGH-4/MED (operator config reset to defaults), just not extended to the gateway/http
bind.
**Fix:** added `GATEWAY_HOST` + `HTTP_HOST` to the export carry list (the bind *address*
is operator config; the *ports* stay host-specific and regenerated). `import-tenant.sh`'s
`inject_keys` then applies them over the add-tenant default, so the binding survives the
migration. *(Separately, mt-admin's `write_tenant_lunarwing_env` still hardcodes these on
every write — a preserve-on-rewrite + override knob there is the broader fix if hand-edits
should survive plain `add-tenant` re-runs; not yet done.)*

## Confirmed correct / not changed

- `pg_dump` is MVCC-consistent (the DB half of the snapshot was never the torn-store
  concern — only the on-disk OMEMO store was, now fixed by quiescing).
- The bundle + manifests are `0600` in a `0700` dir; secrets are written via files and
  `awk ENVIRON`/command substitution, not on argv (after the HIGH-2 fix).
- `import` delegates all init/runtime specifics to `mt-admin`, so it works on systemd
  and OpenRC and on rootless-podman / rootful-docker without script changes.

## Known, intentional limitations

- **PostgreSQL only.** libSQL machine-migration is refused by design (see HIGH-5);
  migrate a libSQL DB file by hand if ever needed.
- **`ic/scripts/rehearse-testbot.sh` is UNTESTED** (syntax/shellcheck-validated, not
  executed). Its seeded DB marker proves DB round-trip only — it does **not** exercise
  OMEMO or encrypted-secret continuity. For a full rehearsal, send a real message + an
  OMEMO chat through the testbot and confirm both survive on the new host.
- The migration is a **cutover with downtime** per tenant (export stops the agent until
  it is started on the new host) — this is deliberate, to guarantee a consistent +
  final snapshot. The old host remains the rollback.
