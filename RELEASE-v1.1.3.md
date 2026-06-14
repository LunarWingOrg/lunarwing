# Release Notes for LunarWing v1.1.3 — Codename `Dark Forest`

**Release Date:** 2026-06-15

## Overview

Per the release cadence (`docs/ops/RELEASE_CADENCE.md`), **odd-numbered releases focus on bug fixes, security improvements, and polishing**. v1.1.3 is a polish/bug-fix release that begins paying down the multi-tenancy debt called out in the v1.1.2 *Known Issues*, and finalizes certain housekeeping items that were deferred to this version.

---

## Changes

### Multi-Tenant Port Schema v6 — Capacity Expansion

v1.1.2 flagged a *Known Issue*: the multi-tenant port registry (`/etc/lunarwing/ports.json`) packs each tenant into a fixed **10-port block** (`block_size: 10`), and the v1→v5 migrations had already assigned all ten offsets (`gateway`, `http`, `bridge`, `postgres`, `proxy`, `weechat`, `orchestrator`, `nanocode_wss`, `pebble_wss`, `weechat_adapter`) — leaving **no free slot for a new service type**. Existing tenants are packed every 10 ports, so their blocks can't be widened in place without colliding with the next tenant. v1.1.3 adds a **v5 → v6** migration that expands capacity *without moving any existing port*.

- **`ports_migrate()` in `ic/scripts/lunarwing-mt-admin.sh`** — gains a `v5 → v6` step alongside the existing v1→v5 chain (same in-place `jq` + atomic temp-file swap, keyed on `.version`), so the upgrade applies automatically on the next admin run. `ports_allocate()` now also writes the extended block for newly created tenants.
- **`ic/scripts/migrate-ports-v6.sh`** (new) — standalone operator script modeled on `migrate-ports-v5.sh` for running the v5→v6 migration explicitly. It is idempotent, takes a timestamped backup, validates the result for port collisions, and swaps the registry in atomically **only** if validation passes (printing a rollback recipe). Supports a dry run on a copy via `PORTS_REGISTRY=/path/to/copy.json`.
- The earlier broken preview script `scripts/migrate-ports-to-v2.sh` and its `MIGRATION_README.md` were **removed** — they targeted a `ports.json` shape that never existed, wrote to the wrong path, stamped a non-existent `"schema_version": "v2"`, and crashed on single-quoted heredocs.

**v6 schema shape.** Every tenant keeps its existing `base_port` and `ports` block **untouched**. v6 adds a parallel block mirrored into a second range (`extended_range: 20000–29999`): each tenant gains `extended_base = base_port − range.start + extended_range.start` and an `extended_ports` object of ten fresh `reserved_N` slots. Because base ports are unique and spaced ≥ `block_size` apart, the mirrored extended blocks never overlap each other or the original range. Future service additions rename `extended_ports.reserved_N → <service>` — the same pattern the v2→v5 migrations used with the original reserved slots, now continued in the new range.

> **Status:** Implemented and verified against synthetic v5 registries (existing ports confirmed untouched, extended blocks collision-free, migration idempotent). It has **not** yet been run against a live production `/etc/lunarwing/ports.json`. Back up the registry and dry-run on a copy before applying — see *Upgrade Notes*.

### DarkIRC — Tenant-Aware Workspace Paths (Multi-Tenant Isolation)

The DarkIRC WASM channel (`darkirc_channel_for_ironclaw/darkirc/src/lib.rs`) was originally written in March, **before** LunarWing gained multi-tenant capability, and v1.1.2 openly flagged that it "was never made to work with multi-tenant setups." Previously the channel persisted its runtime state (`adapter_url`, `dm_policy`, `allow_from`) at **flat, shared workspace keys**, so multiple tenants on one host would clobber each other's DarkIRC configuration. v1.1.3 takes the first step toward fixing this:

- **New `tenant_id` config field** — Added to the channel config (`#[serde(default = "default_tenant_id")]`, so older configs without it keep working). The tenant id is persisted once at a global `state/tenant_id` key on `on_start`.
- **Tenant-namespaced state paths** — New helpers `adapter_url_path()`, `dm_policy_path()`, and `allow_from_path()` write under `state/<tenant_id>/…` instead of a single shared location. `on_start` writes the adapter URL, DM policy, and allow-list under the tenant-scoped paths; `on_poll` and `on_response` read the tenant id first and then resolve the tenant-scoped paths, so each tenant's DarkIRC state is isolated.
- **Cleanup** — The file also picked up an SPDX license header, ASCII-art architecture-diagram cleanup, and a `///` → `//` doc-comment pass (no behavior change).

### External Worker Polishing and improvements

> **Better integration with multi-tenant admin**

> **Status:** Implemented at the channel level; this is **in-progress** multi-tenant work and has **not** been validated end-to-end against a live multi-tenant DarkIRC deployment (adapter + DarkFi node). It does not by itself make the DarkIRC *adapter* tenant-aware. See *Known Issues*.

### Roadmap Update

- **`docs/ops/ROADMAP_2026.MD`** — *Lunarvision K.E.R.S. system setup polishing* was deferred from **v1.1.3 → v1.1.5**, regrouping it with the other late-1.1.x polishing work.

### Documentation & Housekeeping

- **Release-notes archive** — Previous notes were consolidated into a new **`docs/releases/`** directory (`RELEASE-v1.1.0.md`, `RELEASE-v1.1.1.md`, `RELEASE-v1.1.2.md`), and the root **`RELEASE-v1.1.2.md` was relocated to `docs/ops/RELEASE-v1.1.2.md`**, continuing the convention (begun in v1.1.1) that historical release notes live under `docs/`.
- **`docs/ops/GOALS_1.1.3.md`** — The v1.1.3 pre-release checklist (run automated tests, bump crate versions to 1.1.3, continue health-check/self-healing work, finalize these notes, cut the release branch/tag).
- **WASM channel crate metadata normalized.** All five channel crates — `darkirc`, `telegram`, `weechat`, `xmpp`, `multica` — were aligned to `version = "1.1.3"`, `license = "AGPL-3.0-or-later"`, and a *LunarWing* (no longer "IronClaw") description. This extends the AGPL license reconciliation to the channel crates, which the earlier sweep had missed: several still carried `MIT`/`Apache-2.0`, and `multica` had no `license` field at all.

## Bug Fixes

- **DarkIRC tenant state collision (multi-tenant).** The DarkIRC channel stored `adapter_url` / `dm_policy` / `allow_from` at shared workspace keys, so co-located tenants overwrote each other's DarkIRC state. State is now namespaced under `state/<tenant_id>/…`. (First step toward full multi-tenant DarkIRC support — see *Changes* and *Known Issues*.)
- **Spurious `wasm-tools` build warning (multi-tenant).** `build-tenant --with-wasm` printed `wasm-tools not found` and skipped the componentize/strip step even when `wasm-tools` was installed. The cause: `install_wasm_tenant` runs as the admin/root user, but `add-tenant` installs `wasm-tools` into the *tenant's* `~/.cargo/bin`, which is not on root's `PATH`. The installer now resolves the tenant's `wasm-tools` first (falling back to the admin `PATH`), so stripping runs in the normal multi-tenant flow. When `wasm-tools` is genuinely absent the step is still skipped — the raw `wasm32-wasip2` artifact is already a valid component, so functionality is unaffected — but it now logs a clear, benign note instead of an alarming "not found" warning (same wording aligned in the `lunarwing-xmpp-test-env.sh` harness). Separately, `ic/build.rs` no longer mislabels a fallback-copy I/O error as "wasm-tools not found."
- **Spurious skill-load warning for frontmatter-less markdown.** Skill discovery logged a `Failed to load skill … Missing YAML frontmatter` **warning** on startup for any `SKILL.md` that lacked YAML frontmatter — most commonly a legacy Ironclaw `GOTIFYSKILL.md`/`SKILL.md` carried over during migration. Discovery now distinguishes a file that *isn't* a skill (no frontmatter at all → skipped quietly at `debug`) from one that *is* a malformed skill (invalid YAML, bad name, empty body → still warned), via a new `SkillRegistryError::MissingFrontmatter`. Explicit `skill_install` still surfaces a loud parse error by design. Fixed in both skill engines — the classic `crate::skills` registry and the Engine V2 `lunarwing_skills` crate used by the bridge. Functionality was never affected (the Gotify WASM tool is unrelated to the skills loader).
- **Pairing instructions referenced the old `ironclaw` binary.** When an unknown user DMed the agent, the pairing-code reply told them to run `ironclaw pairing approve …` — a stale leftover from the `ironclaw → lunarwing` binary rename, so the command handed to the user was simply wrong. Fixed in the WeeChat channel (the reported case) with a regression test; the identical leftover was also corrected in the Telegram channel (regression-tested) and the DarkIRC channel. The native Signal and XMPP channels already emitted the correct `lunarwing` command. See `docs/proposals/WEECHAT_CHANNEL_PAIRING_CHANGE_OUTPUTTED_COMMAND_IS_WRONG.md`.
- **DarkIRC channel didn't build after the tenant-isolation change.** Follow-up fixes to the *DarkIRC — Tenant-Aware Workspace Paths* change (above), which no longer compiled against the current `wit/channel.wit` and shipped with tenant-path bugs. The wit `Guest` export was renamed back (`on_response` → `on_respond`); the inbound allow-list restored its `pairing_read_allow_from` host call (a botched edit had replaced it with a no-op double `workspace_read` that didn't type-check); a dead, shadowed `dm_policy` read was removed; and the response path (`on_status`, `send_response_to_nick`) now resolves the adapter URL from the tenant-scoped `adapter_url_path(tenant_id)` instead of the sender's nick. The crate also moved to Rust **edition 2021** (it uses no 2024 features — this clears the `wit_bindgen` `unsafe_op_in_unsafe_fn` warnings and matches the other channels), and a stray double `.enumerate()` in the split tests was fixed. DarkIRC now builds clean for `wasm32-wasip2` (zero warnings) with its unit tests passing; live multi-tenant behavior still needs end-to-end validation (see *Known Issues*).

## Documentation

- `ic/scripts/migrate-ports-v6.sh` — New standalone v5→v6 port-registry migration (above); self-documenting header with usage, dry-run, and rollback steps.
- `docs/releases/` — New archive directory containing `RELEASE-v1.1.0.md`, `RELEASE-v1.1.1.md`, and `RELEASE-v1.1.2.md`; root `RELEASE-v1.1.2.md` relocated to `docs/ops/`.
- `docs/ops/ROADMAP_2026.MD` — Lunarvision K.E.R.S. polishing moved to v1.1.5.
- `docs/ops/GOALS_1.1.3.md` — v1.1.3 pre-release checklist.

## Known Issues (not a complete list — see `docs/bugs` and `docs/proposals` for more)

- **Carried forward from v1.1.2** (see `docs/ops/RELEASE-v1.1.2.md` for full detail): XMPP inbound file transfer is implemented but awaits live end-to-end validation and has no SSRF guard; self-healing is verified only by dry-run + unit tests and ships dormant (installed but not auto-scheduled, not wired into tenant provisioning); sandbox/external workers may not be fully configured on a fresh tenant; the Multica bridge remains pre-release/experimental; and the `e2e_advanced_traces` bootstrap-greeting tests remain among the pre-existing, env-dependent e2e failures.
- **XMPP inbound file transfer — implemented (incl. encrypted media), live e2e validation pending.** The full receive pipeline (capability advertisement → OOB/`aesgcm://` extraction → bounded download → decrypt → WASM channel decode) is unit-tested and the bridge builds in release, but it has **not** yet been exercised end-to-end against a real server (Conversations/Gajim → agent over a working XEP-0363 host). This is the one real file-transfer caveat for the release. See `docs/ops/XMPP_KNOWN_ISSUES.md` and `docs/architecture/XMPP_FILE_TRANSFERS.md`.
- **Inbound XMPP downloads have no SSRF guard (deferred).** The client fetches sender-supplied OOB / `aesgcm://` URLs without blocking private/loopback/metadata IPs. Deployments rely on the network boundary and the `ALLOW_PRIVATE_IPS` model; a future phase can reuse `config/helpers.rs::validate_base_url`.
- **Self-healing verified by dry-run + unit tests, not against live running services.** The self-heal hardening and chaos suite were verified on a dev host (dry-run + the mock init system + unit tests); the restart → verify → escalate path has **not** been exercised against running services on a real multi-tenant deployment. (Tracks with the v1.1.8 "expansion of healthcheck tests for ClickHouse" roadmap item.)
- **Self-heal is installed but not auto-scheduled, and not wired into provisioning.** `install-lunarwing-watchdog.sh` copies the self-heal / health-cron scripts into `/usr/local/sbin` but enables no timer for them, and the repo ships no health-check `.timer`/`.service` unit — so a fresh host has self-healing **dormant** until an operator both runs the installer and schedules `cron-wrapper.sh`. Tenant provisioning (`lunarwing-mt-admin.sh add-tenant`) installs none of it (it's a once-per-host concern). See `docs/architecture/SELF_HEAL_DEPLOYMENT_WIRING.md` (gaps G1/G2). This will kept in its current state until further polishing and testing is done with self-healing.
- **Logs download endpoint has no UI button** — `/api/logs/download` is available as a backend API but the corresponding gateway UI "download logs" button has not been added yet.
- **`e2e_advanced_traces` bootstrap-greeting tests failing** — `bootstrap_greeting_fires` and `bootstrap_onboarding_clears_bootstrap` fail because the static bootstrap greeting doesn't arrive in the test rig. Pre-existing (surfaced once the v1.1.1 `cargo test` compile blocker was fixed); not LLM/`StubLlm`-related. One of the 16 pre-existing, env-dependent e2e failures confirmed unchanged by this release's work. See `docs/bugs/BUG-e2e-bootstrap-greeting-tests.md`.
- **Multica Bridge** — May require significant improvements; remains pre-release/experimental. More work on this is scheduled for the next two releases.

## Upgrade Notes

1. **No new database migrations.** v1.1.3 adds no schema changes; the existing V18–V21 migrations from prior releases still run automatically on first startup. **Back up your database before upgrading** as a matter of course. PostgreSQL 15+ remains required for V21's `NULLS NOT DISTINCT` syntax.
2. **Port schema v6 migration (additive, non-disruptive).** The v5 → v6 migration only *adds* an `extended_range` block per tenant; existing `base_port`/`ports` are untouched, so it does not re-allocate tenants. It applies automatically via `ports_migrate()` on the next `lunarwing-mt-admin.sh` run, or explicitly via `sudo ic/scripts/migrate-ports-v6.sh`. **Back up `/etc/lunarwing/ports.json` and dry-run on a copy first** (`PORTS_REGISTRY=/path/to/copy.json ./migrate-ports-v6.sh`); the standalone script also takes its own timestamped backup and aborts on any port collision.
3. **DarkIRC config gains an optional `tenant_id`.** The field defaults via `default_tenant_id()` and is `#[serde(default)]`, so existing DarkIRC channel configs keep working without changes. Multi-tenant DarkIRC operators should set it per tenant once the adapter-side work and live validation land.

## Features and changes deferred to future releases

The full, canonical list lives in **`docs/ops/ROADMAP_2026.MD`**. Items respect the release cadence (`docs/ops/RELEASE_CADENCE.md`): odd-numbered releases focus on bug fixes / security / polish, even-numbered releases on features, and majors (1.2.0+) on large overhauls. Near-term highlights:

| Feature | Target |
|---------|--------|
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

*Testing for this release **commenced.** The pre-release checklist lives in `docs/ops/GOALS_1.1.3.md`; the full checklist is in `docs/ops/PRE-RELEASE-TESTING.md`; automated coverage is driven by `ic/scripts/release-test.sh` and `docs/guides/TESTING_GUIDE.md`.*

*Once evaluation begins, no new changes besides urgent fixes will be accepted into staging during the evaluation period.*
