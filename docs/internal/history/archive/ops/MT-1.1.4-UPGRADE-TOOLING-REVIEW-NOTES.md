# MT v1.1.0→v1.1.4 Upgrade Tooling — Adversarial Review Notes

**Scope:** the in-place upgrade tooling on branch `staging-mt-1.1.0-to-1.1.4-upgrade`
(`upgrade-preflight.sh`, `upgrade-tenant.sh`, `enable-health-fleet.sh`, and the
`start_tenant_postgres` data-orphan guard in `lunarwing-mt-admin.sh`).
**Companion:** `docs/proposals/MT-1.1.0-TO-1.1.4-UPGRADE.md`.
**Status:** all findings below are **fixed**. This doc is a reference in case the
tooling is revisited.

The tooling went through **two adversarial review passes** (multi-agent: review
lenses → per-finding verification). Pass 1 fixes landed in `285a5b7d`; pass 2 (which
first confirmed the pass-1 core fixes held) fixes landed in `e3ce73ab`. This doc
records the **7 residual issues** pass 2 surfaced, since they are the subtle ones
most worth remembering.

---

## Pass 1 (commit `285a5b7d`) — summary

Pass 1 found and fixed: `--dry-run` actually stopped the tenant; `add-tenant`
re-run wiped XMPP MUC/OMEMO/LLM config; the data-orphan ACK was a global boolean;
the preflight CAUTION verdict was unreachable and reported GO for stopped/empty
cases; the Gotify token was accepted on argv (leaked via `/proc/<pid>/cmdline`);
runtime-detection precedence diverged from mt-admin; plus version-parse and dry-run
ordering nits. Pass 2 verified each of these stayed fixed.

---

## Pass 2 (commit `e3ce73ab`) — the 7 residual issues

### 1. Table count ≠ "data restored" (the important one — destructive path)
`--prune-old-root` and the step-8 verify counted **public tables**
(`information_schema.tables`). But the daemon's refinery migrations (`V1..V21`,
unqualified `CREATE TABLE` → `public`) create the full schema on first connect,
**independent of any restore**. So a DB where `add-tenant`+`start-tenant` ran but
the restore never loaded rows would report table-count > 0 and pass the guard —
`--prune-old-root` could then delete the **only** copy of the v1.1.0 data; step-8
would falsely say "restore looks good".
**Fix:** probe **data rows**, not schema — `rootless_data_rows()` counts
`conversations` + `conversation_messages` (core tables, present since `V1__initial`,
unchanged `v1.1.0..v1.1.4`). Prune refuses unless rows > 0; step-8 reports rows.
*(The original 0-table post-flip case stayed correctly blocked; this was a narrower
residual gap.)*

### 2. `set -e` abort before the rollback banner
The row/table-count helper ends in a pipe (`… psql … | tr …`). Under
`set -euo pipefail`, a failed `psql`/`exec` made the pipeline non-zero, and the bare
assignment `vrows="$(rootless_data_rows …)"` at the step-8 call site would abort the
script **before** printing the WARNING + rollback instructions.
**Fix:** the helper ends in `|| true`, so a probe failure yields empty → treated as
0 (callers warn / refuse to prune) and never aborts.

### 3. `awk -v` corrupted backslashes in re-applied env values
`reapply_env_key` re-applied operator config with
`awk -v repl="$line" '…{print repl}…'`. awk subjects `-v` assignments to **C-style
escape processing**, so a value containing `\` was mangled (`\n`→newline, `\t`→tab,
`\"`→`"`, octal decoded) — could split a line or break JSON. Low reachability for
the current key set (JIDs/URLs rarely contain `\`) but a latent corruption path
(e.g. an `LLM_API_KEY` or escaped-quote room JSON).
**Fix:** pass the value via the environment and read it with awk's `ENVIRON`
(not escape-processed): `_rk_repl="$line" awk … '{print ENVIRON["_rk_repl"]}'`.
Verified: `path\to\new&model` and `["a@conf"]` preserved verbatim.

### 4. Re-apply source re-derived from the live env each run
Step 1 snapshotted the **current** live env (per-`$STAMP`), and step 4 re-applied
from it. But step 4's `add-tenant` resets the customizable keys to defaults *before*
re-apply runs. If a run was interrupted in that window, the live env was left holding
defaults; a **subsequent** run's step-1 snapshot would then capture those defaults as
its "backup", and re-apply would faithfully restore the defaults — permanently losing
the operator's original MUC/OMEMO/LLM config.
**Fix:** snapshot the pre-upgrade env **once** to a write-once path
(`$BACKUP_DIR/<t>-env.preupgrade`, never overwritten), and always re-apply from there.

### 5. `XMPP_ALLOW_PLAINTEXT_FALLBACK` omitted from the re-apply list
`add-tenant` hardcodes `XMPP_ALLOW_PLAINTEXT_FALLBACK=true` on every env write. A
tenant an operator had hardened to `false` (no plaintext fallback) would **silently
regain plaintext fallback** after the upgrade — a security regression.
**Fix:** added `XMPP_ALLOW_PLAINTEXT_FALLBACK` to the re-applied key list.

### 6. Preflight rootless-only branch: table-count + no reachability gate
The preflight branch for "rootless PG exists, no root-store PG" counted **tables**
(same flaw as #1) and had **no `pg_isready` gate** — so a running-but-unreachable PG
was conflated with an empty one, and a booted post-flip orphan (schema, no data)
could read as "already migrated → GO".
**Fix:** gate on `pg_isready` first (unreachable → CAUTION, not "empty"), then probe
**conversation rows**; STOP on the reachable-but-zero-rows empty orphan.

### 7. Preflight Host summary hid host-scope CAUTIONs (+ stale doc ACK)
The summary's `Host:` line was binary (`OK` / `STOP`), so host-scope warnings
(`podman < 4.6`, `ports.json < v6`) collapsed to `Host: OK`.
**Fix:** three-state — `Host: CAUTION (N item(s))` via a host-scope warn counter.
*Related doc fix:* the proposal documented the escape hatch as
`LUNARWING_MT_ACK_ROOTLESS_FLIP=1`, but the shipped guard is **per-tenant** (a
comma-separated list of tenant names); corrected to `=<tenant>`.

---

## What pass 2 explicitly confirmed as already-correct (no change)

The per-tenant ACK comma-list match (`$name` is quoted in the pattern and
sanitized to `[a-z0-9-]`, so glob metacharacters can't reach it); `run mt_rootful
stop-tenant` (the `run` wrapper correctly invokes the shell function and honors
`--dry-run`); `RUNTIME="$(detect_runtime)"` aborting under `set -e` when the override
is invalid (plain assignment propagates the subshell `exit`, unlike `export X=$(…)`);
and the preflight three-state per-tenant `w0` snapshot (host warns don't bleed into
the first tenant; a CAUTION in tenant A doesn't carry to B).

## Known, intentionally-deferred limitation

The `start_tenant_postgres` guard fires only when the rootless container is
**absent**. The "rootless exists but **empty** while a root orphan persists" case is
**not** caught at start time — the post-migration steady state (live rootless DB + a
root container kept as a rollback net) also has both present, and a start-time probe
can't tell them apart without the container running, so guarding it there would break
every legitimate restart. That case is instead covered by `upgrade-preflight.sh`
(STOPs on the reachable-but-zero-rows orphan) and `upgrade-tenant.sh --prune-old-root`
(refuses to delete the root copy while the rootless DB has zero conversation rows).
