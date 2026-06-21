# MT Legacy Upgrade — Cherry-Pick & Fix Plan (v1.0.3 → v1.1.2, in-place)

**Status:** DRAFT — awaiting go-ahead before any code mutation.
**Date:** 2026-06-21
**Working branch:** `1.1.6-meta-v2` (changes land here; a copy is then placed on the target machine).
**Source of work under review:** `origin/1.1.6-upgrade-harness-v2` (3 commits on top of `70c48059`).
**Review provenance:** read-only adversarial review, task `wyto6b6c7` (47 agents; 0 critical / 0 high / 3 medium / 11 low after verification).

---

## 1. Goal & locked decisions

Upgrade a **production tenant on a separate machine, in place, to v1.1.2.**

**Confirmed source state (2026-06-21).** The tenant's checkout is commit `e48734cb9a1c158ee19e13dd01c48f52ffa8d85e` (2026-05-10), which `git describe --tags` reports as **`v1.0.4-7-ge48734cb`** (the `ic/Cargo.toml` `version` field reads `1.0.3`, but `detect_source_version` keys off `git describe`, normalizing to **`1.0.4`** → classified **legacy**, correct). The code at that commit ships migrations **V1–V18** (`V18__routine_retry.sql` is the head); **V19/V20/V21 are absent.** Therefore, if the DB is fully migrated, it sits at **`maxv = 18`** — to be confirmed live with `SELECT max(version) FROM refinery_schema_history;`. Upgrading to v1.1.2 will apply **V19 (reflex_patterns), V20 (reflex_embeddings), and the destructive V21 (null-`agent_id` dedup)** — so **MF-1 below is mandatory for this exact tenant, not hypothetical.**

**Tenant identity & runtime (confirmed 2026-06-21):** tenant **`ruffles`**, Docker container **`lunarwing-pg-ruffles`**, DB role `lunarwing`, running **PostgreSQL 16.13** (Debian). **GATE 1 (PG ≥ 15) clears — no Postgres-major upgrade needed; the §6 hard blocker is resolved.**

Decisions locked with the owner (2026-06-21):

- **In-place upgrade**, not relocate-first. The tenant stays on its current host; we copy the fixed repo/branch onto that machine and run the same-host upgrader there. The host-migration (export/import) tooling is **not** used for this job.
- We **cherry-pick the relevant files into `1.1.6-meta-v2`** here, fix the must-fix findings, validate on the MT test-VM, *then* copy the branch to the target machine.
- An informal **operator runbook** accompanies this plan (kept out of the repo).

This plan is the persisted approval artifact per the standing "proposal-doc-before-executing-plans" rule. **No code is cherry-picked or edited, and no service is touched, until this is approved.**

---

## 2. Review verdict (one paragraph)

The reworked `ic/scripts/upgrade-tenant-version.sh` is **safe-by-default** (read-only dry-run default, a mandatory PGDMP-verified backup, recoverable `pg_restore`) and the **modern path (≥ v1.0.9) is a clean byte-equivalent refactor** of the shipped, already-live-validated v1.1.5 tool — that half is trustworthy. The **new legacy path is promising but not yet sound to run unsupervised**, with one data-safety gap that lands squarely in the v1.0.3 scenario, a rehearsal that never exercises the destructive path, and inline-backup hardening regressions. Maturity: **promising-needs-fixes.**

---

## 3. Must-fix changes (before any real run)

All line numbers are in `ic/scripts/upgrade-tenant-version.sh` as it exists on `origin/1.1.6-upgrade-harness-v2`; they will shift once cherry-picked.

| # | Finding | Location | Fix |
|---|---------|----------|-----|
| **MF-1 (the important one — confirmed live for this tenant)** | Legacy `maxv<19` branch skips the V21 dup precheck on a **false premise**; `maxv 19–20` branch only *warns*. This tenant **is at maxv=18** (commit `e48734cb`), so V21's destructive `DELETE` of duplicate NULL-`agent_id` `memory_documents` (cascades to `memory_chunks`/`document_versions`) runs on first boot with **no confirm** — while the modern path *confirms*. | `gates_legacy()` L420–422, L423–434 (false comment L433); contrast modern `gates_modern()` L358–368 | For **any** `maxv < 21` on the legacy path, run the **same** dup-group query + **`confirm`** the modern path uses (L363–368). `memory_documents` exists since `V1__initial.sql:167` (verified), so the table-existence dance is unnecessary; delete the "V19 creates it / may not exist yet" comments (L422, L433). |
| **MF-2** | Legacy path omits the `unique_path_per_user` **constraint-presence guard** the modern path enforces. V21's `DROP CONSTRAINT` has no `IF EXISTS` (`V21:28`), so a hand-dropped constraint aborts V21 → daemon won't boot, no auto-rollback. | `gates_legacy()` (none) vs `gates_modern()` L360–361 | Share the modern constraint-presence check for `maxv < 21` (constraint is created in `V1__initial.sql:180`, normally present). Belt-and-suspenders: not in scope to edit the migration. |
| **MF-3** | Legacy `--target` > v1.1.3 cap only fires inside the `X.Y.Z` regex; a **branch/sha target** (e.g. `--target staging`) bypasses it and checks out a moving ref → post-v1.1.4 rootless code onto a rootful tenant. | legacy target cap L182–191 | Reject any legacy `--target` that is not a literal `vX.Y.Z` tag. |
| **MF-4** | Inline backup reimplements `pg_dump` on a **false rationale** ("pre-v1.1.4 mt-admin lacks backup-tenant" — but `$MT` is the current-repo mt-admin that *has* it), drops `mt backup-tenant`'s hardening (umask/chmod/prune), leaves a never-deleted `/tmp/lunarwing-upgrade.dump` **inside the container** (encrypted-secret rows), and `chown`s the host dump to the tenant. | `backup_tenant_inline()` L101–113, chown L457 | Prefer reusing `"$MT" backup-tenant` + `list-backups` exactly like `apply_modern()`. If inline must stay: `umask 077`, `chmod 0700` dir / `0600` dump, **do not** `chown` the dump to the tenant, and `rm` the in-container `/tmp` dump. |
| **MF-5** | **No auto-rollback.** `restore_from_backup()` is defined (L115) but **never called**; no `trap`. A mid-apply failure under `set -e` leaves the tenant **down / half-applied**, and the rollback heredoc only prints *after* success. | `restore_from_backup()` L115; `print_rollback_legacy()` L464 | Add a `trap` that prints the rollback block + `NEWEST_DUMP`/`cur_rev` on failure. **Decision needed:** wire `restore_from_backup()` behind an explicit flag for true auto-rollback, or delete it to remove the false "automation exists" signal. Recommendation: keep print-only + trap for the first real run (operator drives restore), revisit auto-rollback after VM validation. |
| **MF-6** | Rehearsal harness **proves nothing** about the destructive path: it builds HEAD and never boots a v1.0.3 binary, so `add-tenant` starts an empty PG, no migrations, and it dies at the empty-DB `maxv` gate before `apply`. The verify FAIL branch is dead under `set -e`. | `rehearse-legacy-upgrade.sh` `up` ~L96–106; rc check ~L130–136 | Rework to **boot a real v1.0.3 daemon** to `maxv=18` with populated `memory_documents`, seed duplicate NULL-`agent_id` rows, then assert: the fixed `maxv<19` branch detects/reports/**confirms**, and after V21 the loser rows are gone, cascades cleaned, kept rows + conversation/memory counts intact. Fix the rc capture: `rc=0; cmd || rc=$?`. |

**Nice-to-have (low, fold in opportunistically):** `unsupported` (<v1.0.3, `--force`) currently dispatches to the **modern** path (L482/L494) — make dispatch an explicit `legacy|modern|unsupported` case; drop the dead `render-units` `2>/dev/null` fallback (`$MT` has the verb); `detect_source_version` should fetch tags / fall back to modern-proceed rather than hard-die when `git describe` doesn't normalize; restore the kageho operator banners lost in modern steps 6/7 (MOD-4).

---

## 4. Cherry-pick manifest

| Item | Action | Notes |
|------|--------|-------|
| `ic/scripts/upgrade-tenant-version.sh` (whole reworked file) | **take, then fix** | The modern half is byte-equivalent and trustworthy; we take the file and apply MF-1…MF-5 to the legacy half. |
| `ic/scripts/rehearse-legacy-upgrade.sh` | **rework** | Per MF-6 — only useful once it boots a real pre-V19 fixture. |
| `docs/ops/MT-LEGACY-UPGRADE-NOTES.md` | **take after fix** | Fix the maxv<19 premise, the rollback-table row (both paths print inline `pg_restore`, not `mt restore-tenant`), the inline-backup rationale. |
| `docs/proposals/MT-LEGACY-UPGRADE-QA-PLAN.md` | **take after fix** | Fix the `ports.json` path (`/etc/lunarwing/ports.json`, not `/var/lib/lunarwing/tenants/<t>/`). |
| `docs/proposals/MT-LEGACY-UPGRADE-VERIFICATION.md` | **take after fix** | Reconcile its "complete" framing with the branch's own `VERDICT.txt` REJECT and the live-validation-pending reality (mirror of the v1.1.5 contradiction pattern). |
| `docs/README.md` (+3 index lines) | **take** | Trivial index entries. |
| `.sisyphus/**` (boulder.json, evidence, notepads, plan) | **leave** | Process artifacts. `edge-cases.txt` blesses the false-premise `maxv<19` case as PASS — importing it would carry a misleading "validated" signal. Keep on the source branch for provenance. |

---

## 5. Validation plan (MT test-VM: Arch Linux, systemd, Docker)

The test-VM is a multi-tenant systemd host with one live agent on v1.1.4 (idle). Validation must use a **genuine pre-V19 fixture**, because the rehearsal harness does not produce one.

1. **Build the fixture:** build **and boot** a v1.0.3 binary for a throwaway tenant so refinery lands at **maxv=18** with `memory_documents` populated. Confirm `max(version)=18`.
2. **Seed the hazard:** insert duplicate NULL-`agent_id` `memory_documents` rows for the same `(user_id, path)`.
3. **Run the fixed legacy upgrade** (`--target v1.1.2`): confirm the fixed `maxv<19` branch **reports the dup groups and prompts**, and that after V21 the loser rows are gone, cascades (`memory_chunks`/`document_versions`) are clean, and kept rows + `conversations`/`conversation_messages` counts are intact.
4. **Restore drill:** actually `pg_restore --clean --if-exists` the legacy dump into a scratch DB to prove recovery works (never done on the branch).
5. **systemd/adapter:** confirm `render-units` produces the renamed `lunarwing-weechat-<t>` + adapter units, the stale `weechat-<t>.service` is removed, and `kick_weechat_adapter` reaches `ws_connected=true` (the 401 relay race).
6. **Failure-injection rollback:** break a step after `stop-tenant`; confirm the trap (MF-5) prints the rollback block and the printed steps recover the tenant.
7. **Dry-run classification:** on the fixture's real source ref **without `--apply`**, confirm `detect_source_version` classifies "legacy v1.0.x" (not misrouted) and the banner/cap/gates behave.

A run is "validated" only when 1–7 pass on the fixture. The branch's "GO / 10-PASS" QA does **not** count.

---

## 6. Real-tenant prerequisites & open questions

These gate the day-of runbook; answer before scheduling the real upgrade.

1. **PostgreSQL major version — RESOLVED.** Tenant `ruffles` runs **PostgreSQL 16.13** (`docker exec lunarwing-pg-ruffles postgres --version`), well above the GATE 1 floor of 15 (V21 uses `UNIQUE NULLS NOT DISTINCT`). **No PG-major upgrade is required.** (This was the biggest risk; it's gone. Re-verify just before the run with `docker exec lunarwing-pg-ruffles cat /var/lib/postgresql/data/PG_VERSION`.)
2. **Tenant layout.** The tool assumes the mt-admin layout: `/home/<t>/lunarwing` git checkout, `lunarwing-pg-<t>` container, `/etc/lunarwing/ports.json`, `lunarwing-mt-admin.sh` present. A v1.0.3 tenant predates much of this — confirm the on-disk reality matches, or adapt.
3. **Container runtime — CONFIRMED rootful Docker.** The host (`cmc-onexplayerx1pro-tab`) runs **rootful Docker, not rootless Podman**. GATE 0 passes; the tool pins `LUNARWING_MT_ROOTLESS=false` to keep it that way. **This is exactly the environment `upgrade-tenant-version.sh` targets** — and it means the v1.1.4 rootful→rootless flip, the data-orphan guard, and `LUNARWING_MT_ACK_ROOTLESS_FLIP` (all `upgrade-tenant.sh` concerns) **do NOT apply here.**
4. **Init system.** The adapter steps use `systemctl --user` (systemd). Confirm the target's init system matches.
5. **Target finality.** Is **v1.1.2** the end state, or a stepping stone? The legacy cap is v1.1.3; the rootful→rootless flip to v1.1.4 is a *different* tool (`upgrade-tenant.sh`).
6. **Shared multitenant host — cross-tenant safety.** ruffles lives on a **multitenant rootful-Docker host alongside other tenants on lower versions (≤ v1.1.2)**, and we run the **1.1.6-branch-bundled `mt-admin`** (`$MT`) against it. Cautions:
   - **Health pipeline:** the rehearsal's `add-tenant` MUST use `--no-health` (it does) so it doesn't arm the host-global ~15-min self-heal remediation timer and start acting on the OTHER tenants. The ruffles upgrade itself does not call `add-tenant`, so it won't arm it either.
   - **ports.json schema skew:** the host's existing tenants were provisioned by an older mt-admin. **Back up `/etc/lunarwing/ports.json` before the rehearsal** and confirm the 1.1.6 mt-admin reads/writes it compatibly (the rehearsal's `add-tenant`/`remove-tenant --purge` round-trip must leave the registry consistent for the other tenants).
   - **Resource contention:** cargo builds compete with the live tenants for CPU/RAM — cap `-j` and pick a quiet window.
   - **Scope:** ruffles' `stop/build/render/start` is per-tenant; double-check the rehearsal's `--cleanup --purge` only removes the throwaway rehearsal tenant (its name guard + ports.json refuse-if-exists protect this).
   - **WHERE to rehearse (decision needed):** the separate Arch/systemd test-VM (safest — but it must also be **rootful Docker** to be faithful) vs this production host (most faithful, but risks the other live tenants). Recommend the test-VM if its runtime matches.

---

## 7. Execution sequence (phased, with pause points)

- **Phase A — Cherry-pick (here, on `1.1.6-meta-v2`).** Bring in the manifest (§4), apply MF-1…MF-6. Commit. `shellcheck` clean. **Pause** for owner review of the diff.
- **Phase B — VM validation.** Run §5 1–7 on the Arch/systemd test-VM. Capture evidence. **Pause** — do not proceed to a real tenant unless all pass.
- **Phase C — Real-tenant prerequisites.** Resolve §6 (esp. the PG-version path). **Pause** for go/no-go.
- **Phase D — Production upgrade.** Copy the validated branch to the target machine; run the runbook (full backup → dry-run → apply → verify). Owner-supervised. The old state (backup + rollback steps) is the recovery.

Each phase boundary is an explicit stop for go-ahead. No service mutation on any real tenant before Phase D, and not before Phase B/C pass.

---

## 8. Safety posture

- Default is a **read-only dry-run**; nothing changes without `--apply`.
- A **PGDMP-verified backup** is taken before any mutation (hardened per MF-4).
- Rollback is **operator-driven `pg_restore`** for the first real run, surfaced on failure via the trap (MF-5).
- The destructive V21 dedup is **confirm-gated on the legacy path** after MF-1.
- "Never recreate `$PG_CONTAINER`" — data lives in the writable layer (no named volume pre-1.1.4).

---

## 9. Out of scope

- Host relocation / export-import (owner chose in-place).
- The rootful→rootless flip and any v1.1.4+ target (different tool: `upgrade-tenant.sh`).
- Editing the migrations themselves (e.g. adding `IF EXISTS` to V21) — handled by gates, not schema changes.
- The other three agents' branches (coordination deferred).
