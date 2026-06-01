# Quick Reference: Connecting LunarWing to Multica

**Target:** LunarWing instance on branch `1.1.0-new-lunartica`  
**Multica Version:** Any recent release (server verified compatible as of 2026-06-01)

---

## Prerequisites

- LunarWing running with the `1.1.0-new-lunartica` branch deployed
- A running Multica server instance
- A Multica workspace with at least one member
- Ability to generate a Personal Access Token (PAT) in Multica

---

## Step 1: Gather Multica Credentials

In your Multica instance UI:

1. Navigate to **Settings → Tokens** (or equivalent)
2. Create a new Personal Access Token
3. Copy the token (starts with `mul_`)
4. Note your **Workspace UUID** (visible in the workspace URL or settings)

---

## Step 2: Configure LunarWing

Create or edit the multica config at `config/multica.json` in your LunarWing workspace:

```json
{
  "url": "http://your-multica-server:8080",
  "workspace_id": "your-workspace-uuid-here",
  "daemon_id": "lunarwing",
  "runtime_type": "lunarwing"
}
```

| Field | Description | Example |
|-------|-------------|---------|
| `url` | Full URL of your Multica server | `http://localhost:8080` |
| `workspace_id` | UUID of the workspace | `a1b2c3d4-...` |
| `daemon_id` | Unique identifier for this instance | `lunarwing` (default) |
| `runtime_type` | Runtime type string | `lunarwing` (default) |

---

## Step 3: Set the Secret

Configure the `multica_api_token` secret in LunarWing:

```bash
lunarwing secret set multica_api_token
# Enter your PAT when prompted (starts with mul_)
```

Or via environment variable:

```bash
export MULTICA_API_TOKEN="mul_your_token_here"
```

---

## Step 4: Register as a Runtime

Use the `multica-bridge` tool to register LunarWing with the Multica board:

```
multica(action: "register")
```

This will:
- Register LunarWing as a runtime in the workspace
- Return a `runtime_id` — save this in `config/multica.json` as `"runtime_id": "..."`
- If not auto-saved, manually add it:

```json
{
  "url": "http://your-multica-server:8080",
  "workspace_id": "your-workspace-uuid-here",
  "runtime_id": "returned-runtime-uuid-here",
  "daemon_id": "lunarwing",
  "runtime_type": "lunarwing"
}
```

---

## Step 5: Recover Any Orphaned Tasks

If LunarWing crashed previously, claim any tasks left in progress:

```
multica(action: "recover_orphans")
```

---

## Step 6: Start Polling

Enable the `multica` channel in your LunarWing configuration:

```json
{
  "channels": {
    "multica": {
      "enabled": true,
      "poll_interval_ms": 30000
    }
  }
}
```

Or let the channel auto-poll on startup if `polling_enabled: true` is set in the capabilities config.

---

## Full Polling Loop (via Skill)

The `ic/skills/multica-poll/SKILL.md` skill defines the full lifecycle. Key actions:

| Action | Purpose |
|--------|---------|
| `register` | First-time setup — creates runtime entry |
| `heartbeat` | Keep alive + receive pending skill requests |
| `claim_task` | Pick up the next pending task from the board |
| `start_task` | Mark a claimed task as "running" |
| `report_progress` | Update progress (step/total) |
| `complete_task` | Mark task done, attach output or PR URL |
| `fail_task` | Mark task failed with reason |
| `post_comment` | Comment on an issue |
| `recover_orphans` | Reclaim tasks from crashed runtime |

---

## Tool Actions Reference

The `multica-bridge` tool supports these actions (use `action` parameter):

```
multica(action: "register")
multica(action: "heartbeat")
multica(action: "claim_task")
multica(action: "start_task", task_id: "...")
multica(action: "complete_task", task_id: "...", output: "...", pr_url: "...")
multica(action: "fail_task", task_id: "...", reason: "...")
multica(action: "report_progress", task_id: "...", output: "...", step: 2, total: 5)
multica(action: "post_comment", issue_id: "MUL-123", comment: "...")
multica(action: "list_issues", status: "open")
multica(action: "get_issue", issue_id: "MUL-123")
multica(action: "update_issue", issue_id: "MUL-123", status: "in_progress")
multica(action: "recover_orphans")
multica(action: "report_messages", task_id: "...", messages: [...])
multica(action: "list_skills")
multica(action: "get_skill", skill_id: "...")
multica(action: "export_skill", skill_name: "...", skill_description: "...", skill_content: "...")
```

---

## Troubleshooting

**"multica_api_token secret not configured"**
→ Set the secret in Step 3. Run `lunarwing secret set multica_api_token`.

**"runtime_id not set — run register first"**
→ Run `multica(action: "register")` and save the returned `runtime_id` to config.

**"workspace not found" (404 on register)**
→ Verify `workspace_id` in config matches your actual Multica workspace UUID exactly.

**"daemon_id is required" (400 on register)**
→ Ensure `daemon_id` is set in `config/multica.json`. Defaults to `"lunarwing"` if omitted.

**"runtime not in connection workspace" (WebSocket)**
→ The token's user must be a member of the workspace. Check PAT permissions.

**Tasks not appearing in polling loop**
→ Verify `polling_enabled: true` in channel config. Check Multica board has open tasks assigned to the correct runtime type.

---

## Architecture Overview

```
┌─────────────────────┐       ┌────────────────────────┐
│      LunarWing      │       │    Multica Server       │
│                     │       │                        │
│  ┌─────────────┐   │ HTTP  │  ┌──────────────────┐  │
│  │  Channel    │◄──┼───────┼─►│ /api/daemon/*    │  │
│  │  (poll/emit)│   │       │  │ (runtime mgmt)   │  │
│  └─────────────┘   │       │  └──────────────────┘  │
│                     │       │                        │
│  ┌─────────────┐   │       │  ┌──────────────────┐  │
│  │   Tool      │◄──┼───────┼─►│ /api/issues/*    │  │
│  │  (actions)  │   │       │  │ /api/skills/*    │  │
│  └─────────────┘   │       │  └──────────────────┘  │
└─────────────────────┘       └────────────────────────┘
```

- **Channel:** Polls for tasks, emits them as agent messages, routes completions back
- **Tool:** Direct API access for all daemon + user operations (used by skill/routines)

---

*Dark Forest Wizard Chief of Engineering — Deployment Ready* ⚡🐴