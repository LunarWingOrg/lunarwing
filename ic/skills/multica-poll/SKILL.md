---
name: multica-poll
version: "0.1.0"
description: Poll a Multica/Lunartica board for tasks, claim and execute them, report results
activation:
  keywords:
    - "multica"
    - "lunartica"
    - "task board"
    - "claim task"
  tags:
    - "task-management"
    - "daemon"
  max_context_tokens: 1500
---

# Multica/Lunartica Task Polling

You are connected to a Multica/Lunartica task board via the `multica` tool. Follow this lifecycle on each polling cycle:

## Startup (first run only)

1. Call `multica(action: "register")` to register this LunarWing instance as a runtime.
2. The response is a JSON object with a `runtimes` array. Take the `id` of the first
   entry (`response.runtimes[0].id`) and save it to `config/multica.json` as `runtime_id`
   — this value identifies the runtime for all subsequent calls (heartbeat, claim, etc.).
3. Call `multica(action: "recover_orphans")` to recover any tasks orphaned by a prior crash.

## Poll Cycle

1. Call `multica(action: "heartbeat")` to keep this runtime marked as online.
2. Call `multica(action: "claim_task")` to check for pending work.
3. If no task is available, stop — wait for the next cycle.

## Task Execution

When a task is claimed:

1. Call `multica(action: "start_task", task_id: "<id>")` to mark the task as running.
2. Read the task details — the response includes the issue title, description, and agent instructions.
3. Execute the task using available tools (file operations, shell, web fetch, etc.).
4. Report progress periodically: `multica(action: "report_progress", task_id: "<id>", output: "summary of current step", step: N, total: M)`.
5. On success: `multica(action: "complete_task", task_id: "<id>", output: "summary of what was done")`. Include `pr_url` if a PR was created.
6. On failure: `multica(action: "fail_task", task_id: "<id>", reason: "what went wrong")`.

## Guidelines

- Always report progress before long operations so the board shows activity.
- Post comments on the issue for significant findings: `multica(action: "post_comment", issue_id: "<id>", comment: "...")`.
- Report agent messages for observability: `multica(action: "report_messages", task_id: "<id>", messages: [...])`.
- If a task is unclear, post a comment asking for clarification rather than failing.
- Never leave a task in "started" state without completing or failing it.

## Skill Sharing

You can share skills with the Multica board:

- **List board skills**: `multica(action: "list_skills")` — see what skills are available.
- **Get skill details**: `multica(action: "get_skill", skill_id: "<uuid>")` — fetch a specific skill's content and files.
- **Export a local skill**: `multica(action: "export_skill", skill_name: "my-skill", skill_description: "Does X", skill_content: "<SKILL.md body>")` — publish a skill to the board so other agents can use it. Include `skill_files` for supporting files.

When a claimed task includes agent skills, they are embedded in the task message. Follow any skill instructions provided — they extend your capabilities for that task.
