# LunarWing Documentation

All project documentation, organized by category. Archived material lives under
[`internal/history/`](internal/history/) (superseded LunarWing docs) and
[`internal/vendored/`](internal/vendored/) (third-party upstream copies).

## Directory Structure

### 📐 [`architecture/`](architecture/)

System design and technical architecture documents (the authoritative specs).

| File | Description |
|------|-------------|
| [`ENGINE-V2.md`](architecture/ENGINE-V2.md) | V2 engine: threads, capabilities, CodeAct, gates, learning missions (linked from `CLAUDE.md`) |
| [`SSH_AGENT_HARNESS.md`](architecture/SSH_AGENT_HARNESS.md) | SSH agent harness: per-tenant in-process ssh-agent, encrypted key store, worker socket injection, host-key model |
| [`SSH_DELIVERY_MECHANISMS.md`](architecture/SSH_DELIVERY_MECHANISMS.md) | The three ways the agent runs SSH: worker mode, the `ssh`/`ssh_git` built-in tools, and the WASM `ssh` tool — when-to-use, security, enablement |
| [`SEMANTIC-MEMORY-SEARCH.md`](architecture/SEMANTIC-MEMORY-SEARCH.md) | Hybrid FTS + vector memory search, RRF fusion, embeddings (linked from `CLAUDE.md`) |
| [`WEECHAT-CHANNEL-ARCHITECTURE.md`](architecture/WEECHAT-CHANNEL-ARCHITECTURE.md) | WeeChat channel: components, message flow, ingestion/latency, config precedence, known issues |
| [`XMPP_FILE_TRANSFERS.md`](architecture/XMPP_FILE_TRANSFERS.md) | XMPP file transfer (XEP-0363/0066/0454): inbound/outbound, OMEMO, limits |
| [`SELF_HEAL_DEPLOYMENT_WIRING.md`](architecture/SELF_HEAL_DEPLOYMENT_WIRING.md) | How the infra health-check + self-heal pipeline is installed/scheduled (host-level, not per-tenant) |
| [`ATOMICBOOL_DEEPER_PROPAGATION.md`](architecture/ATOMICBOOL_DEEPER_PROPAGATION.md) | Design note: deeper AtomicBool suppression-flag propagation (deferred) |

---

### 📖 [`guides/`](guides/)

How-to guides, build instructions, and setup walkthroughs.

| File | Description |
|------|-------------|
| [`MT-ADMIN-QUICKSTART.md`](guides/MT-ADMIN-QUICKSTART.md) | `lunarwing-mt-admin.sh` multi-tenant quickstart |
| [`CREATE_TENANT_NEW_SCRIPT.md`](guides/CREATE_TENANT_NEW_SCRIPT.md) | Creating a tenant with the new script |
| [`MIGRATE_IRONCLAW_TO_LUNARWING.md`](guides/MIGRATE_IRONCLAW_TO_LUNARWING.md) | Migrate an existing IronClaw PostgreSQL instance to LunarWing |
| [`MIGRATE_IRONCLAW_TO_MT.md`](guides/MIGRATE_IRONCLAW_TO_MT.md) | PostgreSQL migration to multi-tenant |
| [`MIGRATE_IRONCLAW_LIBSQL_TO_MT.md`](guides/MIGRATE_IRONCLAW_LIBSQL_TO_MT.md) | libSQL cross-backend migration to multi-tenant |
| [`TESTING_GUIDE.md`](guides/TESTING_GUIDE.md) | Pre-release test checklist + automated release testing (linked from `CLAUDE.md`) |
| [`AI-CODE-CONTRIBUTION-POLICY.md`](guides/AI-CODE-CONTRIBUTION-POLICY.md) | AI code contribution policy (effective July 7th, 2026) |
| [`ENABLING_DEV_TOOLS.md`](guides/ENABLING_DEV_TOOLS.md) | Enabling filesystem read/write and shell execution for a tenant |
| [`SSH-TOOL-TESTING.md`](guides/SSH-TOOL-TESTING.md) | Test prompts for validating the three SSH delivery mechanisms (v1.1.8) |
| [`EMBEDDINGS_SETUP.md`](guides/EMBEDDINGS_SETUP.md) | Embedding provider config (OpenAI-compatible, Ollama, NEAR AI) |
| [`VISION_OCR_SIDECAR.md`](guides/VISION_OCR_SIDECAR.md) | Vision/OCR sidecar service overview |
| [`GENTOO_PACKAGE_LIST.md`](guides/GENTOO_PACKAGE_LIST.md) | Gentoo package list + rootless-podman MT prerequisites |
| [`MULTICA_DEPLOYMENT.md`](guides/MULTICA_DEPLOYMENT.md) | Multica/Lunartica deployment guide |
| [`human-delay-mode.md`](guides/human-delay-mode.md) | Human-delay mode overview |
| [`DEBUG_LOG.md`](guides/DEBUG_LOG.md) | Catalog of debug/info log points by `file:line` |
| [`darkirc_channel_for_lunarwing/BUILD_INSTRUCTIONS.md`](guides/darkirc_channel_for_lunarwing/BUILD_INSTRUCTIONS.md) | DarkIRC channel build instructions |
| [`darkirc_channel_for_lunarwing/DARKIRC_BUILD_GUIDE.md`](guides/darkirc_channel_for_lunarwing/DARKIRC_BUILD_GUIDE.md) | Full DarkIRC build guide |
| [`darkirc_channel_for_lunarwing/DARKIRC_MT_ADAPTER.md`](guides/darkirc_channel_for_lunarwing/DARKIRC_MT_ADAPTER.md) | DarkIRC multitenant adapter (adapter-only milestone) |
| [`lunarwing_weechat_wss/README.md`](guides/lunarwing_weechat_wss/README.md) | WeeChat WSS channel overview |
| [`lunarwing_weechat_wss/weechat_relay/INSTALL.md`](guides/lunarwing_weechat_wss/weechat_relay/INSTALL.md) | WeeChat relay installation |
| [`lunarwing_weechat_wss/weechat_relay/TROUBLESHOOTING.md`](guides/lunarwing_weechat_wss/weechat_relay/TROUBLESHOOTING.md) | WeeChat relay troubleshooting |
| [`gotify-wasm/README.md`](guides/gotify-wasm/README.md) | Gotify WASM tool |
| [`ic_sm/README.md`](guides/ic_sm/README.md) | Secret manager (`ic_sm`) |
| [`git-lunarwing-unix-socket-repl-server-repo/README.md`](guides/git-lunarwing-unix-socket-repl-server-repo/README.md) | REPLv2 Unix-socket REPL server |
| [`nanocode-config/README.md`](guides/nanocode-config/README.md) | Nanocode custom-config overview |

---

### 🛠️ [`ops/`](ops/)

Deployment, operations, multitenancy, and production guides.

| File | Description |
|------|-------------|
| [`MULTITENANCY-PRODUCTION.md`](ops/MULTITENANCY-PRODUCTION.md) | Production multi-tenancy walkthrough |
| [`TENANT-CONFIGURATION.md`](ops/TENANT-CONFIGURATION.md) | Per-tenant configuration reference (env, LLM, XMPP, ports) |
| [`TENANT-RENAME-MIGRATION-1.1.9.md`](ops/TENANT-RENAME-MIGRATION-1.1.9.md) | Upgrading 1.1.7/1.1.8 tenants across the 1.1.9 directory renames |
| [`TEST-PLAN-UPGRADED-TENANT-1.1.9.md`](ops/TEST-PLAN-UPGRADED-TENANT-1.1.9.md) | Validated test plan for the upgraded-tenant path |
| [`MULTITENANCY-HARNESS.md`](ops/MULTITENANCY-HARNESS.md) | Multi-tenant test harness guide |
| [`HARNESS-SINGLE-TENANT.md`](ops/HARNESS-SINGLE-TENANT.md) | Single-tenant test harness guide |
| [`guide-for-spin-up-gentoo-tenants.md`](ops/guide-for-spin-up-gentoo-tenants.md) | Grounded walkthrough for spawning a live Gentoo/OpenRC tenant |
| [`SSH-HARNESS-SETUP.md`](ops/SSH-HARNESS-SETUP.md) | SSH harness setup & ops: config, key provisioning, verifying, troubleshooting |
| [`WORKER-CONTAINERS.md`](ops/WORKER-CONTAINERS.md) | Worker container images (LunarWing, Nanocode, Pebble, Opencode) |
| [`PEBBLE-WORKER.md`](ops/PEBBLE-WORKER.md) | Pebble external worker operational guide |
| [`NANOCODE-MULTITENANT.md`](ops/NANOCODE-MULTITENANT.md) | Nanocode external worker, multi-tenant setup |
| [`DARKIRC-MULTITENANT.md`](ops/DARKIRC-MULTITENANT.md) | DarkIRC multitenant operations: port migration, provisioning, lifecycle, health, troubleshooting |
| [`DARKIRC-MULTITENANT-CHANGES-JUN23-FLAG-INFO.md`](ops/DARKIRC-MULTITENANT-CHANGES-JUN23-FLAG-INFO.md) | `--enable-darkirc` flag changes for mt-admin (2026-06-23) |
| [`WEECHAT-SERVICES.md`](ops/WEECHAT-SERVICES.md) | WeeChat services, ports, env vars, day-to-day ops |
| [`XMPP_KNOWN_ISSUES.md`](ops/XMPP_KNOWN_ISSUES.md) | XMPP/OMEMO known issues |
| [`XMPP_TRANSFERS.md`](ops/XMPP_TRANSFERS.md) | XMPP file-transfer methods quick-reference |
| [`RELEASE-COMMANDS.md`](ops/RELEASE-COMMANDS.md) | Release git/GitHub command template |
| [`RELEASE_CADENCE.md`](ops/RELEASE_CADENCE.md) | Release cadence policy |
| [`PRE-RELEASE-TESTING.md`](ops/PRE-RELEASE-TESTING.md) | Pre-release test status + test landscape |
| [`GOALS_1.1.9.md`](ops/GOALS_1.1.9.md) | Pre-release checklist for 1.1.9 (Codename *Kiyome きよめ*) |
| [`ROADMAP_2026.md`](ops/ROADMAP_2026.md) | 2026 roadmap |
| [`MT-MACHINE-MIGRATION.md`](ops/MT-MACHINE-MIGRATION.md) | Migrating a multi-tenant host to a new machine |
| [`MT-GENTOO-SETUP-AND-CHANGES-MADE.md`](ops/MT-GENTOO-SETUP-AND-CHANGES-MADE.md) | Gentoo/OpenRC multi-tenant setup notes |
| [`MT-LEGACY-UPGRADE-NOTES.md`](ops/MT-LEGACY-UPGRADE-NOTES.md) | Legacy same-host version upgrade runbook (v1.0.3–v1.0.8 → v1.1.x) |
| [`SELF_REPAIR_IMPROVEMENTS_GENTOO.md`](ops/SELF_REPAIR_IMPROVEMENTS_GENTOO.md) | Self-heal fd-leak fix found on a live OpenRC MT host |
| [`GITHOOKS_HOW_TO.md`](ops/GITHOOKS_HOW_TO.md) | How to install and use repository git hooks |
| [`IMPORT_EXPORT_EXAMPLE.txt`](ops/IMPORT_EXPORT_EXAMPLE.txt) | Worker import/export example |
| [`KUMOGAKURE_INSTRUCT.md`](ops/KUMOGAKURE_INSTRUCT.md) | Pointer to the external Notes vault |

Shipped per-release prep checklists are archived in [`ops/history/`](ops/history/).

---

### 📋 [`reference/`](reference/)

Protocol specs, contract definitions, and API references.

| File | Description |
|------|-------------|
| [`custom_bridges/XMPP.md`](reference/custom_bridges/XMPP.md) | XMPP custom-bridge reference: architecture, loopback HTTP API, env vars, deployment |

---

### 📐 [`specs/`](specs/)

Feature-level specifications (design contracts for implemented or in-progress features).

| File | Description |
|------|-------------|
| [`podman-wait-babysitter.md`](specs/podman-wait-babysitter.md) | Podman wait babysitter pattern spec |

---

### 💡 [`proposals/`](proposals/)

Active and forward-looking feature proposals, design docs, and planning. Shipped or superseded
proposals were archived under [`internal/history/proposals/`](internal/history/proposals/) during
the reorg.

| File | Description |
|------|-------------|
| [`COOL_THINGS_THAT_HERMES_AGENT_HAS.md`](proposals/COOL_THINGS_THAT_HERMES_AGENT_HAS.md) | Roadmap/wishlist of agent capabilities to add |
| [`APP_BUILDER_DIRECTION.md`](proposals/APP_BUILDER_DIRECTION.md) | App builder enhancement direction |
| [`ROUTINE_ENGINE_IMPROVEMENTS.md`](proposals/ROUTINE_ENGINE_IMPROVEMENTS.md) | Routine engine improvements proposal |
| [`HTTP_TOOL_SSRF_PROTECTIONS.md`](proposals/HTTP_TOOL_SSRF_PROTECTIONS.md) | Agent HTTP tool SSRF protections investigation |
| [`GITWASM/README.md`](proposals/GITWASM/README.md) | Git WASM tool proposal |
| [`SSH_HARNESS_DELIVERY_OPTIONS.md`](proposals/SSH_HARNESS_DELIVERY_OPTIONS.md) | SSH harness delivery options: worker socket (shipped) / built-in Rust / WASM |
| [`SSH_HARNESS_OPTION_2_3_IMPLEMENTATION.md`](proposals/SSH_HARNESS_OPTION_2_3_IMPLEMENTATION.md) | Implementation plans for SSH harness Option 2 (built-in Rust tool) & Option 3 (WASM tool) |
| [`AGENT_SSH_DEV_HARNESS.md`](proposals/AGENT_SSH_DEV_HARNESS.md) | Agent SSH dev test process and tool |
| [`IC_REPAIR_FOLLOWUPS.md`](proposals/IC_REPAIR_FOLLOWUPS.md) | Self-repair / infra-repair follow-up items |
| [`MT-1.1.0-TO-1.1.4-UPGRADE.md`](proposals/MT-1.1.0-TO-1.1.4-UPGRADE.md) | Multi-tenant v1.1.0 → v1.1.4 upgrade plan + tooling |
| [`MT-LEGACY-UPGRADE-VERIFICATION.md`](proposals/MT-LEGACY-UPGRADE-VERIFICATION.md) | Live validation plan for the v1.0.3-era same-host upgrade harness |
| [`MT-LEGACY-UPGRADE-QA-PLAN.md`](proposals/MT-LEGACY-UPGRADE-QA-PLAN.md) | Operator one-page live-validation checklist for legacy upgrades |
| [`MT-LEGACY-UPGRADE-CHERRYPICK-PLAN.md`](proposals/MT-LEGACY-UPGRADE-CHERRYPICK-PLAN.md) | MT legacy upgrade cherry-pick & fix plan (v1.0.3 → v1.1.2) |
| [`MT-WEECHAT-CONSISTENCY-AND-CHANNEL-PRUNING.md`](proposals/MT-WEECHAT-CONSISTENCY-AND-CHANNEL-PRUNING.md) | WeeChat multi-tenant consistency + channel pruning |
| [`MT-ONBOARDING-CLI.md`](proposals/MT-ONBOARDING-CLI.md) | Interactive multi-tenant provisioning CLI proposal |
| [`ADD-TENANTS-ADDITIONS.md`](proposals/ADD-TENANTS-ADDITIONS.md) | Additional configurable flags for `add-tenant` |
| [`KAWARIMI-OWNER-SCOPE-CONTINUITY.md`](proposals/KAWARIMI-OWNER-SCOPE-CONTINUITY.md) | Kawarimi owner-scope continuity implementation proposal |
| [`UPGRADE_AND_MIGRATION_ISSUES_TO_FIX.md`](proposals/UPGRADE_AND_MIGRATION_ISSUES_TO_FIX.md) | Upgrade/migrate issues found (rootless-Podman tenants) |
| [`TEST-MIGRATION-AGAIN.md`](proposals/TEST-MIGRATION-AGAIN.md) | Kawarimi test migration proposal |
| [`OPENRC_ACCURATE_REPORT_16_JUNE_2026.md`](proposals/OPENRC_ACCURATE_REPORT_16_JUNE_2026.md) | OpenRC multi-tenant accurate report (2026-06-16) |
| [`ROOTLESS_PODMAN_CONTAINER_SUPERVISION_GAP.md`](proposals/ROOTLESS_PODMAN_CONTAINER_SUPERVISION_GAP.md) | Rootless-podman container supervision gap analysis |
| [`PODMAN_WAIT_BABYSITTER.md`](proposals/PODMAN_WAIT_BABYSITTER.md) | Podman wait babysitter pattern proposal |
| [`PODMAN_WAIT_BABYSITTER_REVIEW.md`](proposals/PODMAN_WAIT_BABYSITTER_REVIEW.md) | Review notes on podman-wait babysitter branch |
| [`rootless-podman-babysitter.md`](proposals/rootless-podman-babysitter.md) | Plan: podman wait babysitter for OpenRC rootless container supervision |
| [`EXTERNAL_WORKER_NEW_MECHANISM.md`](proposals/EXTERNAL_WORKER_NEW_MECHANISM.md) | External worker new mechanism proposal |
| [`EXTERNAL-WORKER-PLAN-UPGRADES.md`](proposals/EXTERNAL-WORKER-PLAN-UPGRADES.md) | External worker system upgrades plan |
| [`EXTERNAL-WORKER-UPGRADES-PROGRESS.md`](proposals/EXTERNAL-WORKER-UPGRADES-PROGRESS.md) | External worker upgrades progress checklist |
| [`EXTERNAL-WORKER-AUDIT-2026-06-23.md`](proposals/EXTERNAL-WORKER-AUDIT-2026-06-23.md) | External worker security audit (2026-06-23) |
| [`OPENCODE-WORKER-SINGLE-TARGET-BUILD.md`](proposals/OPENCODE-WORKER-SINGLE-TARGET-BUILD.md) | Build only the native target in the opencode worker image |
| [`SESSION-AUDIT-MT-DARKIRC-EWE-2026-06-23.md`](proposals/SESSION-AUDIT-MT-DARKIRC-EWE-2026-06-23.md) | Session audit: MT admin, DarkIRC, external worker enhancements |
| [`MULTICA_INTEGRATION_PLAN.md`](proposals/MULTICA_INTEGRATION_PLAN.md) | Multica/Lunartica integration plan |
| [`MULTICA_SUPPORT.md`](proposals/MULTICA_SUPPORT.md) | Multica/Lunartica integration (stub) |
| [`MULTICA_LUNARTICA_RESKIN.md`](proposals/MULTICA_LUNARTICA_RESKIN.md) | Reskin Multica UI for Lunartica (idea) |
| [`OH-MY-OPENAGENT.md`](proposals/OH-MY-OPENAGENT.md) | OpenAgent proposal |
| [`DARKIRC_THINGS_TO_ADD.md`](proposals/DARKIRC_THINGS_TO_ADD.md) | DarkIRC future additions (Tor transport, peering) |
| [`JINGLE_IBB_FEASIBILITY.md`](proposals/JINGLE_IBB_FEASIBILITY.md) | Jingle/IBB file transfer feasibility investigation |
| [`XMPP_INCOMING_ATTACHMENT.md`](proposals/XMPP_INCOMING_ATTACHMENT.md) | XMPP incoming attachment handling investigation |
| [`XMPP_LUNARVISION_INTEGRATION.md`](proposals/XMPP_LUNARVISION_INTEGRATION.md) | XMPP + LunarVision integration gaps |
| [`XMPP_OMEMO_AESGCM_URL_LEAK_FIX.md`](proposals/XMPP_OMEMO_AESGCM_URL_LEAK_FIX.md) | OMEMO `aesgcm://` URL leak fix proposal |
| [`XMPP_WASM_ATTACHMENT_TRAP.md`](proposals/XMPP_WASM_ATTACHMENT_TRAP.md) | XMPP WASM attachment trap investigation |
| [`qwen3vl-ocr-podman.md`](proposals/qwen3vl-ocr-podman.md) | Qwen3-VL + Tesseract OCR on rootless Podman (quadlets) |
| [`WORKERCACHEDIMG.md`](proposals/WORKERCACHEDIMG.md) | Podman image prune after loading new tenant image |
| [`CHAOS_FOLLOWUP_TESTS.md`](proposals/CHAOS_FOLLOWUP_TESTS.md) | Follow-up chaos / self-heal test scenarios |
| [`RENDER_UNITS_SMALL_BUG.md`](proposals/RENDER_UNITS_SMALL_BUG.md) | `render-units` small-bug note |
| [`human-delay-mode-phase2-plan.md`](proposals/human-delay-mode-phase2-plan.md) | Human-delay mode phase 2 plan |
| [`human-delay-mode-phase1-test-checklist.md`](proposals/human-delay-mode-phase1-test-checklist.md) | Human-delay mode phase 1 test checklist |
| [`human-delay-mode-phase1-verification-handoff.md`](proposals/human-delay-mode-phase1-verification-handoff.md) | Human-delay mode phase 1 verification handoff |
| [`human-delay-mode-testing-guide.md`](proposals/human-delay-mode-testing-guide.md) | Human-delay mode testing guide |
| [`WEECHAT_WS_ADAPTER_SYNC_PROTOCOL.md`](proposals/WEECHAT_WS_ADAPTER_SYNC_PROTOCOL.md) | WeeChat `ws_adapter` sync protocol |
| [`WEECHAT_WS_ADAPTER_MISSING_DEPENDENCY_AND_AUTOMATION.md`](proposals/WEECHAT_WS_ADAPTER_MISSING_DEPENDENCY_AND_AUTOMATION.md) | WeeChat `ws_adapter` dependency + automation |
| [`WEECHAT_CLIENT_RELAY_API_AUTOMATION.md`](proposals/WEECHAT_CLIENT_RELAY_API_AUTOMATION.md) | Automating WeeChat client relay setup (idea) |
| [`LOREBOOKS.md`](proposals/LOREBOOKS.md) | Character lorebooks for agents (idea) |
| [`Profiles.md`](proposals/Profiles.md) | Agent profiles (idea) |
| [`LUNARVISION_POLISHING.md`](proposals/LUNARVISION_POLISHING.md) | LunarVision polish + health-check wiring (idea) |
| [`REFINE_LIBSQL_MIGRATION_GUIDE.md`](proposals/REFINE_LIBSQL_MIGRATION_GUIDE.md) | Refine the libSQL migration guide (TODO) |
| [`CARGO_TESTS_FIX.md`](proposals/CARGO_TESTS_FIX.md) | Revisit the few failing cargo tests (TODO) |
| [`OLDPROJECT_PORT_ANALYSES/`](proposals/OLDPROJECT_PORT_ANALYSES/) | Pre-fork IronClaw 0.28–0.29 port analyses (5 docs; kept for reference) |

---

### 📦 [`releases/`](releases/)

Release notes and changelogs (immutable historical records).

| File | Description |
|------|-------------|
| [`RELEASE-v1.0.7.md`](releases/RELEASE-v1.0.7.md) | Release notes for v1.0.7 |
| [`RELEASE-v1.1.0.md`](releases/RELEASE-v1.1.0.md) | Release notes for v1.1.0 |
| [`RELEASE-v1.1.1.md`](releases/RELEASE-v1.1.1.md) | Release notes for v1.1.1 |
| [`RELEASE-v1.1.2.md`](releases/RELEASE-v1.1.2.md) | Release notes for v1.1.2 |
| [`RELEASE-v1.1.3.md`](releases/RELEASE-v1.1.3.md) | Release notes for v1.1.3 |
| [`RELEASE-v1.1.4.md`](releases/RELEASE-v1.1.4.md) | Release notes for v1.1.4 |
| [`RELEASE-v1.1.5.md`](releases/RELEASE-v1.1.5.md) | Release notes for v1.1.5 |
| [`RELEASE-v1.1.6.md`](releases/RELEASE-v1.1.6.md) | Release notes for v1.1.6 |
| [`RELEASE-v1.1.7.md`](releases/RELEASE-v1.1.7.md) | Release notes for v1.1.7 |
| [`RELEASE-v1.1.8.md`](releases/RELEASE-v1.1.8.md) | Release notes for v1.1.8 (latest) |
| [`CHANGELOG-AGENTS.md`](releases/CHANGELOG-AGENTS.md) | Changelog of AGENTS.md updates |

---

### 🐛 [`bugs/`](bugs/)

A maintained Open/Fixed bug tracker. The full index is **[`bugs/README.md`](bugs/README.md)**.

---

### 🔍 [`reviews/`](reviews/)

Architecture and code reviews.

| File | Description |
|------|-------------|
| [`SWEETIE-ARCH-REVIEW.md`](reviews/SWEETIE-ARCH-REVIEW.md) | Full codebase architecture review by SweetieBot |

---

### 🦸 [`superpowers/`](superpowers/)

Agent-driven implementation plans and design specs (generated by the superpowers workflow).

#### Plans

| File | Description |
|------|-------------|
| [`plans/2026-06-29-lunarvision-vl-wiring.md`](superpowers/plans/2026-06-29-lunarvision-vl-wiring.md) | LunarVision VL wiring implementation plan |
| [`plans/2026-06-30-vision-analyze-tool-wiring.md`](superpowers/plans/2026-06-30-vision-analyze-tool-wiring.md) | Vision-analyze WASM tool per-tenant sidecar wiring plan |
| [`plans/2026-07-01-mt-admin-ssh-streamlining.md`](superpowers/plans/2026-07-01-mt-admin-ssh-streamlining.md) | mt-admin SSH setup streamlining plan |
| [`plans/2026-07-02-mt-admin-runtime-persistence.md`](superpowers/plans/2026-07-02-mt-admin-runtime-persistence.md) | mt-admin container-runtime persistence plan |

#### Specs

| File | Description |
|------|-------------|
| [`specs/2026-06-29-lunarvision-vl-wiring-design.md`](superpowers/specs/2026-06-29-lunarvision-vl-wiring-design.md) | LunarVision VL wiring design spec |
| [`specs/2026-06-30-vision-analyze-tool-wiring-design.md`](superpowers/specs/2026-06-30-vision-analyze-tool-wiring-design.md) | Vision-analyze WASM tool wiring design spec |
| [`specs/2026-07-01-mt-admin-ssh-streamlining-design.md`](superpowers/specs/2026-07-01-mt-admin-ssh-streamlining-design.md) | mt-admin SSH setup streamlining design |
| [`specs/2026-07-02-mt-admin-runtime-persistence-design.md`](superpowers/specs/2026-07-02-mt-admin-runtime-persistence-design.md) | mt-admin container-runtime persistence design |

---

### 🗂️ [`internal/`](internal/)

Internal notes, drafts, and working documents — incomplete or in-progress by nature.

| File | Description |
|------|-------------|
| [`FORK_CONTEXT.md`](internal/FORK_CONTEXT.md) | Fork history and context (authoritative; linked from `CLAUDE.md`) |
| [`.github/pull_request_template.md`](internal/.github/pull_request_template.md) | LunarWing PR template (review tracks, validation checklist) |
| [`ic-infrastructure-health-check/draft-ic-infrastructure-health-check-analysis-report.md`](internal/ic-infrastructure-health-check/draft-ic-infrastructure-health-check-analysis-report.md) | Health-check analysis draft |
| [`nanocode-config/KAGEHO_QUESTIONS.md`](internal/nanocode-config/KAGEHO_QUESTIONS.md) | Agnostic coding-worker container design notes |
| [`nanocode-config/NextSteps.md`](internal/nanocode-config/NextSteps.md) | Nanocode + TensorZero setup next steps |
| [`COMPONENT_SOURCES.md`](internal/COMPONENT_SOURCES.md) | Where each custom component's upstream source repo lives |

**Archives** (kept for provenance, not active docs):

- [`vendored/`](internal/vendored/) — third-party upstream copies (nanocode/opencode) swept into `docs/` by an earlier bulk commit. See [`vendored/README.md`](internal/vendored/README.md).
- [`history/`](internal/history/) — superseded LunarWing docs relocated here during the reorg, by source area: `architecture/`, `guides/`, `internal/`, `proposals/`, plus an `archive/` subfolder. See [`history/README.md`](internal/history/README.md).

---

## What Stays Outside `docs/`

The following are **not** in this directory and should remain where they are:

- **`README.md`** — repo root entry point
- **`CLAUDE.md` / `AGENTS.md` / `CODEX.md`** — AI agent context files (kept at their respective locations)
- **`ic/`** — all documentation within the `ic/` tree stays in place (workspace templates, crate docs, skill definitions, etc.)
- **`projects/`** — satellite service documentation stays with its source (e.g., `projects/ocr-sidecar/README.md`)
- **`lunarcode4lunarwing/` / `pebble4lunarwing/` / `opencode4lunarwing/`** — worker-container docs stay with their container source
- **`.claude/`** — Claude command and rule files

---

## Contributing

When adding new documentation, place it in the appropriate subdirectory:

1. **`architecture/`** — if it describes *why* the system is designed a certain way
2. **`guides/`** — if it tells someone *how to do* something
3. **`ops/`** — if it covers *deployment or operations*
4. **`reference/`** — if it's a *spec, contract, or API doc*
5. **`specs/`** — if it's a *feature-level specification* for implemented or in-progress work
6. **`proposals/`** — if it's a *proposal or design for not-yet-shipped work*
7. **`bugs/`** — if it's a *bug report* (and add it to [`bugs/README.md`](bugs/README.md))
8. **`reviews/`** — if it's a *code or architecture review*
9. **`superpowers/`** — if it's an *agent-generated plan or design spec*
10. **`internal/`** — if it's a *draft, note, or working document*

Superseded or shipped docs are archived under `internal/history/` (LunarWing-authored) or
`internal/vendored/` (third-party). Update this index when adding or moving files.
