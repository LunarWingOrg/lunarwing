# Worker Container Images

Several container images provide sandboxed and persistent job execution for LunarWing.

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

**Dockerfile:** `codex4lunarwing/Dockerfile`

```bash
cd codex4lunarwing
docker build -t lunarwing-codex-worker:latest .

# Or via docker-compose
docker compose up --build
```

Modes: `--mode cli` (one-shot) or `--mode websocket` (persistent). Requires `OPENAI_API_KEY` or TensorZero proxy config. See `codex4lunarwing/CLAUDE.md` for full env var reference.

## Nanocode Worker

Bun-based Nanocode agent. Runs nanocode headless server internally (port 4096) with a TypeScript bridge to the WebSocket protocol. Health on 8443, WebSocket on 9090.

**Dockerfile:** `lunarcode4lunarwing/Dockerfile`

```bash
# Copy nanocode source (required, not checked in)
cp -R nanocode-config/nanocode lunarcode4lunarwing/nanocode

cd lunarcode4lunarwing
docker build -t lunarwing-nanocode-worker:latest .

# Or via docker-compose
docker compose up --build
```

Modes: `--mode websocket` (default, persistent), `--mode cli` (one-shot), `--mode acp`. Requires `AGENT_AUTH_TOKEN` for WebSocket auth. See `lunarcode4lunarwing/CLAUDE.md` for full env var reference.

## Pebble Worker

Rust-based Pebble agentic coding harness. Bridges the NanoGPT community `pebble` binary to the WebSocket protocol. Health on 8443, WebSocket on 9090.

**Dockerfile:** `pebble4lunarwing/Dockerfile`

```bash
cd pebble4lunarwing
docker build -t lunarwing-worker-pebble:latest .

# Or via the mt-admin lifecycle
sudo ic/scripts/lunarwing-mt-admin.sh build-pebble-worker
```

Persistent worker mode (`PEBBLE_MODE=websocket`). Requires `AGENT_AUTH_TOKEN` for WebSocket auth and optionally `NANOGPT_API_KEY` for the underlying NanoGPT backend (configure per-tenant via `configure-pebble <name> --nanogpt-api-key <key>`). See `pebble4lunarwing/` for details.

## Opencode Worker

[opencode](https://opencode.ai) (sst/opencode) integrated as a persistent LunarWing external worker. A Bun/TypeScript bridge wraps the `@opencode-ai/sdk` and translates between the opencode session/event model and the `lunarwing-agent-v1` WebSocket protocol. The opencode headless server runs internally on `127.0.0.1:4096` (not exposed). Health on 8443, WebSocket on 9090.

**Dockerfile:** `opencode4lunarwing/Dockerfile`

```bash
cd opencode4lunarwing
docker build -t lunarwing-worker-opencode:latest .

# Or via the mt-admin lifecycle
sudo ic/scripts/lunarwing-mt-admin.sh build-opencode-worker

# Or as part of a per-tenant build
sudo ic/scripts/lunarwing-mt-admin.sh build-tenant <name> --with-opencode
```

Modes: `--mode websocket` (default, persistent) or `--mode cli` (one-shot; prompt via `TASK_PROMPT`). Requires `AGENT_AUTH_TOKEN` for WebSocket auth. Supports per-tenant model/base-URL overrides via `configure-opencode <name> [--model <m>] [--base-url <url>]`, optional Paseo MCP integration (`PASEO_URL`/`PASEO_TOKEN`), and SSH agent socket bind-mounting. The opencode upstream is cloned at build time and pinned to a release tag via the `OPENCODE_REF` build arg (default `v1.17.13`); override with `docker build --build-arg OPENCODE_REF=<tag>`. See `opencode4lunarwing/CLAUDE.md` for the full env var reference.

## OpenCode Worker (old section)

Bun-based upstream opencode agent (sst/opencode). Runs opencode headless server internally (port 4096) with a TypeScript bridge to the WebSocket protocol. Health on 8443, WebSocket on 9090.

**Dockerfile:** `opencode4lunarwing/Dockerfile`

```bash
cd opencode4lunarwing
docker build -t lunarwing-worker-opencode:latest .

# Or via docker-compose
docker compose up --build
```

Modes: `--mode websocket` (default, persistent), `--mode cli` (one-shot), `--mode acp`. Requires `AGENT_AUTH_TOKEN` for WebSocket auth. Supports optional Paseo MCP integration via `PASEO_URL`/`PASEO_TOKEN` env vars. See `opencode4lunarwing/CLAUDE.md` for full env var reference.


## Shared Protocol

All worker images use the `lunarwing-agent-v1` WebSocket subprotocol; the legacy `ironclaw-agent-v1` name is still accepted as an alias for one release. Messages are JSON envelopes with `id`, `type`, `timestamp`, `payload`. The worker sends `ready` on connect, receives `task_request`, streams `task_progress`, and sends a final `task_result`.

## Proxy Note

On networks with TLS-intercepting proxies (e.g., corporate networks), Docker builds will fail with "server certificate not trusted" errors. Either build on a network without MITM proxies, or add the proxy CA certificate to each Dockerfile before the `apt-get`/`apk` steps.
