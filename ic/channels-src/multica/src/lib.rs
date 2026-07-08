wit_bindgen::generate!({
    world: "sandboxed-channel",
    path: "../../wit/channel.wit",
});

use serde::{Deserialize, Serialize};

use exports::lunarwing::agent::channel::{
    AgentResponse, ChannelConfig, Guest, IncomingHttpRequest, OutgoingHttpResponse, PollConfig,
    StatusUpdate,
};
use lunarwing::agent::channel_host::{self, EmittedMessage};

const CONFIG_PATH: &str = "config.json";
const STATE_PATH: &str = "state.json";
const DEFAULT_POLL_INTERVAL_MS: u32 = 30_000;

// ── Config ─────────────────────────────────────────────────────

#[derive(Debug, Clone, Deserialize)]
struct RuntimeConfig {
    #[serde(default = "default_display_name")]
    display_name: String,
    multica_url: String,
    workspace_id: String,
    runtime_id: Option<String>,
    #[serde(default = "default_daemon_id")]
    daemon_id: String,
    #[serde(default = "default_runtime_type")]
    runtime_type: String,
    #[serde(default = "default_true")]
    polling_enabled: bool,
    #[serde(default = "default_poll_interval")]
    poll_interval_ms: u32,
}

fn default_display_name() -> String {
    "Multica".to_string()
}
fn default_daemon_id() -> String {
    "lunarwing".to_string()
}
fn default_runtime_type() -> String {
    "lunarwing".to_string()
}
fn default_true() -> bool {
    true
}
fn default_poll_interval() -> u32 {
    DEFAULT_POLL_INTERVAL_MS
}

// ── Persistent state ──────────────────────────────────────────

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
struct ChannelState {
    runtime_id: Option<String>,
    registered: bool,
}

fn load_state() -> ChannelState {
    channel_host::workspace_read(STATE_PATH)
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

fn save_state(state: &ChannelState) {
    if let Ok(json) = serde_json::to_string(state) {
        if let Err(e) = channel_host::workspace_write(STATE_PATH, &json) {
            channel_host::log(
                channel_host::LogLevel::Warn,
                &format!("failed to persist channel state: {e}"),
            );
        }
    }
}

// ── HTTP helpers ──────────────────────────────────────────────

fn json_headers() -> String {
    r#"{"Content-Type":"application/json"}"#.to_string()
}

fn api_url(base: &str, path: &str) -> String {
    let base = base.trim_end_matches('/');
    format!("{base}{path}")
}

fn http_post(url: &str, body: &[u8]) -> Result<(u16, Vec<u8>), String> {
    let resp = channel_host::http_request("POST", url, &json_headers(), Some(body), Some(15000))
        .map_err(|e| format!("HTTP POST failed: {e}"))?;
    Ok((resp.status, resp.body))
}

fn json_response(status: u16, body: serde_json::Value) -> OutgoingHttpResponse {
    OutgoingHttpResponse {
        status,
        headers_json: r#"{"Content-Type":"application/json"}"#.to_string(),
        body: body.to_string().into_bytes(),
    }
}

// ── Multica API types ─────────────────────────────────────────

#[derive(Deserialize)]
struct RegisterResponse {
    runtimes: Option<Vec<RegisteredRuntime>>,
}

#[derive(Deserialize)]
struct RegisteredRuntime {
    id: Option<String>,
}

#[derive(Deserialize)]
struct ClaimedTask {
    id: Option<String>,
    issue: Option<ClaimedIssue>,
    agent: Option<ClaimedAgent>,
}

#[derive(Deserialize)]
struct ClaimedIssue {
    id: Option<String>,
    title: Option<String>,
    description: Option<String>,
    identifier: Option<String>,
}

#[derive(Deserialize)]
struct ClaimedAgent {
    #[allow(dead_code)]
    name: Option<String>,
    system_prompt: Option<String>,
    skills: Option<Vec<AgentSkillData>>,
}

#[derive(Deserialize)]
struct AgentSkillData {
    name: String,
    content: String,
    files: Option<Vec<AgentSkillFileData>>,
}

#[derive(Deserialize)]
struct AgentSkillFileData {
    path: String,
    content: String,
}

#[derive(Deserialize)]
struct HeartbeatResponse {
    #[allow(dead_code)]
    status: Option<String>,
    pending_local_skills: Option<PendingLocalSkills>,
    pending_local_skill_import: Option<PendingLocalSkillImport>,
}

#[derive(Deserialize)]
struct PendingLocalSkills {
    request_id: String,
}

#[derive(Deserialize)]
struct PendingLocalSkillImport {
    request_id: String,
    skill_key: String,
}

// ── Channel implementation ────────────────────────────────────

struct MulticaChannel;

export!(MulticaChannel);

impl Guest for MulticaChannel {
    fn on_start(config_json: String) -> Result<ChannelConfig, String> {
        channel_host::workspace_write(CONFIG_PATH, &config_json)
            .map_err(|e| format!("failed to persist config: {e}"))?;

        let config = parse_config(&config_json)?;

        if !channel_host::secret_exists("multica_api_token") {
            channel_host::log(
                channel_host::LogLevel::Warn,
                "multica_api_token secret not configured — channel will not poll",
            );
            return Ok(ChannelConfig {
                display_name: config.display_name,
                http_endpoints: Vec::new(),
                poll: Some(PollConfig {
                    interval_ms: config.poll_interval_ms,
                    enabled: false,
                }),
            });
        }

        Ok(ChannelConfig {
            display_name: config.display_name,
            http_endpoints: Vec::new(),
            poll: Some(PollConfig {
                interval_ms: config.poll_interval_ms.max(DEFAULT_POLL_INTERVAL_MS),
                enabled: config.polling_enabled,
            }),
        })
    }

    fn on_http_request(_req: IncomingHttpRequest) -> OutgoingHttpResponse {
        json_response(
            404,
            serde_json::json!({"error": "multica channel does not expose webhooks"}),
        )
    }

    fn on_poll() {
        let config = match load_config() {
            Ok(c) => c,
            Err(e) => {
                channel_host::log(channel_host::LogLevel::Warn, &format!("config error: {e}"));
                return;
            }
        };
        if !config.polling_enabled {
            return;
        }

        let mut state = load_state();

        // Register if we don't have a runtime_id yet.
        let runtime_id = match resolve_runtime_id(&config, &mut state) {
            Some(id) => id,
            None => return,
        };

        // Heartbeat — also handles pending skill requests from the server.
        match send_heartbeat(&config, &runtime_id) {
            Ok(hb) => handle_heartbeat_actions(&config, &runtime_id, &hb),
            Err(e) => {
                channel_host::log(
                    channel_host::LogLevel::Warn,
                    &format!("heartbeat failed: {e}"),
                );
            }
        }

        // Claim a task.
        match claim_task(&config, &runtime_id) {
            Ok(Some(task)) => emit_task_message(&task),
            Ok(None) => {}
            Err(e) => {
                channel_host::log(
                    channel_host::LogLevel::Warn,
                    &format!("claim_task failed: {e}"),
                );
            }
        }
    }

    fn on_respond(response: AgentResponse) -> Result<(), String> {
        let config = load_config()?;
        let meta: serde_json::Value =
            serde_json::from_str(&response.metadata_json).unwrap_or_default();

        let task_id = meta.get("task_id").and_then(|v| v.as_str());
        let issue_id = meta.get("issue_id").and_then(|v| v.as_str());
        let action = meta
            .get("response_action")
            .and_then(|v| v.as_str())
            .unwrap_or("complete");

        match action {
            "comment" => {
                let iid = issue_id.ok_or("issue_id required to post comment")?;
                let body = serde_json::json!({
                    "content": response.content,
                    "type": "comment"
                });
                let url = api_url(&config.multica_url, &format!("/api/issues/{iid}/comments"));
                let (status, resp_body) = http_post(&url, body.to_string().as_bytes())?;
                if status < 200 || status >= 300 {
                    return Err(format!(
                        "post_comment failed (HTTP {status}): {}",
                        String::from_utf8_lossy(&resp_body)
                    ));
                }
            }
            "complete" | _ => {
                if let Some(tid) = task_id {
                    let body = serde_json::json!({ "output": response.content });
                    let url = api_url(
                        &config.multica_url,
                        &format!("/api/daemon/tasks/{tid}/complete"),
                    );
                    let (status, resp_body) = http_post(&url, body.to_string().as_bytes())?;
                    if status < 200 || status >= 300 {
                        return Err(format!(
                            "complete_task failed (HTTP {status}): {}",
                            String::from_utf8_lossy(&resp_body)
                        ));
                    }
                }
            }
        }
        Ok(())
    }

    fn on_broadcast(_user_id: String, _response: AgentResponse) -> Result<(), String> {
        Err("multica channel does not support broadcast".to_string())
    }

    fn on_status(_update: StatusUpdate) {}

    fn on_shutdown() {}
}

// ── Internal functions ────────────────────────────────────────

fn load_config() -> Result<RuntimeConfig, String> {
    let json =
        channel_host::workspace_read(CONFIG_PATH).ok_or("multica channel config not found")?;
    parse_config(&json)
}

fn parse_config(json: &str) -> Result<RuntimeConfig, String> {
    serde_json::from_str(json).map_err(|e| format!("invalid multica config: {e}"))
}

fn resolve_runtime_id(config: &RuntimeConfig, state: &mut ChannelState) -> Option<String> {
    // Check state first (persisted from prior registration).
    if let Some(ref id) = state.runtime_id {
        return Some(id.clone());
    }
    // Check config (set by user or Phase 1 tool).
    if let Some(ref id) = config.runtime_id {
        state.runtime_id = Some(id.clone());
        state.registered = true;
        save_state(state);
        return Some(id.clone());
    }
    // Register.
    match do_register(config) {
        Ok(id) => {
            channel_host::log(
                channel_host::LogLevel::Info,
                &format!("registered with Multica, runtime_id={id}"),
            );
            state.runtime_id = Some(id.clone());
            state.registered = true;
            save_state(state);
            Some(id)
        }
        Err(e) => {
            channel_host::log(
                channel_host::LogLevel::Error,
                &format!("Multica registration failed: {e}"),
            );
            None
        }
    }
}

fn do_register(config: &RuntimeConfig) -> Result<String, String> {
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
    let url = api_url(&config.multica_url, "/api/daemon/register");
    let (status, resp_bytes) = http_post(&url, body.to_string().as_bytes())?;
    if status < 200 || status >= 300 {
        return Err(format!(
            "register HTTP {status}: {}",
            String::from_utf8_lossy(&resp_bytes)
        ));
    }
    let resp: RegisterResponse = serde_json::from_slice(&resp_bytes)
        .map_err(|e| format!("failed to parse register response: {e}"))?;
    resp.runtimes
        .and_then(|r| r.into_iter().next())
        .and_then(|r| r.id)
        .ok_or_else(|| "register response missing runtime id".to_string())
}

fn send_heartbeat(config: &RuntimeConfig, runtime_id: &str) -> Result<HeartbeatResponse, String> {
    let body = serde_json::json!({ "runtime_id": runtime_id });
    let url = api_url(&config.multica_url, "/api/daemon/heartbeat");
    let (status, resp_bytes) = http_post(&url, body.to_string().as_bytes())?;
    if status < 200 || status >= 300 {
        return Err(format!(
            "heartbeat HTTP {status}: {}",
            String::from_utf8_lossy(&resp_bytes)
        ));
    }
    serde_json::from_slice(&resp_bytes)
        .map_err(|e| format!("failed to parse heartbeat response: {e}"))
}

fn handle_heartbeat_actions(config: &RuntimeConfig, runtime_id: &str, hb: &HeartbeatResponse) {
    if let Some(pending) = &hb.pending_local_skills {
        report_local_skills(config, runtime_id, &pending.request_id);
    }
    if let Some(pending) = &hb.pending_local_skill_import {
        report_local_skill_import(config, runtime_id, &pending.request_id, &pending.skill_key);
    }
}

fn report_local_skills(config: &RuntimeConfig, runtime_id: &str, request_id: &str) {
    let skills = discover_local_skills();
    let body = serde_json::json!({
        "status": "completed",
        "skills": skills,
        "supported": true
    });
    let url = api_url(
        &config.multica_url,
        &format!("/api/daemon/runtimes/{runtime_id}/local-skills/{request_id}/result"),
    );
    match http_post(&url, body.to_string().as_bytes()) {
        Ok((status, _)) if status >= 200 && status < 300 => {
            channel_host::log(
                channel_host::LogLevel::Info,
                &format!("reported {} local skills", skills.len()),
            );
        }
        Ok((status, resp)) => {
            channel_host::log(
                channel_host::LogLevel::Warn,
                &format!(
                    "report local skills failed (HTTP {status}): {}",
                    String::from_utf8_lossy(&resp)
                ),
            );
        }
        Err(e) => {
            channel_host::log(
                channel_host::LogLevel::Warn,
                &format!("report local skills failed: {e}"),
            );
        }
    }
}

fn discover_local_skills() -> Vec<serde_json::Value> {
    let skills = Vec::new();
    // Read skill index from workspace. The channel workspace prefix is
    // channels/multica/, but we read from the agent's skill discovery cache
    // at config/multica-skills.json if available.
    if let Some(index_json) = channel_host::workspace_read("skill-index.json") {
        if let Ok(entries) = serde_json::from_str::<Vec<serde_json::Value>>(&index_json) {
            return entries;
        }
    }
    skills
}

fn report_local_skill_import(
    config: &RuntimeConfig,
    runtime_id: &str,
    request_id: &str,
    skill_key: &str,
) {
    // Read the skill content from workspace cache.
    let skill_path = format!("skills/{skill_key}.md");
    let content = channel_host::workspace_read(&skill_path);

    let body = if let Some(content) = content {
        serde_json::json!({
            "status": "completed",
            "skill": {
                "name": skill_key,
                "description": format!("Imported from LunarWing: {skill_key}"),
                "content": content
            }
        })
    } else {
        serde_json::json!({
            "status": "failed",
            "error": format!("skill '{skill_key}' not found locally")
        })
    };

    let url = api_url(
        &config.multica_url,
        &format!("/api/daemon/runtimes/{runtime_id}/local-skills/import/{request_id}/result"),
    );
    if let Err(e) = http_post(&url, body.to_string().as_bytes()) {
        channel_host::log(
            channel_host::LogLevel::Warn,
            &format!("report skill import failed: {e}"),
        );
    }
}

fn claim_task(config: &RuntimeConfig, runtime_id: &str) -> Result<Option<ClaimedTask>, String> {
    let url = api_url(
        &config.multica_url,
        &format!("/api/daemon/runtimes/{runtime_id}/tasks/claim"),
    );
    let (status, resp_bytes) = http_post(&url, b"{}")?;

    if status == 204 {
        return Ok(None);
    }
    let body_str = String::from_utf8_lossy(&resp_bytes);
    if body_str.trim().is_empty() || body_str.trim() == "null" {
        return Ok(None);
    }
    if status < 200 || status >= 300 {
        return Err(format!("claim_task HTTP {status}: {body_str}"));
    }
    let task: ClaimedTask =
        serde_json::from_slice(&resp_bytes).map_err(|e| format!("parse claim response: {e}"))?;
    if task.id.is_none() {
        return Ok(None);
    }
    Ok(Some(task))
}

fn emit_task_message(task: &ClaimedTask) {
    let task_id = task.id.as_deref().unwrap_or("unknown");
    let issue_title = task
        .issue
        .as_ref()
        .and_then(|i| i.title.as_deref())
        .unwrap_or("Untitled");
    let issue_desc = task
        .issue
        .as_ref()
        .and_then(|i| i.description.as_deref())
        .unwrap_or("");
    let issue_id = task
        .issue
        .as_ref()
        .and_then(|i| i.id.as_deref())
        .unwrap_or("");
    let identifier = task
        .issue
        .as_ref()
        .and_then(|i| i.identifier.as_deref())
        .unwrap_or("");
    let agent_prompt = task
        .agent
        .as_ref()
        .and_then(|a| a.system_prompt.as_deref())
        .unwrap_or("");
    let agent_skills = task
        .agent
        .as_ref()
        .and_then(|a| a.skills.as_deref())
        .unwrap_or(&[]);

    let mut content = format!("[Multica Task] {identifier}: {issue_title}");
    if !issue_desc.is_empty() {
        content.push_str("\n\n");
        content.push_str(issue_desc);
    }
    if !agent_prompt.is_empty() {
        content.push_str("\n\n--- Agent Instructions ---\n");
        content.push_str(agent_prompt);
    }
    for skill in agent_skills {
        content.push_str(&format!("\n\n--- Skill: {} ---\n", skill.name));
        content.push_str(&skill.content);
        if let Some(files) = &skill.files {
            for file in files {
                content.push_str(&format!("\n\n[Skill File: {}]\n", file.path));
                content.push_str(&file.content);
            }
        }
    }

    let metadata = serde_json::json!({
        "source": "multica",
        "task_id": task_id,
        "issue_id": issue_id,
        "identifier": identifier,
        "response_action": "complete"
    });

    // Mark task as started.
    let start_url = format!("/api/daemon/tasks/{task_id}/start");
    if let Ok(config) = load_config() {
        let url = api_url(&config.multica_url, &start_url);
        if let Err(e) = http_post(&url, b"{}") {
            channel_host::log(
                channel_host::LogLevel::Warn,
                &format!("start_task failed: {e}"),
            );
        }
    }

    channel_host::emit_message(&EmittedMessage {
        user_id: "multica".to_string(),
        user_name: Some("Multica Board".to_string()),
        content,
        thread_id: Some(task_id.to_string()),
        metadata_json: metadata.to_string(),
        attachments: Vec::new(),
    });

    channel_host::log(
        channel_host::LogLevel::Info,
        &format!("claimed task {task_id}: {identifier} — {issue_title}"),
    );
}
