# Legacy Same-Host Version Upgrade (v1.0.3–v1.0.8 → v1.1.x)

**When to use this instead of the rootless-flip proposal
(`docs/proposals/MT-1.1.0-TO-1.1.4-UPGRADE.md`) or machine migration
(`docs/ops/MT-MACHINE-MIGRATION.md`):** when you have an **old Docker-based
rootful tenant** checked out at **v1.0.3 through v1.0.8**, and you want to bring
the same host up to a **v1.1.2 or v1.1.3** target without migrating to a new
machine or flipping to rootless Podman.

**Tool:** `ic/scripts/upgrade-tenant-version.sh` now supports both the modern
same-host path (source >= v1.0.9, default target v1.1.2) and a new legacy
same-host path (source v1.0.3–v1.0.8, explicit `--target` required).

**Companion docs:**

- `docs/proposals/MT-1.1.0-TO-1.1.4-UPGRADE.md` — the v1.1.0 → v1.1.4
  rootless-flip proposal. This runbook does **not** cover that path; read it
  only if your source is already v1.1.0-ish and you intend to adopt rootless
  Quadlet.
- `docs/ops/MT-1.1.4-UPGRADE-TOOLING-REVIEW-NOTES.md` — adversarial review notes
  for the v1.1.0 → v1.1.4 tooling (some of the lessons there informed how the
  legacy path guards backups and env handling).
- `ic/scripts/upgrade-tenant.sh` — the rootless-flip tool for v1.1.0-era
  sources. Do **not** use it for v1.0.3–v1.0.8 sources; that is what this
  runbook is for.
- `ic/scripts/rehearse-legacy-upgrade.sh` — the rehearsal fixture for the
  legacy path. It builds a genuine pre-reflex (`maxv < 19`) throwaway tenant at
  a legacy source ref, seeds a duplicate `memory_documents` group, runs the
  upgrade, and asserts the V21 dedup actually ran.

> **PostgreSQL only.** The legacy upgrade path, like the rest of
> `upgrade-tenant-version.sh`, supports only the PostgreSQL backend. It will
> abort if it detects anything other than the expected Docker PostgreSQL
> container for the tenant.

> **Docker rootful only.** Legacy tenants predate the Podman rootless work.
> The script explicitly refuses a Podman Postgres container for a legacy
> source; do not attempt to mix this path with rootless Quadlet.

> **Validation status (2026-06-21).** The legacy upgrade path is **reviewed and
> hardened but not yet live-validated** on a production tenant. The rehearsal
> fixture (`ic/scripts/rehearse-legacy-upgrade.sh`) builds a genuine pre-reflex
> (`maxv < 19`) throwaway tenant, seeds a duplicate `memory_documents` group,
> runs the upgrade, and asserts the V21 dedup ran (`maxv >= 21`, the seeded
> group collapsed, row count `N -> N-1`). The main open risk is whether old
> (v1.0.x) code still **builds** on the current toolchain. Treat the first real
> `v1.0.3-era → v1.1.x` transition as a **canary-first** operation. Modern-path
> upgrades (>= v1.0.9 → v1.1.2) have been exercised live; legacy has not.

---

## Overview

`upgrade-tenant-version.sh` performs a same-host, rootful, in-place version
upgrade of a single multi-tenant tenant. It was originally built for modern
sources (>= v1.0.9) and has been extended to cover legacy v1.0.3–v1.0.8
sources via a thin legacy wrapper around shared logic: it requires an explicit
`--target` (validated as a literal `vX.Y.Z` release tag, capped at v1.1.3) and
adds a mandatory legacy-warning gate. The DB backup, the V21 dedup/constraint
gate, and the apply steps are shared verbatim with the modern path — there is
no separate legacy backup or migration code path anymore.

The legacy path does **not** change the container model. The tenant stays on
Docker, stays rootful, and keeps the same PostgreSQL container. The upgrade
is purely: stop → checkout new tag → build → install WASM → render units →
patch env → start → verify.

---

## Prerequisites

- Root access on the tenant host (`sudo` or direct root).
- Docker CLI and the tenant's `lunarwing-pg-<tenant>` container running.
- PostgreSQL >= 15 inside that container (V21 requires
  `UNIQUE NULLS NOT DISTINCT`).
- `jq`, `git`, and the repo checkout with the target tag fetched.
- `ic/scripts/lunarwing-mt-admin.sh` and
  `ic/scripts/lunarwing-weechat-preflight.sh` in the repo checkout.
- Read `docs/ops/MULTITENANCY-PRODUCTION.md` if you have not operated
  multi-tenant hosts before.

---

## Quick start

```bash
# 1. Dry-run the gates (no changes)
sudo ic/scripts/upgrade-tenant-version.sh <tenant> --target v1.1.3

# 2. If all gates pass, apply
sudo ic/scripts/upgrade-tenant-version.sh <tenant> --target v1.1.3 --apply
```

Legacy sources will abort if you omit `--target`, and the `--target` must be a
literal `vX.Y.Z` release tag — a branch, SHA, or suffixed ref (e.g. a moving
`v1.1.0-rootless` branch) is rejected, because a moving ref could pull
post-v1.1.4 rootless code onto a rootful tenant. The legacy max target is
`v1.1.3`; attempting to target v1.1.4 or later is rejected with a pointer to
`ic/scripts/upgrade-tenant.sh` (the rootless-flip tool).

---

## Source-version detection

`upgrade-tenant-version.sh` runs `git describe --tags` inside the tenant clone
and classifies the result:

| Source range | Classification | Behavior |
|--------------|----------------|----------|
| >= v1.0.9 | `modern` | Default target is `v1.1.2`; `--target` is optional. |
| v1.0.3 – v1.0.8 | `legacy` | `--target` is **required**; max target is `v1.1.3`. |
| < v1.0.3 | `unsupported` | Script aborts unless you pass `--force`. |

The detection is based on `git describe --tags` parsed to extract `MAJOR.MINOR.PATCH`,
then compared as a decimal value. You can override it with `--source-version-override <tag>`
if `git describe` does not produce a clean version string for the tenant clone.

> **Why the explicit `--target` requirement?** Legacy sources are far enough
> behind that a silent default could land you on a target you did not intend
> (for example, a v1.0.3-era tenant cannot safely jump straight to a rootless
> model). The script refuses to pick a default for legacy sources so the
> operator must choose the target deliberately.

> **Why the v1.1.3 cap?** Beyond v1.1.3 you enter the v1.1.4 rootless-flip
> territory covered by `ic/scripts/upgrade-tenant.sh`. If you want to end up
> on v1.1.4 or later, use this runbook to reach v1.1.3 first, then decide
> separately whether to run the rootless-flip.

---

## Legacy vs modern path at a glance

| Concern | Modern path (>= v1.0.9) | Legacy path (v1.0.3–v1.0.8) |
|---------|--------------------------|------------------------------|
| Target default | `v1.1.2` | none — must pass `--target` |
| Max target | whatever the script allows | `v1.1.3` |
| DB backup | `mt-admin backup-tenant` (shared) | `mt-admin backup-tenant` (shared) |
| DB restore (rollback) | printed inline `docker exec ... pg_restore` | printed inline `docker exec ... pg_restore` |
| Render-units | `mt-admin render-units` | tries `mt-admin render-units`, falls back to sourcing modern `lunarwing-mt-admin.sh` for `render_tenant_systemd_units` |
| Migration risk focus | shared V21 dedup / `unique_path_per_user` gate | same shared gate; V19/V20 are additive and may also be pending |
| Extra gate | none | **GATE 8** — explicit legacy warning that must be confirmed |
| Validation status | live-validated | rehearsal fixture only; not production live-validated |

---

## Gates explained

The legacy path runs the same gates 0, 1, 2/3/4, 5, 6, and 7 as the modern path
(Gates 2/3/4 are the shared `gate_migration_state`, not a separate legacy
variant) and adds **GATE 8**:

| Gate | Purpose | Legacy behavior |
|------|---------|-----------------|
| 0 | Container runtime is Docker | Aborts if `lunarwing-pg-<tenant>` is a Podman container or missing. |
| 1 | PostgreSQL >= 15 | Required for V21's `UNIQUE NULLS NOT DISTINCT`. |
| 2/3/4 | V21 dedup + constraint | Shared gate for both paths. For any `maxv < 21` it verifies the `unique_path_per_user` constraint exists (dies if absent — V21's `DROP CONSTRAINT` has no `IF EXISTS`), then counts duplicate `memory_documents` groups (`GROUP BY user_id, COALESCE(agent_id::text,''), path HAVING count(*)>1`). `memory_documents` exists since `V1__initial.sql`, so this always runs — legacy is not special-cased and never skips the check. If duplicates exist it warns and requires explicit confirmation (auto only under `--yes`) before V21 deletes the losers. |
| 5 | Clean working tree | `git checkout <target>` must not clobber local edits. |
| 6 | WeeChat pre-flight | Read-only; warns if the relay/adapter looks unhealthy. |
| 7 | Onboarding flag | Confirms `profile_onboarding_completed=true` in `config.toml` if present. |
| **8** | **Legacy warning** | Prints: "This upgrade path (v1.0.3-era -> v1.1.x) has NOT been live-validated." Requires explicit confirmation; `--yes` is honored only if all other gates also pass. |

---

## Apply steps

When you run with `--apply`, the legacy path performs the following ten steps
(the same shared sequence as the modern path):

1. **Backup** — the shared `backup_tenant()` runs `mt-admin backup-tenant`
   (the repo-checkout `mt-admin` has that verb). The DB dump is a root-owned
   `-Fc` dump written under `$LUNARWING_MT_BACKUP_DIR/<tenant>/`
   (default `/var/lib/lunarwing-backups/<tenant>/`) and is validated for the
   `PGDMP` magic and a sane size. Only `.bak` copies of `lunarwing.env`,
   `ports.json`, and `weechat.capabilities.json` land in
   `$HOME_DIR/backups/<target>-upgrade-<stamp>/` (mode `0700`, chowned to the
   tenant). There is no inline `pg_dump` anymore.
2. **Stop tenant** — `mt-admin stop-tenant <tenant>`.
3. **Fetch + checkout target** — as the tenant user, with `safe.directory` set.
4. **Build tenant** — `mt-admin build-tenant <tenant> --with-wasm`.
5. **Install WASM** — `mt-admin install-wasm <tenant>`.
6. **Render units** — tries `mt-admin render-units` (the repo-checkout
   `mt-admin` the script runs as `$MT`); if that invocation does not expose the
   verb, the script sources the same repo-checkout `lunarwing-mt-admin.sh`
   (`--source-only`) and calls `render_tenant_systemd_units <tenant>` directly.
7. **Patch env** — `mt-admin patch-env <tenant>`.
8. **Start tenant** — `mt-admin start-tenant <tenant>`.
9. **Clean up stale pre-v1.1.0 weechat unit** — removes the old
   `weechat-<tenant>.service` orphan if present.
10. **Kick weechat adapter last** — restarts the adapter after WeeChat has
   settled, then polls `/api/health` for `ws_connected=true`.

After the steps, the script prints verification queries (migration history,
constraint definition, onboarding flag) and the legacy-specific rollback
instructions.

---

## Rollback (legacy-specific)

The legacy path keeps the **same Docker PostgreSQL container** and the same
rootful model, so rollback is primarily a git + DB restore operation. Do **not**
delete or recreate the Postgres container — pre-v1.1.4 tenants store data in
its writable layer, not a named volume.

Rollback is operator-driven and print-only — the script prints these steps at
the end of an `--apply` run; it never restores automatically. In addition, an
`--apply` run arms a failure trap (`on_apply_exit`) right after the verified
backup is taken: if the run aborts mid-flight, the trap prints the same
recovery steps (the validated backup dump path and the pre-upgrade git rev) so
a half-applied, stopped tenant is never left silent.

```bash
# 1. Stop the tenant
sudo ic/scripts/lunarwing-mt-admin.sh stop-tenant <tenant>

# 2. Re-check out the original source tag
sudo -u <tenant> git -c safe.directory=/home/<tenant>/lunarwing \
  -C /home/<tenant>/lunarwing checkout <original-tag>

# 3. Restore the DB from the dump mt-admin took during the upgrade
sudo docker start lunarwing-pg-<tenant>
sudo docker exec -i lunarwing-pg-<tenant> \
  pg_restore -U lunarwing -d lunarwing --clean --if-exists \
  < /var/lib/lunarwing-backups/<tenant>/<newest>.dump

# 4. If env or capabilities diverged, restore from the backup dir
cp -a /home/<tenant>/lunarwing/backups/<target>-upgrade-<stamp>/lunarwing.env.bak \
  /home/<tenant>/lunarwing/env/lunarwing.env
cp -a /home/<tenant>/lunarwing/backups/<target>-upgrade-<stamp>/weechat.capabilities.json.bak \
  /home/<tenant>/lunarwing/state/channels/weechat.capabilities.json

# 5. Rebuild and restart on the old tag
sudo ic/scripts/lunarwing-mt-admin.sh build-tenant <tenant> --with-wasm
sudo ic/scripts/lunarwing-mt-admin.sh render-units <tenant>
sudo ic/scripts/lunarwing-mt-admin.sh start-tenant <tenant>
```

> **Rollback restores via the inline `pg_restore` above, not `mt
> restore-tenant`.** Both the legacy and modern paths print this same direct
> `pg_restore` command; neither rolls back through `mt-admin`. Backups, by
> contrast, do go through the repo-checkout `mt-admin backup-tenant` — that
> verb exists; only a *restore* verb is intentionally not used here.

---

## Rehearsal fixture

`ic/scripts/rehearse-legacy-upgrade.sh` mirrors the `rehearse-testbot.sh`
pattern and provides a throwaway tenant named `rehearse-legacy` (configurable
with `--name`).

Actions:

```bash
# Build a genuine pre-reflex fixture at the legacy source ref + seed a duplicate group
sudo ic/scripts/rehearse-legacy-upgrade.sh up

# Run the legacy upgrade against that tenant and assert the V21 dedup ran
sudo ic/scripts/rehearse-legacy-upgrade.sh verify

# Tear the tenant down
sudo ic/scripts/rehearse-legacy-upgrade.sh --cleanup
```

Flags:

- `--source-ref <ref>` — legacy source tag to build the fixture at (default `v1.0.4`).
- `--target <tag>` — upgrade target; defaults to `v1.1.2`.
- `--dry-run` — prints what `up` or `verify` would do without making changes.
- `--yes` / `-y` — auto-answers confirmation prompts.
- `--name <name>` — uses a tenant named other than `rehearse-legacy`.

The `verify` action ultimately runs:

```bash
ic/scripts/upgrade-tenant-version.sh <name> \
  --source-version-override v1.0.4 --apply --target v1.1.2 --yes
```

> **What the rehearsal proves:** that the gates, checkout, build, `mt-admin`
> backup, unit rendering, and start sequence execute without error on a
> synthetic tenant, **and** that the V21 dedup genuinely ran — it asserts
> `maxv >= 21`, the seeded duplicate group collapsed, and the row count dropped
> by exactly one. **What it does not prove:** OMEMO continuity, encrypted
> secret decryption, real-message round trips, or production load behavior; nor
> does a green run guarantee old (v1.0.x) code builds on every toolchain. After
> the rehearsal succeeds, still treat the first real tenant as a canary and
> verify those operational concerns by hand.

---

## Known limitations

- **PostgreSQL only.** libSQL tenants are not supported by the legacy path (or
  by `upgrade-tenant-version.sh` in general).
- **Rootful Docker only.** Podman containers are rejected; the legacy path is
  not a route into the rootless/Quadlet model.
- **Not live-validated on production.** The path has been dry-runnable via the
  rehearsal fixture, but no production tenant has been taken through it yet.
- **Target cap of v1.1.3.** If you need v1.1.4 or later, reach v1.1.3 with
  this runbook and then evaluate the rootless-flip path separately.
- **`< v1.0.3` requires `--force`.** Source versions older than v1.0.3 are
  classified unsupported and will abort unless you force the issue.
- **Rollback restore is inline, not `mt restore-tenant`.** Backups go through
  the repo-checkout `mt-admin backup-tenant` (root-owned dump under
  `/var/lib/lunarwing-backups/<tenant>/`), but rollback prints a direct
  `pg_restore` for the operator to run — both the legacy and modern paths do
  this, and neither restores through `mt-admin`.

---

## Security notes

- The DB dump is written root-owned under `$LUNARWING_MT_BACKUP_DIR/<tenant>/`
  (default `/var/lib/lunarwing-backups/<tenant>/`) by `mt-admin backup-tenant`.
  It contains the full database, including encrypted secret rows — protect it
  like a key.
- The `$HOME_DIR/backups/<target>-upgrade-<stamp>/` dir (mode `0700`, chowned to
  the tenant) holds only the `.bak` copies of `lunarwing.env`, `ports.json`, and
  `weechat.capabilities.json`. The env file contains `SECRETS_MASTER_KEY` and
  XMPP credentials; keep it locked down and delete both the dump and the backup
  dir once you are confident the upgrade has soaked.
- `render-units` fallback sources the modern `lunarwing-mt-admin.sh` from the
  repo checkout but does not execute arbitrary user-supplied paths; ensure the
  checkout is trusted.
