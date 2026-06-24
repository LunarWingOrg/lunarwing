# Nanocode Workers for OpenClaw — Assessment

**Date:** 2026-05-22  
**Author:** Baud (with input from Ruffles' original drafts)  
**Status:** Assessment — not implemented

## Executive Summary

The Lunarwing monorepo already contains production-ready nanocode worker containers (`nanocode4ironclaw/`) originally built for Ironclaw/Lunarwing agents. These workers provide remote AI-powered coding execution with a 32GB DDR5 footprint, keeping Pi-based agent hosts lightweight. Ruffles drafted integration guides but wrote them from an Ironclaw perspective — many assumptions about `create_job` tools and tenant-scoped job queues don't apply to OpenClaw.

This document maps the real architecture of the existing workers and proposes concrete adaptation paths for OpenClaw integration.

---

## 1. What Exists: The Nanocode Worker (Lunarwing)

### Container Architecture

```
┌────────────────────────── Docker Container ──────────────────────────┐
│  entrypoint.sh (tini)                                                 │
│    ├── health_server.py      → port 8443 (/health, /ready)            │
│    ├── nanocode serve         → port 4096 (internal HTTP/SSE)          │
│    └── ironclaw_bridge.ts    → port 9090 (WebSocket, ironclaw-agent-v1)│
└───────────────────────────────────────────────────────────────────────┘
```

**Source:** `repos/lunarwing/nanocode4ironclaw/`  
**Runtime:** Bun + TypeScript  
**Base image:** `oven/bun:1.3-debian`  
**Source required at build:** Must copy `nanocode-config/nanocode` into build context (not checked in to Lunarwing repo; from https://github.com/nanogpt-community/nanocode).

### Three Operating Modes

| Mode | Command | What it does |
|------|---------|-------------|
| `websocket` | `--mode websocket` | Starts nanocode serve (internal HTTP/SSE) + WebSocket bridge for Ironclaw agent protocol |
| `cli` | `--mode cli -- "prompt"` | One-shot: launches nanocode with a prompt, prints results, exits |
| `acp` | `--mode acp` | ACP stdio server — speaks the Agent Communication Protocol over stdin/stdout |

### WebSocket Protocol (ironclaw-agent-v1)

- **Auth:** Bearer token (`AGENT_AUTH_TOKEN` env var, optional — empty = dev mode no-auth)
- **Subprotocol:** `ironclaw-agent-v1`
- **Message format:** JSON envelope `{id, type, timestamp, payload}`
- **Flow:** ready → task_request → task_progress (streaming) → task_result
- **Protocol spec:** `agent_comm_protocol.json`

### ACP Mode Implementation

The ACP mode is a **full stdio-based ACP server** using `@agentclientprotocol/sdk`. It:
- Launches nanocode's internal HTTP server to back SDK operations
- Creates an `AgentSideConnection` over ndjson stdin/stdout
- Implements the full ACP agent interface: `initialize`, `newSession`, `loadSession`, `prompt`, `cancel`, `setSessionModel`, `setSessionMode`, `forkSession`, `resumeSession`, `listSessions`
- Streams tool execution, text deltas, and agent thoughts as ACP session updates
- Handles permission requests from nanocode → forwarded to ACP client

**Key files:**
- `nanocode-config/nanocode/packages/opencode/src/acp/agent.ts` — full ACP agent class (~800 lines)
- `nanocode-config/nanocode/packages/opencode/src/acp/session.ts` — session state tracking
- `nanocode-config/nanocode/packages/opencode/src/cli/cmd/acp.ts` — CLI entry point wiring

### Storage Model

The worker container has a persistent `/workspace` volume. Build artifacts, cloned repos, and generated files persist across jobs. This makes Pattern B (shared filesystem) from Ruffles' draft the default behavior, not an add-on.

### Build Requirements

```bash
# Prerequisite: nanocode source must be available
cp -R nanocode-config/nanocode nanocode4ironclaw/nanocode

cd nanocode4ironclaw
docker build -t lunarwing-nanocode-worker:latest .
```

The Dockerfile is multi-stage: Stage 1 builds nanocode from TypeScript source via bun, Stage 2 produces a slim runtime image with the built artifacts. The build needs `bun install` + `bun run build` on the nanocode packages.

---

## 2. The Gap: Ironclaw vs OpenClaw Architecture

### What Ironclaw/Lunarwing Has That OpenClaw Doesn't

| Ironclaw Feature | Purpose | OpenClaw Equivalent |
|-----------------|---------|-------------------|
| `create_job` WASM tool | Dispatch tasks to workers | **None** |
| Job queue / orchestrator | Manage container lifecycle, credentials injection | **None** |
| Tenant-scoped workspace isolation | Multiple agents on same worker | **None built-in** |
| Agent WebSocket client natively in runtime | Agents connect to worker WS directly | **No native WS tool** |
| `ic/src/orchestrator/` | Container lifecycle for Lunarwing workers | **None** |

### What OpenClaw Has

| OpenClaw Feature | Relevance |
|-----------------|-----------|
| `sessions_spawn(runtime="acp")` | Can spawn ACP sub-agents if `agentId` is configured in `acp.allowedAgents` |
| Skills system | Can build custom skill wrappers |
| `exec` tool | Can shell out to CLI / scripts / Docker |
| `message` / channel plugins | Can receive task requests conversationally |

---

## 3. Integration Path A: ACP Bridge (Most Native)

### How It Would Work

1. Nanocode worker container runs with `--mode acp`
2. OpenClaw's `sessions_spawn(runtime="acp")` connects to it as an ACP sub-agent
3. Agent says "build the Rust project in /workspace/my-app" → OpenClaw spawns an ACP session → nanocode worker executes → results stream back via ACP protocol
4. Sessions are stateful and resumable

### What's Already Built

The nanocode `acp/agent.ts` is a complete ACP server implementation. It handles:
- Session creation with MCP server attachment
- Prompt submission with text/image/resource context
- Streaming progress (text deltas, tool calls, thoughts)
- Permission requests forwarded to host
- Session resumption, listing, forking
- Model/mode selection

### What Needs to Be Built / Resolved

1. **OpenClaw ACP Harness Configuration**
   - Current config has no `acp` section at all (`openclaw config get acp` → not found)
   - Need to configure `acp.allowedAgents` with a nanocode agent entry
   - Need to understand what `agentId` format the harness expects (binary path? command?)
   - OpenClaw's `acp client --server <command>` suggests it spawns commands via stdio — this matches nanocode's ACP mode perfectly

2. **Nanocode Worker Startup**
   - In the Dockerfile, ACP mode runs `bun run src/index.ts acp` — needs Bun runtime in the container
   - The nanocode source must be pre-built into the image (already handled by Dockerfile stages)
   - LLM provider config (`opencode.json`) must point to TensorZero or a valid LLM endpoint
   - API keys must be set (`TENSORZERO_API_KEY` or equivalent)

3. **Protocol Compatibility**
   - Both use `@agentclientprotocol/sdk` — same protocol spec
   - ACP protocol version negotiation happens at `initialize`
   - Capability mismatch is possible but unlikely since they share the same SDK
   - OpenClaw's ACP client may have assumptions about what agent capabilities are expected

4. **Container Lifecycle**
   - Who starts/stops the nanocode worker container?
   - For ACP mode, the harness would need to spawn the container per session, or keep a persistent container and reconnect
   - Docker socket access needed on the host running OpenClaw

### Effort Estimate: Medium (2-4 days of focused work)
- **Day 1:** Stand up worker container, verify ACP mode works with manual stdio test
- **Day 2:** Configure OpenClaw ACP harness, test basic session creation and prompt
- **Day 3:** Handle edge cases (auth, model selection, streaming, error recovery)
- **Day 4:** Polish, documentation, integration with existing agent workflows

---

## 4. Integration Path B: OpenClaw Skill Wrapper (Most Practical Short-Term)

### How It Would Work

1. Worker container runs in WebSocket mode (`--mode websocket`)
2. New OpenClaw skill: `nanocode-worker` 
3. Skill scripts handle:
   - Connecting to worker WebSocket
   - Sending task requests
   - Receiving streaming progress
   - Polling for completion
   - Returning results to the agent
4. Agent invokes via natural language: "Run a nanocode job that builds the Rust project"
5. Skill translates to WebSocket calls, streams results back

### What Already Exists

- Full WebSocket protocol (`ironclaw-agent-v1`) — documented, implemented, tested with Ironclaw agents
- `agent_comm_protocol.json` — complete message spec
- `scripts/smoke_test.ts` — reference implementation of a client connecting to the worker
- Health endpoints for readiness checking

### What Needs to Be Built

1. **Skill skeleton:** `skills/nanocode-worker/SKILL.md` + script(s)
2. **WebSocket client:** A script (Node/Bun/Python) that:
   - Connects to `ws://<worker>:9090/ws/agent` with subprotocol `ironclaw-agent-v1`
   - Authenticates with `AGENT_AUTH_TOKEN`
   - Sends `task_request` and streams `task_progress` / `task_result`
   - Handles reconnection, timeouts, errors
3. **Skill integration:** Wire the skill's tool call into the OpenClaw skill system so the agent can invoke it
4. **Result formatting:** Map worker output back into the agent's conversation

### Effort Estimate: Low-Medium (1-3 days)
- **Day 1:** Write WebSocket client script, test against local worker
- **Day 2:** Create skill wrapper, integrate with OpenClaw
- **Day 3:** Edge cases, error handling, documentation

### Pros vs ACP
- ✅ Simpler — no harness config, no ACP protocol negotiation
- ✅ Worker can run persistently — no per-request container startup
- ✅ Reuses battle-tested WebSocket protocol
- ✅ Decoupled — the skill can evolve independently of OpenClaw core
- ❌ Less "native" feel — manual protocol vs automatic session management
- ❌ More code to write — custom WebSocket client vs leveraging existing ACP infra
- ❌ No automatic session resumption (without additional work)

---

## 5. Integration Path C: Exec-Mediated (Quickest, Least Elegant)

### How It Would Work

1. Worker container runs in CLI mode (`--mode cli -- "prompt"`)
2. OpenClaw's `exec` tool runs `docker run lunarwing-nanocode-worker --mode cli -- "build the Rust project"`
3. Output is captured from stdout
4. No streaming, no state, no session management

### Effort Estimate: Hours
- Trivial to set up
- Brittle for complex workflows
- No progress feedback
- Every invocation is stateless

**Verdict:** Fine for a 5-minute spike to verify the worker works. Not suitable for real use.

---

## 6. Recommended Approach

### Short Term: Path B (Skill Wrapper + WebSocket)

Fastest path to a working integration with the least OpenClaw internal coupling. The WebSocket protocol already works, the smoke test proves end-to-end connectivity, and a skill can be built incrementally.

### Long Term: Path A (ACP Bridge)

Once the skill path proves the worker is useful in practice, invest in the ACP harness integration. This gives stateful sessions, resumable contexts, and tighter protocol integration. It also aligns with the direction nanocode is heading — the ACP agent implementation is substantial and actively maintained.

### What NOT to do: Path C for anything beyond a smoke test

---

## 7. Open Questions

1. **Nanocode source availability:** The worker Dockerfile requires copying nanocode source from `nanocode-config/nanocode`. Where does this live? Is it already on a machine with Docker, or do we need to clone from the nanocode community repo?

2. **LLM provider config:** The worker's `opencode.json` points at TensorZero (`http://192.168.1.157:3000`). Is this accessible from wherever the worker container will run? Need `TENSORZERO_API_KEY` set.

3. **Worker host:** Where does the container run? Same machine as OpenClaw (cotterhomelab3)? Or a separate beefier machine? The 32GB DDR5 reference in Ruffles' doc suggests dedicated hardware.

4. **Multi-agent isolation:** If multiple OpenClaw agents (Baud, Volta, Sweetiebot) all use the same worker, how do we isolate their workspaces? The WebSocket protocol doesn't have built-in tenant scoping. Options:
   - Separate containers per agent (cleanest, most resource-intensive)
   - Subdirectories in shared `/workspace` (simplest, risk of cross-contamination)
   - Worker auth token per agent + workspace path prefix

5. **OpenClaw ACP harness agentId format:** Need to understand what `acp.allowedAgents` entries look like. Is it `{id: "nanocode", command: "docker", args: ["run", "-i", "lunarwing-nanocode-worker", "--mode", "acp"]}`? Or something else?

---

## 8. References

- Lunarwing repo: `repos/lunarwing/` (already in workspace)
- Nanocode worker: `repos/lunarwing/nanocode4ironclaw/`
- Worker containers overview: `repos/lunarwing/docs/ops/WORKER-CONTAINERS.md`
- Nanocode ACP agent: `repos/lunarwing/nanocode-config/nanocode/packages/opencode/src/acp/agent.ts`
- Ruffles' original drafts: `openclaw-nanocode-guide.md` and `nanocode-storage-architecture.md` (shared via desu.si)
- OpenClaw ACP CLI: `openclaw acp --help` / `openclaw acp client --help`


