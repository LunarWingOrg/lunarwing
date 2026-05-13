# Multica/Lunartica Integration Plan for LunarWing

## Problem

LunarWing is WASM-native — capabilities are declared and sandboxed, not CLI-detected. Multica's daemon protocol assumes CLI runtimes discovered via stdio/TCP (OpenClaw, Claude Code, Codex, etc.). To make LunarWing a first-class Multica runtime, we need a bridge layer that speaks the Multica daemon protocol from within LunarWing's WASM tool/channel/routine architecture.

## Multica Daemon Protocol Summary

The Multica server exposes a daemon API at `/api/daemon/` authenticated via daemon tokens (`mdt_*`) or PAT tokens (`mul_*`). The lifecycle:

1. **Register** — `POST /api/daemon/register` with `daemon_id`, `workspace_id`, and a list of `runtimes` (type, version, status). Returns runtime UUIDs.
2. **Heartbeat** — `POST /api/daemon/heartbeat` (or `daemon:heartbeat` over WebSocket). Keeps runtime `last_seen_at` fresh. Server replies with pending actions (updates, model list requests, skill import requests).
3. **Claim task** — `POST /api/daemon/runtimes/{runtimeId}/tasks/claim`. Atomically dequeues the next task for this runtime. Returns task details + agent data (name, instructions, skills, custom env/args, MCP config).
4. **Task lifecycle** — `POST /api/daemon/tasks/{taskId}/start`, `/progress`, `/complete`, `/fail`, `/usage`, `/messages`, `/session`.
5. **WebSocket** — `GET /api/daemon/ws?runtime_id=...` for real-time push events (`daemon:task_available`, `daemon:heartbeat_ack`).
6. **Orphan recovery** — `POST /api/daemon/runtimes/{runtimeId}/recover-orphans` on startup.

User-facing APIs (authenticated differently) provide issue CRUD (`/api/issues`), comments (`/api/comments`), agents (`/api/agents`), skills (`/api/skills`), and runtimes (`/api/runtimes`).

## Architecture Decision

**LunarWing will act as a Multica daemon**, not just a tool consumer. This means LunarWing registers itself as a runtime, claims tasks from the board, executes them using its own agent loop, and reports results back. This is the correct abstraction because:

- LunarWing already has a full agent loop (LLM ↔ tool dispatch, sessions, context management)
- Tasks from Multica map naturally to LunarWing jobs
- LunarWing's routine system provides the polling/heartbeat infrastructure
- WASM tools handle the Multica API calls in a sandboxed way

---

## Phase 1: WASM Tool — `multica-bridge`

**Goal:** LunarWing can poll a Multica board, claim tasks, report progress/completion, and post comments. Agent uses it via routines.

### Components

#### 1a. WASM Tool: `multica-bridge`

Location: `ic/tools-src/multica-bridge/`

A single WASM tool that exposes multiple operations via an `action` parameter. This follows the existing tool pattern (one WASM module, one capabilities file, multiple logical operations distinguished by params).

**Actions:**

| Action | Multica API | Description |
|--------|-------------|-------------|
| `register` | `POST /api/daemon/register` | Register LunarWing as a runtime. Stores runtime ID in workspace config. |
| `heartbeat` | `POST /api/daemon/heartbeat` | Send heartbeat, return any pending actions. |
| `claim_task` | `POST /runtimes/{id}/tasks/claim` | Claim next available task. Returns task details or null. |
| `start_task` | `POST /tasks/{id}/start` | Mark task as started. |
| `complete_task` | `POST /tasks/{id}/complete` | Mark task as completed, attach PR URL/output. |
| `fail_task` | `POST /tasks/{id}/fail` | Mark task as failed with reason. |
| `report_progress` | `POST /tasks/{id}/progress` | Report progress summary/step/total. |
| `post_comment` | `POST /api/issues/{id}/comments` | Post a comment on an issue (uses user API, not daemon API). |
| `list_issues` | `GET /api/issues?status=...&assignee_id=...` | List issues (filtered by status, assignee, etc.). |
| `get_issue` | `GET /api/issues/{id}` | Get issue details. |
| `update_issue` | `PUT /api/issues/{id}` | Update issue status/priority/assignee. |
| `recover_orphans` | `POST /runtimes/{id}/recover-orphans` | Recover tasks orphaned by prior crash. |
| `report_messages` | `POST /tasks/{id}/messages` | Report agent execution messages (tool calls, text). |

**Capabilities file** (`multica-bridge.capabilities.json`):

```json
{
  "name": "multica-bridge",
  "display_name": "Multica/Lunartica Bridge",
  "description": "Bridge between LunarWing and a Multica/Lunartica task management server",
  "version": "0.1.0",
  "tools": [
    {
      "name": "multica",
      "description": "Interact with a Multica/Lunartica server. Actions: register, heartbeat, claim_task, start_task, complete_task, fail_task, report_progress, post_comment, list_issues, get_issue, update_issue, recover_orphans, report_messages.",
      "parameters": {
        "type": "object",
        "properties": {
          "action": { "type": "string", "description": "The operation to perform" },
          "task_id": { "type": "string", "description": "Task UUID (for task lifecycle actions)" },
          "issue_id": { "type": "string", "description": "Issue UUID (for comment/issue actions)" },
          "output": { "type": "string", "description": "Completion output or progress summary" },
          "pr_url": { "type": "string", "description": "Pull request URL (for complete_task)" },
          "reason": { "type": "string", "description": "Failure reason (for fail_task)" },
          "comment": { "type": "string", "description": "Comment body (for post_comment)" },
          "status_filter": { "type": "string", "description": "Issue status filter (for list_issues)" },
          "step": { "type": "integer", "description": "Current step (for report_progress)" },
          "total": { "type": "integer", "description": "Total steps (for report_progress)" }
        },
        "required": ["action"]
      }
    }
  ],
  "capabilities": {
    "http": {
      "allowlist": [
        { "host": "${MULTICA_HOST}", "path_prefix": "/api/" }
      ],
      "credentials": {
        "multica_api": {
          "secret_name": "multica_api_token",
          "location": { "type": "header", "name": "Authorization" },
          "format": "Bearer ${secret}",
          "host_patterns": ["${MULTICA_HOST}"]
        }
      }
    },
    "workspace": {
      "allowed_prefixes": ["config/"]
    },
    "secrets": {
      "allowed_names": ["multica_api_token", "multica_url", "multica_workspace_id"]
    }
  }
}
```

**Workspace config** (`config/multica.json`):

```json
{
  "url": "http://localhost:8080",
  "workspace_id": "<uuid>",
  "runtime_id": null,
  "daemon_id": "lunarwing-<hostname>",
  "runtime_type": "lunarwing",
  "poll_interval_secs": 30
}
```

The `runtime_id` is populated after first registration and persisted so the agent survives restarts without re-registering.

#### 1b. Routine: `multica-poll`

A LunarWing routine (cron) that runs every 30–60 seconds:

1. Call `multica(action: "heartbeat")` to keep the runtime alive
2. Call `multica(action: "claim_task")` to check for pending work
3. If a task is claimed:
   - Call `multica(action: "start_task", task_id: "...")` 
   - Execute the task using LunarWing's agent capabilities (file ops, shell, web fetch, etc.)
   - Report progress periodically via `multica(action: "report_progress", ...)`
   - On completion: `multica(action: "complete_task", task_id: "...", output: "...")`
   - On failure: `multica(action: "fail_task", task_id: "...", reason: "...")`

This routine would be a SKILL.md that instructs the agent on the poll-claim-execute-report cycle, plus a cron trigger in the routines system.

#### 1c. Setup Flow

New CLI subcommand or onboarding step:

```bash
lunarwing tool install multica-bridge
lunarwing tool auth multica-bridge   # prompts for server URL + PAT token
```

Or via the gateway UI's extension install flow. The auth step stores `multica_api_token` and `multica_url` in secrets, then calls `register` to get a `runtime_id`.

### Deliverables

- `ic/tools-src/multica-bridge/` — WASM tool crate
- `ic/tools-src/multica-bridge/multica-bridge.capabilities.json` — capabilities
- `ic/skills/multica-poll.md` — SKILL.md for the polling routine
- Workspace config schema for `config/multica.json`
- Build integration in `scripts/build-wasm-extensions.sh`

### Validation

- Agent can register with a running Lunartica server
- Agent can claim a task assigned to it on the board
- Agent can report completion and the board reflects it
- Heartbeat keeps the runtime online
- Comments posted from the agent appear on the issue timeline

---

## Phase 2: WASM Channel — `multica-channel`

**Goal:** Real-time bidirectional communication. Multica pushes events to LunarWing (new task available, issue updated, comment added). LunarWing responds immediately instead of waiting for the next poll interval.

### Architecture

A WASM **channel** (not just a tool) that maintains a persistent connection to the Multica server via WebSocket.

Location: `ic/channels-src/multica/`

#### 2a. Channel Implementation

The channel connects to `GET /api/daemon/ws?runtime_id=<id>` and translates Multica events into LunarWing `IncomingMessage`s:

| Multica WS Event | LunarWing Message |
|-------------------|-------------------|
| `daemon:task_available` | Agent turn: "New task available for runtime {id}. Claim and execute it." |
| `task:queued` | Notification: "Task queued: {title}" |
| `task:cancelled` | Agent turn: "Task {id} was cancelled. Stop work if in progress." |
| `issue:updated` | Conditional: if assigned to this agent, notify |
| `comment:created` | If on an active issue, deliver as agent input |

The channel implements LunarWing's `Channel` trait via the WASM channel WIT interface (`wit/channel.wit`). The `ChannelManager` merges it with XMPP, CLI, web gateway, etc.

#### 2b. Outbound Integration

When the agent produces output for a Multica-originated message, the channel routes the response back via the daemon API:

- Task progress → `POST /tasks/{id}/progress`
- Task completion → `POST /tasks/{id}/complete`
- Comments → `POST /api/issues/{id}/comments`

This replaces the polling routine from Phase 1 with event-driven execution.

#### 2c. Hybrid Mode

Phase 1's polling routine remains as a fallback:
- If the WebSocket drops, the routine continues polling via HTTP
- The routine handles startup registration and orphan recovery
- The channel handles real-time dispatch

### Deliverables

- `ic/channels-src/multica/` — WASM channel crate
- Channel capabilities file with WS allowlist
- Integration with `ChannelManager` for event merging
- Fallback to Phase 1 polling on WS disconnect

### Open Questions

- **WASM WS support**: LunarWing's WASM host currently provides `http-request` but not a persistent WebSocket API. The channel WIT (`wit/channel.wit`) may need an extension, or the channel could be implemented as a native Rust channel (like the XMPP bridge) rather than WASM. Evaluate whether adding `ws-connect` / `ws-send` / `ws-recv` to the WASM host interface is worth the complexity.
- **Alternative: native Rust channel**: Like the XMPP bridge, implement as `src/channels/multica.rs` with a `Channel` trait impl. Avoids the WASM WS limitation. Downside: not sandboxed, lives in the main binary.
- **Alternative: bridge service**: Like `bridges/xmpp-bridge/`, a separate binary that connects to Multica WS and forwards to LunarWing via HTTP webhook. Most isolated, but adds operational complexity.

---

## Phase 3: Skill Compounding

**Goal:** LunarWing's WASM-compiled skills are registered in the Multica board and shared across agents/runtimes.

### Architecture

#### 3a. Skill Export

LunarWing SKILL.md files and WASM tools can be exported to Multica as skills:

```
multica(action: "export_skill", skill_name: "deploy-k8s", skill_content: "...")
```

This calls `POST /api/skills` (or `POST /api/skills/import`) to register the skill on the board. Other agents in the workspace can then use it.

#### 3b. Skill Import

When claiming a task, the task response includes agent skills. The bridge downloads referenced skills and installs them as temporary SKILL.md files in the agent's skill search path for the duration of the task.

#### 3c. WASM Skill Artifacts

The real prize: WASM tool modules registered in Multica as portable, compiled artifacts. A skill on the board could reference a WASM binary URL, and any LunarWing runtime could download, validate, and execute it in its sandbox.

This requires:
- A skill artifact storage mechanism in Multica (or external, referenced by URL)
- WASM module validation and trust verification on the LunarWing side
- A skill-to-tool mapping so imported skills become available tools during task execution

### Deliverables

- `multica(action: "export_skill", ...)` and `multica(action: "import_skill", ...)` actions on the bridge tool
- Skill sync routine that keeps LunarWing's local skills in sync with the board
- WASM artifact upload/download protocol (TBD — depends on Multica's skill file storage capabilities)

### Open Questions

- Multica's skill model is prompt-level (markdown instructions). WASM artifact sharing would need a new skill type or extension to the `skill_files` table.
- Trust model: WASM modules from the board are untrusted. LunarWing's existing trust model (Trusted vs Installed) applies — board-imported skills would be Installed (read-only tools only) unless explicitly promoted.
- Versioning: how to handle skill version drift between the board and local cache.

---

## Implementation Order

```
Phase 1 (WASM tool)
├── multica-bridge crate scaffolding
├── capabilities.json + config schema
├── register + heartbeat actions
├── claim_task + start/complete/fail lifecycle
├── list_issues + post_comment
├── report_progress + report_messages
├── multica-poll SKILL.md
├── build script integration
└── manual testing against local Lunartica instance

Phase 2 (real-time channel)
├── Evaluate WASM WS vs native Rust channel vs bridge service
├── Implement chosen approach
├── Event → IncomingMessage translation
├── Outbound response routing
├── Hybrid mode (WS + HTTP polling fallback)
└── Integration testing

Phase 3 (skill compounding)
├── Skill export/import actions
├── Skill sync routine
├── WASM artifact protocol (if Multica supports it)
└── Trust model integration
```

## Authentication

Two auth paths are relevant:

1. **Daemon token** (`mdt_*`): scoped to a single workspace. Obtained by `POST /auth/send-code` + `POST /auth/verify-code` to get a session, then `POST /api/cli-token` to get a PAT, or directly via `POST /api/daemon/register` if using a PAT. The daemon API routes accept both PAT and daemon tokens.

2. **Personal Access Token** (`mul_*`): user-scoped, works across workspaces. Created via `POST /api/tokens` in the UI or `multica config` CLI.

For LunarWing, the simplest path is a PAT stored as a LunarWing secret (`multica_api_token`). The WASM tool never sees the token — it's injected by the host into the `Authorization: Bearer <token>` header at the HTTP boundary.

## Configuration

All config lives in the LunarWing workspace and secrets store:

| Item | Storage | Notes |
|------|---------|-------|
| `multica_api_token` | LunarWing secrets (AES-256-GCM) | PAT or daemon token |
| `multica_url` | `config/multica.json` in workspace | Server base URL |
| `multica_workspace_id` | `config/multica.json` | Target workspace UUID |
| `multica_runtime_id` | `config/multica.json` | Populated after registration |
| `multica_daemon_id` | `config/multica.json` | Stable identifier for this LunarWing instance |
| Poll interval | `config/multica.json` or routine cron | Default 30s |

## Risk Assessment

| Risk | Severity | Mitigation |
|------|----------|------------|
| WASM HTTP-only (no WS) | Medium | Phase 1 uses polling; Phase 2 evaluates native channel |
| Multica API changes | Low | Lunartica is our fork — we control the API |
| Task execution model mismatch | Medium | Multica expects CLI-style runs; LunarWing uses LLM agent loop. Bridge must translate task descriptions into agent-compatible prompts |
| Credential exposure in WASM | None | Host injects credentials — WASM never sees tokens |
| Polling overhead | Low | 30s interval is modest; heartbeat doubles as poll |
