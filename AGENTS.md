# Agent Rules

## Purpose and Precedence

- `AGENTS.md` is the quick-start contract for coding agents. It is not the full architecture spec.
- Read the relevant subsystem spec before changing a complex area. When a repo spec exists, treat it as authoritative.
Start with these deeper docs as needed (keep in mind most of these are outdated so you need to actually verify any information from them):
- `CLAUDE.md`
- `src/agent/CLAUDE.md`
- `src/channels/web/CLAUDE.md`
- `src/db/CLAUDE.md`
- `src/llm/CLAUDE.md`
- `src/setup/README.md`
- `src/tools/README.md`
- `src/workspace/README.md`
- `src/NETWORK_SECURITY.md`
- `tests/e2e/CLAUDE.md`
- `crates/lunarwing_engine/CLAUDE.md`
- In this repo, `ic/` contains the core daemon; however, the product name is LunarWing.

## Architecture Mental Model

- Channels normalize external input into `IncomingMessage`; `ChannelManager` merges all active channel streams.
- `Agent` owns session/thread/turn handling, submission parsing, the LLM/tool loop, approvals, routines, and background runtime behavior.
- `AppBuilder` is the composition root that wires database, secrets, LLMs, tools, workspace, extensions, skills, hooks, and cost controls before the agent starts.
- The web gateway is a browser-facing API/UI layered on top of the same agent/session/tool systems, not a separate product path.

## Where to Work

- Agent/runtime behavior: `src/agent/`
- Web gateway/API/SSE/WebSocket: `src/channels/web/`
- Persistence and DB abstractions: `src/db/`
- Setup/onboarding/configuration flow: `src/setup/`
- LLM providers and routing: `src/llm/`
- Workspace, memory, embeddings, search: `src/workspace/`
- Extensions, tools, channels, MCP, WASM: `src/extensions/`, `src/tools/`, `src/channels/`
- Docker sandbox and network proxy: `src/sandbox/`
- Container orchestrator and external workers: `src/orchestrator/`
- Secrets management: `src/secrets/`
- Lifecycle hooks: `src/hooks/`
- Tunnel abstraction (cloudflare, ngrok, tailscale): `src/tunnel/`
- SKILL.md prompt extensions: `src/skills/`
- Engine V2 bridge: `src/bridge/`
- Execution gate and approval pending state: `src/gate/`
- DM pairing for channels: `src/pairing/`
- Webhook ingress for tools: `src/webhooks/`
- Observability: `src/observability/`
- Extension registry catalog: `src/registry/`
- OpenClaw port staging work: `ic/openclaw-ports/`. For OpenClaw port tasks, keep edits inside `ic/openclaw-ports/` unless the user explicitly approves touching core LunarWing files.

## Build Constraints (Fedora Dev Machine)

This dev/test machine has limited resources. **All cargo commands must follow these rules:**

- **16 threads max**: prefix every cargo command with `taskset -c 0-15`
- **Use `cargo check` for compile verification, NOT `cargo build`** — full debug builds are wasteful and should be avoided. Reserve release builds (`cargo build --release`) for deploying to a new tenant or upgrading an existing tenant's release binary.
- **Use `taskset -c 0-15` for every cargo command**, not just `cargo build`. This applies to `cargo check`, `cargo test`, `cargo clippy`, `cargo doc`, etc.

```bash
taskset -c 0-15 cargo check -j16                              # compile check
taskset -c 0-15 cargo check -j16 --no-default-features --features postgres  # postgres-only
taskset -c 0-15 cargo check -j16 --no-default-features --features libsql    # libsql-only
taskset -c 0-15 cargo check -j16 --all-features               # all features
taskset -c 0-15 cargo test -j16 -- --test-threads=16            # unit tests
taskset -c 0-15 cargo clippy -j16 --all --benches --tests --examples -- -D warnings  # lint
taskset -c 0-15 cargo clippy -j16 --all --benches --tests --examples --all-features -- -D warnings
```

Long-running commands (5–20+ minutes) **must use tmux**:
```bash
tmux new-session -d -s build "taskset -c 0-15 cargo build --release -j16 2>&1 | tee /tmp/build.log"
```

## Build, Test, and Lint Commands

Run these from the `ic/` directory. Apply `taskset -c 0-15` and `-j16` per the build constraints above.

```bash
# Compile check (preferred over cargo build for verification)
cargo check
cargo check --all-features

# Build (release only when needed for deploy)
cargo build --release --bin lunarwing

# Run all tests
cargo test -- --nocapture

# Run a single test (exact match)
cargo test <test_name> -- --exact --nocapture

# Run a specific integration test file
cargo test --test <file_name> -- --nocapture

# Run tests with specific features
cargo test --no-default-features --features postgres
cargo test --all-features

# Format check
cargo fmt --all -- --check

# Lint (zero warnings policy)
cargo clippy --all --benches --tests --examples -- -D warnings
cargo clippy --all --benches --tests --examples --all-features -- -D warnings

# Dependency audit
cargo deny check

# Compile benchmarks without running
cargo bench --all-features --no-run

# Build WASM extensions (needed for some integration tests)
./scripts/build-wasm-extensions.sh             # all (tools + channels)
./scripts/build-wasm-extensions.sh --tools     # tools only
./scripts/build-wasm-extensions.sh --channels  # channels only
```

## Ownership and Composition Rules

- Keep `src/main.rs` and `src/app.rs` orchestration-focused. Do not move module-owned logic into entrypoints.
- Module-specific initialization should live in the owning module behind a public factory/helper, not be reimplemented ad hoc.
- Keep feature-flag branching inside the module that owns the abstraction whenever possible.
- Prefer extending existing traits and registries over hardcoding one-off integration paths.

## Repo-Wide Coding Rules

- **Edition**: Rust 2024, MSRV 1.92 or 1.96 or 1.96.1.
- **Formatting**: Standard `rustfmt`. Run `cargo fmt --all` before committing.
- **Imports**: Prefer `crate::` for cross-module references. Group std, external, then internal crates.
- **Error handling**: Use `thiserror` for structured errors and `anyhow` for propagation. Avoid `.unwrap()` and `.expect()` in production; they are allowed only in tests or for truly infallible invariants (e.g., literals/regexes) with a safety comment.
- **Types**: Use strong types and enums over stringly-typed control flow when the shape is known.
- **Naming**: Follow standard Rust conventions (`snake_case` for functions/variables, `PascalCase` for types/traits, `SCREAMING_SNAKE_CASE` for constants).
- **Complexity**: Keep functions under 100 lines, cognitive complexity under 15, and arguments under 7 (see `clippy.toml`).
- **Secrets**: Use the `secrecy` crate for sensitive values; never log or expose secrets.
- **Logging**: Use `tracing` macros (`info!`, `warn!`, `error!`) rather than `println!`.
- Keep clippy clean with zero warnings.

## Database, Setup, and Config Rules

- PostgreSQL is the primary backend and is far more heavily supported. libSQL support is aspirational — not every feature needs it, but do not regress existing libSQL coverage when possible.
- Add new DB operations to the shared DB trait first, then implement both backends. If libSQL work would be disproportionate to the feature, PostgreSQL-only is acceptable with a note in the relevant spec.
- Treat bootstrap config, DB-backed settings, and encrypted secrets as distinct layers; do not collapse them casually.
- If onboarding or setup behavior changes, update `src/setup/README.md` in the same branch.
- Do not break config precedence, bootstrap env loading, DB-backed config reload, or post-secrets LLM re-resolution.

## Security and Runtime Invariants

- Review any change touching listeners, routes, auth, secrets, sandboxing, approvals, or outbound HTTP with a security mindset.
- Do not weaken bearer-token auth, webhook auth, CORS/origin checks, body limits, rate limits, allowlists, or secret-handling guarantees.
- Treat Docker and podman containers and external services as untrusted.
- Session/thread/turn state matters. Submission parsing happens before normal chat handling.
- Skills are selected deterministically. Tool approval and auth flows are special paths and must not be mixed into normal chat history carelessly.
- Persistent memory is the workspace system, not just transcript storage; preserve file-like semantics, chunking/search behavior, and identity/system-prompt loading.

## Tools, Channels, and Extensions

- Use a built-in Rust tool for core internal capabilities tightly coupled to the runtime.
- Use WASM tools or WASM channels for sandboxed extensions and plugin-style integrations.
- Use MCP for external server integrations when the capability belongs outside the main binary.
- Preserve extension lifecycle expectations: install, authenticate/configure, activate, remove.

## Local XMPP and Service Operations

- Treat systemd unit environment values as secret-bearing. Do not paste passwords, bearer tokens, or webhook secrets into user-facing output; summarize or redact them.
- **Both systemd and OpenRC must be supported.** - launchd is prioritized signficantly less. Just prioritize OpenRC and systemd. 
- `xmpp-bridge.service` is coupled to `lunarwing.service` with `PartOf=lunarwing.service`, so LunarWing restarts can also restart the bridge. Do not assume the bridge caused a LunarWing stop just because both units restarted together.
- For install-style harness tests, prefer the rendered service units over leaving `scripts/lunarwing-xmpp-test-env.sh up` attached to a transient shell. The durable path is `render-systemd` plus `systemctl --user` on systemd hosts; `render-launchd` plus `launchctl` on macOS; OpenRC validation should use `lunarwing service install` or the committed OpenRC templates.
- The harness and service path intentionally seed `ALLOW_PRIVATE_IPS=1`, `DATABASE_SSLMODE=disable`, and `PGSSLMODE=disable` for private-network Postgres/TensorZero test setups. Preserve those defaults unless the task explicitly changes the network or SSL assumptions.
- Use `scripts/xmpp-rate-limit.sh` for live XMPP outbound rate-limit changes. It requires `XMPP_BRIDGE_TOKEN`; `status`, `set <n>`, `off`, and `reset` are the main commands.
- Use `scripts/xmpp-configure.sh` for bridge room/configuration checks and configure calls when working with the existing XMPP bridge API.
- The local service watchdog assets are `scripts/lunarwing-watchdog.sh` (systemd), `scripts/lunarwing-watchdog-openrc.sh` (OpenRC), `scripts/lunarwing-watchdog-launchd.sh` (macOS), `scripts/install-lunarwing-watchdog.sh`, `systemd/lunarwing-watchdog.service`, `systemd/lunarwing-watchdog.timer`, `systemd/lunarwing-watchdog.confd`, `systemd/lunarwing-watchdog.cron.hourly`, and `systemd/com.lunarwing.watchdog.plist` (launchd). The installer auto-detects `systemd` vs `OpenRC` vs `launchd`; on OpenRC it also auto-selects the scheduler. `auto` prefers an existing `cronie`/`crond`/`dcron` hourly setup and only falls back to a managed `fcron` entry when that avoids interfering.
- Prefer read-only diagnostics first for service issues: `systemctl status`, `systemctl show`, `journalctl`, and bridge status endpoints. Only restart services after identifying the unit state or when the user explicitly asks.
- If harness `verify` only fails the TensorZero proxy check, inspect the upstream `TENSORZERO_URL` before treating the local service install as broken. The local proxy can be bound and healthy while the upstream `/openai/v1/models` probe still returns `500`.

## Docs, Parity, and Testing

- If behavior changes, update the relevant docs/specs in the same branch.
- If you change implementation status for any feature tracked in `FEATURE_PARITY.md`, update that file in the same branch.
- Do not open a PR that changes feature behavior without checking `FEATURE_PARITY.md` for needed status updates (`❌`, `🚧`, `✅`, notes, and priorities).
- Add the narrowest tests that validate the change: unit tests for local logic, integration tests for runtime/DB/routing behavior, and E2E or trace coverage for gateway, approvals, extensions, or other user-visible flows.

## Risk and Change Discipline

- Keep changes scoped; avoid broad refactors unless the task truly requires them.
- Security, database schema, runtime, worker, CI, and secrets changes are high-risk. Call out rollback risks, compatibility concerns, and hidden side effects.
- Preserve existing defaults unless the task explicitly changes them.
- Avoid unrelated file churn and generated-file edits unless required.
- Respect a dirty worktree and never revert user changes you did not make.

## Before Finishing

- Confirm whether behavior changes require updates to `FEATURE_PARITY.md`, specs, API docs, or `CHANGELOG.md`.
- Run the most targeted tests/checks that cover the change.
- Re-check security-sensitive paths when touching auth, secrets, network listeners, sandboxing, or approvals.
- Keep the final diff scoped to the task.
