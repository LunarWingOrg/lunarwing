//! Built-in `ssh_git` tool (delivery Option 2, phase 2) — runs a git operation
//! (clone/fetch/pull/push) over SSH by shelling out to the system `git` binary,
//! authenticating via the harness's in-process ssh-agent socket.
//!
//! Unlike the `ssh` tool (which uses the in-process russh client, `ssh.rs`),
//! this tool delegates the transport to `git`/`ssh` and only supplies:
//!   - `SSH_AUTH_SOCK` pointing at the harness agent socket
//!     ([`SSHBridge::get_agent_socket_path`]) — keys never leave the agent;
//!   - `GIT_SSH_COMMAND` with a materialized, ephemeral `known_hosts` built from
//!     each host's configured `known_host_key` / [`HostKeyVerifier`] pins, so
//!     host identity is verified;
//!   - `GIT_TERMINAL_PROMPT=0` + `BatchMode=yes` so it never blocks on a prompt.
//!
//! Safety:
//!   - `host` must be a configured `[[ssh.hosts]]` alias (the egress allowlist);
//!   - all local paths are confined under `<base_dir>/ssh-git/` via
//!     [`validate_path`] (rejects absolute paths, `..` traversal, symlink escape);
//!   - the child process env is scrubbed to an allowlist (no gateway secrets);
//!   - `requires_approval = Always`, `domain = Orchestrator`, output sanitized.

use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use base64::{Engine, engine::general_purpose::STANDARD as BASE64};
use tokio::io::AsyncReadExt;
use tokio::process::Command;
use tokio::sync::RwLock;

use crate::bridge::ssh::{HostKeyMode, SSHBridge, SSHHostConfig};
use crate::bridge::ssh_hostkeys::StoredHostKey;
use crate::context::JobContext;
use crate::tools::builtin::path_utils::validate_path;
use crate::tools::builtin::shell::SAFE_ENV_VARS;
use crate::tools::tool::{
    ApprovalRequirement, Tool, ToolDomain, ToolError, ToolOutput, ToolRateLimitConfig, require_str,
};

/// Max bytes captured per stream (stdout/stderr); matches ShellTool.
const MAX_OUTPUT_SIZE: usize = 64 * 1024;

/// Runs git operations over SSH for a configured remote host.
pub struct SshGitTool {
    ssh_bridge: Arc<RwLock<SSHBridge>>,
    /// `<base_dir>/ssh-git/` — all git operations are confined under this root.
    sandbox_root: PathBuf,
}

impl SshGitTool {
    pub fn new(ssh_bridge: Arc<RwLock<SSHBridge>>, base_dir: PathBuf) -> Self {
        Self {
            ssh_bridge,
            sandbox_root: base_dir.join("ssh-git"),
        }
    }
}

/// Best-effort cleanup of the ephemeral known_hosts file when the guard drops.
struct FileGuard(PathBuf);
impl Drop for FileGuard {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}

#[async_trait]
impl Tool for SshGitTool {
    fn name(&self) -> &str {
        "ssh_git"
    }

    fn description(&self) -> &str {
        "Run a git operation (clone/fetch/pull/push) over SSH against a configured host. \
         `host` must be an alias in [[ssh.hosts]]. `path` is a location RELATIVE to the ssh-git \
         sandbox (absolute paths and '..' are rejected): the clone destination, or an existing \
         repo dir for fetch/pull/push. Authentication uses the harness ssh-agent; the private key \
         never leaves the daemon. pull is fast-forward-only and force-push is not allowed."
    }

    fn parameters_schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "properties": {
                "operation": {
                    "type": "string",
                    "enum": ["clone", "fetch", "pull", "push"],
                    "description": "Git operation to perform over SSH."
                },
                "host": {
                    "type": "string",
                    "description": "Configured SSH host alias (must exist in [[ssh.hosts]])."
                },
                "repo": {
                    "type": "string",
                    "description": "Repository path on the remote host (e.g. 'org/project.git'). Required for clone; builds the remote URL."
                },
                "path": {
                    "type": "string",
                    "description": "Local path RELATIVE to the ssh-git sandbox: clone destination, or existing repo dir for fetch/pull/push."
                },
                "ref": {
                    "type": "string",
                    "description": "Optional branch/tag/refspec (clone --branch; fetch/pull/push refspec)."
                },
                "depth": {
                    "type": "integer",
                    "minimum": 1,
                    "description": "Optional shallow depth for clone/fetch."
                }
            },
            "required": ["operation", "host", "path"]
        })
    }

    async fn execute(
        &self,
        params: serde_json::Value,
        _ctx: &JobContext,
    ) -> Result<ToolOutput, ToolError> {
        let start = std::time::Instant::now();

        let operation = require_str(&params, "operation")?;
        if !matches!(operation, "clone" | "fetch" | "pull" | "push") {
            return Err(ToolError::InvalidParameters(format!(
                "operation must be one of clone|fetch|pull|push, got '{operation}'"
            )));
        }
        let host = require_str(&params, "host")?;
        let path_str = require_str(&params, "path")?;
        let git_ref = params.get("ref").and_then(|v| v.as_str());
        let repo = params.get("repo").and_then(|v| v.as_str());
        let depth = params.get("depth").and_then(|v| v.as_u64());

        // --- filesystem sandbox (the security core) ---
        if Path::new(path_str).is_absolute() {
            return Err(ToolError::InvalidParameters(
                "path must be relative to the ssh-git sandbox".into(),
            ));
        }
        tokio::fs::create_dir_all(&self.sandbox_root)
            .await
            .map_err(|e| ToolError::ExecutionFailed(format!("cannot create ssh-git root: {e}")))?;
        let repo_dir = validate_path(path_str, Some(&self.sandbox_root))?;

        // --- option-injection defense on caller-influenced git args ---
        if let Some(r) = git_ref {
            validate_git_arg("ref", r)?;
        }

        // --- resolve host config + agent socket + verifier (brief read lock) ---
        let (host_cfg, auth_sock, verifier) = {
            let bridge = self.ssh_bridge.read().await;
            let host_cfg = bridge.get_host_config(host).await.map_err(|e| {
                ToolError::NotAuthorized(format!("unknown SSH host '{host}': {e}"))
            })?;
            let auth_sock = bridge.get_agent_socket_path().ok_or_else(|| {
                ToolError::ExecutionFailed(
                    "SSH agent socket unavailable (agent not running); cannot authenticate git over SSH".into(),
                )
            })?;
            let verifier = bridge.host_key_verifier();
            (host_cfg, auth_sock, verifier)
        };

        // --- per-operation preconditions ---
        match operation {
            "clone" => {
                let repo = repo.ok_or_else(|| {
                    ToolError::InvalidParameters("'repo' is required for clone".into())
                })?;
                validate_git_arg("repo", repo)?;
                if repo_dir.exists()
                    && std::fs::read_dir(&repo_dir)
                        .map(|mut d| d.next().is_some())
                        .unwrap_or(false)
                {
                    return Err(ToolError::InvalidParameters(format!(
                        "clone destination '{path_str}' already exists and is not empty"
                    )));
                }
            }
            _ => {
                if !repo_dir.join(".git").exists() {
                    return Err(ToolError::InvalidParameters(format!(
                        "no git repository at '{path_str}'"
                    )));
                }
                if operation == "push" {
                    if let Some(r) = git_ref {
                        validate_push_ref(r)?;
                    }
                }
            }
        }

        // --- materialize an ephemeral known_hosts for host-key verification ---
        let pin = verifier.get_host_key(&host_cfg.host, host_cfg.port).await;
        let known_line = known_hosts_line(&host_cfg, pin.as_ref());
        if known_line.is_none() && host_cfg.host_key_mode == HostKeyMode::Strict {
            return Err(ToolError::NotAuthorized(format!(
                "no known host key for '{host}' (strict mode); cannot verify host identity"
            )));
        }
        let known_hosts_path = self
            .sandbox_root
            .join(format!(".known_hosts-{}", uuid::Uuid::new_v4()));
        std::fs::write(&known_hosts_path, known_line.unwrap_or_default())
            .map_err(|e| ToolError::ExecutionFailed(format!("cannot write known_hosts: {e}")))?;
        // Keep alive until run_git returns; dropped (file removed) at fn end.
        let _known_hosts_guard = FileGuard(known_hosts_path.clone());

        // --- build the command ---
        let git_ssh_command = build_git_ssh_command(&host_cfg, &known_hosts_path);
        let url = repo
            .map(|r| build_remote_url(&host_cfg, r))
            .unwrap_or_default();
        let dest = repo_dir.to_string_lossy().to_string();
        let args = build_argv(operation, &url, &dest, git_ref, depth)?;

        let workdir: &Path = if operation == "clone" {
            &self.sandbox_root
        } else {
            &repo_dir
        };

        let (stdout, stderr, code, truncated) = run_git(
            &args,
            workdir,
            Duration::from_secs(host_cfg.operation_timeout_secs.max(1)),
            &auth_sock,
            &git_ssh_command,
        )
        .await?;

        Ok(ToolOutput::success(
            serde_json::json!({
                "operation": operation,
                "host": host,
                "repo": repo,
                "path": path_str,
                "stdout": stdout,
                "stderr": stderr,
                "exit_code": code,
                "success": code == 0,
                "truncated": truncated,
            }),
            start.elapsed(),
        ))
    }

    fn requires_approval(&self, _params: &serde_json::Value) -> ApprovalRequirement {
        // Network + potentially destructive (push). Always require approval.
        ApprovalRequirement::Always
    }

    fn requires_sanitization(&self) -> bool {
        // Remote git output (branch names, commit messages, server stderr) is untrusted.
        true
    }

    fn domain(&self) -> ToolDomain {
        // Needs the in-process agent socket + bridge; runs in the gateway process.
        ToolDomain::Orchestrator
    }

    fn execution_timeout(&self) -> Duration {
        Duration::from_secs(180)
    }

    fn rate_limit_config(&self) -> Option<ToolRateLimitConfig> {
        Some(ToolRateLimitConfig::new(30, 300))
    }
}

/// Build the remote git URL from the host alias config + repo path.
///
/// Port 22 uses scp-form (`user@host:repo`, repo relative to the login home);
/// other ports use `ssh://user@host:port/repo` (path absolute-from-root). The
/// port is also passed via `-p` in GIT_SSH_COMMAND, which matches scp-form.
fn build_remote_url(cfg: &SSHHostConfig, repo: &str) -> String {
    let repo = repo.trim_start_matches('/');
    if cfg.port == 22 {
        format!("{}@{}:{}", cfg.user, cfg.host, repo)
    } else {
        format!("ssh://{}@{}:{}/{}", cfg.user, cfg.host, cfg.port, repo)
    }
}

/// OpenSSH known_hosts host-spec: bare host for :22, `[host]:port` otherwise.
fn host_spec(cfg: &SSHHostConfig) -> String {
    if cfg.port == 22 {
        cfg.host.clone()
    } else {
        format!("[{}]:{}", cfg.host, cfg.port)
    }
}

/// Build a single known_hosts line, preferring a live verifier pin (raw wire
/// bytes → base64) over the config's OpenSSH `known_host_key` string. Returns
/// `None` if no host key material is available.
fn known_hosts_line(cfg: &SSHHostConfig, pin: Option<&StoredHostKey>) -> Option<String> {
    let spec = host_spec(cfg);
    if let Some(pin) = pin {
        Some(format!(
            "{} {} {}\n",
            spec,
            pin.key_type,
            BASE64.encode(&pin.public_key)
        ))
    } else {
        cfg.known_host_key
            .as_deref()
            .map(|k| format!("{} {}\n", spec, k.trim()))
    }
}

/// Build the GIT_SSH_COMMAND. StrictHostKeyChecking is keyed to the host's
/// `host_key_mode` (`yes` for Strict, `accept-new` for AcceptFirst TOFU). The
/// known_hosts path is quoted (GIT_SSH_COMMAND is shell-parsed).
fn build_git_ssh_command(cfg: &SSHHostConfig, known_hosts_path: &Path) -> String {
    let strict = match cfg.host_key_mode {
        HostKeyMode::Strict => "yes",
        HostKeyMode::AcceptFirst => "accept-new",
    };
    format!(
        "ssh -o StrictHostKeyChecking={strict} -o UserKnownHostsFile=\"{ukhf}\" \
         -o GlobalKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout={ct} -p {port}",
        strict = strict,
        ukhf = known_hosts_path.display(),
        ct = cfg.connect_timeout_secs,
        port = cfg.port,
    )
}

/// Build the git argv for an operation. `--` terminates options before the
/// caller-influenced URL/dest (clone); `origin` is the remote for the mutating
/// ops; `pull` is fast-forward-only.
fn build_argv(
    operation: &str,
    url: &str,
    dest: &str,
    git_ref: Option<&str>,
    depth: Option<u64>,
) -> Result<Vec<String>, ToolError> {
    let mut args: Vec<String> = Vec::new();
    match operation {
        "clone" => {
            args.push("clone".into());
            if let Some(d) = depth {
                args.push("--depth".into());
                args.push(d.to_string());
            }
            if let Some(r) = git_ref {
                args.push("--branch".into());
                args.push(r.to_string());
            }
            args.push("--".into());
            args.push(url.to_string());
            args.push(dest.to_string());
        }
        "fetch" => {
            args.push("fetch".into());
            if let Some(d) = depth {
                args.push("--depth".into());
                args.push(d.to_string());
            }
            args.push("origin".into());
            if let Some(r) = git_ref {
                args.push(r.to_string());
            }
        }
        "pull" => {
            args.push("pull".into());
            args.push("--ff-only".into());
            args.push("origin".into());
            if let Some(r) = git_ref {
                args.push(r.to_string());
            }
        }
        "push" => {
            args.push("push".into());
            args.push("origin".into());
            if let Some(r) = git_ref {
                args.push(r.to_string());
            }
        }
        other => {
            return Err(ToolError::InvalidParameters(format!(
                "unknown operation '{other}'"
            )));
        }
    }
    Ok(args)
}

/// Reject empty values and leading `-` (option injection) on caller-influenced
/// positional git args.
fn validate_git_arg(name: &str, value: &str) -> Result<(), ToolError> {
    if value.is_empty() {
        return Err(ToolError::InvalidParameters(format!(
            "{name} must not be empty"
        )));
    }
    if value.starts_with('-') {
        return Err(ToolError::InvalidParameters(format!(
            "{name} must not start with '-' (option injection)"
        )));
    }
    Ok(())
}

/// Reject force-push refspecs (a leading `+`).
fn validate_push_ref(git_ref: &str) -> Result<(), ToolError> {
    if git_ref.starts_with('+') {
        return Err(ToolError::NotAuthorized(
            "force-push refspecs (leading '+') are not allowed".into(),
        ));
    }
    Ok(())
}

/// Spawn `git` with a scrubbed env (allowlist + SSH_AUTH_SOCK / GIT_SSH_COMMAND
/// / GIT_TERMINAL_PROMPT), capture stdout/stderr (capped), bounded by `timeout`
/// (child killed on timeout). Returns (stdout, stderr, exit_code, truncated).
async fn run_git(
    args: &[String],
    workdir: &Path,
    timeout: Duration,
    auth_sock: &str,
    git_ssh_command: &str,
) -> Result<(String, String, i32, bool), ToolError> {
    let mut command = Command::new("git");
    command.args(args);

    // Scrub the environment: only forward the allowlist, so gateway secrets
    // (API keys, DB URL) never reach the git child (CWE-200).
    command.env_clear();
    for var in SAFE_ENV_VARS {
        if let Ok(val) = std::env::var(var) {
            command.env(var, val);
        }
    }
    command.env("SSH_AUTH_SOCK", auth_sock);
    command.env("GIT_SSH_COMMAND", git_ssh_command);
    command.env("GIT_TERMINAL_PROMPT", "0");

    command
        .current_dir(workdir)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());

    let mut child = command
        .spawn()
        .map_err(|e| ToolError::ExecutionFailed(format!("failed to spawn git: {e}")))?;

    let mut stdout = child.stdout.take();
    let mut stderr = child.stderr.take();

    let collected = tokio::time::timeout(timeout, async {
        let out_fut = async {
            let mut buf = Vec::new();
            if let Some(s) = stdout.as_mut() {
                let _ = s.take(MAX_OUTPUT_SIZE as u64).read_to_end(&mut buf).await;
            }
            buf
        };
        let err_fut = async {
            let mut buf = Vec::new();
            if let Some(s) = stderr.as_mut() {
                let _ = s.take(MAX_OUTPUT_SIZE as u64).read_to_end(&mut buf).await;
            }
            buf
        };
        let (out_buf, err_buf, status) = tokio::join!(out_fut, err_fut, child.wait());
        let status =
            status.map_err(|e| ToolError::ExecutionFailed(format!("git wait failed: {e}")))?;
        Ok::<_, ToolError>((out_buf, err_buf, status.code().unwrap_or(-1)))
    })
    .await;

    match collected {
        Ok(Ok((out_buf, err_buf, code))) => {
            let truncated = out_buf.len() >= MAX_OUTPUT_SIZE || err_buf.len() >= MAX_OUTPUT_SIZE;
            Ok((
                String::from_utf8_lossy(&out_buf).to_string(),
                String::from_utf8_lossy(&err_buf).to_string(),
                code,
                truncated,
            ))
        }
        Ok(Err(e)) => Err(e),
        Err(_) => {
            let _ = child.kill().await;
            Err(ToolError::Timeout(timeout))
        }
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;

    use super::*;
    use crate::bridge::ssh::{NullAuditLogger, SSHKeyType};
    use crate::secrets::{InMemorySecretsStore, SecretsCrypto, SecretsStore};
    use tempfile::TempDir;

    fn cfg(host: &str, port: u16, mode: HostKeyMode, known: Option<&str>) -> SSHHostConfig {
        SSHHostConfig {
            host: host.into(),
            port,
            user: "git".into(),
            key_type: SSHKeyType::Ed25519,
            host_key_mode: mode,
            known_host_key: known.map(|s| s.into()),
            connect_timeout_secs: 10,
            operation_timeout_secs: 30,
            keepalive_interval_secs: 60,
            keepalive_max_misses: 3,
        }
    }

    async fn bridge(hosts: Vec<SSHHostConfig>) -> Arc<RwLock<SSHBridge>> {
        let store: Arc<dyn SecretsStore + Send + Sync> = Arc::new(InMemorySecretsStore::new(
            Arc::new(
                SecretsCrypto::new(secrecy::SecretString::from(
                    "test-master-key-that-is-at-least-32-bytes-long!",
                ))
                .unwrap(),
            ),
        ));
        let mut map = HashMap::new();
        for h in hosts {
            map.insert(h.host.clone(), h);
        }
        Arc::new(RwLock::new(
            SSHBridge::new(
                uuid::Uuid::new_v4(),
                "t".into(),
                map,
                store,
                Arc::new(NullAuditLogger),
            )
            .await
            .unwrap(),
        ))
    }

    #[test]
    fn test_build_remote_url() {
        let c22 = cfg("git.example.com", 22, HostKeyMode::Strict, None);
        assert_eq!(
            build_remote_url(&c22, "org/repo.git"),
            "git@git.example.com:org/repo.git"
        );
        assert_eq!(
            build_remote_url(&c22, "/org/repo.git"),
            "git@git.example.com:org/repo.git"
        );
        let c2222 = cfg("h", 2222, HostKeyMode::Strict, None);
        assert_eq!(
            build_remote_url(&c2222, "org/repo.git"),
            "ssh://git@h:2222/org/repo.git"
        );
    }

    #[test]
    fn test_host_spec() {
        assert_eq!(host_spec(&cfg("h", 22, HostKeyMode::Strict, None)), "h");
        assert_eq!(
            host_spec(&cfg("h", 2222, HostKeyMode::Strict, None)),
            "[h]:2222"
        );
    }

    #[test]
    fn test_build_git_ssh_command() {
        let accept = build_git_ssh_command(
            &cfg("h", 2222, HostKeyMode::AcceptFirst, None),
            Path::new("/root/kh"),
        );
        assert!(accept.contains("StrictHostKeyChecking=accept-new"));
        assert!(accept.contains("BatchMode=yes"));
        assert!(accept.contains("ConnectTimeout=10"));
        assert!(accept.contains("-p 2222"));
        assert!(accept.contains("UserKnownHostsFile=\"/root/kh\""));
        let strict =
            build_git_ssh_command(&cfg("h", 22, HostKeyMode::Strict, None), Path::new("/root/kh"));
        assert!(strict.contains("StrictHostKeyChecking=yes"));
    }

    #[test]
    fn test_known_hosts_line() {
        let c = cfg("h", 22, HostKeyMode::Strict, Some("ssh-ed25519 AAAAKEY"));
        assert_eq!(
            known_hosts_line(&c, None),
            Some("h ssh-ed25519 AAAAKEY\n".to_string())
        );
        let pin = StoredHostKey {
            public_key: b"rawbytes".to_vec(),
            key_type: "ssh-ed25519".into(),
            fingerprint: String::new(),
        };
        let line = known_hosts_line(&c, Some(&pin)).unwrap();
        assert!(line.starts_with("h ssh-ed25519 "));
        assert!(line.contains(&BASE64.encode(b"rawbytes")));
        let bracketed = cfg("h", 2222, HostKeyMode::Strict, Some("ssh-ed25519 K"));
        assert_eq!(
            known_hosts_line(&bracketed, None),
            Some("[h]:2222 ssh-ed25519 K\n".to_string())
        );
        assert_eq!(known_hosts_line(&cfg("h", 22, HostKeyMode::Strict, None), None), None);
    }

    #[test]
    fn test_build_argv() {
        assert_eq!(
            build_argv("clone", "url", "/dest", Some("main"), Some(1)).unwrap(),
            vec!["clone", "--depth", "1", "--branch", "main", "--", "url", "/dest"]
        );
        assert_eq!(
            build_argv("fetch", "", "", None, None).unwrap(),
            vec!["fetch", "origin"]
        );
        assert_eq!(
            build_argv("pull", "", "", Some("main"), None).unwrap(),
            vec!["pull", "--ff-only", "origin", "main"]
        );
        assert_eq!(
            build_argv("push", "", "", Some("main"), None).unwrap(),
            vec!["push", "origin", "main"]
        );
    }

    #[test]
    fn test_validate_args() {
        assert!(validate_git_arg("ref", "-x").is_err());
        assert!(validate_git_arg("ref", "").is_err());
        assert!(validate_git_arg("ref", "main").is_ok());
        assert!(validate_push_ref("+main").is_err());
        assert!(validate_push_ref("main").is_ok());
    }

    #[tokio::test]
    async fn test_absolute_path_rejected() {
        let tmp = TempDir::new().unwrap();
        let tool = SshGitTool::new(bridge(vec![]).await, tmp.path().to_path_buf());
        let err = tool
            .execute(
                serde_json::json!({"operation":"clone","host":"h","repo":"r","path":"/etc/passwd"}),
                &JobContext::new("t", "t"),
            )
            .await
            .unwrap_err();
        assert!(matches!(err, ToolError::InvalidParameters(_)), "{err:?}");
    }

    #[tokio::test]
    async fn test_traversal_rejected() {
        let tmp = TempDir::new().unwrap();
        let tool = SshGitTool::new(bridge(vec![]).await, tmp.path().to_path_buf());
        let err = tool
            .execute(
                serde_json::json!({"operation":"clone","host":"h","repo":"r","path":"../../etc/passwd"}),
                &JobContext::new("t", "t"),
            )
            .await
            .unwrap_err();
        assert!(
            matches!(
                err,
                ToolError::NotAuthorized(_) | ToolError::InvalidParameters(_)
            ),
            "{err:?}"
        );
    }

    #[tokio::test]
    async fn test_unknown_host_rejected() {
        let tmp = TempDir::new().unwrap();
        let tool = SshGitTool::new(
            bridge(vec![cfg("known", 22, HostKeyMode::Strict, None)]).await,
            tmp.path().to_path_buf(),
        );
        let err = tool
            .execute(
                serde_json::json!({"operation":"clone","host":"nope","repo":"r","path":"dest"}),
                &JobContext::new("t", "t"),
            )
            .await
            .unwrap_err();
        assert!(matches!(err, ToolError::NotAuthorized(_)), "{err:?}");
    }

    #[tokio::test]
    async fn test_no_agent_socket_rejected() {
        // Bridge has the host but the agent server was never started.
        let tmp = TempDir::new().unwrap();
        let tool = SshGitTool::new(
            bridge(vec![cfg("h", 22, HostKeyMode::Strict, Some("ssh-ed25519 AAAA"))]).await,
            tmp.path().to_path_buf(),
        );
        let err = tool
            .execute(
                serde_json::json!({"operation":"clone","host":"h","repo":"r","path":"dest"}),
                &JobContext::new("t", "t"),
            )
            .await
            .unwrap_err();
        assert!(matches!(err, ToolError::ExecutionFailed(_)), "{err:?}");
    }
}
