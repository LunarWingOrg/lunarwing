# LunarWing Documentation

All project documentation, organized by category. This index reflects the current tree —
every **active** file is listed below. Archived material lives under
[`internal/history/`](internal/history/) (superseded LunarWing docs).

* Original Author: Starforce Nebula *
* Updated on July 6th by Rarity to reflect recent changes to the documentation tree: added missing entries for reviews/, specs/, superpowers/; fixed broken links (ROADMAP_2026, DOCS_REORG_CHECKLIST); added READMEs to previously undocumentated subdirectories.*

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
| [`SELF_HEAL_DEPLOYMENT_WIRING.md`](architecture/SELF_HEAL_DEPLOYMENT_WIRING.md) | How the infra health-check + self-heal pipeline is installed/scheduled (host-level, auto-scheduled by add-tenant as of v1.1.9) |
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
| [`EMBEDDINGS_SETUP.md`](guides/EMBEDDINGS_SETUP.md) | Embedding provider config (OpenAI-compatible, Ollama, NEAR AI) |
| [`VISION_OCR_SIDECAR.md`](guides/VISION_OCR_SIDECAR.md) | Vision/OCR sidecar service overview |
| [`GENTOO_PACKAGE_LIST.md`](guides/GENTOO_PACKAGE_LIST.md) | Gentoo package list + rootless-podman MT prerequisites |
| [`MULTICA_DEPLOYMENT.md`](guides/MULTICA_DEPLOYMENT.md) | Multica/Lunartica deployment guide |
| [`human-delay-mode.md`](guides/human-delay-mode.md) | Human-delay mode overview |
| [`DEBUG_LOG.md`](guides/DEBUG_LOG.md) | Catalog of debug/info log points by `file:line` |
| [`ENABLING_DEV_TOOLS.md`](guides/ENABLING_DEV_TOOLS.md) | Enabling filesystem/shell developer tools for a tenant |
| [`SSH-TOOL-TESTING.md`](guides/SSH-TOOL-TESTING.md) | Test prompts for validating the three SSH delivery mechanisms |
| [`AI-CODE-CONTRIBUTION-POLICY.md`](guides/AI-CODE-CONTRIBUTION-POLICY.md) | AI code contribution policy (effective July 7th, 2026) |
| [`darkirc_channel_for_lunarwing/BUILD_INSTRUCTIONS.md`](guides/darkirc_channel_for_lunarwing/BUILD_INSTRUCTIONS.md) | DarkIRC channel build instructions |
| [`darkirc_channel_for_lunarwing/DARKIRC_BUILD_GUIDE.md`](guides/darkirc_channel_for_lunarwing/DARKIRC_BUILD_GUIDE.md) | Full DarkIRC build guide |
| [`darkirc_channel_for_lunarwing/DARKIRC_MT_ADAPTER.md`](guides/darkirc_channel_for_lunarwing/DARKIRC_MT_ADAPTER.md) | DarkIRC multi-tenant adapter |
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
| [`DARKIRC-MULTITENANT.md`](ops/DARKIRC-MULTITENANT.md) | DarkIRC multitenant operations: port migration, provisioning, lifecycle, health, troubleshooting |
| [`DARKIRC-MULTITENANT-CHANGES-JUN23-FLAG-INFO.md`](ops/DARKIRC-MULTITENANT-CHANGES-JUN23-FLAG-INFO.md) | `--enable-darkirc` flag changes for mt-admin (June 2023 snapshot) |
| [`TENANT-CONFIGURATION.md`](ops/TENANT-CONFIGURATION.md) | Per-tenant configuration reference (env, LLM, XMPP, ports) |
| [`TENANT-RENAME-MIGRATION-1.1.9.md`](ops/TENANT-RENAME-MIGRATION-1.1.9.md) | Upgrading 1.1.7/1.1.8 tenants across the 1.1.9 directory renames (render-units flow, compat-symlink window, v2.0.0 deadline) |
| [`TEST-PLAN-UPGRADED-TENANT-1.1.9.md`](ops/TEST-PLAN-UPGRADED-TENANT-1.1.9.md) | Validated test plan for the upgraded-tenant path: synthesize a v1.1.8 tenant, upgrade, assert compat symlinks/protocol/render-units (OpenRC) |
| [`MULTITENANCY-HARNESS.md`](ops/MULTITENANCY-HARNESS.md) | Multi-tenant test harness guide |
| [`HARNESS-SINGLE-TENANT.md`](ops/HARNESS-SINGLE-TENANT.md) | Single-tenant test harness guide |
| [`SSH-HARNESS-SETUP.md`](ops/SSH-HARNESS-SETUP.md) | SSH harness setup & ops: config, key provisioning (mt-admin + manual), verifying in a worker, troubleshooting |
| [`WORKER-CONTAINERS.md`](ops/WORKER-CONTAINERS.md) | Worker container images (LunarWing, Nanocode, Pebble, Opencode) |
| [`PEBBLE-WORKER.md`](ops/PEBBLE-WORKER.md) | Pebble external worker operational guide |
| [`NANOCODE-MULTITENANT.md`](ops/NANOCODE-MULTITENANT.md) | Nanocode external worker, multi-tenant setup |
| [`WEECHAT-SERVICES.md`](ops/WEECHAT-SERVICES.md) | WeeChat services, ports, env vars, day-to-day ops |
| [`XMPP_KNOWN_ISSUES.md`](ops/XMPP_KNOWN_ISSUES.md) | XMPP/OMEMO known issues |
| [`XMPP_TRANSFERS.md`](ops/XMPP_TRANSFERS.md) | XMPP file-transfer methods quick-reference |
| [`RELEASE-COMMANDS.md`](ops/RELEASE-COMMANDS.md) | Release git/GitHub command template |
| [`RELEASE_CADENCE.md`](ops/RELEASE_CADENCE.md) | Release cadence policy |
| [`PRE-RELEASE-TESTING.md`](ops/PRE-RELEASE-TESTING.md) | Pre-release test status + test landscape |
| [`GOALS_1.1.9.md`](ops/GOALS_1.1.9.md) | Pre-release checklist for 1.1.9 (`Kiyome きよめ`) |
| [`ROADMAP_2026.MD`](ops/ROADMAP_2026.MD) | 2026 roadmap |
| [`MT-MACHINE-MIGRATION.md`](ops/MT-MACHINE-MIGRATION.md) | Migrating a multi-tenant host to a new machine |
| [`MT-GENTOO-SETUP-AND-CHANGES-MADE.md`](ops/MT-GENTOO-SETUP-AND-CHANGES-MADE.md) | Gentoo/OpenRC multi-tenant setup notes |
| [`guide-for-spin-up-gentoo-tenants.md`](ops/guide-for-spin-up-gentoo-tenants.md) | Step-by-step guide for spinning up a Gentoo/OpenRC tenant |
| [`MT-LEGACY-UPGRADE-NOTES.md`](ops/MT-LEGACY-UPGRADE-NOTES.md) | Legacy same-host version upgrade runbook (v1.0.3–v1.0.8 → v1.1.x) |
| [`SELF_REPAIR_IMPROVEMENTS_GENTOO.md`](ops/SELF_REPAIR_IMPROVEMENTS_GENTOO.md) | Self-heal fd-leak fix found on a live OpenRC MT host |
| [`ROADMAP_2026.md`](ops/ROADMAP_2026.md) | 2026 roadmap |
| [`GITHOOKS_HOW_TO.md`](ops/GITHOOKS_HOW_TO.md) | How to install githooks |
| [`IMPORT_EXPORT_EXAMPLE.txt`](ops/IMPORT_EXPORT_EXAMPLE.txt) | Worker import/export example |
| [`KUMOGAKURE_INSTRUCT.md`](ops/KUMOGAKURE_INSTRUCT.md) | Pointer to the external Notes vault |

Versioned release notes live in [`releases/`](releases/). Shipped per-release prep checklists are
archived in [`ops/history/`](ops/history/).

---

### 📋 [`reference/`](reference/)

Protocol specs, contract definitions, and API references.

| File | Description |
|------|-------------|
| [`custom_bridges/XMPP.md`](reference/custom_bridges/XMPP.md) | XMPP custom-bridge reference: architecture, loopback HTTP API, env vars, deployment |

---

### 📐 [`specs/`](specs/)

Standalone specifications for specific features or patterns.

| File | Description |
|------|-------------|
| [`podman-wait-babysitter.md`](specs/podman-wait-babysitter.md) | Podman wait-babysitter pattern spec |

---

### 🔍 [`reviews/`](reviews/)

Architecture and code reviews.

| File | Description |
|------|-------------|
| [`SWEETIE-ARCH-REVIEW.md`](reviews/SWEETIE-ARCH-REVIEW.md) | Full codebase architecture review by SweetieBot |

---

### 🚀 [`superpowers/`](superpowers/)

Agent-driven plan and spec documents produced by the superpowers workflow.

| Subdirectory | Description |
|--------------|-------------|
| [`plans/`](superpowers/plans/) | Implementation plans (LunarVision VL wiring, vision-analyze tool, mt-admin SSH, mt-admin runtime persistence) |
| [`specs/`](superpowers/specs/) | Design specs corresponding to the plans |

---

### 💡 [`proposals/`](proposals/)

Active and forward-looking feature proposals, design docs, and planning. Shipped or superseded
proposals were archived under [`internal/history/proposals/`](internal/history/proposals/) during
the reorg. *(Updated 2026-07-09: reviewed and refreshed for v1.1.9 accuracy.)*

| File | Description |
|------|-------------|
| [`COOL_THINGS_THAT_HERMES_AGENT_HAS.md`](proposals/COOL_THINGS_THAT_HERMES_AGENT_HAS.md) | Roadmap/wishlist of agent capabilities to add |
| [`GITWASM/README.md`](proposals/GITWASM/README.md) | Git WASM tool proposal |
| [`SSH_HARNESS_DELIVERY_OPTIONS.md`](proposals/SSH_HARNESS_DELIVERY_OPTIONS.md) | SSH harness delivery options: worker socket (shipped) / built-in Rust / WASM |
| [`SSH_HARNESS_OPTION_2_3_IMPLEMENTATION.md`](proposals/SSH_HARNESS_OPTION_2_3_IMPLEMENTATION.md) | Implementation plans for SSH harness Option 2 (built-in Rust tool) & Option 3 (WASM tool) |
| [`IC_REPAIR_FOLLOWUPS.md`](proposals/IC_REPAIR_FOLLOWUPS.md) | Self-repair / infra-repair follow-up items |
| [`MT-1.1.0-TO-1.1.4-UPGRADE.md`](proposals/MT-1.1.0-TO-1.1.4-UPGRADE.md) | Multi-tenant v1.1.0 → v1.1.4 upgrade plan + tooling |
| [`MT-LEGACY-UPGRADE-VERIFICATION.md`](proposals/MT-LEGACY-UPGRADE-VERIFICATION.md) | Live validation plan for the v1.0.3-era same-host upgrade harness |
| [`MT-LEGACY-UPGRADE-QA-PLAN.md`](proposals/MT-LEGACY-UPGRADE-QA-PLAN.md) | Operator one-page live-validation checklist for legacy upgrades (v1.0.3-era → v1.1.2/3) |
| [`MT-LEGACY-UPGRADE-CHERRYPICK-PLAN.md`](proposals/MT-LEGACY-UPGRADE-CHERRYPICK-PLAN.md) | Cherry-pick & fix plan for legacy upgrades (v1.0.3 → v1.1.2) |
| [`MT-WEECHAT-CONSISTENCY-AND-CHANNEL-PRUNING.md`](proposals/MT-WEECHAT-CONSISTENCY-AND-CHANNEL-PRUNING.md) | WeeChat multi-tenant consistency + channel pruning |
| [`OPENRC_ACCURATE_REPORT_16_JUNE_2026.md`](proposals/OPENRC_ACCURATE_REPORT_16_JUNE_2026.md) | OpenRC multi-tenant accurate report (2026-06-16) |
| [`ROOTLESS_PODMAN_CONTAINER_SUPERVISION_GAP.md`](proposals/ROOTLESS_PODMAN_CONTAINER_SUPERVISION_GAP.md) | Rootless-podman container supervision gap analysis |
| [`MULTICA_INTEGRATION_PLAN.md`](proposals/MULTICA_INTEGRATION_PLAN.md) | Multica/Lunartica integration plan |
| [`CHAOS_FOLLOWUP_TESTS.md`](proposals/CHAOS_FOLLOWUP_TESTS.md) | Follow-up chaos / self-heal test scenarios |
| [`RENDER_UNITS_SMALL_BUG.md`](proposals/RENDER_UNITS_SMALL_BUG.md) | `render-units` small-bug note |
| [`human-delay-mode-phase2-plan.md`](proposals/human-delay-mode-phase2-plan.md) | Human-delay mode phase 2 plan |
| [`human-delay-mode-phase1-test-checklist.md`](proposals/human-delay-mode-phase1-test-checklist.md) | Human-delay mode phase 1 test checklist |
| [`human-delay-mode-phase1-verification-handoff.md`](proposals/human-delay-mode-phase1-verification-handoff.md) | Human-delay mode phase 1 verification handoff |
| [`human-delay-mode-testing-guide.md`](proposals/human-delay-mode-testing-guide.md) | Human-delay mode testing guide |
| [`WEECHAT_WS_ADAPTER_SYNC_PROTOCOL.md`](proposals/WEECHAT_WS_ADAPTER_SYNC_PROTOCOL.md) | WeeChat `ws_adapter` sync protocol |
| [`WEECHAT_WS_ADAPTER_MISSING_DEPENDENCY_AND_AUTOMATION.md`](proposals/WEECHAT_WS_ADAPTER_MISSING_DEPENDENCY_AND_AUTOMATION.md) | WeeChat `ws_adapter` dependency + automation |
| [`WEECHAT_CLIENT_RELAY_API_AUTOMATION.md`](proposals/WEECHAT_CLIENT_RELAY_API_AUTOMATION.md) | Automating WeeChat client relay setup (idea) |
| [`MULTICA_SUPPORT.md`](proposals/MULTICA_SUPPORT.md) | Multica/Lunartica integration (stub) |
| [`MULTICA_LUNARTICA_RESKIN.md`](proposals/MULTICA_LUNARTICA_RESKIN.md) | Reskin Multica UI for Lunartica (idea) |
| [`LOREBOOKS.md`](proposals/LOREBOOKS.md) | Character lorebooks for agents (idea) |
| [`Profiles.md`](proposals/Profiles.md) | Agent profiles (idea) |
| [`LUNARVISION_POLISHING.md`](proposals/LUNARVISION_POLISHING.md) | LunarVision polish + health-check wiring (idea) |
| [`REFINE_LIBSQL_MIGRATION_GUIDE.md`](proposals/REFINE_LIBSQL_MIGRATION_GUIDE.md) | Refine the libSQL migration guide (TODO) |
| [`CARGO_TESTS_FIX.md`](proposals/CARGO_TESTS_FIX.md) | Revisit the few failing cargo tests (TODO) |
| [`HTTP_TOOL_SSRF_PROTECTIONS.md`](proposals/HTTP_TOOL_SSRF_PROTECTIONS.md) | Agent HTTP tool SSRF protections investigation |
| [`JINGLE_IBB_FEASIBILITY.md`](proposals/JINGLE_IBB_FEASIBILITY.md) | Jingle/IBB file transfer feasibility investigation |
| [`XMPP_INCOMING_ATTACHMENT.md`](proposals/XMPP_INCOMING_ATTACHMENT.md) | XMPP incoming attachment handling investigation |
| [`XMPP_LUNARVISION_INTEGRATION.md`](proposals/XMPP_LUNARVISION_INTEGRATION.md) | XMPP + LunarVision integration proposal |
| [`XMPP_OMEMO_AESGCM_URL_LEAK_FIX.md`](proposals/XMPP_OMEMO_AESGCM_URL_LEAK_FIX.md) | OMEMO `aesgcm://` URL leak fix proposal |
| [`XMPP_WASM_ATTACHMENT_TRAP.md`](proposals/XMPP_WASM_ATTACHMENT_TRAP.md) | XMPP WASM attachment trap investigation |
| [`KAWARIMI-OWNER-SCOPE-CONTINUITY.md`](proposals/KAWARIMI-OWNER-SCOPE-CONTINUITY.md) | Kawarimi owner-scope continuity implementation proposal |
| [`APP_BUILDER_DIRECTION.md`](proposals/APP_BUILDER_DIRECTION.md) | App Builder (enhanced) direction proposal |
| [`AGENT_SSH_DEV_HARNESS.md`](proposals/AGENT_SSH_DEV_HARNESS.md) | Agent SSH dev test process and tool |
| [`DARKIRC_THINGS_TO_ADD.md`](proposals/DARKIRC_THINGS_TO_ADD.md) | DarkIRC future enhancements (Tor transport, seed availability) |
| [`ADD-TENANTS-ADDITIONS.md`](proposals/ADD-TENANTS-ADDITIONS.md) | Additional flags to make configurable for `add-tenants` |
| [`OH-MY-OPENAGENT.md`](proposals/OH-MY-OPENAGENT.md) | Add `oh-my-openagent.jsonc` equivalent for opencode worker |
| [`EXTERNAL-WORKER-AUDIT-2026-06-23.md`](proposals/EXTERNAL-WORKER-AUDIT-2026-06-23.md) | External worker security audit (2026-06-23) |
| [`EXTERNAL-WORKER-PLAN-UPGRADES.md`](proposals/EXTERNAL-WORKER-PLAN-UPGRADES.md) | External worker system upgrades plan |
| [`EXTERNAL-WORKER-UPGRADES-PROGRESS.md`](proposals/EXTERNAL-WORKER-UPGRADES-PROGRESS.md) | External worker upgrades progress checklist |
| [`OPENCODE-WORKER-SINGLE-TARGET-BUILD.md`](proposals/OPENCODE-WORKER-SINGLE-TARGET-BUILD.md) | Build only the native target in the opencode worker image |
| [`PODMAN_WAIT_BABYSITTER.md`](proposals/PODMAN_WAIT_BABYSITTER.md) | Podman wait babysitter pattern proposal |
| [`PODMAN_WAIT_BABYSITTER_REVIEW.md`](proposals/PODMAN_WAIT_BABYSITTER_REVIEW.md) | Review of the podman-wait babysitter branch |
| [`rootless-podman-babysitter.md`](proposals/rootless-podman-babysitter.md) | Rootless podman babysitter plan |
| [`qwen3vl-ocr-podman.md`](proposals/qwen3vl-ocr-podman.md) | Qwen3-VL + Tesseract OCR on rootless Podman (quadlets) |
| [`ROUTINE_ENGINE_IMPROVEMENTS.md`](proposals/ROUTINE_ENGINE_IMPROVEMENTS.md) | Routine engine improvements proposal |
| [`SESSION-AUDIT-MT-DARKIRC-EWE-2026-06-23.md`](proposals/SESSION-AUDIT-MT-DARKIRC-EWE-2026-06-23.md) | Session audit: MT admin, DarkIRC, external worker (2026-06-23) |
| [`UPGRADE_AND_MIGRATION_ISSUES_TO_FIX.md`](proposals/UPGRADE_AND_MIGRATION_ISSUES_TO_FIX.md) | Upgrade/migrate issues found |
| [`OLDPROJECT_PORT_ANALYSES/`](proposals/OLDPROJECT_PORT_ANALYSES/) | Pre-fork IronClaw 0.28–0.29 port analyses (5 docs; kept for reference) |
| [`IRONCLAW_ADDITION_CANDIDATES.md`](proposals/IRONCLAW_ADDITION_CANDIDATES.md) | Filtered IronClaw additions for current LunarWing, with priorities and adaptation notes |
| [`MT-ONBOARDING-CLI.md`](proposals/MT-ONBOARDING-CLI.md) | MT onboarding CLI (`lunarwing_mt_onboard`) — shipped v1.1.9 (design record) |
| [`SUPERGATEWAY_MCP.md`](proposals/SUPERGATEWAY_MCP.md) | MCP stdio support gap + supergateway workaround |
| [`PASEO.MD`](proposals/PASEO.MD) | Paseo support (stub) |
| [`PAST.MD`](proposals/PAST.MD) | PAST+SS (stub idea) |
| [`ports_expansion.txt`](proposals/ports_expansion.txt) | Port allocation notes (vision sidecar health, SSH socket) |

---

### 🔍 [`reviews/`](reviews/)

Third-party and internal architecture reviews of the LunarWing codebase.

| File | Description |
|------|-------------|
| [`SWEETIE-ARCH-REVIEW.md`](reviews/SWEETIE-ARCH-REVIEW.md) | Full codebase architecture review by SweetieBot (system overview, agent loop, session/thread model, tool system, channels, orchestration, workspace/memory) |

---

### 📐 [`specs/`](specs/)

Technical specifications for specific subsystems and patterns.

| File | Description |
|------|-------------|
| [`podman-wait-babysitter.md`](specs/podman-wait-babysitter.md) | Podman wait babysitter pattern: OpenRC crash recovery for rootless Podman containers via `supervise-daemon` |

---

### 🦸 [`superpowers/`](superpowers/)

Dated implementation plans and design specs produced by the superpowers agentic workflow.

#### Plans

| File | Description |
|------|-------------|
| [`plans/2026-06-29-lunarvision-vl-wiring.md`](superpowers/plans/2026-06-29-lunarvision-vl-wiring.md) | LunarVision VL wiring: connect GPU-backed Qwen3-VL server to OCR sidecars via `VL_URL`, persist as systemd unit |
| [`plans/2026-06-30-vision-analyze-tool-wiring.md`](superpowers/plans/2026-06-30-vision-analyze-tool-wiring.md) | Vision-analyze WASM tool wiring: re-register with WASM toolset, end-to-end integration |
| [`plans/2026-07-01-mt-admin-ssh-streamlining.md`](superpowers/plans/2026-07-01-mt-admin-ssh-streamlining.md) | `mt-admin` SSH streamlining: key upload, daemon bounce, worker startup ordering |
| [`plans/2026-07-02-mt-admin-runtime-persistence.md`](superpowers/plans/2026-07-02-mt-admin-runtime-persistence.md) | `mt-admin` runtime persistence: state file management, idempotent operations |
| [`plans/2026-07-10-cross-version-diverged-branch-integration.md`](superpowers/plans/2026-07-10-cross-version-diverged-branch-integration.md) | Corrected cross-version port of serde, Codex-provider removal, lockfile, CLI, and proposal changes |

#### Design Specs

| File | Description |
|------|-------------|
| [`specs/2026-06-29-lunarvision-vl-wiring-design.md`](superpowers/specs/2026-06-29-lunarvision-vl-wiring-design.md) | Design spec for LunarVision VL wiring |
| [`specs/2026-06-30-vision-analyze-tool-wiring-design.md`](superpowers/specs/2026-06-30-vision-analyze-tool-wiring-design.md) | Design spec for vision-analyze tool wiring |
| [`specs/2026-07-01-mt-admin-ssh-streamlining-design.md`](superpowers/specs/2026-07-01-mt-admin-ssh-streamlining-design.md) | Design spec for mt-admin SSH streamlining |
| [`specs/2026-07-02-mt-admin-runtime-persistence-design.md`](superpowers/specs/2026-07-02-mt-admin-runtime-persistence-design.md) | Design spec for mt-admin runtime persistence |
| [`specs/2026-07-10-cross-version-diverged-branch-integration-design.md`](superpowers/specs/2026-07-10-cross-version-diverged-branch-integration-design.md) | Design spec for corrected branch integration across LunarWing V1 and V2 |

---

### 📦 [`releases/`](releases/)

Release notes and changelogs (immutable historical records). See [`releases/README.md`](releases/README.md) for the full index (v1.0.7 → v1.1.8, latest: RELEASE-v1.1.8.md).

---

### 🐛 [`bugs/`](bugs/)

A maintained Open/Fixed bug tracker. The full index is **[`bugs/README.md`](bugs/README.md)**.
Open bugs live in `bugs/`; resolved bugs are retained under [`bugs/history/`](bugs/history/).
A maintained Open/Fixed bug tracker. The full index is **[`bugs/README.md`](bugs/README.md)** —
it lists bug docs (Open + Fixed-retained-for-history) plus the two 1.1.4 multi-tenant
pre-release issue logs (`SYSTEMD-MT-1.1.4-ISSUES.md`, `OPENRC-MT-1.1.4-ISSUES.md`).

---

### 🗂️ [`internal/`](internal/)

Internal notes, drafts, and working documents — incomplete or in-progress by nature.

| File | Description |
|------|-------------|
| [`FORK_CONTEXT.md`](internal/FORK_CONTEXT.md) | Fork history and context (authoritative; linked from `CLAUDE.md`) |
| [`.github/pull_request_template.md`](internal/.github/pull_request_template.md) | LunarWing PR template (review tracks, validation checklist) |
| [`CHANGELOG-AGENTS.md`](internal/CHANGELOG-AGENTS.md) | Internal changelog of `AGENTS.md` updates |
| [`ic-infrastructure-health-check/draft-ic-infrastructure-health-check-analysis-report.md`](internal/ic-infrastructure-health-check/draft-ic-infrastructure-health-check-analysis-report.md) | Health-check analysis draft |
| [`nanocode-config/KAGEHO_QUESTIONS.md`](internal/nanocode-config/KAGEHO_QUESTIONS.md) | Agnostic coding-worker container design notes |
| [`nanocode-config/NextSteps.md`](internal/nanocode-config/NextSteps.md) | Nanocode + TensorZero setup next steps |
| [`COMPONENT_SOURCES.md`](internal/COMPONENT_SOURCES.md) | Where each custom component's upstream source repo lives |

**Archives** (kept for provenance, not active docs):

- [`history/`](internal/history/) — superseded LunarWing docs relocated here during the reorg, by source area: `architecture/`, `guides/`, `internal/`, `proposals/`. See [`history/README.md`](internal/history/README.md).

---

### 📝 Top-level docs

There are currently no top-level files in `docs/` outside the subdirectories above.
- [`history/`](internal/history/) — superseded LunarWing docs relocated here during the reorg, by source area: `architecture/`, `guides/`, `internal/`, `proposals/`, `archive/`. See [`history/README.md`](internal/history/README.md).

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
4. **`reference/`** — if it's a *protocol spec, contract, or API doc*
5. **`specs/`** — if it's a *standalone feature specification*
6. **`proposals/`** — if it's a *proposal or design for not-yet-shipped work*
7. **`bugs/`** — if it's a *bug report* (and add it to [`bugs/README.md`](bugs/README.md))
8. **`reviews/`** — if it's a *codebase or architecture review*
9. **`internal/`** — if it's a *draft, note, or working document*

Superseded or shipped docs are archived under `internal/history/` (LunarWing-authored). Update this index when adding or moving files.
