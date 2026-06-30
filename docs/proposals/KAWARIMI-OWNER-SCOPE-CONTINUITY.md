# Kawarimi Owner-Scope Continuity — Implementation Proposal

**Status:** Proposed (deferred feature) · **Branch:** `staging-kawarimi-migration` ·
**Date:** 2026-06-30

**Tracks:** GOALS_1.1.7 #13 ("Retest kawarimi tenant migration since NEW database
migration is needed now since 1.1.6"). **Reference:** `docs/ops/MT-MACHINE-MIGRATION.md`
§ *Owner-scope (`user_id`) continuity*.

> This proposal is grounded in an adversarially-verified design pass (the gap, the
> integration points, the users-table FK behaviour, and the self-wipe hazard were each
> confirmed against the code). Line numbers are current as of the branch HEAD; prefer the
> named functions/subcommands as the durable anchors.

---

## 1. Problem

Kawarimi machine migration (`export-tenant.sh` → bundle → `import-tenant.sh` →
`lunarwing-mt-admin.sh`) restores a tenant's PostgreSQL with
`pg_restore --single-transaction --clean --if-exists` (`lunarwing-mt-admin.sh:3739`),
which reloads **every row's `user_id` ("owner scope") verbatim**. The new daemon, however,
is **hard-scoped** to `LUNARWING_OWNER_ID=<tenant>` (written by `add-tenant`,
`lunarwing-mt-admin.sh:1923`). The only automatic reconciliation is the `start-tenant`
safety net (`:5266`) — and it, the `build-tenant` net (`:1517`), and `patch-env` (`:2400`)
all call `_owner_scope_needs_migration "$name"` / `migrate_owner_scope "$name"` with **no
`--from`**, so both default `old_scope='default'` (`:2512`, `:2536`).

**Result — the silent-empty gap.** If the restored rows are scoped to anything other than
`default` *and* other than the target tenant name — i.e. a `--name` **rename**, a **non-`default`
source** (an MT tenant already scoped to its own name, or a legacy owner id), or a
**multi-scope / dirty** source — the `default`-only gate never fires and the new daemon comes
up **silently amnesiac**: empty history, no memory, routines don't load, encrypted secrets
unavailable, with **no error logged**.

**What is already landed on this branch (necessary but not sufficient):**

| Commit | Change | Why it does *not* close this gap |
|--------|--------|----------------------------------|
| `91283004` | `migrate_owner_scope` collision-hardening (per-table dedup, atomic txns, surfaced errors, all-13-table verify) | A **no-op on a clean restore-into-empty-DB** — there are no pre-existing `<tenant>` rows to collide with. It hardens the *convert-existing-tenant* case, not this. |
| `1a095c21` | Self-wipe guard (`old_scope == name` early-return) | Prevents a **catastrophe** when `--from <tenant>` is passed, but does not *invoke* any rekey. |
| `d00accf4`, `fbd505d1` | Docs: owner-scope continuity + silent-amnesia risk note | Documents the manual workaround; does not automate it. |

The gap is that the rekey is **never invoked with the right `--from`** on a non-`default`
source — not that it mishandles the rekey once invoked.

---

## 2. Goals & non-goals

**Goals**
- The import path **guarantees owner-scope continuity** (no silent-empty) for `default`,
  same-name, renamed, and non-`default` single-scope sources — automatically.
- On an **ambiguous (multi-scope) source**, **fail closed** with an actionable message
  rather than silently rekeying one scope and orphaning the rest.
- Stay within kawarimi's existing constraints: PostgreSQL-only; `export-tenant.sh` remains
  self-contained (container runtime + `jq` + `tar`, v1.1.0-source-safe); the target DB/role
  is always `lunarwing`.

**Non-goals**
- Changing the **fleet-wide `start-tenant` behaviour** for normal (non-migration) operation
  — too high a blast radius (rejected option, §3).
- libSQL machine migration (kawarimi is postgres-only by design).
- Redesigning web-gateway multi-user identity (the `users`-table FK is handled narrowly, §4.5).

---

## 3. Design decision

**Chosen: import-side authoritative detection + guarded `migrate-owner-scope --from`,**
with an **optional** export-side hint recorded in `meta.txt`.

After `restore-tenant`, `import-tenant.sh` detects the **actual** distinct owner scope(s) in
the just-restored DB (via a new read-only `mt-admin` helper) and reconciles them to the
target tenant name using the existing `migrate-owner-scope --from` path.

**Why import-side detection is canonical:**
- **Authoritative** — reflects exactly what `pg_restore` loaded, not what the source *said*.
- **Idempotent under `--force` re-import** — re-derived from the freshly-restored DB each run.
- **Works for old bundles** — needs no new `meta.txt` field.
- **Lowest blast radius** — does not touch the protected `start-tenant` hot path (`:5266`).
- **Knows the operator's `--name` intent** (`import-tenant.sh:44`), which the target-side gate
  cannot see.

**Rejected / secondary:**
- *Generalize the `start-tenant` gate to auto-detect any non-target scope* — fixes all paths
  in one place but runs on **every start for every tenant**, re-introduces the self-wipe
  hazard into normal operation, and changes long-stable fleet behaviour. **Rejected** as the
  primary mechanism (acceptable only as a narrow, strictly-guarded backstop, out of scope here).
- *Export records a single `source_owner_scope` and import blindly rekeys from it* — unsafe on
  multi-scope sources (orphans the non-recorded scope) and requires an updated source. Kept
  only as an **optional early-warning hint** (§4.4), not the canonical mechanism.

---

## 4. Components & changes

### 4.1 `mt-admin`: read-only detection helper + subcommand
Add `_owner_scope_detect <name>` next to `_owner_scope_needs_migration`
(`lunarwing-mt-admin.sh:2512`) plus a `detect-owner-scopes <name>` dispatch case near the
`migrate-owner-scope)` case (`:5910`). It runs a read-only `SELECT DISTINCT user_id` over the
core owner-scoped tables the gate already trusts (`settings`, `conversations`,
`memory_documents`, `secrets`, `agent_jobs`), excluding `NULL`/empty, one scope per line.
Hardcodes `-U lunarwing -d lunarwing` (the target DB is always `lunarwing`, so a pre-rename
`ironclaw` source is irrelevant here). Per-table guarded with `2>/dev/null || true` so a
table missing on a v1.1.0-schema dump contributes nothing instead of aborting.

### 4.2 `mt-admin`: guards in `migrate_owner_scope`
- **Self-wipe guard** (`old_scope == name` → no-op return): **DONE** (`1a095c21`, `~:2550`).
  Mandatory precondition for any `--from` caller.
- **Charset validation** (TODO): validate `old_scope` against `^[A-Za-z0-9._-]+$` before it is
  interpolated into the ~30 SQL string-literals (`:2520`+) and at the `--from` dispatch
  (`:5910`+), aborting with a manual-remediation message on failure. Closes the raw-interpolation
  surface (a scope containing a quote otherwise breaks the rekey — loud per-table rollback, not
  silent, but still incomplete).

### 4.3 `import-tenant.sh`: the rekey step (the core change)
Insert a new banner step **between `restore-tenant` (`:166`) and the stage/start branch
(`stage_msg` `:187` / `if ! $DO_START` `:199` / `start-tenant` `:211`)** — it **must** run
before either stage or start, because a later manual `start-tenant` would still only hit the
`default`-gate. Logic (decision table in §5), driven by `detect-owner-scopes`:
- Add an optional `--owner-scope <S>` (a.k.a. `--from <S>`) operator override for the
  ambiguous case.
- Honour `--dry-run` (print the planned `migrate-owner-scope` command, change nothing).
- Treat `migrate_owner_scope`'s post-run "offenders remain" report as a **hard stop** before start.

### 4.4 `export-tenant.sh` (optional, phase 2): early-warning hint
In the `meta.txt` heredoc (`~:218-226`), record `source_owner_scopes=<comma-list>` from a
read-only `SELECT DISTINCT user_id` against `$PG_ROLE/$PG_DB` (parsed at `:82-84`; PG is up
for `pg_dump` at `~:142`). Lets export **warn or refuse on a dirty multi-scope source before
the bundle ships**. Import treats it as advisory only — import-side detection (§4.1) stays
authoritative.

### 4.5 `users`-table FK handling
`api_tokens.user_id` and `user_identities.user_id` are `NOT NULL REFERENCES users(id) ON
DELETE CASCADE` (non-deferrable, no `ON UPDATE`), and `users` is **not** in
`migrate_owner_scope`'s 13-table list (`:2568`); `users.id` *is* the scope (no separate
column). So rekeying those two children to `<tenant>` **FK-fails unless a `users(id=<tenant>)`
row exists** — but only when those tables are **non-empty** (web-gateway users), which is rare
for XMPP/CLI tenants (empty → 0-row `UPDATE` → no FK check).
- **Phase 1 (recommended):** detect a non-empty `api_tokens`/`user_identities` under the old
  scope and **warn loudly + skip** those two tables, documenting that web-gateway tokens/
  identities are not migrated. (Loud, not a silent mid-batch abort.)
- **Phase 2 (optional):** full rekey — in one transaction `INSERT` a `users` row
  `id=<tenant>` (clone old, remap the `created_by` self-ref `ON CONFLICT DO NOTHING`),
  `UPDATE` the children, then `DELETE` the old `users` row (a plain `UPDATE users SET id`
  is blocked by the non-deferrable children).

---

## 5. Import decision logic

| Detected scope(s) in restored DB | Action |
|----------------------------------|--------|
| **0 scopes** (empty / fresh source) | No-op (fresh OMEMO/workspace/DB is correct). Do **not** error. |
| exactly **`<tenant>`** | **No-op (guarded).** Already correctly scoped — never rekey (self-wipe). |
| exactly **`default`** | `migrate-owner-scope <tenant> --from default` (same end state as the old gate, run earlier so the stage path is correct too). |
| exactly **one other** value `S` | Validate charset, then `migrate-owner-scope <tenant> --from S`. Covers non-`default` sources **and `--name` renames** (`S` = source name, `<tenant>` = new name). |
| **more than one** scope | **Fail closed:** stage without `--start`, print the exact `migrate-owner-scope <tenant> --from <scope>` remediation; or accept an explicit `import --owner-scope <S>`. Never auto-pick. |

After any rekey, **verify zero residual old-scope rows across all 13 tables** before allowing
start (reuse `migrate_owner_scope`'s offender report; treat non-empty as a hard stop).

---

## 6. Guardrails (non-negotiable)

1. **Same-name no-op** — never call `migrate_owner_scope` with `old_scope == name`
   (self-join dedup `DELETE`s would wipe the table). **Done** (`1a095c21`).
2. **Multi-scope → refuse**, don't guess. Blocking for an automatic flow.
3. **Charset-validate** the scope before SQL interpolation (§4.2). Blocking before any
   detected/`--from` value is trusted.
4. **`users`-FK conditional** — only act when `api_tokens`/`user_identities` are non-empty;
   loud-skip (phase 1) or full users rekey (phase 2). Never silently FK-abort mid-batch.

---

## 7. Edge cases (required behaviour)

- **Same-name MT→MT** (source scope == target name): no-op (guard #1). Previously worked only
  by luck; now explicit.
- **`--name` rename** of a `default` source: `default → <new>` — same as today's gate,
  generalized to the stage path.
- **`--name` rename** of a name-scoped source: `<old> → <new>` — the core gap; silent-empty
  without the fix.
- **Mixed/dirty multi-scope** (Kageho-style `default` + tenant duplicates): fail closed /
  explicit `--owner-scope`; never silently orphan a scope.
- **Empty source**: no-op, not an error.
- **Pre-1.1.7 bundle** (no `meta` hint): import-side detection still works (independent of meta).
- **Pre-rename `ironclaw` source**: target queries always use db/role `lunarwing`; unaffected.
- **Scope with SQL/shell metacharacters**: rejected by charset validation with a manual
  remediation message.
- **`--force` re-import / half-applied rekey**: detection re-derives from the freshly-restored
  DB each run, so re-running is idempotent; rekey must complete before the daemon starts.

---

## 8. Backward compatibility

- **Old bundles** (no `source_owner_scopes` in `meta.txt`) get the **same protection** via
  import-side detection — the meta hint is purely advisory.
- The **`default` happy path is unchanged in outcome** — the explicit `--from default` produces
  the same end state the `start-tenant` gate would, just earlier and verified.
- The fleet-wide `start-tenant` / `build-tenant` / `patch-env` gates are **left untouched** and
  remain a backstop for the `default` case.

---

## 9. Testing & validation plan

**Static:** `bash -n`, `shellcheck` (no new warning classes beyond the file's existing
intentional `SC2086` on `$psql_cmd`), `ic/scripts/pre-commit-safety.sh`.

**Rehearsal (per GOALS_1.1.7 #13 — use Starforce / a throwaway tenant):** run the full
export → transfer → import for each matrix row and confirm the agent sees its data + secrets
decrypt + OMEMO works:
1. `default` source, same name — baseline.
2. `--name` rename of a `default` source.
3. Non-`default` (name-scoped) source, same name and renamed.
4. **Multi-scope** source (seed `default` + `<name>` duplicate rows) — expect fail-closed.
5. Empty source — expect no-op, clean start.
6. **`users`-FK** — seed `users` + `api_tokens`/`user_identities`, confirm phase-1 loud-skip
   (or phase-2 full rekey).
7. **`--force` re-import** — confirm idempotent.

Post-each: `SELECT user_id, count(*)` shows rows under `<tenant>`, **zero residual old-scope**
across all 13 tables; a stored secret decrypts (`SECRETS_MASTER_KEY`); OMEMO 1:1 + group decrypt.

---

## 10. Phasing

- **Phase 0 — DONE** (`91283004`, `1a095c21`, `d00accf4`, `fbd505d1`): collision-hardening,
  self-wipe guard, docs.
- **Phase 1 — core feature:** `detect-owner-scopes` helper (§4.1) + charset guard (§4.2) +
  `import-tenant.sh` rekey step & decision table (§4.3, §5) + `users`-FK loud-skip (§4.5
  phase 1). This closes the silent-empty gap.
- **Phase 2 — optional:** export `source_owner_scopes` hint (§4.4); full `users`-table rekey
  (§4.5 phase 2).

---

## 11. Risk & rollout

Low blast radius: changes are confined to `import-tenant.sh` (migration-only orchestration), a
**read-only** new `mt-admin` subcommand, and additive guards in `migrate_owner_scope`. The
protected `start-tenant` path is unchanged. Until Phase 1 lands, the **documented manual flow**
(measure scope → `migrate-owner-scope --from` → verify) is the supported path; the self-wipe
guard already removes the sharpest edge of that manual path. Rehearse on Starforce before
relying on the automated flow (the live kawarimi validation predates the owner-scope migration).

---

## 12. Open questions

1. **Multi-scope policy:** hard-refuse and require a re-run with `--owner-scope <S>`, or prompt
   interactively? (Lean: refuse + actionable message; `--owner-scope` for unattended.)
2. **`users`-table:** is Phase-1 loud-skip acceptable for the foreseeable tenants (web-gateway
   users unused on XMPP/CLI tenants), deferring the full users rekey to Phase 2?
3. **Detection table set:** are `settings`/`conversations`/`memory_documents`/`secrets`/
   `agent_jobs` a sufficient sample, or should detection union all 13 owner-scoped tables for
   completeness on unusual sources?
