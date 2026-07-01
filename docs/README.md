# LunarWing Documentation

All project documentation, organized by category. This index reflects the tree after the
2026-06 documentation reorganization — every **active** file is listed below. Archived material
lives under [`internal/history/`](internal/history/) (superseded LunarWing docs) and
[`internal/vendored/`](internal/vendored/) (third-party upstream copies).

* Original Author: Starforce Nebula *
* Updated on June 19th by humans and agents to reflect changes in a semi-total document re-organization pass (only re-organized the documents in docs/ directory and nothing outside of this directory has been re-organized or updated as of the time of writing this edit).*

## Directory Structure

### 📐 [`architecture/`](architecture/)

System design and technical architecture documents (the authoritative specs).

| File | Description |
|------|-------------|
| [`ENGINE-V2.md`](architecture/ENGINE-V2.md) | V2 engine: threads, capabilities, CodeAct, gates, learning missions (linked from `CLAUDE.md`) |
| [`SSH_AGENT_HARNESS.md`](architecture/SSH_AGENT_HARNESS.md) | SSH agent harness: per-tenant in-process ssh-agent, encrypted key store, worker socket injection, host-key model |
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
| [`EMBEDDINGS_SETUP.md`](guides/EMBEDDINGS_SETUP.md) | Embedding provider config (OpenAI-compatible, Ollama, NEAR AI) |
| [`VISION_OCR_SIDECAR.md`](guides/VISION_OCR_SIDECAR.md) | Vision/OCR sidecar service overview |
| [`GENTOO_PACKAGE_LIST.md`](guides/GENTOO_PACKAGE_LIST.md) | Gentoo package list + rootless-podman MT prerequisites |
| [`MULTICA_DEPLOYMENT.md`](guides/MULTICA_DEPLOYMENT.md) | Multica/Lunartica deployment guide |
| [`human-delay-mode.md`](guides/human-delay-mode.md) | Human-delay mode overview |
| [`DEBUG_LOG.md`](guides/DEBUG_LOG.md) | Catalog of debug/info log points by `file:line` |
| [`darkirc_channel_for_ironclaw/BUILD_INSTRUCTIONS.md`](guides/darkirc_channel_for_ironclaw/BUILD_INSTRUCTIONS.md) | DarkIRC channel build instructions |
| [`darkirc_channel_for_ironclaw/DARKIRC_BUILD_GUIDE.md`](guides/darkirc_channel_for_ironclaw/DARKIRC_BUILD_GUIDE.md) | Full DarkIRC build guide |
| [`ironclaw_weechat_wss/README.md`](guides/ironclaw_weechat_wss/README.md) | WeeChat WSS channel overview |
| [`ironclaw_weechat_wss/weechat_relay/INSTALL.md`](guides/ironclaw_weechat_wss/weechat_relay/INSTALL.md) | WeeChat relay installation |
| [`ironclaw_weechat_wss/weechat_relay/TROUBLESHOOTING.md`](guides/ironclaw_weechat_wss/weechat_relay/TROUBLESHOOTING.md) | WeeChat relay troubleshooting |
| [`gotify-wasm/README.md`](guides/gotify-wasm/README.md) | Gotify WASM tool |
| [`ic_sm/README.md`](guides/ic_sm/README.md) | Secret manager (`ic_sm`) |
| [`tensorzero-proxy-configurations/README.md`](guides/tensorzero-proxy-configurations/README.md) | TensorZero proxy configuration |
| [`git-ironclaw-unix-socket-repl-server-repo/README.md`](guides/git-ironclaw-unix-socket-repl-server-repo/README.md) | REPLv2 Unix-socket REPL server |
| [`nanocode-config/README.md`](guides/nanocode-config/README.md) | Nanocode custom-config overview |
| [`nanocode-config/SETUP_NANOCODE_FOR_TENSORZERO.md`](guides/nanocode-config/SETUP_NANOCODE_FOR_TENSORZERO.md) | Point nanocode at the TensorZero gateway |

---

### 🛠️ [`ops/`](ops/)

Deployment, operations, multitenancy, and production guides.

| File | Description |
|------|-------------|
| [`MULTITENANCY-PRODUCTION.md`](ops/MULTITENANCY-PRODUCTION.md) | Production multi-tenancy walkthrough |
| [`DARKIRC-MULTITENANT.md`](ops/DARKIRC-MULTITENANT.md) | DarkIRC multitenant operations: port migration, provisioning, lifecycle, health, troubleshooting |
| [`TENANT-CONFIGURATION.md`](ops/TENANT-CONFIGURATION.md) | Per-tenant configuration reference (env, LLM, XMPP, ports) |
| [`MULTITENANCY-HARNESS.md`](ops/MULTITENANCY-HARNESS.md) | Multi-tenant test harness guide |
| [`HARNESS-SINGLE-TENANT.md`](ops/HARNESS-SINGLE-TENANT.md) | Single-tenant test harness guide |
| [`SSH-HARNESS-SETUP.md`](ops/SSH-HARNESS-SETUP.md) | SSH harness setup & ops: config, key provisioning (mt-admin + manual), verifying in a worker, troubleshooting |
| [`WORKER-CONTAINERS.md`](ops/WORKER-CONTAINERS.md) | Worker container images (LunarWing, Codex, Nanocode, Pebble) |
| [`PEBBLE-WORKER.md`](ops/PEBBLE-WORKER.md) | Pebble external worker operational guide |
| [`NANOCODE-MULTITENANT.md`](ops/NANOCODE-MULTITENANT.md) | Nanocode external worker, multi-tenant setup |
| [`WEECHAT-SERVICES.md`](ops/WEECHAT-SERVICES.md) | WeeChat services, ports, env vars, day-to-day ops |
| [`WEECHAT-MULTITENANT-PORT-BUG.md`](ops/WEECHAT-MULTITENANT-PORT-BUG.md) | Per-tenant WeeChat port/password fix |
| [`XMPP_KNOWN_ISSUES.md`](ops/XMPP_KNOWN_ISSUES.md) | XMPP/OMEMO known issues |
| [`XMPP_TRANSFERS.md`](ops/XMPP_TRANSFERS.md) | XMPP file-transfer methods quick-reference |
| [`RELEASE-COMMANDS.md`](ops/RELEASE-COMMANDS.md) | Release git/GitHub command template |
| [`RELEASE_CADENCE.md`](ops/RELEASE_CADENCE.md) | Release cadence policy |
| [`PRE-RELEASE-TESTING.md`](ops/PRE-RELEASE-TESTING.md) | Pre-release test status + test landscape |
| [`MT-MACHINE-MIGRATION.md`](ops/MT-MACHINE-MIGRATION.md) | Migrating a multi-tenant host to a new machine |
| [`MT-MACHINE-MIGRATION-REVIEW-NOTES.md`](ops/MT-MACHINE-MIGRATION-REVIEW-NOTES.md) | Review notes for the machine-migration tooling |
| [`MT-GENTOO-SETUP-AND-CHANGES-MADE.md`](ops/MT-GENTOO-SETUP-AND-CHANGES-MADE.md) | Gentoo/OpenRC multi-tenant setup notes |
| [`MT-1.1.4-UPGRADE-TOOLING-REVIEW-NOTES.md`](ops/MT-1.1.4-UPGRADE-TOOLING-REVIEW-NOTES.md) | Review notes for the 1.1.4 MT upgrade tooling |
| [`MT-LEGACY-UPGRADE-NOTES.md`](ops/MT-LEGACY-UPGRADE-NOTES.md) | Legacy same-host version upgrade runbook (v1.0.3–v1.0.8 → v1.1.x) |
| [`SELF_REPAIR_IMPROVEMENTS_GENTOO.md`](ops/SELF_REPAIR_IMPROVEMENTS_GENTOO.md) | Self-heal fd-leak fix found on a live OpenRC MT host |
| [`ROADMAP_2026.MD`](ops/ROADMAP_2026.MD) | 2026 roadmap |
| [`FUTURE_RELEASE_ITEMS.md`](ops/FUTURE_RELEASE_ITEMS.md) | Longer-horizon / unscheduled ideas |
| [`PENDING_CLEANUP.md`](ops/PENDING_CLEANUP.md) | Forward-looking cleanup checklist |
| [`KNOWN_ISSUES_TO_ADDRESS.md`](ops/KNOWN_ISSUES_TO_ADDRESS.md) | Ops known-issues scratchpad |
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

### 💡 [`proposals/`](proposals/)

Active and forward-looking feature proposals, design docs, and planning. Shipped or superseded
proposals were archived under [`internal/history/proposals/`](internal/history/proposals/) during
the reorg.

| File | Description |
|------|-------------|
| [`COOL_THINGS_THAT_HERMES_AGENT_HAS.md`](proposals/COOL_THINGS_THAT_HERMES_AGENT_HAS.md) | Roadmap/wishlist of agent capabilities to add |
| [`FUTURE_OF_ICHC.md`](proposals/FUTURE_OF_ICHC.md) | Infra health-check roadmap (v1.1.6+) |
| [`GITWASM/README.md`](proposals/GITWASM/README.md) | Git WASM tool proposal |
| [`IC_REPAIR_FOLLOWUPS.md`](proposals/IC_REPAIR_FOLLOWUPS.md) | Self-repair / infra-repair follow-up items |
| [`MT-1.1.0-TO-1.1.4-UPGRADE.md`](proposals/MT-1.1.0-TO-1.1.4-UPGRADE.md) | Multi-tenant v1.1.0 → v1.1.4 upgrade plan + tooling |
| [`MT-LEGACY-UPGRADE-VERIFICATION.md`](proposals/MT-LEGACY-UPGRADE-VERIFICATION.md) | Live validation plan for the v1.0.3-era same-host upgrade harness |
| [`MT-LEGACY-UPGRADE-QA-PLAN.md`](proposals/MT-LEGACY-UPGRADE-QA-PLAN.md) | Operator one-page live-validation checklist for legacy upgrades (v1.0.3-era → v1.1.2/3) |
| [`MT-WEECHAT-CONSISTENCY-AND-CHANNEL-PRUNING.md`](proposals/MT-WEECHAT-CONSISTENCY-AND-CHANNEL-PRUNING.md) | WeeChat multi-tenant consistency + channel pruning |
| [`OPENRC_ACCURATE_REPORT_16_JUNE_2026.md`](proposals/OPENRC_ACCURATE_REPORT_16_JUNE_2026.md) | OpenRC multi-tenant accurate report (2026-06-16) |
| [`ROOTLESS_PODMAN_CONTAINER_SUPERVISION_GAP.md`](proposals/ROOTLESS_PODMAN_CONTAINER_SUPERVISION_GAP.md) | Rootless-podman container supervision gap analysis |
| [`MULTICA_INTEGRATION_PLAN.md`](proposals/MULTICA_INTEGRATION_PLAN.md) | Multica/Lunartica integration plan |
| [`CHAOS_FOLLOWUP_TESTS.md`](proposals/CHAOS_FOLLOWUP_TESTS.md) | Follow-up chaos / self-heal test scenarios |
| [`RENDER_UNITS_SMALL_BUG.md`](proposals/RENDER_UNITS_SMALL_BUG.md) | `render-units` small-bug note |
| [`RENAME_IRONCLAW_WEECHAT_WS_CHANNEL_AND_ADAPTER`](proposals/RENAME_IRONCLAW_WEECHAT_WS_CHANNEL_AND_ADAPTER) | TODO: rename the WeeChat channel/adapter in code + references |
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
| [`FUNDING.JSON.MD`](proposals/FUNDING.JSON.MD) | Add a `funding.json` (idea) |
| [`REFINE_LIBSQL_MIGRATION_GUIDE.md`](proposals/REFINE_LIBSQL_MIGRATION_GUIDE.md) | Refine the libSQL migration guide (TODO) |
| [`CARGO_TESTS_FIX.md`](proposals/CARGO_TESTS_FIX.md) | Revisit the few failing cargo tests (TODO) |
| [`OLDPROJECT_PORT_ANALYSES/`](proposals/OLDPROJECT_PORT_ANALYSES/) | Pre-fork IronClaw 0.28–0.29 port analyses (5 docs; kept for reference) |

---

### 📦 [`releases/`](releases/)

Release notes and changelogs (immutable historical records).

---

### 🐛 [`bugs/`](bugs/)

A maintained Open/Fixed bug tracker. The full index is **[`bugs/README.md`](bugs/README.md)** —
it lists 18 bug docs (Open + Fixed-retained-for-history) plus the two 1.1.4 multi-tenant
pre-release issue logs (`SYSTEMD-MT-1.1.4-ISSUES.md`, `OPENRC-MT-1.1.4-ISSUES.md`).

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
| [`codex4ironclaw/kageho_other_ideas/draft2.md`](internal/codex4ironclaw/kageho_other_ideas/draft2.md) | Codex-worker Dockerfile draft + security-hardening checklist |
| [`codex4ironclaw/PASSING_SECRETS.md`](internal/codex4ironclaw/PASSING_SECRETS.md) | Options for passing secrets to the Codex worker |
| [`codex4ironclaw/whatajsonshouldlookliken.md`](internal/codex4ironclaw/whatajsonshouldlookliken.md) | Codex-worker task-envelope JSON format |

**Archives** (kept for provenance, not active docs):

- [`vendored/`](internal/vendored/) — third-party upstream copies (nanocode/opencode) swept into `docs/` by an earlier bulk commit. See [`vendored/README.md`](internal/vendored/README.md).
- [`history/`](internal/history/) — superseded LunarWing docs relocated here during the reorg, by source area: `architecture/`, `guides/`, `internal/`, `proposals/`. See [`history/README.md`](internal/history/README.md).

---

### 📝 Top-level docs

| File | Description |
|------|-------------|
| [`DOCS_AUDIT.md`](DOCS_AUDIT.md) | Documentation audit (M/L items): stale IronClaw references, naming inconsistencies, and their current status |
| [`DOCS_REORG_CHECKLIST.md`](DOCS_REORG_CHECKLIST.md) | Progress tracker + work log for the 2026-06 `docs/` reorganization |

---

## What Stays Outside `docs/`

The following are **not** in this directory and should remain where they are:

- **`README.md`** — repo root entry point
- **`CLAUDE.md` / `AGENTS.md` / `CODEX.md`** — AI agent context files (kept at their respective locations)
- **`ic/`** — all documentation within the `ic/` tree stays in place (workspace templates, crate docs, skill definitions, etc.)
- **`projects/`** — satellite service documentation stays with its source (e.g., `projects/ocr-sidecar/README.md`)
- **`codex4lunarwing/` / `lunarcode4lunarwing/` / `pebble4lunarwing/`** — worker-container docs stay with their container source
- **`.claude/`** — Claude command and rule files

---

## Contributing

When adding new documentation, place it in the appropriate subdirectory:

1. **`architecture/`** — if it describes *why* the system is designed a certain way
2. **`guides/`** — if it tells someone *how to do* something
3. **`ops/`** — if it covers *deployment or operations*
4. **`reference/`** — if it's a *spec, contract, or API doc*
5. **`proposals/`** — if it's a *proposal or design for not-yet-shipped work*
6. **`bugs/`** — if it's a *bug report* (and add it to [`bugs/README.md`](bugs/README.md))
7. **`internal/`** — if it's a *draft, note, or working document*

Superseded or shipped docs are archived under `internal/history/` (LunarWing-authored) or
`internal/vendored/` (third-party). Update this index when adding or moving files.
