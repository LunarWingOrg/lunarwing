# Worker Container Images

Three container images provide sandboxed job execution for LunarWing.

## LunarWing Worker

The main sandbox worker. Includes dev tools (git, build-essential, Node.js, Python3, Rust, GitHub CLI) and Claude Code CLI. The orchestrator (`ic/src/orchestrator/`) manages container lifecycle, LLM proxying, and credential injection.

**Dockerfile:** `ic/Dockerfile.worker`

```bash
cd ic
docker build -f Dockerfile.worker -t lunarwing-worker:latest .
```

Runs as non-root user `sandbox` (UID 1000) in `/workspace`. Entrypoint is the `lunarwing` binary — the orchestrator passes the full command via Docker cmd.

## Codex Worker

Node.js-based Codex agent with WebSocket protocol bridge. Health endpoint on port 8443, WebSocket server on port 9090.

**Dockerfile:** `codex4ironclaw/Dockerfile`

```bash
cd codex4ironclaw
docker build -t lunarwing-codex-worker:latest .

# Or via docker-compose
docker compose up --build
```

Modes: `--mode cli` (one-shot) or `--mode websocket` (persistent). Requires `OPENAI_API_KEY` or TensorZero proxy config. See `codex4ironclaw/CLAUDE.md` for full env var reference.

## Nanocode Worker

Bun-based Nanocode agent. Runs nanocode headless server internally (port 4096) with a TypeScript bridge to the WebSocket protocol. Health on 8443, WebSocket on 9090.

**Dockerfile:** `nanocode4ironclaw/Dockerfile`

```bash
# Copy nanocode source (required, not checked in)
cp -R nanocode-config/nanocode nanocode4ironclaw/nanocode

cd nanocode4ironclaw
docker build -t lunarwing-nanocode-worker:latest .

# Or via docker-compose
docker compose up --build
```

Modes: `--mode websocket` (default, persistent), `--mode cli` (one-shot), `--mode acp`. Requires `AGENT_AUTH_TOKEN` for WebSocket auth. See `nanocode4ironclaw/CLAUDE.md` for full env var reference.

## Shared Protocol

All worker images use the `ironclaw-agent-v1` WebSocket subprotocol. Messages are JSON envelopes with `id`, `type`, `timestamp`, `payload`. The worker sends `ready` on connect, receives `task_request`, streams `task_progress`, and sends a final `task_result`.

## Proxy Note

On networks with TLS-intercepting proxies (e.g., corporate networks), Docker builds will fail with "server certificate not trusted" errors. Either build on a network without MITM proxies, or add the proxy CA certificate to each Dockerfile before the `apt-get`/`apk` steps.
