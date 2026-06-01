wit_bindgen::generate!({
    world: "sandboxed-tool",
    path: "../../wit/tool.wit",
});

use serde::{Deserialize, Serialize};

use exports::near::agent::tool;

// ── Config ─────────────────────────────────────────────────────

#[derive(Deserialize)]
struct MulticaConfig {
    url: String,
    workspace_id: String,
    runtime_id: Option<String>,
    #[serde(default = "default_daemon_id")]
    daemon_id: String,
    #[serde(default = "default_runtime_type")]
    runtime_type: String,
}

fn default_daemon_id() -> String {
    "lunarwing".to_string()
}

fn default_runtime_type() -> String {
    "lunarwing".to_string()
}

fn load_config() -> Result<MulticaConfig, String> {
    let content = near::agent::host::workspace_read("config/multica.json")
        .ok_or("config/multica.json not found in workspace")?;
    serde_json::from_str(&content).map_err(|e| format!("failed to parse config/multica.json: {e}"))
}

// ── Request types ──────────────────────────────────────────────

#[derive(Deserialize)]
struct ToolInput {
    action: String,
    task_id: Option<String>,
    issue_id: Option<String>,
    output: Option<String>,
    pr_url: Option<String>,
    reason: Option<String>,
    comment: Option<String>,
    status: Option<String>,
    priority: Option<String>,
    assignee_id: Option<String>,
    step: Option<i32>,
    total: Option<i32>,
    messages: Option<Vec<MessageInput>>,
    skill_id: Option<String>,
    skill_name: Option<String>,
    skill_description: Option<String>,
    skill_content: Option<String>,
    skill_files: Option<Vec<SkillFileInput>>,
}

#[derive(Deserialize, Serialize)]
struct SkillFileInput {
    path: Option<String>,
    content: Option<String>,
}

#[derive(Deserialize, Serialize)]
struct MessageInput {
    #[serde(rename = "type")]
    msg_type: Option<String>,
    content: Option<String>,
    tool: Option<String>,
}

// ── HTTP helpers ───────────────────────────────────────────────

fn api_url(base: &str, path: &str) -> String {
    let base = base.trim_end_matches('/');
    format!("{base}{path}")
}

fn json_headers() -> String {
    serde_json::json!({"Content-Type": "application/json"}).to_string()
}

fn http_get(url: &str) -> Result<(u16, String), String> {
    let resp = near::agent::host::http_request("GET", url, &json_headers(), None, Some(15000))
        .map_err(|e| format!("HTTP GET failed: {e}"))?;
    Ok((resp.status, String::from_utf8_lossy(&resp.body).to_string()))
}

fn http_post(url: &str, body: &[u8]) -> Result<(u16, String), String> {
    let resp =
        near::agent::host::http_request("POST", url, &json_headers(), Some(body), Some(15000))
            .map_err(|e| format!("HTTP POST failed: {e}"))?;
    Ok((resp.status, String::from_utf8_lossy(&resp.body).to_string()))
}

fn http_put(url: &str, body: &[u8]) -> Result<(u16, String), String> {
    let resp =
        near::agent::host::http_request("PUT", url, &json_headers(), Some(body), Some(15000))
            .map_err(|e| format!("HTTP PUT failed: {e}"))?;
    Ok((resp.status, String::from_utf8_lossy(&resp.body).to_string()))
}

fn require_ok(status: u16, body: &str, action: &str) -> Result<(), String> {
    if status >= 200 && status < 300 {
        Ok(())
    } else {
        Err(format!("{action} failed (HTTP {status}): {body}"))
    }
}

fn require_field<'a>(val: &'a Option<String>, name: &str) -> Result<&'a str, String> {
    val.as_deref()
        .filter(|s| !s.is_empty())
        .ok_or_else(|| format!("'{name}' is required for this action"))
}

// ── Tool implementation ───────────────────────────────────────

struct MulticaBridgeTool;

export!(MulticaBridgeTool);

impl tool::Guest for MulticaBridgeTool {
    fn execute(req: tool::Request) -> tool::Response {
        match dispatch(&req.params) {
            Ok(output) => tool::Response {
                output: Some(output),
                error: None,
            },
            Err(e) => tool::Response {
                output: None,
                error: Some(e),
            },
        }
    }

    fn schema() -> String {
        r#"{
  "type": "object",
  "properties": {
    "action": {
      "type": "string",
      "description": "Operation to perform",
      "enum": ["register", "heartbeat", "claim_task", "start_task", "complete_task", "fail_task", "report_progress", "list_issues", "get_issue", "update_issue", "post_comment", "recover_orphans", "report_messages", "list_skills", "get_skill", "export_skill"]
    },
    "task_id": { "type": "string", "description": "Task UUID (for start_task, complete_task, fail_task, report_progress, report_messages)" },
    "issue_id": { "type": "string", "description": "Issue ID — UUID or identifier like MUL-123 (for get_issue, update_issue, post_comment)" },
    "output": { "type": "string", "description": "Completion output (complete_task) or progress summary (report_progress)" },
    "pr_url": { "type": "string", "description": "Pull request URL (complete_task)" },
    "reason": { "type": "string", "description": "Failure reason (fail_task)" },
    "comment": { "type": "string", "description": "Comment body (post_comment)" },
    "status": { "type": "string", "description": "Issue status to set (update_issue) or filter (list_issues)" },
    "priority": { "type": "string", "description": "Issue priority to set (update_issue)" },
    "assignee_id": { "type": "string", "description": "Agent UUID to filter by (list_issues)" },
    "step": { "type": "integer", "description": "Current step number (report_progress)" },
    "total": { "type": "integer", "description": "Total steps (report_progress)" },
    "messages": {
      "type": "array",
      "description": "Agent execution messages (report_messages)",
      "items": {
        "type": "object",
        "properties": {
          "type": { "type": "string" },
          "content": { "type": "string" },
          "tool": { "type": "string" }
        }
      }
    },
    "skill_id": { "type": "string", "description": "Skill UUID (get_skill)" },
    "skill_name": { "type": "string", "description": "Skill name (export_skill)" },
    "skill_description": { "type": "string", "description": "Skill description (export_skill)" },
    "skill_content": { "type": "string", "description": "Skill SKILL.md content (export_skill)" },
    "skill_files": {
      "type": "array",
      "description": "Skill supporting files (export_skill)",
      "items": {
        "type": "object",
        "properties": {
          "path": { "type": "string" },
          "content": { "type": "string" }
        }
      }
    }
  },
  "required": ["action"]
}"#
        .to_string()
    }

    fn description() -> String {
        "Interact with a Multica/Lunartica task management server. Use the 'action' parameter to select an operation. Available actions: register (register as runtime), heartbeat (keep alive), claim_task (claim next pending task), start_task (mark started), complete_task (mark done), fail_task (mark failed), report_progress (report step progress), list_issues (list workspace issues), get_issue (get issue details), update_issue (update issue fields), post_comment (comment on issue), recover_orphans (recover crashed tasks), report_messages (report agent messages), list_skills (list board skills), get_skill (get skill details), export_skill (publish local skill to board).".to_string()
    }
}

// ── Dispatch ──────────────────────────────────────────────────

fn dispatch(params_json: &str) -> Result<String, String> {
    let input: ToolInput =
        serde_json::from_str(params_json).map_err(|e| format!("invalid parameters: {e}"))?;

    if !near::agent::host::secret_exists("multica_api_token") {
        return Err("Secret 'multica_api_token' not configured. Run: lunarwing tool auth multica-bridge".into());
    }

    let config = load_config()?;
    let base = config.url.trim_end_matches('/');

    match input.action.as_str() {
        "register" => action_register(base, &config),
        "heartbeat" => action_heartbeat(base, &config),
        "claim_task" => action_claim_task(base, &config),
        "start_task" => action_start_task(base, &input),
        "complete_task" => action_complete_task(base, &input),
        "fail_task" => action_fail_task(base, &input),
        "report_progress" => action_report_progress(base, &input),
        "list_issues" => action_list_issues(base, &input),
        "get_issue" => action_get_issue(base, &input),
        "update_issue" => action_update_issue(base, &input),
        "post_comment" => action_post_comment(base, &input),
        "recover_orphans" => action_recover_orphans(base, &config),
        "report_messages" => action_report_messages(base, &input),
        "list_skills" => action_list_skills(base),
        "get_skill" => action_get_skill(base, &input),
        "export_skill" => action_export_skill(base, &input),
        other => Err(format!("unknown action: '{other}'")),
    }
}

// ── Actions ───────────────────────────────────────────────────

fn action_register(base: &str, config: &MulticaConfig) -> Result<String, String> {
    let body = serde_json::json!({
        "workspace_id": config.workspace_id,
        "daemon_id": config.daemon_id,
        "runtimes": [{
            "name": "LunarWing",
            "type": config.runtime_type,
            "version": env!("CARGO_PKG_VERSION"),
            "status": "online"
        }]
    });
    let url = api_url(base, "/api/daemon/register");
    near::agent::host::log(
        near::agent::host::LogLevel::Info,
        &format!("Registering with Multica at {url}"),
    );
    let (status, resp_body) = http_post(&url, body.to_string().as_bytes())?;
    require_ok(status, &resp_body, "register")?;

    near::agent::host::log(near::agent::host::LogLevel::Info, "Multica registration successful");
    Ok(resp_body)
}

fn action_heartbeat(base: &str, config: &MulticaConfig) -> Result<String, String> {
    let runtime_id = config
        .runtime_id
        .as_deref()
        .filter(|s| !s.is_empty())
        .ok_or("runtime_id not set in config — run register first")?;

    let body = serde_json::json!({ "runtime_id": runtime_id });
    let url = api_url(base, "/api/daemon/heartbeat");
    let (status, resp_body) = http_post(&url, body.to_string().as_bytes())?;
    require_ok(status, &resp_body, "heartbeat")?;
    Ok(resp_body)
}

fn action_claim_task(base: &str, config: &MulticaConfig) -> Result<String, String> {
    let runtime_id = config
        .runtime_id
        .as_deref()
        .filter(|s| !s.is_empty())
        .ok_or("runtime_id not set in config — run register first")?;

    let url = api_url(
        base,
        &format!("/api/daemon/runtimes/{runtime_id}/tasks/claim"),
    );
    let (status, resp_body) = http_post(&url, b"{}")?;

    if status == 204 || resp_body.trim().is_empty() || resp_body.trim() == "null" {
        return Ok(r#"{"task":null,"message":"No tasks available"}"#.to_string());
    }
    require_ok(status, &resp_body, "claim_task")?;
    Ok(resp_body)
}

fn action_start_task(base: &str, input: &ToolInput) -> Result<String, String> {
    let task_id = require_field(&input.task_id, "task_id")?;
    let url = api_url(base, &format!("/api/daemon/tasks/{task_id}/start"));
    let (status, resp_body) = http_post(&url, b"{}")?;
    require_ok(status, &resp_body, "start_task")?;
    Ok(resp_body)
}

fn action_complete_task(base: &str, input: &ToolInput) -> Result<String, String> {
    let task_id = require_field(&input.task_id, "task_id")?;
    let mut body = serde_json::Map::new();
    if let Some(output) = &input.output {
        body.insert("output".into(), serde_json::Value::String(output.clone()));
    }
    if let Some(pr_url) = &input.pr_url {
        body.insert("pr_url".into(), serde_json::Value::String(pr_url.clone()));
    }
    let url = api_url(base, &format!("/api/daemon/tasks/{task_id}/complete"));
    let payload = serde_json::Value::Object(body).to_string();
    let (status, resp_body) = http_post(&url, payload.as_bytes())?;
    require_ok(status, &resp_body, "complete_task")?;
    Ok(resp_body)
}

fn action_fail_task(base: &str, input: &ToolInput) -> Result<String, String> {
    let task_id = require_field(&input.task_id, "task_id")?;
    let error_msg = input.reason.as_deref().unwrap_or("unknown error");
    let body = serde_json::json!({ "error": error_msg });
    let url = api_url(base, &format!("/api/daemon/tasks/{task_id}/fail"));
    let (status, resp_body) = http_post(&url, body.to_string().as_bytes())?;
    require_ok(status, &resp_body, "fail_task")?;
    Ok(resp_body)
}

fn action_report_progress(base: &str, input: &ToolInput) -> Result<String, String> {
    let task_id = require_field(&input.task_id, "task_id")?;
    let mut body = serde_json::Map::new();
    if let Some(output) = &input.output {
        body.insert(
            "summary".into(),
            serde_json::Value::String(output.clone()),
        );
    }
    if let Some(step) = input.step {
        body.insert("step".into(), serde_json::Value::Number(step.into()));
    }
    if let Some(total) = input.total {
        body.insert("total".into(), serde_json::Value::Number(total.into()));
    }
    let url = api_url(base, &format!("/api/daemon/tasks/{task_id}/progress"));
    let payload = serde_json::Value::Object(body).to_string();
    let (status, resp_body) = http_post(&url, payload.as_bytes())?;
    require_ok(status, &resp_body, "report_progress")?;
    Ok(resp_body)
}

fn action_list_issues(base: &str, input: &ToolInput) -> Result<String, String> {
    let mut query_parts = Vec::new();
    if let Some(status) = &input.status {
        query_parts.push(format!("status={status}"));
    }
    if let Some(assignee) = &input.assignee_id {
        query_parts.push(format!("assignee_id={assignee}"));
    }
    let query = if query_parts.is_empty() {
        String::new()
    } else {
        format!("?{}", query_parts.join("&"))
    };
    let url = api_url(base, &format!("/api/issues{query}"));
    let (status, resp_body) = http_get(&url)?;
    require_ok(status, &resp_body, "list_issues")?;
    Ok(resp_body)
}

fn action_get_issue(base: &str, input: &ToolInput) -> Result<String, String> {
    let issue_id = require_field(&input.issue_id, "issue_id")?;
    let url = api_url(base, &format!("/api/issues/{issue_id}"));
    let (status, resp_body) = http_get(&url)?;
    require_ok(status, &resp_body, "get_issue")?;
    Ok(resp_body)
}

fn action_update_issue(base: &str, input: &ToolInput) -> Result<String, String> {
    let issue_id = require_field(&input.issue_id, "issue_id")?;
    let mut body = serde_json::Map::new();
    if let Some(status) = &input.status {
        body.insert("status".into(), serde_json::Value::String(status.clone()));
    }
    if let Some(priority) = &input.priority {
        body.insert(
            "priority".into(),
            serde_json::Value::String(priority.clone()),
        );
    }
    if body.is_empty() {
        return Err("update_issue requires at least one of: status, priority".into());
    }
    let url = api_url(base, &format!("/api/issues/{issue_id}"));
    let payload = serde_json::Value::Object(body).to_string();
    let (status, resp_body) = http_put(&url, payload.as_bytes())?;
    require_ok(status, &resp_body, "update_issue")?;
    Ok(resp_body)
}

fn action_post_comment(base: &str, input: &ToolInput) -> Result<String, String> {
    let issue_id = require_field(&input.issue_id, "issue_id")?;
    let comment_text = require_field(&input.comment, "comment")?;
    let body = serde_json::json!({
        "content": comment_text,
        "type": "comment"
    });
    let url = api_url(base, &format!("/api/issues/{issue_id}/comments"));
    let (status, resp_body) = http_post(&url, body.to_string().as_bytes())?;
    require_ok(status, &resp_body, "post_comment")?;
    Ok(resp_body)
}

fn action_recover_orphans(base: &str, config: &MulticaConfig) -> Result<String, String> {
    let runtime_id = config
        .runtime_id
        .as_deref()
        .filter(|s| !s.is_empty())
        .ok_or("runtime_id not set in config — run register first")?;

    let url = api_url(
        base,
        &format!("/api/daemon/runtimes/{runtime_id}/recover-orphans"),
    );
    let (status, resp_body) = http_post(&url, b"{}")?;
    require_ok(status, &resp_body, "recover_orphans")?;
    Ok(resp_body)
}

fn action_report_messages(base: &str, input: &ToolInput) -> Result<String, String> {
    let task_id = require_field(&input.task_id, "task_id")?;
    let messages = input.messages.as_deref().unwrap_or(&[]);

    #[derive(Serialize)]
    struct MsgPayload {
        seq: usize,
        #[serde(rename = "type")]
        msg_type: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        content: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        tool: Option<String>,
    }

    let payload_msgs: Vec<MsgPayload> = messages
        .iter()
        .enumerate()
        .map(|(i, m)| MsgPayload {
            seq: i + 1,
            msg_type: m.msg_type.clone().unwrap_or_else(|| "text".to_string()),
            content: m.content.clone(),
            tool: m.tool.clone(),
        })
        .collect();

    let body = serde_json::json!({ "messages": payload_msgs });
    let url = api_url(base, &format!("/api/daemon/tasks/{task_id}/messages"));
    let (status, resp_body) = http_post(&url, body.to_string().as_bytes())?;
    require_ok(status, &resp_body, "report_messages")?;
    Ok(resp_body)
}

// ── Skill actions ─────────────────────────────────────────────

fn action_list_skills(base: &str) -> Result<String, String> {
    let url = api_url(base, "/api/skills");
    let (status, resp_body) = http_get(&url)?;
    require_ok(status, &resp_body, "list_skills")?;
    Ok(resp_body)
}

fn action_get_skill(base: &str, input: &ToolInput) -> Result<String, String> {
    let skill_id = require_field(&input.skill_id, "skill_id")?;
    let url = api_url(base, &format!("/api/skills/{skill_id}"));
    let (status, resp_body) = http_get(&url)?;
    require_ok(status, &resp_body, "get_skill")?;
    Ok(resp_body)
}

fn action_export_skill(base: &str, input: &ToolInput) -> Result<String, String> {
    let name = require_field(&input.skill_name, "skill_name")?;
    let content = input.skill_content.as_deref().unwrap_or("");
    let description = input.skill_description.as_deref().unwrap_or("");

    let mut body = serde_json::json!({
        "name": name,
        "description": description,
        "content": content
    });

    if let Some(files) = &input.skill_files {
        let file_entries: Vec<serde_json::Value> = files
            .iter()
            .filter_map(|f| {
                let path = f.path.as_deref()?;
                let file_content = f.content.as_deref().unwrap_or("");
                Some(serde_json::json!({ "path": path, "content": file_content }))
            })
            .collect();
        if !file_entries.is_empty() {
            body["files"] = serde_json::Value::Array(file_entries);
        }
    }

    let url = api_url(base, "/api/skills");
    let (status, resp_body) = http_post(&url, body.to_string().as_bytes())?;
    require_ok(status, &resp_body, "export_skill")?;

    near::agent::host::log(
        near::agent::host::LogLevel::Info,
        &format!("Exported skill '{name}' to Multica board"),
    );
    Ok(resp_body)
}
