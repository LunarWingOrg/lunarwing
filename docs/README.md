# LunarWing Documentation

### This document is out of date.

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
| [`SELF_HEAL_DEPLOYMENT_WIRING.md`](architecture/SELF_HEAL_DEPLOYMENT_WIRING.md) | How the infra health-check + self-heal pipeline is installed/scheduled; why it's host-level (not per-tenant) and not wired into MT provisioning |

---

### 📖 [`guides/`](guides/)

How-to guides, build instructions, and setup walkthroughs.

| File | Description |
|------|-------------|
| [`EMBEDDINGS_SETUP.md`](guides/EMBEDDINGS_SETUP.md) | Embedding provider configuration (OpenAI-compatible, Ollama, NEAR AI) |
| [`VISION_OCR_SIDECAR.md`](guides/VISION_OCR_SIDECAR.md) | Vision/OCR sidecar service overview |
| [`MIGRATE_IRONCLAW_TO_LUNARWING.md`](guides/MIGRATE_IRONCLAW_TO_LUNARWING.md) | Migrating an existing IronClaw PostgreSQL instance to LunarWing |
| [`darkirc_channel_for_ironclaw/BUILD_INSTRUCTIONS.md`](guides/darkirc_channel_for_ironclaw/BUILD_INSTRUCTIONS.md) | DarkIRC channel build instructions |
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

Versioned release notes live in [`releases/`](releases/). Historical per-release prep checklists are archived in [`ops/history/`](ops/history/).

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
| [`RELEASE-v1.1.0.md`](releases/RELEASE-v1.1.0.md) | v1.1.0 release notes |
| [`RELEASE-v1.1.1.md`](releases/RELEASE-v1.1.1.md) | v1.1.1 release notes |
| [`RELEASE-v1.1.2.md`](releases/RELEASE-v1.1.2.md) | v1.1.2 release notes |
| [`RELEASE-v1.1.3.md`](releases/RELEASE-v1.1.3.md) | v1.1.3 release notes |
| [`RELEASE-v1.1.4.md`](releases/RELEASE-v1.1.4.md) | v1.1.4 release notes |
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

See [`bugs/README.md`](bugs/README.md) for the full Open/Fixed bug index (18 docs).

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
| [`FORK_CONTEXT.md`](internal/FORK_CONTEXT.md) | Fork history and context (authoritative; linked from `CLAUDE.md`) |
| [`.github/pull_request_template.md`](internal/.github/pull_request_template.md) | LunarWing PR template (review tracks, validation checklist) |
| [`ic-infrastructure-health-check/draft-ic-infrastructure-health-check-analysis-report.md`](internal/ic-infrastructure-health-check/draft-ic-infrastructure-health-check-analysis-report.md) | Health-check analysis draft |
| [`nanocode-config/KAGEHO_QUESTIONS.md`](internal/nanocode-config/KAGEHO_QUESTIONS.md) | Agnostic coding-worker container design notes |
| [`nanocode-config/NextSteps.md`](internal/nanocode-config/NextSteps.md) | Nanocode + TensorZero setup next steps |

**Archives** (kept for provenance, not active docs):

- [`vendored/`](internal/vendored/) — third-party upstream copies (nanocode/opencode) swept into `docs/` by an earlier bulk commit. See [`vendored/README.md`](internal/vendored/README.md).
- [`history/`](internal/history/) — superseded LunarWing docs relocated here during the docs reorg (by source area: `architecture/`, `guides/`, `internal/`). See [`history/README.md`](internal/history/README.md).

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
