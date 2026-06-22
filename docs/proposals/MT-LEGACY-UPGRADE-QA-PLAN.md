# MT Legacy Upgrade: Live QA Plan (v1.0.3-era → v1.1.2/3)

**Status:** Reviewed + hardened — live validation pending (open risk: old v1.0.x code may not build on the current toolchain)  
**Date:** 2026-06-21  
**Source:** v1.0.3–v1.0.8 (Docker rootful, PostgreSQL)  
**Target:** v1.1.2 or v1.1.3 (max v1.1.3)  
**Key files:** [`ic/scripts/upgrade-tenant-version.sh`](../../ic/scripts/upgrade-tenant-version.sh), [`ic/scripts/rehearse-legacy-upgrade.sh`](../../ic/scripts/rehearse-legacy-upgrade.sh), [`docs/ops/MT-LEGACY-UPGRADE-NOTES.md`](../ops/MT-LEGACY-UPGRADE-NOTES.md)

---

## 1-page summary

This checklist is for a real operator validating the legacy same-host upgrade path for a v1.0.3-era multi-tenant tenant.

Use it when the tenant:
- is still on Docker rootful
- uses PostgreSQL
- is checked out somewhere in the v1.0.3–v1.0.8 range
- needs to land on v1.1.2 or v1.1.3 without doing the v1.1.4+ rootless flip

This is not an implementation note and not a migration design document. It is a live run checklist for a canary tenant.

Expected upgrade shape:
- dry-run gates first
- apply the legacy path with explicit `--target`
- verify migrations, health, secrets, and WeeChat adapter recovery
- verify rollback works from the backup dump produced by `mt-admin backup-tenant`
- capture evidence for sign-off

Do not use this checklist for:
- v1.0.9+ modern-source tenants
- libSQL tenants
- Podman/rootless tenants
- targets above v1.1.3

---

## Prerequisites

- Host with Docker rootful, PostgreSQL, and current repo checkout available.
- Run commands as root or via `sudo`.
- `ic/scripts/lunarwing-mt-admin.sh` from the current repo is present and executable.
- A real v1.0.3-era tenant is available, or a synthetic tenant has been prepared with `sudo ic/scripts/rehearse-legacy-upgrade.sh up` (which builds a genuine pre-reflex `maxv<19` fixture and seeds a duplicate `memory_documents` group).
- Target tag chosen explicitly: `--target v1.1.2` or `--target v1.1.3`.
- For legacy sources, `--target` is mandatory, must be a literal `vX.Y.Z` release tag (branch / SHA / suffixed refs are rejected), and must not exceed `v1.1.3` (v1.1.4+ rootless flips are `upgrade-tenant.sh`'s job).
- `jq`, `docker`, `git`, and `shellcheck` are installed on the host.
- PostgreSQL inside `lunarwing-pg-<tenant>` is version 15 or newer.
- Operator has a place to save logs and command output.
- If XMPP is enabled, operator can send and receive a real test message.
- If encrypted secrets are in use, operator has a safe key name to verify with `secret-get`.

Recommended variables:

```bash
export TENANT=<tenant>
export TARGET=v1.1.3
export LOGDIR="$PWD/legacy-upgrade-evidence-$TENANT-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOGDIR"
```

---

## Live Validation Checklist

1. **Confirm the tenant is a legacy-source candidate.**
   ```bash
   sudo ic/scripts/upgrade-tenant-version.sh "$TENANT" --target "$TARGET"
   ```
   Expect dry-run output showing source in the `v1.0.3–v1.0.8` range and legacy handling.

2. **Confirm legacy path selection is explicit.**
   ```bash
   sudo ic/scripts/upgrade-tenant-version.sh "$TENANT" --target "$TARGET" 2>&1 | tee "$LOGDIR/dry-run.log"
   ```
   Expect `source: v... (legacy)` in the banner and no attempt to use a silent default target.

3. **Confirm all legacy gates pass.**
   ```bash
   grep -E "GATE [0-9]|PASS|WARN|legacy" "$LOGDIR/dry-run.log"
   ```
   Review all reported gates, especially Docker runtime, PostgreSQL >= 15, migration state, clean tree, WeeChat pre-flight, onboarding flag, and legacy warning.

4. **Confirm the tenant is not being routed to the modern path.**
   ```bash
   grep -E "source: v.*\(legacy\)|legacy path|legacy upgrade" "$LOGDIR/dry-run.log"
   ```
   Expect legacy wording only; do not proceed if the tenant is classified as modern unexpectedly.

5. **Capture pre-upgrade migration state.**
   ```bash
   sudo docker exec -i "lunarwing-pg-$TENANT" psql -U lunarwing -d lunarwing -c "SELECT version, name FROM refinery_schema_history ORDER BY version;" | tee "$LOGDIR/pre-schema-history.txt"
   ```

6. **Confirm duplicate-group state before apply.**
   ```bash
   sudo docker exec -i "lunarwing-pg-$TENANT" psql -U lunarwing -d lunarwing -c "SELECT user_id, COALESCE(agent_id::text,''), path, COUNT(*) FROM memory_documents GROUP BY user_id, COALESCE(agent_id::text,''), path HAVING COUNT(*) > 1;" | tee "$LOGDIR/pre-duplicates.txt"
   ```
   `memory_documents` exists since `V1__initial.sql`, so this check always applies (legacy is not special-cased). Zero rows is ideal; if not zero, the shared migration-state gate (GATE 2/3/4) requires an explicit confirmation before apply because V21 keeps the oldest row per `(user_id, COALESCE(agent_id,''), path)` and deletes the duplicate losers.

7. **Run the real upgrade apply path and capture full output.**
   ```bash
   sudo ic/scripts/upgrade-tenant-version.sh "$TENANT" --apply --target "$TARGET" 2>&1 | tee "$LOGDIR/upgrade-apply.log"
   ```
   Expect the ten apply steps: backup (DB dump via mt-admin + env/ports/caps), stop, checkout, build, install WASM, render units, patch env, start, stale unit cleanup, and adapter kick.

8. **Confirm the backup was created.**
   ```bash
   grep -E "verified DB dump|saved env|saved ports.json|saved installed caps" "$LOGDIR/upgrade-apply.log" | tee "$LOGDIR/backup-summary.txt"
   ```
   The DB dump is produced by `mt-admin backup-tenant` and lands root-owned (`-Fc`, validated for the `PGDMP` magic and size) under `${LUNARWING_MT_BACKUP_DIR:-/var/lib/lunarwing-backups}/$TENANT/`. Only the env/ports/capabilities `.bak` copies live under `/home/$TENANT/lunarwing/backups/$TARGET-upgrade-<stamp>/` (mode 0700). There is no inline `pg_dump` and no tenant-owned DB dump.

9. **Confirm V19, V20, and V21 are present after upgrade.**
   ```bash
   sudo docker exec -i "lunarwing-pg-$TENANT" psql -U lunarwing -d lunarwing -c "SELECT version, name FROM refinery_schema_history ORDER BY version;" | tee "$LOGDIR/post-schema-history.txt"
   ```
   Expect 19, 20, and 21 in the applied history.

10. **Confirm the `unique_path_per_user` constraint exists after V21.**
    ```bash
    sudo docker exec -i "lunarwing-pg-$TENANT" psql -U lunarwing -d lunarwing -c "SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname='unique_path_per_user';" | tee "$LOGDIR/constraint-check.txt"
    ```

11. **Confirm duplicate groups are gone after upgrade.**
    ```bash
    sudo docker exec -i "lunarwing-pg-$TENANT" psql -U lunarwing -d lunarwing -c "SELECT user_id, COALESCE(agent_id::text,''), path, COUNT(*) FROM memory_documents GROUP BY user_id, COALESCE(agent_id::text,''), path HAVING COUNT(*) > 1;" | tee "$LOGDIR/post-duplicates.txt"
    ```
    Expect zero rows.

12. **Confirm tenant services are healthy after start.**
    ```bash
    sudo ic/scripts/lunarwing-mt-admin.sh status "$TENANT" | tee "$LOGDIR/mt-status.txt"
    ```
    Expect the tenant to be up and the main health checks to respond.

13. **Confirm the WeeChat adapter recovered and connected cleanly.**
    ```bash
    sudo journalctl --user -u "lunarwing-weechat-adapter-$TENANT.service" --no-pager -n 100 | tee "$LOGDIR/weechat-adapter-journal.txt"
    ```
    Look for successful restart behavior and healthy WebSocket/relay connectivity. If available in logs or health output, confirm `ws_connected=true`.

14. **Confirm encrypted secrets still decrypt.**
    ```bash
    sudo ic/scripts/lunarwing-mt-admin.sh secret-get "$TENANT" <known-key> > "$LOGDIR/secret-get.txt"
    ```
    Expect success. Do not copy the secret value into tickets or shared notes.

15. **If XMPP is enabled, confirm OMEMO/message continuity manually.**
    - Send a test message to the tenant.
    - Send a reply from the tenant.
    - Confirm the recipient sees expected decrypted content.
    - Record pass/fail and timestamp in operator notes.

16. **Confirm tenant port metadata still looks sane.**
    ```bash
    sudo jq ".tenants[\"$TENANT\"]" /etc/lunarwing/ports.json | tee "$LOGDIR/tenant-ports.json"
    ```
    The canonical registry is `/etc/lunarwing/ports.json` (override with `LUNARWING_PORTS_REGISTRY`); there is no per-tenant `ports.json`. Expect valid JSON and no obvious collisions or broken values.

17. **Exercise the rehearsal path if using a synthetic tenant.**
    ```bash
    sudo ic/scripts/rehearse-legacy-upgrade.sh verify 2>&1 | tee "$LOGDIR/rehearsal-verify.log"
    ```
    The rehearsal runs the legacy upgrade against the genuine `maxv<19` fixture and asserts the V21 dedup actually ran: the migration head reaches V21 or higher, the seeded duplicate group collapses to zero, and the row count drops `N -> N-1` (the duplicate loser is deleted). Pass matching `--name`/`--source-ref`/`--target` if you changed them at `up` time. Use this only for synthetic validation; it does not replace the real-tenant checks above. Note: building old (v1.0.x) code on the current toolchain may fail — that itself is a useful finding.

18. **Run final script linting for operator confidence.**
    ```bash
    shellcheck ic/scripts/upgrade-tenant-version.sh ic/scripts/rehearse-legacy-upgrade.sh | tee "$LOGDIR/shellcheck.txt"
    ```
    Expect clean output or only already-accepted noise that has been reviewed.

---

## Rollback Verification

Rollback is operator-driven (print-only) — the apply path never auto-restores. If an `--apply` run aborts mid-flight after the backup is taken, a failure trap prints the recovery steps (backup dump path + pre-upgrade revision) automatically. The manual sequence below restores from the verified backup dump with an inline `pg_restore` (not `mt-admin restore-tenant`).

1. **Locate the backup dump referenced during apply.**
   ```bash
   grep -E "verified DB dump|ROLLBACK|RECOVERY STEPS" "$LOGDIR/upgrade-apply.log" | tee "$LOGDIR/rollback-prep.txt"
   ```

2. **Run the printed rollback sequence using the captured dump path.**
   ```bash
   sudo ic/scripts/lunarwing-mt-admin.sh stop-tenant "$TENANT"
   sudo -u "$TENANT" git -c safe.directory="/home/$TENANT/lunarwing" -C "/home/$TENANT/lunarwing" checkout <original-tag>
   sudo docker start "lunarwing-pg-$TENANT"
   sudo docker exec -i "lunarwing-pg-$TENANT" pg_restore -U lunarwing -d lunarwing --clean --if-exists < <backup-dump-path>
   ```

3. **Rebuild and restart the old version.**
   ```bash
   sudo ic/scripts/lunarwing-mt-admin.sh build-tenant "$TENANT" --with-wasm
   sudo ic/scripts/lunarwing-mt-admin.sh render-units "$TENANT"
   sudo ic/scripts/lunarwing-mt-admin.sh start-tenant "$TENANT"
   ```

4. **Confirm post-rollback schema state matches the pre-upgrade capture.**
   ```bash
   sudo docker exec -i "lunarwing-pg-$TENANT" psql -U lunarwing -d lunarwing -c "SELECT version, name FROM refinery_schema_history ORDER BY version;" | tee "$LOGDIR/post-rollback-schema-history.txt"
   ```

5. **Confirm the rolled-back tenant still starts and secrets still decrypt.**
   ```bash
   sudo ic/scripts/lunarwing-mt-admin.sh status "$TENANT" | tee "$LOGDIR/post-rollback-status.txt"
   sudo ic/scripts/lunarwing-mt-admin.sh secret-get "$TENANT" <known-key> > "$LOGDIR/post-rollback-secret-get.txt"
   ```

---

## Definition of Done

- [ ] Dry-run classified the tenant as legacy and all required gates were reviewed.
- [ ] Apply path completed successfully with a captured log.
- [ ] Post-upgrade schema shows V19, V20, and V21 applied.
- [ ] `unique_path_per_user` exists and duplicate groups are absent.
- [ ] Tenant status is healthy after restart.
- [ ] WeeChat adapter connectivity was checked.
- [ ] Encrypted secret retrieval was verified.
- [ ] XMPP/OMEMO continuity was checked when applicable.
- [ ] Rollback steps were executed or at minimum rehearsed against the captured backup.
- [ ] Operator sign-off recorded with tenant name, target tag, and timestamp.

---

## Evidence to Capture

- `dry-run.log`
- `upgrade-apply.log`
- `backup-summary.txt`
- `pre-schema-history.txt`
- `post-schema-history.txt`
- `constraint-check.txt`
- `pre-duplicates.txt`
- `post-duplicates.txt`
- `mt-status.txt`
- `weechat-adapter-journal.txt`
- `tenant-ports.json`
- `shellcheck.txt`
- `post-rollback-schema-history.txt` if rollback is exercised
- operator note with pass/fail, tenant, target, timestamp, and any anomalies
