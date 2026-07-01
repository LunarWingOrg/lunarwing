# Upgrade / Migrate Issues Found

## The core problem: no tooling fits rootless-Podman tenants

Mercury and venus are **rootless Podman + Quadlet** tenants. The three upgrade scripts all miss this case:

- **`upgrade-tenant-version.sh`** (the "in-place version bump") **refuses to run** — it dies at `:125 "docker required"` and GATE 0 aborts if PG isn't a docker container. Built for rootful Docker.
- **`upgrade-tenant.sh`** is the v1.1.0→v1.1.4 **rootless flip** tool. Mercury/venus are already rootless, so it's the wrong tool.
- **Named variants** (`kageho`/`starforce`/`sunburst`) **hardcode tenant paths** — not usable for mercury/venus.

So the realistic path is a **manual mt-admin sequence** (`backup → stop → git checkout → build → render-units → patch-env → start`), which skips all the pre-flight safety gates the scripted tools have.

## Risk surface ranked

### 1. Owner-scope rekey — the #1 silent-failure risk
`migrate_owner_scope` (`lunarwing-mt-admin.sh:2543`) rekeys 15 tables from `user_id='default'` → tenant name. It auto-fires in `patch-env`/`start-tenant`/build hook — **but only if PG is running at that moment** (`_owner_scope_needs_migration` returns false if it can't reach PG, `:2526`).

**Failure mode (from `MT-MACHINE-MIGRATION.md:111-125`):** if PG isn't up when `start-tenant` checks, the rekey silently skips. The daemon boots against `default`-scoped rows → **empty history/memory, no error logged** ("silently amnesiac"). Worse: if the amnesiac daemon writes new `<tenant>`-scoped rows, a *later* rekey hits unique-constraint collisions and dedup keeps the *new* (empty) rows, dropping old data.

Additional weaknesses: it only samples 5 of 15 tables in the trigger check (`:2531`), and swallows per-table SQL errors. GOALS_1.1.7 #13 is still OPEN.

### 2. Wrong tool selection
As above — easy to grab the wrong generic tool and hit a hard refusal, or reach for a named variant that hardcodes another tenant's paths.

### 3. Migration-on-boot abort (`db/mod.rs:111`)
`embed_migrations!("migrations")` bakes V1..V21 SQL into the binary at compile time. On daemon boot, `run_migrations` runs automatically; a failing migration is propagated via `?` and **hard-aborts daemon startup**. The scripted `gate_migration_state` pre-flight catches this beforehand; the manual sequence doesn't.

(Note: for v1.1.6→v1.1.7 specifically, V1..V21 are byte-identical, so no new SQL runs — this risk is for *future* jumps.)

### 4. `--prune-old-root` (IRREVERSIBLE)
Guarded by row-count (refuses if rootless DB has 0 conversation rows), only runs after migration is verified. Low risk on already-rootless tenants like mercury/venus, but worth knowing it's a one-way delete.

### 5. SECRETS_MASTER_KEY drift
The env file isn't rewritten by the in-place path, but a stray `add-tenant` re-run or `patch-env` could reset it. If it drifts, all encrypted DB secrets become **undecryptable** (AES-256-GCM, HKDF-SHA256 keyed from the master key). The env writer does preserve it via `_env_existing` (`:1888`), but worth verifying post-upgrade.

## Safety-machinery gaps in mt-admin itself

- **Postgres Quadlet has NO config-hash gating** (`start_tenant_postgres:3488`). The hash sidecar that forces worker/vision container recreation on env drift does **not** cover PG. A changed PG password/image is written to the quadlet but not picked up by an existing container. That's why `tenant_pg_password` is deliberately stable and rotation is a separate command.
- **Backups are NOT automatic on upgrades** within mt-admin — `backup-tenant` is on-demand only. The `upgrade-tenant.sh` orchestrator takes one; the manual sequence doesn't unless you remember to.
- **Rootful→rootless orphan guard** (`:3439`) has a coverage hole: it doesn't catch "rootless exists but empty while a root orphan persists" — that indistinguishable-from-steady-state case is left to `upgrade-preflight.sh` / `--prune-old-root`.

## Footguns that *were* real but are already fixed
Good to know these existed (so you can spot regressions):
- **Table-count verify** used to count `information_schema.tables`, which refinery creates on first connect regardless of restore → a never-restored DB falsely passed. Now counts conversation *rows*.
- **Re-apply source re-derived from live env** — an interrupted run after `add-tenant` reset env would capture defaults as the "backup." Fixed via write-once pre-upgrade snapshot.
- **`XMPP_ALLOW_PLAINTEXT_FALLBACK`** — `add-tenant` hardcodes it `true` on every write, so a hardened tenant would silently regain plaintext fallback after upgrade (security regression). Fixed → added to the re-apply list.

---

Want me to dig deeper into any one of these, or pivot to something else?
