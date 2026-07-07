//! LunarWing WASM tool: SSH command execution (delivery Option 3).
//!
//! The guest is a thin shim. It parses `{host, command}` from the tool request
//! and calls the host's `ssh-exec` import, which runs the command host-side via
//! the in-process russh client (`ic/src/bridge/ssh_client.rs`). Private keys,
//! the ssh-agent, and host-key verification stay host-side — they never enter
//! WASM. The guest only ever sees `{host, command}` and the resulting output.
//!
//! The WASM sandbox here bounds *this guest's* CPU/memory and forces all SSH
//! access through the narrow `ssh-exec` waist; it does not (and cannot) sandbox
//! the SSH operation itself, which runs with host privilege. Approval is
//! enforced host-side: any WASM tool granted the `ssh` capability is treated as
//! `requires_approval = Always`.

wit_bindgen::generate!({
    world: "sandboxed-tool",
    path: "../../wit/tool.wit",
});

use exports::lunarwing::agent::tool;
use serde::Deserialize;

struct SshTool;
export!(SshTool);

#[derive(Deserialize)]
struct SshInput {
    host: String,
    command: String,
}

impl tool::Guest for SshTool {
    fn execute(req: tool::Request) -> tool::Response {
        match run(&req.params) {
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
        SCHEMA.to_string()
    }

    fn description() -> String {
        "Run a command on a preconfigured SSH host and return its stdout, stderr, and exit code. \
         Parameters (JSON object): host (string, REQUIRED — a configured host alias in [[ssh.hosts]] \
         and this tool's allowlist), command (string, REQUIRED). Authentication and host-key \
         verification happen host-side; keys never leave the daemon."
            .to_string()
    }
}

fn run(params: &str) -> Result<String, String> {
    let input: SshInput =
        serde_json::from_str(params).map_err(|e| format!("invalid parameters: {e}"))?;

    let resp = lunarwing::agent::host::ssh_exec(&input.host, &input.command)
        .map_err(|e| format!("ssh failed: {e}"))?;

    let stdout = String::from_utf8_lossy(&resp.stdout).to_string();
    let stderr = String::from_utf8_lossy(&resp.stderr).to_string();
    let output = serde_json::json!({
        "host": input.host,
        "exit_code": resp.exit_code,
        "stdout": stdout,
        "stderr": stderr,
        "truncated": resp.truncated,
        "success": resp.exit_code == 0,
    });
    serde_json::to_string(&output).map_err(|e| e.to_string())
}

const SCHEMA: &str = r#"{
  "type": "object",
  "properties": {
    "host": {
      "type": "string",
      "description": "Configured SSH host alias (must be in [[ssh.hosts]] and this tool's allowlist)"
    },
    "command": {
      "type": "string",
      "description": "Command to run on the remote host"
    }
  },
  "required": ["host", "command"],
  "additionalProperties": false
}"#;
