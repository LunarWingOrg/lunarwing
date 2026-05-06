## LunarWing v1.0.0

First major release of LunarWing, a hard fork of IronClaw (NearAI). A self-hosted, privacy-first AI agent prioritizing open protocols and user freedom.

### Features

- **XMPP with OMEMO** — Full end-to-end encrypted messaging via WASM channel, bridge service, and core daemon integration (1:1 and group chat)
- **Gotify notifications** — WASM tool allowing agents to send push notifications via Gotify
- **WeeChat channel** — WASM channel enabling IRC/DarkIRC/Signal/XMPP/Matrix/RocketChat access through WeeChat relay
- **DarkIRC channel** — DarkFi-based WASM channel
- **Scheduling system with retry & backoff** — Native exponential backoff for transient failures (configurable RetryPolicy), stuck-run recovery, lightweight execution timeouts, and automatic orphaned-run sweeping
- **Systemd & OpenRC service units** — Production-ready service definitions for the daemon, XMPP bridge, and watchdog
- **Infrastructure health checks** — 8 parallel checks with automatic init-system detection (systemd/OpenRC), multi-tenant service auto-discovery
- **Watchdog scheduler** — Auto-healing watchdog with systemd timer or OpenRC hourly/fcron support
- **Multi-tenancy** — Production multi-tenant deployment via `lunarwing-mt-admin.sh` with per-user OS isolation, port registry, and support for systemd, OpenRC, and launchd
- **Cross-platform test harness** — Full-stack integration harness managing PostgreSQL, TensorZero, XMPP bridge, and WASM artifacts on Linux and macOS (systemd, OpenRC, launchd, PID-file fallback)
- **Secret management** — AES-256-GCM encrypted secrets store with OS keychain integration, wrapper scripts for PostgreSQL and libSQL
- **TensorZero proxy routing** — HTTP proxy configurations for model training feedback loops and tool_choice routing
- **REPLv2** — Enhanced REPL server and client with better formatting, subagent support, and processing indicators
- **Codex worker container** — Persistent OpenAI Codex worker with optional ACP bridge and mounted storage
- **Nanocode worker container** — Persistent NanoGPT community worker with optional ACP bridge
- **Fork bomb protection** — Security hardening against document extraction fork bombs
- **Credential mapping improvements** — Enhanced WASM tool and channel credential injection
- **Dual database backend** — PostgreSQL (primary) + libSQL/Turso with full feature parity
- **Binary rename** — Complete rename from `ironclaw` to `lunarwing` across binary, crates, services, and configuration

### Philosophy

LunarWing is built on Lunarpunk principles. We support only self-hostable, open-protocol communication layers. Proprietary channels (Slack, Discord, Telegram) are intentionally unsupported. Licensed AGPLv3.
