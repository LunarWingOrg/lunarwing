# Enabling Developer Tools for a Tenant

This guide covers how to enable filesystem read/write access, shell execution,
and other "developer tools" for a LunarWing agent in a multi-tenant deployment.

## Overview

LunarWing gates agent tool access through **three independent layers**:

1. **Tool registration** — controls *whether the tools exist at all* (the agent must know about `read_file`, `write_file`, `shell`, etc. before it can use them).
2. **Sandbox policy** — controls *what the tools can do* (filesystem scope, shell access).
3. **Tool permissions** — controls *whether the agent asks before using a tool* (per-tool, stored in the database).

All three must be configured for the agent to have unrestricted filesystem and shell
access without approval prompts.

---

## Layer 0: Tool Registration (REQUIRED — without this, the tools don't exist)

The filesystem and shell tools (`read_file`, `write_file`, `list_dir`, `apply_patch`,
`shell`) are **not registered by default**. They are only loaded when
`ALLOW_LOCAL_TOOLS=true` is set in the tenant's environment.

Without this env var, the agent literally does not know these tools exist — it will
report that it has no filesystem access, regardless of sandbox policy or database
permissions.

| Env var | Default | Description |
|---------|---------|-------------|
| `ALLOW_LOCAL_TOOLS` | `false` | When `true`, registers `ShellTool`, `ReadFileTool`, `WriteFileTool`, `ListDirTool`, `ApplyPatchTool` into the agent's tool set. |

Set in the tenant's `lunarwing.env`:

```bash
ALLOW_LOCAL_TOOLS=true
```

Restart the daemon after setting this — the tool registration happens at startup.

---

## Layer 1: Sandbox Policy

Set via environment variables in the tenant's `lunarwing.env` (or `[sandbox]` in
`config.toml`).

| Env var | Values | Default | Description |
|---------|--------|---------|-------------|
| `SANDBOX_POLICY` | `readonly`, `workspace_write`, `full_access` | `readonly` | Filesystem scope for the agent's tools. |
| `SANDBOX_ALLOW_FULL_ACCESS` | `true` / `false` | `false` | Safety gate — **required** for `full_access` to take effect. Without it, `full_access` is silently downgraded to `workspace_write`. |
| `SANDBOX_ENABLED` | `true` / `false` | `true` | Master switch for the sandbox subsystem. |

### Policy levels

- **`readonly`** — the agent can read files but cannot write, patch, or run shell commands.
- **`workspace_write`** — the agent can read and write **within its workspace directory** (`$LUNARWING_BASE_DIR/workspace/`). Shell commands are scoped to the workspace.
- **`full_access`** — the agent can read/write **anywhere on the filesystem** and run shell commands with full access. Requires `SANDBOX_ALLOW_FULL_ACCESS=true`.

### Setting the policy

Edit the tenant's `lunarwing.env` (typically at
`/home/<tenant>/lunarwing/env/lunarwing.env`):

```bash
# For workspace-scoped access (recommended for most dev/testing):
SANDBOX_POLICY=workspace_write

# For unrestricted filesystem + shell access:
SANDBOX_POLICY=full_access
SANDBOX_ALLOW_FULL_ACCESS=true
```

Restart the daemon after changing sandbox policy:

```bash
sudo bash ic/scripts/lunarwing-mt-admin.sh restart-tenant <tenant>
```

---

## Layer 2: Tool Permissions

Tool permissions control whether the agent **asks for user approval** before
invoking a tool. The filesystem and shell tools default to `AskEachTime` (the
agent pauses and waits for approval on every use).

There are three ways to change tool permissions:

### Option A: `AUTO_APPROVE_TOOLS` (simplest — all tools)

Set in `lunarwing.env`:

```bash
AUTO_APPROVE_TOOLS=true
```

This **bypasses all permission checks** — every tool runs without asking. Best
for development, CI, and benchmarking where interactive approval is impractical.

Restart the daemon after setting this.

### Option B: Database settings (per-tool granularity)

Tool permissions are stored in the `settings` table as key-value pairs:

- **Table:** `settings`
- **Primary key:** `(user_id, key)`
- **Key format:** `tool_permissions.<tool_name>`
- **Value:** JSON string — `"always_allow"`, `"ask_each_time"`, or `"disabled"`
- **Default user_id:** `default`

#### Enabling filesystem + shell tools via SQL

Run against the tenant's PostgreSQL container:

```bash
sudo -u <tenant> XDG_RUNTIME_DIR=/run/user/$(id -u <tenant>) \
  podman exec lunarwing-pg-<tenant> \
  psql -U lunarwing -d lunarwing -c "
INSERT INTO settings (user_id, key, value, updated_at) VALUES
  ('default', 'tool_permissions.read_file',   '\"always_allow\"'::jsonb, now()),
  ('default', 'tool_permissions.write_file',  '\"always_allow\"'::jsonb, now()),
  ('default', 'tool_permissions.list_dir',    '\"always_allow\"'::jsonb, now()),
  ('default', 'tool_permissions.apply_patch', '\"always_allow\"'::jsonb, now()),
  ('default', 'tool_permissions.shell',       '\"always_allow\"'::jsonb, now())
ON CONFLICT (user_id, key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
"
```

also try

```bash
sudo -u name XDG_RUNTIME_DIR=/run/user/uidno podman exec lunarwing-pg-name psql -U lunarwing -d lunarwing -c "INSERT INTO settings (user_id, key, value) VALUES ('default', 'sandbox.enabled', 'true'), ('default', 'sandbox.policy', '\"workspace_write\"'), ('default', 'sandbox.timeout_secs', '300'), ('default', 'sandbox.image', '\"lunarwing-worker:latest\"') ON CONFLICT (user_id, key) DO UPDATE SET value = EXCLUDED.value;"
```

Replace `<tenant>` with the tenant name (e.g., `tiggy`).

#### Verifying the settings

```bash
sudo -u <tenant> XDG_RUNTIME_DIR=/run/user/$(id -u <tenant>) \
  podman exec lunarwing-pg-<tenant> \
  psql -U lunarwing -d lunarwing -c \
  "SELECT key, value FROM settings WHERE key LIKE 'tool_permissions%';"
```

#### Reverting to defaults (ask each time)

```bash
sudo -u <tenant> XDG_RUNTIME_DIR=/run/user/$(id -u <tenant>) \
  podman exec lunarwing-pg-<tenant> \
  psql -U lunarwing -d lunarwing -c \
  "DELETE FROM settings WHERE user_id = 'default' AND key LIKE 'tool_permissions%';"
```

Database permission changes take effect on the **next agent turn** — no daemon
restart needed.

### Option C: Approve via chat UI (interactive)

When the agent first tries to use a gated tool (e.g., `shell`), it asks for
approval. Approving once persists `tool_permissions.<tool> = "always_allow"` to
the database automatically. The agent will not ask again for that tool.

This is the normal interactive-user path and requires no manual SQL.

---

## Available Tools and Default Permissions

| Tool | What it does | Default permission |
|------|-------------|-------------------|
| `read_file` | Read a file from disk | `AskEachTime` |
| `write_file` | Write or create a file | `AskEachTime` |
| `list_dir` | List directory contents | `AskEachTime` |
| `apply_patch` | Apply a unified diff patch | `AskEachTime` |
| `shell` | Run a shell command | `AskEachTime` |
| `http` | Make outbound HTTP requests | `AskEachTime` |
| `create_job` | Dispatch a task to a worker | `AskEachTime` |
| `echo` | Echo text (no side effects) | `AlwaysAllow` |
| `time` | Get current time | `AlwaysAllow` |
| `json` | Parse/format JSON | `AlwaysAllow` |
| `memory_search` | Search workspace memory | `AlwaysAllow` |
| `memory_read` | Read memory documents | `AlwaysAllow` |
| `memory_write` | Write memory documents | `AlwaysAllow` |
| `memory_tree` | Browse memory tree | `AlwaysAllow` |
| `tool_list` | List available tools | `AlwaysAllow` |
| `tool_info` | Show tool details | `AlwaysAllow` |
| `image_analyze` | Analyze an image | `AlwaysAllow` |
| `message` | Send a message | `AlwaysAllow` |

Tools not listed here fall back to `AskEachTime` if unknown.

---

## Quick Start: Full Dev Mode for a Tenant

To give a tenant full filesystem + shell access with zero approval prompts:

### Step 1: Register the dev tools (REQUIRED)

```bash
# Edit the tenant's lunarwing.env
sudo nano /home/<tenant>/lunarwing/env/lunarwing.env

# Add this line (without it, the tools don't exist at all):
ALLOW_LOCAL_TOOLS=true
```

### Step 2: Set sandbox policy

```bash
# Add or modify these lines:
SANDBOX_POLICY=full_access
SANDBOX_ALLOW_FULL_ACCESS=true
```
```bash
SANDBOX_ALLOW_FULL_ACCESS=true
```
is particularly important

### Step 3: Set tool permissions (pick one)

**Option A (all tools, no prompts):**
```bash
# Add to lunarwing.env:
AUTO_APPROVE_TOOLS=true
```

**Option B (filesystem + shell only, via database):**
```bash
sudo -u <tenant> XDG_RUNTIME_DIR=/run/user/$(id -u <tenant>) \
  podman exec lunarwing-pg-<tenant> \
  psql -U lunarwing -d lunarwing -c "
INSERT INTO settings (user_id, key, value, updated_at) VALUES
  ('default', 'tool_permissions.read_file',   '\"always_allow\"'::jsonb, now()),
  ('default', 'tool_permissions.write_file',  '\"always_allow\"'::jsonb, now()),
  ('default', 'tool_permissions.list_dir',    '\"always_allow\"'::jsonb, now()),
  ('default', 'tool_permissions.apply_patch', '\"always_allow\"'::jsonb, now()),
  ('default', 'tool_permissions.shell',       '\"always_allow\"'::jsonb, now())
ON CONFLICT (user_id, key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
"
```

### Step 4: Restart the daemon

```bash
sudo bash ic/scripts/lunarwing-mt-admin.sh restart-tenant <tenant>
```

The daemon must restart for the sandbox policy change to take effect. Database
permission changes (Option B) take effect on the next agent turn without a
restart, but the sandbox policy does require one.

---

## Security Considerations

- **`full_access` + `AUTO_APPROVE_TOOLS=true`** gives the agent unrestricted
  filesystem and shell access with no human-in-the-loop. Only use this on
  trusted development/testing tenants.
- **`workspace_write`** is the recommended policy for production tenants that
  need file tools — it confines writes to the workspace directory.
- Tool permissions in the database are **per-user** (`user_id`). If multiple
  users share a tenant, set permissions for each user_id individually.
- The `shell` tool can execute arbitrary commands. Even with `workspace_write`
  policy, shell commands are scoped to the workspace but the agent can still
  read system files. Use `readonly` + `AskEachTime` for untrusted agents.


