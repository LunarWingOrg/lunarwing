# Release Notes for LunarWing v1.1.3 — Codename _TBD_

**Release Date:** TBD (in development)

**Status:** Draft / in progress. This document tracks everything that has changed since the `v1.1.2` tag, and will be finalized when the release is cut. The pre-release checklist lives in `docs/ops/GOALS_1.1.3.md`.

## Overview

Per the release cadence (`docs/ops/RELEASE_CADENCE.md`), **odd-numbered releases focus on bug fixes, security improvements, and polishing**. v1.1.3 is a polish/bug-fix release that begins paying down the multi-tenancy debt called out in the v1.1.2 *Known Issues*, and finalizes housekeeping items that were deferred to this version.

Changes landed so far:

1. **Multi-tenant port schema v2 — migration tooling.** A new `scripts/migrate-ports-to-v2.sh` migration script plus `scripts/MIGRATION_README.md` introduce a per-tenant **port-block** schema to replace the static "reserved slots" model that ran out of room in v1.1.2. This is the *"new ports schema"* item targeted at v1.1.3.
2. **DarkIRC multi-tenant isolation.** The DarkIRC WASM channel now namespaces its persisted workspace state per tenant, the first step toward the *"DarkIRC channel and adapter polishing to make compatible with multi-tenant setups"* roadmap item — directly addressing the v1.1.2 known issue that DarkIRC "does not just work" under multi-tenancy.
3. **Funding metadata finalized.** `funding.json` now carries real Bitcoin and Monero donation addresses (replacing the `TODO_*` placeholders) and is stamped to `v1.1.3` — completing the *"update funding.json with actual payment addresses"* item that was scheduled for this release.
4. **Roadmap & documentation housekeeping.** A roadmap deferral, relocation of the v1.1.2 notes, and a new `docs/releases/` archive of prior release notes.

> **Scope note:** Several v1.1.3 roadmap items — external-worker (Pebble/Codex/Nanocode) polishing, and the *live* end-to-end validation of DarkIRC under multi-tenancy — are still in progress and are not yet reflected on this branch. This document will grow as they land.

---

## Changes

### Multi-Tenant Port Schema v2 — Migration Tooling

v1.1.2 shipped with a flagged *Known Issue*: the static `ports.json` schema (v5) with fixed, individually-named `reserved_N` slots had **run out of reserved slots** — every assigned port was in use — so the scheme needed to be redesigned without disturbing existing tenants' ports. v1.1.3 introduces the migration tooling for a **per-tenant port-block** schema (v2 of the standalone migration format) that scales by adding tenant blocks rather than reserved slots.

- **`scripts/migrate-ports-to-v2.sh`** (new) — Converts a legacy `ports.json` (flat `tenant → {gateway, websocket, telemetry, …}` map) into the new tenant-block structure. It backs up the existing file to a timestamped `ic/config/ports.json.bak.<ts>`, auto-detects the block size from the spacing of existing base ports, derives each service's offset from its current port, fills in default offsets for any unconfigured services, validates the result for port collisions, and logs to `logs/port-migration.log`. It prints a rollback recipe on completion.
- **`scripts/MIGRATION_README.md`** (new) — Operator guide: when to run, prerequisites, before/after schema examples, the service-offset table, benefits, troubleshooting, and rollback steps.

**v2 schema shape.** Each tenant gets a contiguous block (default **10 ports**) addressed by a `base_port` plus per-service `service_offsets`:

| Service | Offset | Port (base = 10000) |
|---------|--------|---------------------|
| gateway | 0 | 10000 |
| websocket | 1 | 10001 |
| telemetry | 2 | 10002 |
| adapter | 3 | 10003 |
| worker | 4 | 10004 |
| debug | 5 | 10005 |
| metrics | 6 | 10006 |
| health | 7 | 10007 |
| reserved_1 | 8 | 10008 |
| reserved_2 | 9 | 10009 |

Existing tenants keep the same ports (offsets are derived from their current assignments), so the migration is designed to be non-disruptive. Per the README, deprecation of the legacy schema is targeted at v1.2.0, and the tenant-isolation guarantee this provides is groundwork the self-healing work (v1.1.6+) will build on.

> **Status:** This is **preview tooling shipped for review and dry-running** — it has **not** been validated end-to-end against a live multi-tenant `ports.json` yet. See *Known Issues* before running it on a production registry.

### DarkIRC — Tenant-Aware Workspace Paths (Multi-Tenant Isolation)

The DarkIRC WASM channel (`darkirc_channel_for_ironclaw/darkirc/src/lib.rs`) was originally written in March, **before** LunarWing gained multi-tenant capability, and v1.1.2 openly flagged that it "was never made to work with multi-tenant setups." Previously the channel persisted its runtime state (`adapter_url`, `dm_policy`, `allow_from`) at **flat, shared workspace keys**, so multiple tenants on one host would clobber each other's DarkIRC configuration. v1.1.3 takes the first step toward fixing this:

- **New `tenant_id` config field** — Added to the channel config (`#[serde(default = "default_tenant_id")]`, so older configs without it keep working). The tenant id is persisted once at a global `state/tenant_id` key on `on_start`.
- **Tenant-namespaced state paths** — New helpers `adapter_url_path()`, `dm_policy_path()`, and `allow_from_path()` write under `state/<tenant_id>/…` instead of a single shared location. `on_start` writes the adapter URL, DM policy, and allow-list under the tenant-scoped paths; `on_poll` and `on_response` read the tenant id first and then resolve the tenant-scoped paths, so each tenant's DarkIRC state is isolated.
- **Cleanup** — The file also picked up an SPDX license header, ASCII-art architecture-diagram cleanup, and a `///` → `//` doc-comment pass (no behavior change).

> **Status:** Implemented at the channel level; this is **in-progress** multi-tenant work and has **not** been validated end-to-end against a live multi-tenant DarkIRC deployment (adapter + DarkFi node). It does not by itself make the DarkIRC *adapter* tenant-aware. See *Known Issues*.

### Roadmap Update

- **`docs/ops/ROADMAP_2026.MD`** — *Lunarvision K.E.R.S. system setup polishing* was deferred from **v1.1.3 → v1.1.5**, regrouping it with the other late-1.1.x polishing work. The remaining v1.1.3 roadmap entries (external-worker polishing; funding.json finalization) are unchanged; funding.json is now complete (above).

### Documentation & Housekeeping

- **Release-notes archive** — Previous notes were consolidated into a new **`docs/releases/`** directory (`RELEASE-v1.1.0.md`, `RELEASE-v1.1.1.md`, `RELEASE-v1.1.2.md`), and the root **`RELEASE-v1.1.2.md` was relocated to `docs/ops/RELEASE-v1.1.2.md`**, continuing the convention (begun in v1.1.1) that historical release notes live under `docs/`.
- **`docs/ops/GOALS_1.1.3.md`** — The v1.1.3 pre-release checklist (run automated tests, bump crate versions to 1.1.3, continue health-check/self-healing work, finalize these notes, cut the release branch/tag).

## Bug Fixes

- **DarkIRC tenant state collision (multi-tenant).** The DarkIRC channel stored `adapter_url` / `dm_policy` / `allow_from` at shared workspace keys, so co-located tenants overwrote each other's DarkIRC state. State is now namespaced under `state/<tenant_id>/…`. (First step toward full multi-tenant DarkIRC support — see *Changes* and *Known Issues*.)
- **Spurious `wasm-tools` build warning (multi-tenant).** `build-tenant --with-wasm` printed `wasm-tools not found` and skipped the componentize/strip step even when `wasm-tools` was installed. The cause: `install_wasm_tenant` runs as the admin/root user, but `add-tenant` installs `wasm-tools` into the *tenant's* `~/.cargo/bin`, which is not on root's `PATH`. The installer now resolves the tenant's `wasm-tools` first (falling back to the admin `PATH`), so stripping runs in the normal multi-tenant flow. When `wasm-tools` is genuinely absent the step is still skipped — the raw `wasm32-wasip2` artifact is already a valid component, so functionality is unaffected — but it now logs a clear, benign note instead of an alarming "not found" warning (same wording aligned in the `lunarwing-xmpp-test-env.sh` harness). Separately, `ic/build.rs` no longer mislabels a fallback-copy I/O error as "wasm-tools not found."
- **Spurious skill-load warning for frontmatter-less markdown.** Skill discovery logged a `Failed to load skill … Missing YAML frontmatter` **warning** on startup for any `SKILL.md` that lacked YAML frontmatter — most commonly a legacy Ironclaw `GOTIFYSKILL.md`/`SKILL.md` carried over during migration. Discovery now distinguishes a file that *isn't* a skill (no frontmatter at all → skipped quietly at `debug`) from one that *is* a malformed skill (invalid YAML, bad name, empty body → still warned), via a new `SkillRegistryError::MissingFrontmatter`. Explicit `skill_install` still surfaces a loud parse error by design. Fixed in both skill engines — the classic `crate::skills` registry and the Engine V2 `lunarwing_skills` crate used by the bridge. Functionality was never affected (the Gotify WASM tool is unrelated to the skills loader).
- **Pairing instructions referenced the old `ironclaw` binary.** When an unknown user DMed the agent, the pairing-code reply told them to run `ironclaw pairing approve …` — a stale leftover from the `ironclaw → lunarwing` binary rename, so the command handed to the user was simply wrong. Fixed in the WeeChat channel (the reported case) with a regression test; the identical leftover was also corrected in the Telegram channel (regression-tested) and the DarkIRC channel. The native Signal and XMPP channels already emitted the correct `lunarwing` command. See `docs/proposals/WEECHAT_CHANNEL_PAIRING_CHANGE_OUTPUTTED_COMMAND_IS_WRONG.md`.

> This release is predominantly polish and forward-looking tooling; the bulk of the substantive runtime fixes from the 1.1.x line landed in v1.1.1 and v1.1.2. Additional fixes (external-worker polishing, DarkIRC adapter MT work) are expected to land in this release before it is finalized.

## Documentation

- `scripts/MIGRATION_README.md` — New operator guide for the port-schema v2 migration (above).
- `docs/releases/` — New archive directory containing `RELEASE-v1.1.0.md`, `RELEASE-v1.1.1.md`, and `RELEASE-v1.1.2.md`; root `RELEASE-v1.1.2.md` relocated to `docs/ops/`.
- `docs/ops/ROADMAP_2026.MD` — Lunarvision K.E.R.S. polishing moved to v1.1.5.
- `docs/ops/GOALS_1.1.3.md` — v1.1.3 pre-release checklist.

## Known Issues (not a complete list — see `docs/bugs` and `docs/proposals` for more)

- **Port schema v2 migration is unvalidated preview tooling.** `migrate-ports-to-v2.sh` has **not** been run end-to-end against a live `ports.json`. In particular, its embedded Python is in **single-quoted heredocs** (`<< 'PYTHON_SCRIPT'` / `<< 'VALIDATE_SCRIPT'`), so the shell does not interpolate `${PORTS_FILE}` / `$(date …)` inside them — the migration and validation blocks need a fix (and a dry run on a backup) before use on a production registry. **Back up `ports.json` first** (the script also makes its own timestamped backup). Treat as a starting point, not a turnkey migration!
- **DarkIRC multi-tenancy is partially addressed, not done.** The WASM channel now isolates state per tenant, but the change has not been validated against a live multi-tenant deployment, and the DarkIRC **adapter** (the Python/HTTP side) is not yet tenant-aware. DarkIRC does not yet "just work" under multi-tenancy; full compatibility remains a v1.1.3-line goal.
- **last two related to first two** - see last two
- **Crate versions not yet bumped.** The workspace is still at `1.1.2` (`ic/Cargo.toml`); the bump to `1.1.3` is a pre-release checklist item (`docs/ops/GOALS_1.1.3.md`).
- **Carried forward from v1.1.2** (see `docs/ops/RELEASE-v1.1.2.md` for full detail): XMPP inbound file transfer is implemented but awaits live end-to-end validation and has no SSRF guard; self-healing is verified only by dry-run + unit tests and ships dormant (installed but not auto-scheduled, not wired into tenant provisioning); sandbox/external workers may not be fully configured on a fresh tenant; the Multica bridge remains pre-release/experimental; and the `e2e_advanced_traces` bootstrap-greeting tests remain among the pre-existing, env-dependent e2e failures.
- **XMPP inbound file transfer — implemented (incl. encrypted media), live e2e validation pending.** The full receive pipeline (capability advertisement → OOB/`aesgcm://` extraction → bounded download → decrypt → WASM channel decode) is unit-tested and the bridge builds in release, but it has **not** yet been exercised end-to-end against a real server (Conversations/Gajim → agent over a working XEP-0363 host). This is the one real file-transfer caveat for the release. See `docs/ops/XMPP_KNOWN_ISSUES.md` and `docs/architecture/XMPP_FILE_TRANSFERS.md`.
- **Inbound XMPP downloads have no SSRF guard (deferred).** The client fetches sender-supplied OOB / `aesgcm://` URLs without blocking private/loopback/metadata IPs. Deployments rely on the network boundary and the `ALLOW_PRIVATE_IPS` model; a future phase can reuse `config/helpers.rs::validate_base_url`.
- **Self-healing verified by dry-run + unit tests, not against live running services.** The self-heal hardening and chaos suite were verified on a dev host (dry-run + the mock init system + unit tests); the restart → verify → escalate path has **not** been exercised against running services on a real multi-tenant deployment. (Tracks with the v1.1.8 "expansion of healthcheck tests for ClickHouse" roadmap item.)
- **Self-heal is installed but not auto-scheduled, and not wired into provisioning.** `install-lunarwing-watchdog.sh` copies the self-heal / health-cron scripts into `/usr/local/sbin` but enables no timer for them, and the repo ships no health-check `.timer`/`.service` unit — so a fresh host has self-healing **dormant** until an operator both runs the installer and schedules `cron-wrapper.sh`. Tenant provisioning (`lunarwing-mt-admin.sh add-tenant`) installs none of it (it's a once-per-host concern). See `docs/architecture/SELF_HEAL_DEPLOYMENT_WIRING.md` (gaps G1/G2). This will kept in its current state until further polishing and testing is done with self-healing.
- **Logs download endpoint has no UI button** — `/api/logs/download` is available as a backend API but the corresponding gateway UI "download logs" button has not been added yet.
- **`e2e_advanced_traces` bootstrap-greeting tests failing** — `bootstrap_greeting_fires` and `bootstrap_onboarding_clears_bootstrap` fail because the static bootstrap greeting doesn't arrive in the test rig. Pre-existing (surfaced once the v1.1.1 `cargo test` compile blocker was fixed); not LLM/`StubLlm`-related. One of the 16 pre-existing, env-dependent e2e failures confirmed unchanged by this release's work. See `docs/bugs/BUG-e2e-bootstrap-greeting-tests.md`.
- **Multica Bridge** — May require significant improvements; remains pre-release/experimental. More work on this is scheduled for the next two releases.
- **Multi-tenant admin script** — A flag exists to set an API key for a model endpoint, but no equivalent flag exists to set an HTTP URL automatically via this method.
- **Sandbox workers and external workers may not be fully configured at start when creating a new tenant or setting up a new multi-tenant instance** - This is actually already documented and should be tracked as an item to fix here for future releases since it seems fairly important.
- **Last two related to first two** - see first two
- **DarkIRC WASM channel and adapter was never made to work with multi-tenant setups** - Can admit that this was partially an oversight. Shipped new DarkIRC code in this release but the original channel and adapter was created back in March, long before multi-tenant capability was built. This will need to be rectified in the next release. At this time, multi-tenant setups do not "just work" with DarkIRC.
- **Speaking of Multi-Tenant Setups** - The current static ports.json schema with reserved slots has officially run out of `reserved` slots, as all of the assigned ports are now in use for something. Sadly, this means the current ports.json v5 system needs to be thrown out and redone. Ideas include: 1) Dynamic Port Pool 2) Per-Tenant Port Blocks 3) Service-Type Hierarchy - The best idea currently is some combination of 2 and 3. We already have versioned port schemas, so a method for upgrading v5 to a v6 would be doable. If we can figure out a way to do this without messing with current tenant's ports, then a solution will exist for this in the future and it will solve this problem as well as the *DarkIRC WASM channel and adapter was never made to work with multi-tenant setups* known issue.


## Upgrade Notes

1. **No new database migrations.** v1.1.3 adds no schema changes; the existing V18–V21 migrations from prior releases still run automatically on first startup. **Back up your database before upgrading** as a matter of course. PostgreSQL 15+ remains required for V21's `NULLS NOT DISTINCT` syntax.
2. **Port schema v2 migration is opt-in (and preview).** Existing multi-tenant hosts continue to run on the current `ports.json` unchanged. Do **not** run `scripts/migrate-ports-to-v2.sh` on a live registry yet — see *Known Issues*. When validated, run it with all LunarWing services stopped, keep the timestamped backup, and restart services after verifying no collisions.
3. **DarkIRC config gains an optional `tenant_id`.** The field defaults via `default_tenant_id()` and is `#[serde(default)]`, so existing DarkIRC channel configs keep working without changes. Multi-tenant DarkIRC operators should set it per tenant once the adapter-side work and live validation land.
4. **Crate version bump pending.** Workspace crates must be bumped from `1.1.2` to `1.1.3` before tagging (`docs/ops/GOALS_1.1.3.md`).
5. **Funding addresses live.** `funding.json` now contains real BTC/XMR donation addresses; no action required for operators.

## Features and changes deferred to future releases

The full, canonical list lives in **`docs/ops/ROADMAP_2026.MD`**. Items respect the release cadence (`docs/ops/RELEASE_CADENCE.md`): odd-numbered releases focus on bug fixes / security / polish, even-numbered releases on features, and majors (1.2.0+) on large overhauls. Near-term highlights:

| Feature | Target |
|---------|--------|
| External worker (Pebble, Codex, Nanocode) polishing; complete DarkIRC multi-tenant compatibility (adapter + live e2e) | v1.1.3 (in progress) |
| Multica bridge/channel refinements; Lunartica UI reskin; Lunarvision K.E.R.S. setup polishing | v1.1.4 / v1.1.5 |
| XMPP file transfer remaining polish (live e2e, optional SSRF guard); XMPP OMEMO MUC fallback fix; drop the custom TensorZero proxy | v1.1.5 |
| Further development and ironing out of the new self-healing infrastructure | v1.1.6 |
| Self-healing epic (first-class, wired-in) | v1.2.0 |

## Release Cadence

*A brief note about release cadence*

### LunarWing abides by a release cadence. This helps to organize introduction of new `feature` and `polish` focused releases.
### For more information, please see:
* docs/ops/RELEASE_CADENCE.md
#### Occasionally, exceptions are made to the release cadence guidelines, but the goal is to try to stay within this paradigm.

## Testing

*In accordance with developer guidelines, a brief testing period must begin before each release.*

*Testing for this release has **not yet commenced.** The pre-release checklist lives in `docs/ops/GOALS_1.1.3.md`; the full checklist is in `docs/ops/PRE-RELEASE-TESTING.md`; automated coverage is driven by `ic/scripts/release-test.sh` and `docs/guides/TESTING_GUIDE.md`. Per the checklist, the port-schema v2 migration and the DarkIRC multi-tenant change must be exercised before this release is cut.*

*Once evaluation begins, no new changes besides urgent fixes will be accepted into staging during the evaluation period.*
