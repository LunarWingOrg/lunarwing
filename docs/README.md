# LunarWing Documentation

## Written by Starforce Nebula

This directory contains all project documentation organized by category.

## Directory Structure

### 📐 [`architecture/`](architecture/)

System design and technical architecture documents.

| File | Description |
|------|-------------|
| [`ENGINE-V2.md`](architecture/ENGINE-V2.md) | V2 engine architecture: threads, capabilities, CodeAct, gates, learning missions |
| [`SEMANTIC-MEMORY-SEARCH.md`](architecture/SEMANTIC-MEMORY-SEARCH.md) | Semantic memory search: embeddings, hybrid FTS+vector, RRF fusion, configuration |
| [`ATOMICBOOL_DEEPER_PROPAGATION.md`](architecture/ATOMICBOOL_DEEPER_PROPAGATION.md) | AtomicBool cancellation propagation design |
| [`HANDLE_MESSAGE_FIX.md`](architecture/HANDLE_MESSAGE_FIX.md) | Message handler timeout fix |
| [`RESPONSE_SUPPRESSION_IMPLEMENTATION.md`](architecture/RESPONSE_SUPPRESSION_IMPLEMENTATION.md) | Response suppression implementation |

---

### 📖 [`guides/`](guides/)

How-to guides, build instructions, and setup walkthroughs.

| File | Description |
|------|-------------|
| [`EMBEDDINGS_SETUP.md`](guides/EMBEDDINGS_SETUP.md) | Embedding provider configuration (OpenAI-compatible, Ollama, NEAR AI) |
| [`VISION_OCR_SIDECAR.md`](guides/VISION_OCR_SIDECAR.md) | Vision/OCR sidecar service overview |
| [`REFLEX_COMPILER_TESTING.md`](guides/REFLEX_COMPILER_TESTING.md) | Reflex compiler testing guide |
| [`MIGRATE_IRONCLAW_TO_LUNARWING.md`](guides/MIGRATE_IRONCLAW_TO_LUNARWING.md) | Migrating an existing IronClaw PostgreSQL instance to LunarWing |
| [`codex4ironclaw/HOW_TO_CONNECT_LUNARWING.md`](guides/codex4ironclaw/HOW_TO_CONNECT_LUNARWING.md) | Connecting to LunarWing via Codex |
| [`codex4ironclaw/INTEGRATION.md`](guides/codex4ironclaw/INTEGRATION.md) | Codex integration guide |
| [`codex4ironclaw/KAGEHO_INTEGRATION_GUIDE.md`](guides/codex4ironclaw/KAGEHO_INTEGRATION_GUIDE.md) | Kageho integration walkthrough |
| [`darkirc_channel_for_ironclaw/BUILD_INSTRUCTIONS.md`](guides/darkirc_channel_for_ironclaw/BUILD_INSTRUCTIONS.md) | DarkIRC channel build instructions |
| [`darkirc_channel_for_ironclaw/BUILD_REQUIREMENTS.md`](guides/darkirc_channel_for_ironclaw/BUILD_REQUIREMENTS.md) | DarkIRC build dependencies |
| [`darkirc_channel_for_ironclaw/DARKIRC_BUILD_GUIDE.md`](guides/darkirc_channel_for_ironclaw/DARKIRC_BUILD_GUIDE.md) | Full DarkIRC build guide |
| [`ironclaw_weechat_wss/weechat_relay/INSTALL.md`](guides/ironclaw_weechat_wss/weechat_relay/INSTALL.md) | WeeChat relay installation |
| [`nanocode-config/SETUP_NANOCODE_FOR_TENSORZERO.md`](guides/nanocode-config/SETUP_NANOCODE_FOR_TENSORZERO.md) | Nanocode setup for TensorZero |
| [`MIGRATE_IRONCLAW_TO_MT.md`](guides/MIGRATE_IRONCLAW_TO_MT.md) | PostgreSQL migration to multi-tenant |
| [`MIGRATE_IRONCLAW_LIBSQL_TO_MT.md`](guides/MIGRATE_IRONCLAW_LIBSQL_TO_MT.md) | libSQL cross-backend migration to multi-tenant |
| [`TESTING_GUIDE.md`](guides/TESTING_GUIDE.md) | Pre-release test checklist and automated release testing |
| [`ironclaw_weechat_wss/weechat_relay/TROUBLESHOOTING.md`](guides/ironclaw_weechat_wss/weechat_relay/TROUBLESHOOTING.md) | WeeChat relay troubleshooting |

---

### 🛠️ [`ops/`](ops/)

Deployment, operations, multitenancy, and production guides.

| File | Description |
|------|-------------|
| [`HARNESS-SINGLE-TENANT.md`](ops/HARNESS-SINGLE-TENANT.md) | Single-tenant test harness guide |
| [`MULTITENANCY-HARNESS.md`](ops/MULTITENANCY-HARNESS.md) | Multi-tenant test harness guide |
| [`MULTITENANCY-PRODUCTION.md`](ops/MULTITENANCY-PRODUCTION.md) | Production multi-tenancy configuration |
| [`TENANT-CONFIGURATION.md`](ops/TENANT-CONFIGURATION.md) | Per-tenant configuration reference (env, LLM, XMPP, ports) |
| [`WORKER-CONTAINERS.md`](ops/WORKER-CONTAINERS.md) | Worker container images (LunarWing, Codex, Nanocode) |
| [`NANOCODE-MULTITENANT.md`](ops/NANOCODE-MULTITENANT.md) | Nanocode external worker, multi-tenant setup |
| [`PEBBLE-WORKER.md`](ops/PEBBLE-WORKER.md) | Pebble external worker operational guide |
| [`WEECHAT-SERVICES.md`](ops/WEECHAT-SERVICES.md) | WeeChat services, ports, env vars, day-to-day ops |
| [`WEECHAT-MULTITENANT-PORT-BUG.md`](ops/WEECHAT-MULTITENANT-PORT-BUG.md) | Per-tenant WeeChat port/password fix |
| [`XMPP_KNOWN_ISSUES.md`](ops/XMPP_KNOWN_ISSUES.md) | XMPP/OMEMO known issues |
| [`KNOWN_ISSUES_TO_ADDRESS.md`](ops/KNOWN_ISSUES_TO_ADDRESS.md) | Ops known-issues scratchpad |
| [`PENDING_CLEANUP.md`](ops/PENDING_CLEANUP.md) | Forward-looking cleanup checklist |
| [`FUTURE_RELEASE_ITEMS.md`](ops/FUTURE_RELEASE_ITEMS.md) | Longer-horizon / unscheduled ideas |
| [`PRE-RELEASE-TESTING.md`](ops/PRE-RELEASE-TESTING.md) | Pre-release test status + test landscape |
| [`RELEASE_CADENCE.md`](ops/RELEASE_CADENCE.md) | Release cadence policy |
| [`RELEASE-COMMANDS.md`](ops/RELEASE-COMMANDS.md) | Release git/GitHub command template |
| [`GOALS_1.1.2.md`](ops/GOALS_1.1.2.md) | v1.1.2 release checklist (current) |
| [`GOALS_1.1.2_INFRA_HEALTH_CHECK.md`](ops/GOALS_1.1.2_INFRA_HEALTH_CHECK.md) | v1.1.2 infra health-check + self-heal notes |
| [`RELEASE-v1.1.0.md`](ops/RELEASE-v1.1.0.md) | v1.1.0 release notes |
| [`RELEASE-v1.1.1.md`](ops/RELEASE-v1.1.1.md) | v1.1.1 release notes |

Historical per-release prep checklists are archived in [`ops/history/`](ops/history/).

---

### 📋 [`reference/`](reference/)

Protocol specs, contract definitions, and API references.

| File | Description |
|------|-------------|
| [`custom_bridges/XMPP.md`](reference/custom_bridges/XMPP.md) | XMPP bridge protocol and configuration |

---

### 💡 [`proposals/`](proposals/)

Feature proposals, design documents, and project planning.

| File | Description |
|------|-------------|
| [`MULTICA_SUPPORT.md`](proposals/MULTICA_SUPPORT.md) | Multica/Lunartica integration proposal |
| [`LOREBOOKS.md`](proposals/LOREBOOKS.md) | Lorebooks feature proposal |
| [`GITHUB_ACCS.md`](proposals/GITHUB_ACCS.md) | GitHub accounts proposal |
| [`GITWASM/README.md`](proposals/GITWASM/README.md) | Git WASM tool proposal |
| [`VisionProject/README.md`](proposals/VisionProject/README.md) | Vision service project overview |
| [`VisionProject/KAGEHO_SUMMARY.md`](proposals/VisionProject/KAGEHO_SUMMARY.md) | OCR/Vision integration discussion summary |
| [`VisionProject/KAGEHO_BUILD_PLAN.md`](proposals/VisionProject/KAGEHO_BUILD_PLAN.md) | Kageho vision build plan |
| [`VisionProject/KAGEHO_LOG.md`](proposals/VisionProject/KAGEHO_LOG.md) | Kageho vision implementation log |
| [`VisionProject/VISION-SERVICE.md`](proposals/VisionProject/VISION-SERVICE.md) | Vision service design spec |
| [`VisionProject/LunarWingVisionServicev1.1.md`](proposals/VisionProject/LunarWingVisionServicev1.1.md) | Vision service v1.1 spec |
| [`reflex-compiler.md`](proposals/reflex-compiler.md) | Reflex compiler design proposal |
| [`NANOCODE_WORKER_SECRETS.md`](proposals/NANOCODE_WORKER_SECRETS.md) | Nanocode worker secrets integration |

---

### 📦 [`releases/`](releases/)

Release notes and changelogs.

| File | Description |
|------|-------------|
| [`RELEASE-v1.0.7.md`](releases/RELEASE-v1.0.7.md) | v1.0.7 release notes (2026-05-17) |
| [`CHANGELOG-AGENTS.md`](releases/CHANGELOG-AGENTS.md) | AGENTS.md change history |

---

### 🐛 [`bugs/`](bugs/)

Bug reports, analyses, and proposed fixes.

| File | Description |
|------|-------------|
| [`BUG-daemon-stops-polling-xmpp-bridge.md`](bugs/BUG-daemon-stops-polling-xmpp-bridge.md) | Daemon stops polling XMPP bridge (fixed) |
| [`BUG-subagent-worker-hang.md`](bugs/BUG-subagent-worker-hang.md) | Subagent worker hang (fixed) |
| [`BUG-unbounded-mpsc-recv-in-spawned-tasks.md`](bugs/BUG-unbounded-mpsc-recv-in-spawned-tasks.md) | Unbounded mpsc recv in spawned tasks (open) |
| [`BUG-LAPSE.md`](bugs/BUG-LAPSE.md) | Agent "lapse" — `<function=NAME>` tool-call dialect recovery (fixed) |
| [`WEECHAT-NO-SECRET-ACCESS.md`](bugs/WEECHAT-NO-SECRET-ACCESS.md) | WeeChat tool secret access (fixed) |

See [`bugs/README.md`](bugs/README.md) for the full Open/Fixed bug index (15 docs).

---

### 📝 [`DOCS_AUDIT.md`](DOCS_AUDIT.md)

Full documentation audit (medium and low priority items) identifying stale IronClaw references, missing index entries, and naming inconsistencies.

---

### 🗂️ [`internal/`](internal/)

Internal notes, drafts, historical context, and vendored documentation. These are working documents and may be incomplete or outdated.

<details>
<summary>Expand file list</summary>

| File | Description |
|------|-------------|
| [`BRANCHES.md`](internal/BRANCHES.md) | Branch tracking notes |
| [`FORK_CONTEXT.md`](internal/FORK_CONTEXT.md) | Fork history and context |
| [`GRANT_PROPOSAL_FRAMEWORK.md`](internal/GRANT_PROPOSAL_FRAMEWORK.md) | Grant proposal template |
| [`REPLv2_Client_and_Server.md`](internal/REPLv2_Client_and_Server.md) | REPL v2 design notes |
| [`codex4ironclaw/DEPRECATED.md`](internal/codex4ironclaw/DEPRECATED.md) | Deprecated Codex features |
| [`codex4ironclaw/PASSING_SECRETS.md`](internal/codex4ironclaw/PASSING_SECRETS.md) | Secrets passing reference |
| [`codex4ironclaw/kageho_other_ideas/draft2.md`](internal/codex4ironclaw/kageho_other_ideas/draft2.md) | Kageho ideas draft |
| [`custom_channels/DarkIRC.md`](internal/custom_channels/DarkIRC.md) | DarkIRC channel notes |
| [`custom_channels/Weechat.md`](internal/custom_channels/Weechat.md) | WeeChat channel notes |
| [`custom_external_scripts/Secret_Manager.md`](internal/custom_external_scripts/Secret_Manager.md) | Secret manager scripts |
| [`custom_external_scripts/enjin.md`](internal/custom_external_scripts/enjin.md) | Enjin integration notes |
| [`custom_healthcheck_and_timers/healthcheck.md`](internal/custom_healthcheck_and_timers/healthcheck.md) | Health check scripts |
| [`custom_tools/Gotify.md`](internal/custom_tools/Gotify.md) | Gotify tool reference |
| [`custom_tools/codex4ironclaw.md`](internal/custom_tools/codex4ironclaw.md) | Codex tool reference |
| [`custom_tools/git-md.md`](internal/custom_tools/git-md.md) | Git-md tool reference |
| [`darkirc_channel_for_ironclaw/CONTRIBUTING.md`](internal/darkirc_channel_for_ironclaw/CONTRIBUTING.md) | DarkIRC contributing guide |
| [`docs/APPROACH_TO_DOCS.md`](internal/docs/APPROACH_TO_DOCS.md) | Documentation strategy |
| [`docs/EXAMPLES.md`](internal/docs/EXAMPLES.md) | Usage examples |
| [`ic-infrastructure-health-check/...`](internal/ic-infrastructure-health-check/) | Health check analysis draft |
| [`nanocode-config/`](internal/nanocode-config/) | Nanocode/nanocode.nvim vendored docs |
| [`tensorzero-proxy-configurations/TEST.md`](internal/tensorzero-proxy-configurations/TEST.md) | TensorZero proxy test notes |

</details>

---

## What Stays Outside `docs/`

The following files are **not** in this directory and should remain where they are:

- **`README.md`** — repo root entry point
- **`CLAUDE.md` / `AGENTS.md` / `CODEX.md`** — AI agent context files (kept at their respective locations)
- **`ic/`** — all documentation within the `ic/` tree stays in place (includes workspace templates, crate docs, skill definitions, etc.)
- **`projects/`** — satellite service documentation stays with its source (e.g., `projects/ocr-sidecar/README.md`)
- **`lunarcode4lunarwing/`** — nanocode worker docs stay with the container source
- **`codex4ironclaw/`** — codex worker docs stay with the container source
- **`.claude/`** — Claude command and rule files

---

## Contributing

When adding new documentation, place it in the appropriate subdirectory:

1. **`architecture/`** — if it describes *why* the system is designed a certain way
2. **`guides/`** — if it tells someone *how to do* something
3. **`ops/`** — if it covers *deployment or operations*
4. **`reference/`** — if it's a *spec, contract, or API doc*
5. **`internal/`** — if it's a *draft, note, or working document*

Update this README when adding new files.
