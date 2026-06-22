# Legacy Upgrade Harness: Live-Validation Plan (v1.0.3-era → v1.1.x)

**Status:** Reviewed + hardened — **not yet live-validated**
**Date:** 2026-06-21
**Source range:** v1.0.3–v1.0.8
**Target:** any literal vX.Y.Z tag, capped at v1.1.3 (no lower bound enforced; v1.1.2 recommended)
**Audience:** operator performing pre-production validation of the legacy same-host upgrade path

---

## 1. Executive Summary

The legacy same-host upgrade harness extends `ic/scripts/upgrade-tenant-version.sh` so it can
upgrade a multi-tenant Docker rootful tenant from any v1.0.3–v1.0.8 source to a v1.1.2 or v1.1.3
target. The gate logic, backup, and apply steps are now **shared** with the modern path — a single
`backup_tenant()`, `gate_migration_state()`, and `apply_core_steps()` serve both. The legacy branch
adds only: a mandatory explicit `--target` (literal `vX.Y.Z` tag, capped at v1.1.3), a
legacy-warning gate (GATE 8), and its own rollback printout. Backup runs `mt-admin backup-tenant`
(the repo-checkout `mt-admin` has that verb), and the shared `apply_core_steps()` includes a
`render-units` fallback that sources the modern `lunarwing-mt-admin.sh` if the in-checkout
`mt-admin` lacks the verb.

**Implementation is reviewed and hardened**: all planned deliverables exist, shellcheck/`bash -n`
are clean, and the modern path is structurally unchanged. The legacy path has **not** been
live-validated — neither against a real v1.0.3-era production tenant nor end-to-end via the
rehearsal. The rehearsal fixture (`ic/scripts/rehearse-legacy-upgrade.sh`) was rewritten to build a
*genuine* pre-reflex (maxv<19) tenant — `add-tenant --no-health`, then check out the legacy source,
build, and start it so refinery stops at the legacy head — seed a duplicate NULL-`agent_id`
`memory_documents` group, run the legacy upgrade, and assert the V21 dedup actually ran (maxv >= 21,
the seeded duplicate group collapsed, row count N -> N-1). That rehearsal has not yet been executed
end-to-end; the chief open risk is whether old (v1.0.x) code still **builds** on the current
toolchain. The actual `v1.0.3-era → v1.1.x` transition should be treated as a **canary-first**
operation.

This document captures the complete live-validation checklist that must be performed on a real
multi-tenant system before the v1.0.3-era upgrade path can be considered production-ready.

**Verification status as of 2026-06-21:**

| Wave | Status | Notes |
|------|--------|-------|
| F1 — Plan Compliance Audit | APPROVE | All Must Haves present, all Must NOT Haves absent |
| F2 — Code Quality Review | APPROVE | shellcheck clean, bash -n clean, modern path identical |
| F3 — Real Manual QA | PARTIAL | Rehearsal rewritten to build a genuine pre-reflex fixture and assert the V21 dedup; not yet run end-to-end. Live tenant QA not performed |
| F4 — Scope Fidelity Check | PARTIAL | Implementation matches plan; the only flagged nit was a waived ROADMAP edit (Task 10, cancelled by request) |

The branch's `VERDICT.txt` recorded a REJECT, but that REJECT was the waived ROADMAP-edit nit
(Task 10 was cancelled by request), not a substantive defect. The honest status is
**reviewed + hardened, not live-validated**. Two genuine open items remain before this path can be
trusted on a real tenant: (1) confirm that old v1.0.x code still builds on the current toolchain,
and (2) run the reworked rehearsal end-to-end on the Arch/systemd MT test VM.

---

## 2. Implementation Summary

### Files delivered

| File | Lines | Purpose |
|------|-------|---------|
| `ic/scripts/upgrade-tenant-version.sh` | ~489 | Extended with `detect_source_version()`, `gates_legacy()`, `apply_legacy()`, and shared helpers (`backup_tenant()`, `gate_migration_state()`, `apply_core_steps()`, `on_apply_exit` failure trap); modern path extracted into `gates_modern()`/`apply_modern()` with zero logic change |
| `ic/scripts/rehearse-legacy-upgrade.sh` | ~170 | Genuine pre-reflex (maxv<19) fixture builder + V21 dedup assertion (`up` / `verify` / `--cleanup` / `--dry-run`) |
| `docs/ops/MT-LEGACY-UPGRADE-NOTES.md` | ~325 | Operator-facing runbook for the legacy path |

### Key design decisions

- **Single script extension** (not a separate script) — `upgrade-tenant-version.sh` detects source
  version via `git describe --tags` and branches into `modern` or `legacy` code paths.
- **Source classification**: `modern` >= v1.0.9, `legacy` v1.0.3–v1.0.8, `unsupported` < v1.0.3.
- **Legacy sources require explicit `--target`** — no silent default; the target must be a literal
  `vX.Y.Z` release tag (branch / SHA / suffixed refs are rejected — a moving ref could pull
  post-v1.1.4 rootless code onto a rootful tenant) and is capped at v1.1.3 (beyond that is
  `upgrade-tenant.sh` rootless-flip territory).
- **Shared backup via `mt-admin backup-tenant`** — the repo-checkout `mt-admin` provides
  `backup-tenant`, which writes a root-owned `-Fc` dump under `$LUNARWING_MT_BACKUP_DIR/<tenant>/`
  (default `/var/lib/lunarwing-backups/<tenant>/`), validated for the PGDMP magic and a sane size.
  Only the `env`/`ports`/`caps` `.bak` copies live under `$HOME_DIR/backups/<target>-upgrade-<stamp>/`
  (chmod 700, chowned to the tenant). The same `backup_tenant()` helper serves both paths.
- **`render-units` fallback** — tries `mt-admin render-units` first, falls back to sourcing the
  modern `lunarwing-mt-admin.sh` from the current repo checkout.
- **GATE 8** — explicit legacy-warning gate that requires confirmation (`--yes` or interactive).
- **Rollback** is operator-driven and print-only — both the legacy and modern paths print inline
  `pg_restore` instructions; neither calls `mt restore-tenant`, and there is no automatic restore.
  After the backup is taken, an `on_apply_exit` failure trap also prints recovery steps (backup
  dump path + pre-upgrade rev) if an `--apply` run aborts mid-flight.

---

## 3. Scope and Constraints

- **PostgreSQL only.** libSQL tenants are not supported by `upgrade-tenant-version.sh` at all.
- **Docker rootful only.** Podman containers are rejected for legacy sources. This path does not
  perform a rootless flip; that is `upgrade-tenant.sh`'s domain.
- **Source range**: v1.0.3–v1.0.8. Sources older than v1.0.3 require `--force`.
- **Target**: any literal vX.Y.Z release tag (branch/SHA/suffixed refs rejected), capped at
  v1.1.3 — no lower bound enforced (v1.1.2 recommended). A target > v1.1.3 is rejected with a
  pointer to `ic/scripts/upgrade-tenant.sh`.
- **No schema/data migration logic in the harness** — refinery handles all migrations automatically
  on daemon start.
- **No rootless Podman flip** — the tenant stays on Docker rootful throughout.

---

## 4. Live Validation Checklist

> **IMPORTANT:** This checklist has NOT been executed. Mark items `[ ]` → `[x]` only after
> performing them on a real multi-tenant host with a genuine v1.0.3-era tenant (or the rehearsal
> fixture as a minimum viable substitute where noted). Capture evidence in a shared location
> (screenshots, command output logs, journal excerpts) before claiming any item complete.

### 4.1 Pre-flight: tenant discovery and dry-run

- [ ] **4.1.1** — Identify or create a real v1.0.3-era tenant on a multi-tenant host
  - Command: `sudo ic/scripts/lunarwing-mt-admin.sh list-tenants` and verify one tenant's
    `/home/<tenant>/lunarwing` clone is at a tag between v1.0.3 and v1.0.8 inclusive.
    Alternatively: `sudo ic/scripts/rehearse-legacy-upgrade.sh up` to create a synthetic tenant.
  - **Success**: a tenant exists with source version in the legacy range.
  - **Risk if fails**: no tenant to validate against — must create a rehearsal or locate one.

- [ ] **4.1.2** — Run dry-run gates for the legacy source with `--target v1.1.3`
  - Command: `sudo ic/scripts/upgrade-tenant-version.sh <tenant> --target v1.1.3`
  - **Success**: all gates (0–8) pass; GATE 2/3/4 reports V19/V20/V21 status; GATE 8 displays
    the legacy-warning and requires confirmation.
  - **Risk if fails**: script is misconfigured or the tenant environment doesn't match expectations
    (wrong PG version, unclean working tree, missing Docker runtime).

- [ ] **4.1.3** — Verify dry-run refuses `--target` > v1.1.3 on legacy source
  - Command: `sudo ic/scripts/upgrade-tenant-version.sh <tenant> --target v1.1.4`
  - **Success**: script dies with "use upgrade-tenant.sh" (exit ≠ 0).
  - **Risk if fails**: target cap is not enforced; operator could bypass into unsupported territory.

- [ ] **4.1.4** — Verify dry-run refuses legacy source without explicit `--target`
  - Command: `sudo ic/scripts/upgrade-tenant-version.sh <tenant>` (with legacy source detected)
  - **Success**: script dies with "requires an explicit --target" (exit ≠ 0).
  - **Risk if fails**: legacy path silently defaults to v1.1.2, landing operator on unintended target.

- [ ] **4.1.5** — Run shellcheck on both scripts on the target host
  - Command: `shellcheck ic/scripts/upgrade-tenant-version.sh ic/scripts/rehearse-legacy-upgrade.sh`
  - **Success**: exit 0, no warnings.
  - **Risk if fails**: shellcheck version difference on target host uncovers warnings not seen in
    the development environment.

### 4.2 Apply phase: execute the legacy upgrade

- [ ] **4.2.1** — Run `--apply` on the legacy tenant
  - Command: `sudo ic/scripts/upgrade-tenant-version.sh <tenant> --target v1.1.3 --apply --yes`
  - **Success**: all 10 apply steps complete in order.
  - **Risk if fails**: any step failure (backup, checkout, build, render-units, start) blocks the
    tenant and requires rollback.

- [ ] **4.2.2** — Capture all 10 apply steps in order in a log file
  - Steps expected: 1/10 backup → 2/10 stop → 3/10 checkout → 4/10 build → 5/10 install-wasm →
    6/10 render-units → 7/10 patch-env → 8/10 start → 9/10 stale unit cleanup → 10/10 weechat adapter.
  - **Success**: all 10 step banners appear in output; no step is skipped.
  - **Risk if fails**: gap in step sequence indicates a logic path bug in the legacy apply function.

### 4.3 Post-upgrade verification

- [ ] **4.3.1** — Verify `refinery_schema_history` shows V19, V20, V21 applied
  - Command: `sudo docker exec lunarwing-pg-<tenant> psql -U lunarwing -d lunarwing -c "SELECT version, name FROM refinery_schema_history ORDER BY version DESC LIMIT 5;"`
  - **Success**: max version >= 21; V19, V20, V21 rows all present.
  - **Risk if fails**: refinery did not run migrations on daemon start — the daemon may be running
    against a pre-V19 schema.

- [ ] **4.3.2** — Verify `unique_path_per_user` constraint exists on `memory_documents`
  - Command: `sudo docker exec lunarwing-pg-<tenant> psql -U lunarwing -d lunarwing -c "SELECT conname FROM pg_constraint WHERE conname = 'unique_path_per_user';"`
  - **Success**: one row returned for `unique_path_per_user`.
  - **Risk if fails**: V21 migration did not apply — duplicate memory groups may exist.

- [ ] **4.3.3** — Verify no duplicate `memory_documents` groups remain
  - Command: `sudo docker exec lunarwing-pg-<tenant> psql -U lunarwing -d lunarwing -c "SELECT user_id, COALESCE(agent_id::text,''), path, COUNT(*) FROM memory_documents GROUP BY user_id, COALESCE(agent_id::text,''), path HAVING COUNT(*) > 1;"` (matches GATE 2/3/4's dup-group key)
  - **Success**: zero rows returned.
  - **Risk if fails**: duplicate entries exist that V21's dedup should have eliminated; check
    refinery logs for errors during migration.

- [ ] **4.3.4** — Verify tenant daemon starts and responds to health checks
  - Command: `sudo ic/scripts/lunarwing-mt-admin.sh status <tenant>`
  - **Success**: daemon process running; `lunarwing-mt-admin.sh status` reports healthy.
  - **Risk if fails**: daemon startup failure; check `journalctl --user -u lunarwing-<tenant>` or
    `/var/log/lunarwing/<tenant>/` for startup errors.

- [ ] **4.3.5** — Verify WeeChat adapter `ws_connected=true` after upgrade (if tenant uses WeeChat)
  - Command: `curl -s http://127.0.0.1:<tenant-weechat-port>/api/health | jq '.ws_connected'`
  - **Success**: returns `true`.
  - **Risk if fails**: WeeChat adapter did not reconnect after the upgrade kick; restart adapter
    and re-check.

- [ ] **4.3.6** — Verify env secrets still decrypt
  - Command: `sudo docker exec lunarwing-pg-<tenant> psql -U lunarwing -d lunarwing -c "SELECT key FROM encrypted_secrets LIMIT 3;"` (confirm the table is queryable) and check daemon logs for any
    secret-decryption errors on startup.
  - **Success**: no `Failed to decrypt secret` or `SECRETS_MASTER_KEY` warnings in daemon stderr.
  - **Risk if fails**: encrypted secrets are unreadable — likely a key-rotation or env-file issue
    introduced during the `patch-env` step.

- [ ] **4.3.7** — Verify `ports.json` unchanged or sensibly updated
  - Command: `diff /home/<tenant>/lunarwing/backups/<target>-upgrade-<stamp>/ports.json.bak /etc/lunarwing/ports.json` — the canonical ports registry is the shared /etc/lunarwing/ports.json (override LUNARWING_PORTS_REGISTRY), not a per-tenant file.
  - **Success**: no diff, or only the reserved-block addition from v5→v6 migration (additive, safe).
  - **Risk if fails**: port assignments shifted — could cause port conflicts with other tenants.

- [ ] **4.3.8** — Verify XMPP/OMEMO continuity (if tenant uses XMPP)
  - Command: Send a test message to the tenant via XMPP and verify it responds.
  - **Success**: message sent and response received within a reasonable timeout.
  - **Risk if fails**: OMEMO session state may have been lost; check xmpp-bridge logs.

- [ ] **4.3.9** — Verify encrypted-secret read/write cycle works
  - Command: Have the agent store a secret via the `secrets-set` built-in tool (or equivalent) and
    then read it back. To test non-interactively: insert a known encrypted-secret row and confirm
    the daemon can decrypt it on next secret lookup.
  - **Success**: secret is stored and retrieved correctly.
  - **Risk if fails**: encryption/decryption path is broken — may indicate a master-key or
    encryption-scheme mismatch introduced during upgrade.

### 4.4 Rollback validation

- [ ] **4.4.1** — Stop the upgraded tenant
  - Command: `sudo ic/scripts/lunarwing-mt-admin.sh stop-tenant <tenant>`
  - **Success**: daemon and associated services stop cleanly.
  - **Risk if fails**: daemon won't stop; may need kill + manual cleanup.

- [ ] **4.4.2** — Restore the DB from the `backup-tenant` dump
  - Command: `sudo docker exec -i lunarwing-pg-<tenant> pg_restore -U lunarwing -d lunarwing --clean --if-exists < /var/lib/lunarwing-backups/<tenant>/<stamp>.dump`
    (the dump lives under `$LUNARWING_MT_BACKUP_DIR/<tenant>/`, default `/var/lib/lunarwing-backups/<tenant>/` — the `env`/`ports`/`caps` `.bak` copies are the only thing under `$HOME_DIR/backups/`)
  - **Success**: pg_restore exits 0 with no fatal errors.
  - **Risk if fails**: the backup dump is invalid or pg_restore encounters schema conflicts.
    This is a high-priority failure — the dump is the recovery path for legacy tenants.

- [ ] **4.4.3** — Re-checkout the original source tag
  - Command: `sudo -u <tenant> git -C /home/<tenant>/lunarwing checkout <original-tag>`
  - **Success**: checkout succeeds; `git describe --tags` reports the original version.
  - **Risk if fails**: working tree corruption; may need `git reset --hard`.

- [ ] **4.4.4** — Rebuild and start on the original tag
  - Command: `sudo ic/scripts/lunarwing-mt-admin.sh build-tenant <tenant> --with-wasm && sudo ic/scripts/lunarwing-mt-admin.sh render-units <tenant> && sudo ic/scripts/lunarwing-mt-admin.sh start-tenant <tenant>`
  - **Success**: tenant restarts and reports healthy.
  - **Risk if fails**: the original source can no longer build or run — may need to restore from a
    disk-level snapshot.

- [ ] **4.4.5** — Verify tenant health after rollback
  - Command: `sudo ic/scripts/lunarwing-mt-admin.sh status <tenant>`
  - **Success**: `status` reports healthy; all channels respond if previously functional.
  - **Risk if fails**: rollback did not fully restore tenant state.

### 4.5 Rehearsal fixture lifecycle

- [ ] **4.5.1** — Run full rehearsal lifecycle
  - Commands:
    ```bash
    sudo ic/scripts/rehearse-legacy-upgrade.sh up
    sudo ic/scripts/rehearse-legacy-upgrade.sh verify
    sudo ic/scripts/rehearse-legacy-upgrade.sh --cleanup
    ```
  - **Success**: `up` builds a genuine pre-reflex (maxv<19) fixture and seeds a duplicate group,
    `verify` runs the upgrade and asserts the V21 dedup (maxv >= 21, dup group collapsed, N -> N-1
    rows) and prints GO, `--cleanup` removes all traces.
  - **Risk if fails**: the fixture itself has a bug — check the tenant's `/home/rehearse-legacy/`
    clone and container state for diagnosis.

- [ ] **4.5.2** — Verify no orphan units or containers after `--cleanup`
  - Command: `ls /home/rehearse-legacy 2>&1` (should not exist) and
    `docker ps -a --filter name=rehearse-legacy` (should be empty).
  - **Success**: `/home/rehearse-legacy` does not exist; no Docker containers matching
    `rehearse-legacy`.
  - **Risk if fails**: cleanup is incomplete; manual teardown needed.

### 4.6 Regression: modern path

- [ ] **4.6.1** — Run the modern path on a v1.0.9+ tenant to ensure no regression
  - Command: `sudo ic/scripts/upgrade-tenant-version.sh <modern-tenant> --apply`
  - **Success**: modern path behaves identically to pre-extension version (same gates, same
    apply steps, same rollback section).
  - **Risk if fails**: the refactor or new helper functions changed modern-path behavior despite
    the structural-extraction intent.

---

## 5. Environment Requirements

To perform the live validation, you need a host with:

- **Root access** (`sudo` or direct root).
- **Docker** (rootful) — the legacy path does not support Podman.
- **PostgreSQL >= 15** inside the tenant's Docker container.
- **`jq`**, **`git`**, **`shellcheck`**, **`bash` >= 4.4**, **`find`** (GNU), **`sort`** (GNU).
- **`lunarwing-mt-admin.sh`** at the expected path (`ic/scripts/lunarwing-mt-admin.sh`).
- **`lunarwing-weechat-preflight.sh`** at the expected path (`ic/scripts/lunarwing-weechat-preflight.sh`).
- A **real v1.0.3-era tenant** (or the rehearsal fixture can create one synthetically).
- **Disk space** for: the `mt-admin backup-tenant` `-Fc` dump under `/var/lib/lunarwing-backups/<tenant>/` (≈ size of the tenant DB) + the tenant build artifacts.
- **Network access** to fetch git tags if the target commit isn't already present in the tenant clone.

---

## 6. Rollback Test Checklist

In addition to the per-item checks in §4.4, the following should be confirmed as a holistic
rollback test on a real tenant (or the rehearsal fixture):

| # | Step | Success condition |
|---|------|-------------------|
| R1 | Perform upgrade via legacy path `--apply` | All 10 steps complete |
| R2 | Stop tenant | Daemon stops cleanly |
| R3 | `pg_restore` from the `backup-tenant` dump | pg_restore exits 0 |
| R4 | `git checkout <original-tag>` | Checkout succeeds |
| R5 | Rebuild + render-units + start | Tenant starts and reports healthy |
| R6 | Verify pre-upgrade state | Agent responds, channels functional, secrets decryptable |
| R7 | Optionally repeat upgrade path to confirm idempotency | Second upgrade also succeeds |

**Evidence to capture**: pg_restore stdout/stderr, `status` output after rollback, and at least
one end-to-end agent interaction proving the rollback restored functional state.

---

## 7. Definition of Done for Live Validation

The legacy upgrade path is **production-ready** when ALL of the following are true:

- [ ] All 22 numbered items in §4 are checked (`[x]`) with evidence captured.
- [ ] The rollback test (§6) passed end-to-end on a real tenant (or rehearsal fixture as fallback).
- [ ] At least one real v1.0.3-era tenant has been taken through the full upgrade + soak (minimum
  24 hours of operation on the new version with no regressions).
- [ ] XMPP/OMEMO continuity confirmed (if the tenant uses XMPP) — at least one inbound and one
  outbound encrypted message.
- [ ] Encrypted secrets verified readable and writable after upgrade.
- [ ] No daemon crashes, routine failures, or channel disconnections attributable to the upgrade.
- [ ] Rollback path verified: the tenant can be restored cleanly from the `backup-tenant` dump.
- [ ] Modern path regression test passed on a separate v1.0.9+ tenant.
- [ ] All evidence logged in `.sisyphus/evidence/live-validation/` (or equivalent shared location).

**Blocking criteria**: any failure in §4.2 (apply phase), §4.3 (post-upgrade verification), or
§4.4 (rollback) blocks production readiness. §4.1 (dry-run) and §4.5 (rehearsal) failures are
non-blocking for the rehearsal fixture path but MUST be understood and documented before proceeding
with a real tenant.

---

## 8. Known Limitations / Assumptions

- **Not yet live-validated.** The rehearsal has not been run end-to-end, and the path has never been
  exercised against a real v1.0.3-era production tenant with real OMEMO sessions, encrypted secrets,
  routine schedules, and production load. The chief unknown is whether old (v1.0.x) code still builds
  on the current toolchain — the rehearsal's `build-tenant` step at the legacy source ref will
  surface that.
- **PostgreSQL-only.** libSQL tenants are not supported by `upgrade-tenant-version.sh` or the
  rehearsal fixture.
- **Rootful Docker only.** The legacy path rejects Podman. A separate
  `ic/scripts/upgrade-tenant.sh` handles the rootful→rootless Podman flip for sources >= v1.1.0.
- **Target capped at v1.1.3.** To reach v1.1.4+, upgrade to v1.1.3 via this path, then evaluate
  the rootless-flip path separately.
- **`< v1.0.3` requires `--force`.** The script classifies sources older than v1.0.3 as
  unsupported but allows override.
- **Rehearsal fixture does not prove:** OMEMO continuity, encrypted secret decryption, real-message
  round trips, production load behavior, or routine schedule survival.
- **The `backup-tenant` dump** (root-owned `-Fc`, under `/var/lib/lunarwing-backups/<tenant>/`) is
  the recovery mechanism — the repo-checkout `mt-admin` supplies `backup-tenant`. Restore is
  operator-driven inline `pg_restore`; neither path calls `mt restore-tenant`, and there is no
  automatic restore. Its validity (PGDMP magic + size) is checked at backup time but should still be
  confirmed as part of validation.
- **Refinery runs migrations on daemon start**, not during the script's apply phase. The script
  gates on migration state but does not execute migrations itself.

---

## 9. Next Steps / Sign-off

1. **Run the validation checklist** (this document, §4–§6) on a real v1.0.3-era tenant or the
   rehearsal fixture.
2. **Capture evidence** for every item: logs, screenshots, command output, journal excerpts.
   Save into `.sisyphus/evidence/live-validation/` or an equivalent shared location.
3. **Report results** — if all items pass:
   - Mark this document's status as "Live-validated — production-ready" with the date and operator
     name.
   - Update `docs/ops/ROADMAP_2026.md` to mark the legacy upgrade item as shipped.
   - Update `docs/ops/GOALS_1.1.5.md` if this was tracked as a v1.1.5 goal.
4. **If any item fails:** document the failure in `.sisyphus/notepads/legacy-upgrade-harness/issues.md`,
   fix the root cause in `ic/scripts/upgrade-tenant-version.sh` or
   `ic/scripts/rehearse-legacy-upgrade.sh`, re-run shellcheck, and re-execute the checklist from
   §4.1.
5. **After validation:** the operator who ran the validation signs off below.

| Role | Name | Date | Signature |
|------|------|------|-----------|
| Validator | — | — | — |
| Reviewer | — | — | — |

---

## 10. Implementation Reference

| File | Purpose |
|------|---------|
| `ic/scripts/upgrade-tenant-version.sh` | Main upgrade script (supports source >= v1.0.3, target <= v1.1.3) |
| `ic/scripts/rehearse-legacy-upgrade.sh` | Throwaway v1.0.3-era tenant fixture (`up` / `verify` / `--cleanup`) |
| `docs/ops/MT-LEGACY-UPGRADE-NOTES.md` | Operator-facing runbook for the legacy upgrade path |
| `docs/proposals/MT-1.1.0-TO-1.1.4-UPGRADE.md` | v1.1.0 → v1.1.4 rootless-flip proposal (separate path) |
| `docs/ops/MT-1.1.4-UPGRADE-TOOLING-REVIEW-NOTES.md` | Adversarial review notes for v1.1.4 upgrade tooling |

---

## 11. Plan Summary Reference

For the full implementation plan, see `.sisyphus/plans/legacy-upgrade-harness.md`. Key architectural notes:

- **Wave execution**: 3 implementation waves + 1 final review wave (4 parallel reviewers).
- **11 tasks**: source-version detection (T1), `--target` validation (T2), shared backup via
  `mt-admin backup-tenant` (T3), modern path refactor (T4), legacy gates (T5), legacy apply (T6),
  rehearsal fixture (T7),
  rollback section (T8), operator runbook (T9), ROADMAP update (T10 — cancelled), self-audit (T11).
- **Final review results**: F1 APPROVE, F2 APPROVE, F3 PARTIAL (needs live env), F4 PARTIAL
  (two minor flags).
- **Task 10 (ROADMAP update) was cancelled** per user request — the user will update ROADMAP after
  live validation.
