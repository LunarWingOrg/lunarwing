# Release Notes for LunarWing v1.1.5 — Codename `Kawarimi`

**Release Date:** 2026-06-21

> Codename *Kawarimi* — the ninja substitution art (替わり身): swap yourself out and leave a stand-in behind. Fitting for a release whose centerpiece is moving a tenant to a fresh host while the old one stays as the rollback.

## Overview

Per the release cadence (`docs/ops/RELEASE_CADENCE.md`), **odd-numbered releases focus on bug fixes, security improvements, and polishing**. v1.1.5 is a polish/bug-fix release, and its centerpiece is a suite of **multi-tenant migration & upgrade tooling**: operator scripts for **moving a tenant to a fresh host** and for performing the **in-place v1.1.0 → v1.1.4 upgrade** — both designed around the one hazard that the v1.1.4 *Known Issues* flagged but did not yet have tooling for: the Podman **rootful → rootless PostgreSQL flip**, which a naive restart turns into a silently-empty database. The new tooling closes the gap the v1.1.4 pre-release checklist deferred (`docs/ops/GOALS_1.1.4.md` #11 — in-place upgrade of a live tenant on a version > v1.1.0, via direct upgrade or migration). The **machine-migration path (`export` → `import`) has been live-validated on a production tenant**, and the **same-host version-upgrade tool (`upgrade-tenant-version.sh`) has been live-validated on a production tenant for a v1.0.9 → v1.1.2 upgrade**.

Additionally, a fix has been introduced to fix an **agent-loop reliability case**: a hung LLM backend could let retries stack past the agent's turn budget, and the resulting hard-kill **silently discarded the user's already-queued follow-up** (the recurring *"your request timed out / message queued"* symptom). v1.1.5 caps the whole LLM call below the turn budget and preserves the pending queue on a hard timeout.

A third focus is a **large, `docs/`-only documentation reorganization** — a semi-total reorg that establishes a `history/` archive for superseded LunarWing docs and a `vendored/` archive for upstream third-party copies, rebuilds the `docs/README.md` index, and reconciles the documentation audit. No documentation outside `docs/` was touched for this specific documentation reorganization activity.

This release **does not** add database schema changes.

---

## Changes

### Multi-Tenant Migration & Upgrade Tooling

New operator tooling (all under `ic/scripts/`, `root`-only, gated by confirmation prompts — with read-only/dry-run defaults where applicable: `upgrade-preflight.sh` is read-only and `upgrade-tenant-version.sh` defaults to a dry-run) for **moving and upgrading multi-tenant fleets** without orphaning data or silently resetting operator config. See new documentation in `docs/ops/MT-MACHINE-MIGRATION-REVIEW-NOTES.md`, `docs/ops/MT-1.1.4-UPGRADE-TOOLING-REVIEW-NOTES.md`, `docs/ops/MT-MACHINE-MIGRATION.md`, and `docs/proposals/MT-1.1.0-TO-1.1.4-UPGRADE.md`.

#### Kawarimi Machine Migration — `export-tenant.sh` + `import-tenant.sh`

Kawarimi no Jutsu is a basic Ninjutsu technique. Move one tenant to a **fresh** host. `export-tenant.sh <tenant>` runs on the source and is self-contained (it needs only the container runtime + `jq` + `tar`, so a v1.1.0 source works); it produces a single `0600` tar bundle: `meta.txt`, a `pg_dump -Fc` `db.dump` (verified for the `PGDMP` magic header), `manifest-lunarwing.env` / `manifest-bridge.env` carry-over keys, and `state.tar.gz` (OMEMO store + workspace, excluding `*.sock`, `state/config.toml`, and `*.wasm`). `import-tenant.sh <bundle.tar>` runs on the target and **delegates all init/runtime specifics to `lunarwing-mt-admin.sh`** — so the target's init system and container mode need not match the source — via `add-tenant --no-health` → `build-tenant --with-wasm` → inject carried secrets → `restore-tenant --yes` → restore state → `install-wasm` → optional `--start`.

- **Export is the start of a cutover, not a snapshot.** Per review finding HIGH-1, export now **stops the tenant daemon + xmpp-bridge first** (PostgreSQL stays up only for the dump) so the OMEMO double-ratchet store can't be tarred mid-write and nothing is written after the snapshot. `--no-quiesce` skips the stop but still verifies the daemon is down; `--dry-run` prints the plan.
- **Carry policy is deliberate.** Only values that *must* match the source travel: `SECRETS_MASTER_KEY` (the AES-256-GCM vault key — both sides refuse a bundle without it), the XMPP identity (`XMPP_JID` / `XMPP_PASSWORD`), and operator config (XMPP rooms/allowlist/OMEMO + `LLM_MODEL` / `LLM_API_KEY`). Intra-host tokens (gateway / bridge / webhook / relay) are **not** carried — `add-tenant` mints fresh self-consistent ones, and gateway-UI / external-webhook clients re-authenticate after cutover. `LLM_BASE_URL` is carried **only** if it is a non-loopback custom endpoint.
- **Double-login safety.** Because the new daemon logs into the same `XMPP_JID`, `--start` is **not** satisfied by `--yes` alone — an unattended start additionally requires `--old-stopped`, otherwise it prompts. By default it stages without starting and prints cutover / rollback steps (the old host remains the rollback).
- **NOTE: This method is PostgreSQL only.** A non-`postgres` `DATABASE_BACKEND` is refused on both sides rather than risk a silent empty import. Unfortunately, libsql is not supported at this time.

> **Status:** Implemented and **live-validated end-to-end on a production tenant** — a full `export → import → start` cutover onto a fresh host completed successfully, with the migrated tenant operational on the new host. Source-side export specifics (consistent quiesced OMEMO snapshot, loopback `LLM_BASE_URL` correctly not carried, `0600` bundle, role/db parsed from `DATABASE_URL`) are captured in `docs/ops/IMPORT_EXPORT_EXAMPLE.txt`. OMEMO encrypted-chat continuity and `SECRETS_MASTER_KEY`-decryptable secret continuity were **not separately spot-checked** during that run — see *Known Issues* for that residual.

#### v1.1.0 → v1.1.4 In-Place Upgrade — `upgrade-tenant.sh` + the data-orphan guard

`upgrade-tenant.sh <tenant>` performs the in-place v1.1.0 → v1.1.4 ("Phoenix") upgrade on systemd / Podman, superseding the earlier hardcoded one-off scripts. Its reason for existing is the **Podman rootful → rootless PostgreSQL flip**: v1.1.0 ran PG rootful (root store, no named volume), whereas v1.1.4 defaults `MT_ROOTLESS=true`, so a naive start boots an **empty** rootless DB and orphans the real data. The default `rootless-adopt` mode performs a deliberate data migration — preflight gate → `backup-tenant` + `PGDMP` verify → `stop-tenant` → `git checkout` `--target` (default `v1.1.4`) + `build-tenant --with-wasm` + `install-wasm` → `add-tenant --no-health` (empty rootless PG + rendered units, no daemon) → `restore-tenant --yes` → `start-tenant` → orphaned-weechat-unit cleanup → verify. `--keep-rootful` instead pins `LUNARWING_MT_ROOTLESS=false` to reuse the existing container (no data migration).

- It re-applies operator config (XMPP MUC / OMEMO / plaintext-fallback / LLM keys) from a **write-once** `*-env.preupgrade` snapshot, verifies restored data by **row count** in `conversations` + `conversation_messages` (not table existence — refinery recreates the schema regardless), and `--prune-old-root` refuses to delete the root-store copy unless the rootless DB is up, `pg_isready`, and holds > 0 conversation rows.
- **The data-orphan guard (commit `95b0a193`).** `start_tenant_postgres` in `lunarwing-mt-admin.sh` now refuses by default to create a fresh empty rootless PG when a legacy root-store `lunarwing-pg-<t>` still exists and no rootless container is present yet. It fires **only** in that exact window and offers three escape hatches: migrate (`upgrade-tenant.sh`), `LUNARWING_MT_ROOTLESS=false` (keep rootful), or `LUNARWING_MT_ACK_ROOTLESS_FLIP=<tenant>` (intended fresh DB — `upgrade-tenant.sh` sets this automatically once it holds a verified backup). The ACK is **per-tenant** (a comma-separated name list), not a global boolean.

> **Status:** Implemented and Tested; all residuals fixed in `docs/ops/MT-1.1.4-UPGRADE-TOOLING-REVIEW-NOTES.md`. The guard and `--dry-run` paths are reasoned-through. Please note that v1.1.0 → v1.1.5 targets need further refactoring and that a separate v1.0.3 → v1.1.0-era harness is still in development progress.

#### Generic Same-Host Version Upgrade — `upgrade-tenant-version.sh`

`upgrade-tenant-version.sh <tenant>` is the **rootful, same-Docker-host** version-bump tool (default `--target v1.1.2`), generalizing the one-off `upgrade-tenant-kageho.sh`. It is explicitly *not* the rootless-flip tool — it stays rootful for 1.0.x / 1.1.x → 1.1.x jumps where the only schema delta is additive (the reflex tables V19/V20 + the self-heal dedup V21). It **defaults to a read-only dry-run** (changes nothing until `--apply`) and gates on PostgreSQL ≥ 15 (V21 uses `UNIQUE NULLS NOT DISTINCT`), pending-migration / duplicate-`memory_documents` detection, a clean working tree, and a WeeChat pre-flight. Lessons carried forward: May need to run: `render-units` before start (pre-1.1.0 tenants carry the old `weechat-<t>` unit name), and restart the WeeChat adapter **last** to avoid the relay-readiness 401 race (verifying `ws_connected`).

> **Status:** Implemented and **live-validated on a production tenant for the v1.0.9 → v1.1.2 upgrade** (building on the predecessor `upgrade-tenant-kageho.sh` in ic/scripts, run live for the kageho 1.0.x → 1.1.2 upgrade on 2026-06-18). Support for **source versions older than v1.0.9** is a planned extension (see *Deferred*) as well as the note above: > Please note that v1.1.0 → v1.1.5 targets need further refactoring and that a separate v1.0.3 → v1.1.0-era harness is still in development progress.

#### Preflight & Rehearsal — `upgrade-preflight.sh`, `rehearse-testbot.sh`

`upgrade-preflight.sh <tenant> | --all [--keep-rootful]` is a **read-only** assessor printing a per-tenant `GO` / `CAUTION` / `STOP` verdict and a three-state host summary. Its key check is the rootful → rootless data-orphan hazard: it locates where the live PG data actually is (root vs rootless store), gates on `pg_isready` before counting **conversation rows**, and STOPs on the reachable-but-zero-rows empty post-flip orphan. It also checks Podman ≥ 4.6 (Quadlet), `ports.json` schema ≥ v6, a v1.1.4-class `mt-admin` (`MT_ROOTLESS` + `restore-tenant`), `SECRETS_MASTER_KEY`, linger, and passwordless `sudo -n` root → tenant; it exits 1 if any tenant is STOP. `rehearse-testbot.sh` spins up a throwaway tenant, seeds a `migration_rehearsal_marker` row, and prints the export → import → verify → `--cleanup` rehearsal steps.

> **Status:** `upgrade-preflight.sh` is Implemented (read-only; review pass 2 made the `CAUTION` verdict reachable and added the row-count / `pg_isready` gating). `rehearse-testbot.sh` carries its own **helper banner**.

#### Fleet Health Enablement — `enable-health-fleet.sh`

`enable-health-fleet.sh` turns on the host-global health-check + self-heal pipeline for an **existing** fleet without re-adding tenants (in v1.1.4 it was enabled only as a side effect of `add-tenant` / `add-tenants`). It sources `lunarwing-mt-admin.sh` (whose `main` is guarded, so only functions/config load) and calls `ensure_health_pipeline` directly — no duplicated logic — and adds the safety the implicit path lacks: it **refuses to arm the ~15-minute remediation timer while any tenant daemon is down** (unless `--allow-down`). The Gotify escalation token is never accepted on argv (`--gotify-token` is rejected; use `--gotify-token-file` or `LUNARWING_MT_GOTIFY_TOKEN`), and an existing `/etc/lunarwing/health.env` is preserved. `--dry-run` prints the plan and exits before any gate.

> **Status:** Implemented; the down-tenant refusal and argv-token rejection are enforced in-script. Live verification has been confirmed.

#### Migration-Harness Fold-Ins (PR #66, merge `38e4e1a1`)

PR #66 brought the machine-migration tooling to its reviewed state with four fold-ins:

- **Gateway / HTTP bind-address carry (`94c754df`)** — found in real use: the export carry-list omitted `GATEWAY_HOST` / `HTTP_HOST`, so a tenant bound to `0.0.0.0` for remote access came up `127.0.0.1`-only after migration. Both keys are now in the export manifest (the bind **address** is operator config; the **ports** stay host-specific and are regenerated), and `import-tenant.sh`'s `inject_keys` applies them over the `add-tenant` default. Recorded as review note **PR-1**.
- **`docs/ops/MT-MACHINE-MIGRATION-REVIEW-NOTES.md`** — the adversarial-review record (HIGH / MED / LOW findings, all fixed in `4d1943cd`).
- **`docs/ops/IMPORT_EXPORT_EXAMPLE.txt`** — the live source-side validation log.
- **WeeChat WSS adapter heartbeat (`356b31ec`)** — `ws_adapter.py` now sets `heartbeat=25` (was `heartbeat=None`) on the relay WS connection so silent / half-open drops are detected.

### LLM Turn-Budget Timeout — Cap the Whole Call Below the Agent Turn Budget

A hung LLM backend could let `RetryProvider` stack `max_retries + 1` attempts of `request_timeout_secs` each (the default 4 × 120 s ≈ 487 s), far past the agent's 300 s `handle_message` turn budget. The turn was then hard-killed mid-flight, which silently dropped the user's queued follow-up — the recurring *"request timed out / message queued"* symptom. v1.1.5 caps the entire call below the turn budget so it fails gracefully.

- **New `TimeoutProvider` decorator (`ic/src/llm/timeout.rs`, new file).** Wraps any `LlmProvider` so a single *logical* call — including all internal retries, backoff, and failover — can never exceed a total wall-clock `budget`. It wraps `complete()` and `complete_with_tools()` in `tokio::time::timeout(self.budget, …)`; on elapse it logs a `warn!` and returns a **retryable** `LlmError::RequestFailed` (reason *"LLM call exceeded the Ns turn budget …"*) instead of letting the call run away. All other `LlmProvider` methods (`model_name`, `cost_per_token`, `list_models`, `model_metadata`, `set_model`, `calculate_cost`, …) delegate straight through to the inner provider.
- **Wired near the outside of the provider chain.** In `build_provider_chain()` (`ic/src/llm/mod.rs`) the wrapper is applied as step 5b — after retry/failover but before the recording layer — so the budget bounds the whole stack rather than a single attempt. It is applied only when `llm_turn_budget_secs` is nonzero (`0` disables it).
- **New config knob `llm_turn_budget_secs`.** Added to `LlmConfig` in both `ic/src/llm/config.rs` (the provider-facing struct) and `ic/src/config/llm.rs` (the env/settings resolver), set via the new **`LLM_TURN_BUDGET_SECS`** env var. **Default: `270`** — deliberately below the 300 s `handle_message` turn timeout (`AGENT_HANDLE_MESSAGE_TIMEOUT_SECS`, default `300`), so the LLM call fails gracefully before the soft timeout fires; the doc comment notes it *"must stay below the turn timeout."* The existing per-attempt `request_timeout_secs` (`LLM_REQUEST_TIMEOUT_SECS`, default `120`) is unchanged — the new budget caps the aggregate across retries.

### Hard-Timeout Reset Now Preserves the Queued Follow-Up

- **`ic/src/agent/agent_loop.rs` hard-kill path.** When a turn was hard-killed (soft timeout at 300 s, then a `HARD_KILL_GRACE_SECS = 30 s` grace before `abort_handle.abort()`), the reset previously called `thread.fail_turn_hard(…)`, which cleared the thread's `pending_messages` — silently discarding the user's queued follow-up despite the *"your request timed out / will be processed"* acknowledgment. The reset now calls `thread.fail_turn(…)`, which **preserves** `pending_messages`, and logs `preserved_pending` in the `HARD TIMEOUT` warning. Rationale: the preceding `abort()` guarantees the orphaned task can no longer emit a response, so the "confusing concurrent response" risk that originally justified clearing no longer applies at the hard-kill.
- **`Thread::fail_turn_hard()` removed (`ic/src/agent/session.rs`).** The now-unused method (which did `fail_turn()` then `pending_messages.clear()`) was deleted; the hard-kill path was its only caller. `fail_turn()` (which preserves the queue for the drain path) is now used on both the normal-fail and hard-timeout paths.
- **Soft-timeout drain-loop clear left as-is (intentional).** On the soft-timeout branch the original task continues running and could still respond, so the existing drain-loop clear is retained to avoid a double response. Only the hard-kill reset changed.

### AppBuilder changes

- build_all() now reconciles that LLM budget against the agent's turn timeout via a pure, testable resolve_turn_budget() returning a TurnBudgetOutcome (Ok / Clamp(n) / TimeoutTooSmall). Rather than merely warning, it's self-correcting: if LLM_TURN_BUDGET_SECS sits too close to or over the timeout, it clamps the effective budget down to the safe ceiling (handle_message_timeout − HARD_KILL_GRACE_SECS) so the TimeoutProvider is guaranteed to fire before the hard-kill — warning on clamp, and on a timeout too small to position any budget. The default 270/300 now passes clean (the prior version warned on every boot), and the margin is sourced directly from agent_loop::HARD_KILL_GRACE_SECS (re-exported pub(crate)) so the grace period can't drift between the two files. Along the way it also fixed two non-compiling commits on the branch (a bare Self::-less call and a missing test-module import).

### Minor Lunartica polishing and live testing

- Lunartica is confirmed to work after some refinements and testing scripts have been created and used. A tenant is able to successfully complete a task after being assigned an issue, utilize the new custom workspace_read functionality to read the lunartica config as part of a routine in order to claim and execute tasks. This is still considered to be very experimental and buggy. More polishing and development on Lunartica will continue and certain tool calls may be finnicky and may not work correctly. Chatting from the Lunartica interface does not work. The bridge has zero websocket support at this time and all actions must be done via HTTPS polling. The Lunartica repository itself has recieved its first commit, which is nothing more than a simple, incomplete CSS reskin and some documentation on getting started with development. See, the seperate repo: LunarWingOrg/Lunartica for more information. The multica bridge tool also works with standard Multica as well without any needed modification at this time.

### Documentation & Housekeeping

- **`docs/` tree reorganization.** A semi-total reorg and consolidation of the documentation tree, tracked end-to-end by a new living checklist **`docs/DOCS_REORG_CHECKLIST.md`** (all 10 declared areas complete, 2026-06-19). **Scope was deliberately limited to `docs/` only** — no `README.md` / `CLAUDE.md` / `AGENTS.md` outside `docs/` (repo root, `ic/`, `projects/`, worker dirs) was moved or edited.
- **Archive convention.** Two archives were established so nothing of historical value is deleted: **`docs/internal/history/`** for superseded LunarWing-authored docs (organized by source area, e.g. `history/architecture/`, `history/guides/`, `history/proposals/`, `history/internal/`) and **`docs/internal/vendored/`** for third-party upstream copies. Disposition rule: vendored upstream → `internal/vendored/`; stale LunarWing docs → `internal/history/`; only pure stubs/junk deleted outright. All moves used `git mv`, so file history is preserved. See `docs/internal/history/README.md` and `docs/internal/vendored/README.md`.
- **Vendored upstream noise consolidated (~70 files).** An earlier bulk commit had swept an entire copy of the upstream **nanocode / opencode** project's docs into `docs/`; these were consolidated under `docs/internal/vendored/nanocode-config/` (including a 384 KB `nanogpt.md`, 17-language UI glossaries, per-package READMEs, and test fixtures).
- **Per-area passes (before → after, per the commit messages and `docs/DOCS_REORG_CHECKLIST.md`):** `architecture/` 19 → 6 (kept the genuine specs; archived 8 session-logs/fix-notes; deleted 5 scratch stubs); `guides/` 56 → 23 (archived 19 vendored + 6 deprecated; deleted 8 stubs/duplicates); `internal/` folded 48 vendored and archived 23 stubs, keeping 5 active docs; `proposals/` 61 → 32 (archived 29 shipped/superseded — including the entire `VisionProject/`, now that the OCR/vision service has shipped — with **zero** hard deletions); `ops/` a light pass that archived 3 shipped checklists (`GOALS_1.1.2*`, `GOALS_1.1.3`) to the existing `ops/history/`; `reference/` pruned to genuine LunarWing references; `releases/` all 7 release notes **kept immutable** (audited only).
- **`docs/bugs/` index reconciliation (no files moved/deleted).** `bugs/` is a deliberate Open/Fixed tracker, so all 18 docs were kept; the index had drifted (listed 14, directory held 18) and was reconciled — including rewriting a 315 B transcript stub into a proper `BUG-WEECHAT-WARNINGS.md` after **verifying** the flagged latent `rand_check` bug is still live.
- **`docs/DOCS_AUDIT.md` reconciled** against the current tree (7 more items closed; 10 remain, all but one — `M13`, the lone stale doc still under `docs/` — being IronClaw → LunarWing rename fixes in files **outside** `docs/`), and **`docs/README.md` rebuilt from scratch** as a complete, fully-linked index of the reorganized tree.

---

## Bug Fixes

- **Queued follow-up silently dropped when a turn was hard-killed.** A hung LLM backend let retries stack past the 300 s agent turn budget; the turn was hard-killed, and the hard-kill reset cleared the thread's pending message queue, so a follow-up the user had queued (and been told would be processed) was discarded. Two fixes combine to address this: (1) the new `TimeoutProvider` caps one logical LLM call (all retries included) at `LLM_TURN_BUDGET_SECS` (default 270 s), so the common LLM-hang case now fails gracefully before the 300 s soft timeout and the queue is preserved by default; and (2) the residual case — a non-LLM stall that still rides past the budget into a hard-kill — now resets via `fail_turn` instead of the removed `fail_turn_hard`, preserving the queued follow-up so it is drained on the user's next turn. Both fixes ship regression tests (`TimeoutProvider`: timeout-abort, fast-path passthrough, and metadata delegation in `ic/src/llm/timeout.rs`; the agent path: `test_hard_timeout_reset_preserves_pending_messages` in `ic/src/agent/session.rs`).
- **Gateway/HTTP bind address reset to localhost after a machine migration.** `export-tenant.sh` omitted `GATEWAY_HOST` / `HTTP_HOST` from its carry-list, so a tenant deliberately bound to `0.0.0.0` for remote access came up `127.0.0.1`-only on the new host. Both keys are now carried in the export manifest and re-applied by `import-tenant.sh` over the `add-tenant` default (`94c754df`). (The broader generator fix — preserving a hand-edited bind across a plain `add-tenant` re-run — is still open; see *Known Issues*.)
- **WeeChat WSS relay could silently half-open.** The relay WebSocket in `ws_adapter.py` connected with `heartbeat=None`, so a silent / half-open drop went undetected. It now sets `heartbeat=25` to surface dead connections (`356b31ec`). This channel also needs better health checking which is going to be worked on in the future.

---

## Documentation

- `docs/ops/MT-MACHINE-MIGRATION.md` — operator runbook for the cross-host `export-tenant.sh` / `import-tenant.sh` flow (incl. the `rehearse-testbot.sh` UNTESTED-helper warning).
- `docs/ops/MT-MACHINE-MIGRATION-REVIEW-NOTES.md` — adversarial-review record for the machine-migration tooling (HIGH/MED/LOW findings + the PR-1 bind-address note).
- `docs/proposals/MT-1.1.0-TO-1.1.4-UPGRADE.md` — runbook + proposal for the in-place v1.1.0 → v1.1.4 upgrade (pending operator go-ahead before any service mutation).
- `docs/ops/MT-1.1.4-UPGRADE-TOOLING-REVIEW-NOTES.md` — adversarial-review record for the upgrade tooling.
- `docs/ops/IMPORT_EXPORT_EXAMPLE.txt` — the live source-side export validation log.
- `docs/ops/XMPP_TRANSFERS.md` — XMPP file-transfer quick-reference (XEP-0363/0066/0234/0361 comparison + bridge implementation status).
- `docs/DOCS_REORG_CHECKLIST.md` — living progress tracker for the `docs/` reorg (scope rules, disposition convention, per-area work log, open follow-ups).
- `docs/internal/COMPONENT_SOURCES.md` — consolidated table of each custom component's standalone upstream source repo, replacing the scattered `custom_*` bookmarks.
- `docs/internal/history/README.md`, `docs/internal/vendored/README.md` — index/READMEs for the two new archive trees.
- `docs/proposals/DOCUMENTATION_UPDATING_STATUS.md` — status note recording remaining documentation work after the reorg (see *Known Issues*).
- `docs/ops/GOALS_1.1.5.md` — the v1.1.5 pre-release checklist.
- **Updated** — `docs/README.md` (rebuilt index), `docs/DOCS_AUDIT.md` (reconciled), and `ic/scripts/lunarwing-mt-admin.sh` (the data-orphan guard + migration/upgrade entry points).

---

## Known Issues (not a complete list — see `docs/bugs` and `docs/proposals` for more)

### Resolved since v1.1.4

- **LLM-hang turn-budget overrun + silently-dropped queued follow-up — fixed.** Closed by the new `TimeoutProvider` cap (`LLM_TURN_BUDGET_SECS`, default 270 s) and the `fail_turn` (vs removed `fail_turn_hard`) reset, both with regression tests. See *Changes* and *Bug Fixes*.
- **No general in-place upgrade tooling existed** (only one-off hardcoded scripts). v1.1.5 ships a generalized set: the same-host `upgrade-tenant-version.sh` (rootful, additive-schema jumps), the rootless-adopt `upgrade-tenant.sh` (the v1.1.0 → v1.1.4 PG flip), the `start_tenant_postgres` data-orphan guard, `upgrade-preflight.sh`, and `enable-health-fleet.sh`. The **same-host path is live-validated on a production tenant for a v1.0.9 → v1.1.2 upgrade**; the **rootless-adopt v1.1.0 → v1.1.4 path is reviewed but not yet live-validated** (`GOALS_1.1.4.md` #11) — see *New in v1.1.5* below.
- **No QA'd alternative to the risky rootful → rootless flip existed.** v1.1.5 ships the clean-host `export-tenant.sh` / `import-tenant.sh` path (which routes through the QA'd `add-tenant` flow and keeps the old host as rollback), fixes the real-use `GATEWAY_HOST` / `HTTP_HOST` bind-reset found while using it, and has now been **live-validated end-to-end on a production tenant** (`export → import → start` cutover, tenant operational on the new host).

### New in v1.1.5 (migration/upgrade tooling caveats)

- **Cross-machine migration is live-validated, but OMEMO/secret continuity was not separately spot-checked.** A full `export → import → start` cutover has been **run successfully on a production tenant** (it came up operational on the new host). What was *not* explicitly verified during that run is OMEMO encrypted-chat continuity and `SECRETS_MASTER_KEY`-decryptable secret-row continuity — both are expected to carry (the OMEMO store and the vault key travel in the bundle) but should be confirmed on the next migration. Separately, dump validation is a `PGDMP`-header + non-zero-size check, not a full `pg_restore` integrity verify.
- **Kawarimi Machine migration and in-place upgrade are PostgreSQL-only by design.** Both `export-tenant.sh` / `import-tenant.sh` **refuse a libSQL tenant** rather than risk a silent empty import; a libSQL DB file must be migrated by hand. Intentional limitation, newly introduced with the tooling. In the future, libSQL tenants may be supported as well.
- **Machine migration is a cutover with per-tenant downtime.** `export-tenant.sh` stops the tenant daemon + xmpp-bridge before dumping (PostgreSQL stays up only for `pg_dump`); the agent is down from export until it is started on the new host. Deliberate, to guarantee a consistent and final snapshot. I've used a similar script in the past for migrating my Ironclaw tenants. This current iteration works significantly better than my old script for this though. When migrating tenants, you should plan a maintenance window.
- **The data-orphan guard fires only when the rootless container is absent.** The "rootless container exists but is empty while a root orphan still holds the data" case cannot be distinguished at start time without breaking every legitimate restart, so it is intentionally not guarded there — it is instead covered by `upgrade-preflight.sh` (STOPs on a reachable-but-zero-rows orphan) and `upgrade-tenant.sh --prune-old-root` (refuses to delete the root copy while the rootless DB has zero conversation rows).
- **Documentation reorg follow-ups.** `docs/proposals/DOCUMENTATION_UPDATING_STATUS.md` flags remaining work: `docs/guides/darkirc_channel_for_ironclaw/BUILD_INSTRUCTIONS.md` is the one doc still under `docs/` carrying stale `ironclaw` paths, and a separate out-of-`docs/` IronClaw → LunarWing rename sweep (code/root files) is deliberately deferred. Stale in-repo links inside the immutable `releases/` notes (caused by the reorg moves) were intentionally left as-is and logged, not fixed.

### Carried forward (unchanged in v1.1.5)

- **XMPP inbound file transfer — implemented (incl. encrypted media), live e2e validation still pending.** The full receive pipeline (capability advertisement → OOB / `aesgcm://` extraction → bounded download → decrypt → WASM channel decode) is unit-tested and the bridge builds in release, but it has not been exercised end-to-end against a real server. No XMPP code changed in this range. See `docs/ops/XMPP_KNOWN_ISSUES.md` and `docs/architecture/XMPP_FILE_TRANSFERS.md`. (Carried from v1.1.2/v1.1.3/v1.1.4.)
- **Inbound XMPP downloads have no SSRF guard (deferred).** The client still fetches sender-supplied OOB / `aesgcm://` URLs without blocking private/loopback/metadata IPs; deployments rely on the network boundary and the `ALLOW_PRIVATE_IPS` model. A future phase can reuse `config/helpers.rs::validate_base_url`.
- **Rootless container supervision gap (crash-recovery latency).** On rootless Podman, per-tenant containers (`lunarwing-pg-<t>`, workers) are health-monitored but not *parent-supervised*, so a crash *after* `start()` returns is only recovered by the next 15-minute self-heal sweep (~30 min worst case) rather than in seconds. The proposed `podman wait` babysitter (`docs/proposals/ROOTLESS_PODMAN_CONTAINER_SUPERVISION_GAP.md`) remains deferred.
- **WeeChat health-glob flap.** Because the per-tenant unit is named `lunarwing-weechat-<t>`, an optional/stopped weechat backend matches the `lunarwing-*` health-discovery glob and can report critical (and flap/escalate if auto-restart is attempted). Confirmed pre-existing in the merged code — a fresh `add-tenant` hits it too — and `render-units` is a footgun until it is fixed (`docs/proposals/RENDER_UNITS_SMALL_BUG.md`). Workaround: only render/enable weechat units for tenants that actually use it. (Was targeted for v1.1.5; no fix landed — re-targeted, see *Deferred*.)
- **`podman save | load` image distribution is slow.** Seeding worker images into each tenant's isolated rootless store (`nanocode` ~6 GB, `pebble` ~195 MB) still takes minutes per tenant per image; a shared read-only `additionalimagestore` remains a future optimization.
- **A few non-critical cargo tests fail** (tracked in `docs/proposals/CARGO_TESTS_FIX.md`), and the `e2e_advanced_traces` bootstrap-greeting tests remain among the pre-existing, env-dependent e2e failures. Also, see `docs/bugs/BUG-e2e-bootstrap-greeting-tests.md`. Not addressed by v1.1.5's bug-fix scope.
- **`/api/logs/download` has no UI button.** The endpoint is available as a backend API but the gateway UI "download logs" button has not been added. (Carried from v1.1.2/v1.1.3/v1.1.4; no web-gateway code changed in v1.1.5.)
- **Multica bridge remains pre-release/experimental.** Requires significant improvements, despite technically in a working state; refinements are scheduled for a later feature release (see *Deferred*).
- **DarkIRC WASM channel and adapter are not fully multi-tenant-aware.** The v1.1.3 work namespaced the channel's state under `state/<tenant_id>/…`, but the adapter side and live multi-tenant validation remain outstanding; MT setups do not yet "just work" with DarkIRC. This is explained in more detail in the release notes for 1.1.3
- **Sandbox/external workers may not be fully configured on a fresh tenant.** Tracked as an operator setup gap. (The narrower `nanocode` external-worker config gap, `docs/bugs/MISSING-CONFIG-FOR-NANOCODE.md`, was resolved 2026-06-14 — before this release — so that specific case no longer applies; the broader caveat stands.)

---

## Upgrade Notes

1. **No new database migrations.** v1.1.5 adds no schema changes; the existing migrations from prior releases still run automatically on first startup. **Back up your database before upgrading** as a matter of course. PostgreSQL 15+ remains required (V21's `NULLS NOT DISTINCT` syntax).
2. **Optional new env var: `LLM_TURN_BUDGET_SECS` (default `270`).** Caps the total wall-clock time of one logical LLM call (all retries included) and must stay **below** the `handle_message` turn timeout (`AGENT_HANDLE_MESSAGE_TIMEOUT_SECS`, default `300`). Set `0` to disable. No action is required to adopt the default.
3. **Multi-tenant operators — read the runbooks and preflight first.** The **machine-migration path (`export-tenant.sh` / `import-tenant.sh`)** and the **same-host version upgrade (`upgrade-tenant-version.sh`, v1.0.9 → v1.1.2)** have both been **live-validated on production tenants**; the **rootless-adopt `upgrade-tenant.sh` (v1.1.0 → v1.1.4) has been live-validated**. Before any in-place upgrade, run `ic/scripts/upgrade-preflight.sh --all` and act on any `STOP`/`CAUTION` verdict (its key check is the rootful → rootless data-orphan hazard), treat the first rootless-adopt tenant as a canary, and keep full backups. See `docs/ops/MT-MACHINE-MIGRATION.md` and `docs/proposals/MT-1.1.0-TO-1.1.4-UPGRADE.md`.
4. **The rootful → rootless PostgreSQL flip is guarded.** A plain start that would create a fresh empty rootless PG while a legacy root-store DB still holds the data is now refused by `start_tenant_postgres`. Resolve it deliberately: migrate with `upgrade-tenant.sh`, keep rootful with `LUNARWING_MT_ROOTLESS=false`, or acknowledge an intended fresh DB with `LUNARWING_MT_ACK_ROOTLESS_FLIP=<tenant>`.
5. **Machine migration is PostgreSQL-only and a downtime cutover.** libSQL tenants are refused by the tooling; the tenant is down from export until it is started on the new host. Plan a maintenance window, and keep the old host as the rollback until the new one is verified, especially for production agents.
6. **Enabling fleet-wide self-heal on an existing fleet.** Use `ic/scripts/enable-health-fleet.sh` (it refuses to arm the timer while a tenant daemon is down unless `--allow-down`). Put the Gotify URL/token in `/etc/lunarwing/health.env` (mode `0600`) via `--gotify-token-file` or `LUNARWING_MT_GOTIFY_TOKEN` — never on the command line.

---

## Features and changes deferred to future releases

The full, canonical list lives in **`docs/ops/ROADMAP_2026.MD`** and respects the release cadence (`docs/ops/RELEASE_CADENCE.md`). Near-term highlights:

| Feature | Target |
|---------|--------|
| External Worker planned enhancements | v1.1.6 |
| Remaining migration/upgrade work (extend `upgrade-tenant-version.sh` to source versions older than v1.0.9) | v1.1.6 |
| Multica bridge/channel refinements and agent orchestration workflow improvements; Lunartica UI reskin continuation | v1.1.7 |
| XMPP OMEMO MUC fallback fix *(was targeted v1.1.5 — slipped)* | v1.1.7 |
| XMPP file transfer — remaining polish (live e2e validation, optional SSRF guard, further hardening) *(was targeted v1.1.5 — slipped)* | v1.1.7 |
| Lunarvision K.E.R.S and Vision OCR Sidecar. system setup polishing. Extend health check for LunarVision system *(was targeted v1.1.5 — slipped)* | v1.1.7 |
| Per-tenant WeeChat health-glob gate (fix the flap / `render-units` footgun) | v1.1.7 |
| Rootless Podman per-tenant container parent-supervision babysitter (`podman wait`, crash-recovery latency) | v1.1.7 |
| Drop support for the custom TensorZero proxy (toggle off existing, default-disabled on new); planned input-validation security improvements; remaining `ironclaw` → `lunarwing` renames (WeeChat channel/adapter, Gotify tool) | v1.1.7 |
| Re-add the custom Git WASM workspace tool; TensorZero upgrade + optional tighter integration across deployments + Gateway/ClickHouse/UI healthcheck test expansion | v1.1.8 |

---

## Release Cadence

**A brief note about release cadence.** LunarWing abides by a release cadence to organize `feature`- and `polish`-focused releases — odd-numbered releases (like this one) focus on bug fixes, security improvements, and polishing. For details see `docs/ops/RELEASE_CADENCE.md`. Occasionally, exceptions may be made, but the goal is to stay within this paradigm.

## Testing

### In accordance with developer guidelines, a testing period precedes each release.

#### Testing for this release is **complete**. The pre-release checklist lives in `docs/ops/GOALS_1.1.5.md`; the full checklist is in `docs/ops/PRE-RELEASE-TESTING.md`; automated coverage is driven by `ic/scripts/release-test.sh` and `docs/guides/TESTING_GUIDE.md`. These documents may also reference other documents as well.

##### Once evaluation begins in earnest, no new changes besides urgent fixes will be accepted into staging during the evaluation period.
