# SSH Operations for the LunarWing Agent — Options 2 & 3 Implementation Plans

**Date:** 2026-07-01
**Status:** Proposal — implementation plans for Options 2 & 3 (Option 1 is shipped)
**Companion docs:** [`SSH_HARNESS_DELIVERY_OPTIONS.md`](SSH_HARNESS_DELIVERY_OPTIONS.md) · [`../architecture/SSH_AGENT_HARNESS.md`](../architecture/SSH_AGENT_HARNESS.md) · [`../ops/SSH-HARNESS-SETUP.md`](../ops/SSH-HARNESS-SETUP.md)

> Grounded in the current implementation of the Agent SSH Harness (verified
> against source 2026-07-01). The `russh` 0.45 client signatures were checked
> against docs.rs and the `Tool` trait against `ic/src/tools/tool.rs`. See the
> companion delivery-options doc for the Option 1/2/3 framing.

---

Both plans build on the **already-shipped Agent SSH Harness** (`ic/src/bridge/ssh.rs`, `ssh_agent.rs`, `ssh_secrets.rs`, `ssh_hostkeys.rs`, `ssh_api.rs`, `config/ssh.rs`). Option 1 (agent-socket bind-mount into worker containers) already ships; Options 2 and 3 make SSH usable *inline* from the agent process. Both introduce the **first live consumer of the russh 0.45 client** (`Cargo.toml:153-154` — only `russh-keys` is used today) and the **first live wiring of `HostKeyVerifier`** (`ssh_hostkeys.rs:267`, built + unit-tested but wired into no connection path).

---

## Option 2 — Built-in Rust SSH tool

### 1. Goal & scope

Ship one, optionally two, agent-visible **built-in `Tool`s** (`Tool` trait, `ic/src/tools/tool.rs:271`):

- **`ssh`** — run a single command on a **configured** host and return stdout/stderr/exit code.
- **`ssh_git`** (optional, phase 2) — run a git operation (clone/fetch/pull, and optionally push) over SSH by shelling out to `git` with `SSH_AUTH_SOCK` pointed at the harness agent socket. This is a *different execution path* than raw command exec and should be a deliberate second tool because its risk/approval profile differs (flagged as an open question by the research: "Should git operations be a distinct tool vs a generic ssh_exec").

**`ssh` parameter schema** (`parameters_schema()`, mirrors the shape in `parameters_schema` used by `HttpTool`/`CreateJobTool`):

```json
{
  "type": "object",
  "properties": {
    "host":    { "type": "string", "description": "Configured host alias (must exist in [[ssh.hosts]])" },
    "command": { "type": "string", "description": "Command to execute on the remote host" }
  },
  "required": ["host", "command"]
}
```

Deliberately **no** `user`/`port`/`private_key` params — host, port, user and timeouts come from `SSHHostConfig` resolved by alias (`ssh.rs:404 get_host_config`). This makes the configured host map the egress allowlist (see §5). This resolves the research open question "Should host allowlisting be enforced strictly to only `config.ssh.hosts` entries (recommended)".

**Output shape** (`ToolOutput::success(json, dur)`, `tool.rs:180-226`):

```json
{ "output": "<stdout>", "stderr": "<stderr>", "exit_code": 0, "success": true, "host": "prod-db" }
```

`ssh_git` schema adds `operation` (`clone|fetch|pull|push`), `repo`, `dest`, `ref`.

### 2. Architecture

**Where the client lives:** new module `ic/src/bridge/ssh_client.rs`, registered `pub mod ssh_client;` in `bridge/mod.rs`, exposing `SshClient::connect_and_exec(host: &SSHHostConfig, command: &str) -> Result<CommandResult, SshBridgeError>`. This wraps the russh 0.45 client (the currently-unused half of the dep). Keeping it in `bridge/` (next to `ssh_agent.rs`) rather than in `tools/builtin/` lets both the tool and a future `ssh_api.rs` exec endpoint (`ssh_api.rs`) reuse it.

**Credential acquisition — recommendation: decode the key directly via `SshSecretsManager`, not the agent socket.** Justification from the russh research: for an in-process client, `russh_keys::decode_secret_key(&key_str, passphrase)` → `KeyPair`, then `authenticate_publickey(user, Arc<KeyPair>)` is cleaner than driving the agent socket; the agent socket stays the mechanism for *out-of-process* consumers (git shell-out, worker containers / Option 1). The decode logic already exists in `ssh_agent.rs::parse_key` (`ssh_agent.rs:62`) and should be lifted into a shared helper.

- **Wiring gap to close (flagged by research):** `SSHBridge` exposes no public per-host key accessor today — `load_key` is called only internally inside `start_agent_server` (`ssh_secrets.rs:121`, `SshSecretsManager::load_key` returns `SSHCredentials { key_data: Zeroizing<Vec<u8>>, passphrase }`, `ssh.rs:240`). **Decision needed:** either (a) add `pub async fn load_key(&self, host) -> Result<SSHCredentials>` to `SSHBridge` (re-exposes zeroized key bytes to the tool — widens blast radius), or (b) hand the tool the `secrets_store` and let it construct its own `SshSecretsManager`. The wiring-safety researcher notes the **agent-socket auth path is safer** (keys never re-enter the tool) but the russh researcher notes **direct decode is cleaner**. This is a genuine open tradeoff — recommend **(a) `SSHBridge::load_key` + direct decode** for phase 1 (simplest, single russh code path), and reserve the agent socket for `ssh_git`.

**Host-key verification — finally wiring `HostKeyVerifier`.** The russh `client::Handler::check_server_key` callback (`ssh_hostkeys.rs`'s `verify_from_config`, `ssh_hostkeys.rs:267`) is the single place `HostKeyVerifier` becomes live. It runs during KEX, *before* any `authenticate_*` call, so host verification precedes auth automatically.

**Critical byte-comparison detail (research trap):** compare via `PublicKey::public_key_bytes()` (raw wire blob), **not** fingerprint strings — russh's `PublicKey::fingerprint()` is base64 SHA256 *without* `=` padding, while `HostKeyVerifier::compute_fingerprint` (`ssh_hostkeys.rs:82`) uses STANDARD base64 *with* padding; `verify_from_config` already compares raw bytes, so pass `public_key_bytes()` straight through.

`SSHBridge` needs an `Arc<HostKeyVerifier>` (it doesn't own one today — wiring gap). Recommend `SSHBridge` constructs and holds it, keyed off each host's `host_key_mode` (`ssh.rs:165`, `HostKeyMode` Strict/AcceptFirst).

### 3. New / changed files

**New: `ic/src/bridge/ssh_client.rs`** — russh recipe (types are in `russh` 0.45 / `russh_keys` 0.45, **not** `russh::keys`; that re-export merge is >= 0.50 — **do not bump russh**):

```rust
use std::sync::Arc;
use russh::client::{self, Config, Handle, Handler};
use russh::{ChannelMsg, Disconnect};
use russh_keys::key::{KeyPair, PublicKey};
use russh_keys::PublicKeyBase64; // public_key_bytes()

struct ClientHandler { verifier: Arc<HostKeyVerifier>, host: SSHHostConfig }

#[async_trait::async_trait]
impl Handler for ClientHandler {
    type Error = russh::Error;
    async fn check_server_key(&mut self, key: &PublicKey) -> Result<bool, Self::Error> {
        let key_bytes = key.public_key_bytes();
        match self.verifier.verify_from_config(&self.host, &key_bytes).await {
            Ok(VerifyResult::Verified) | Ok(VerifyResult::Accepted) => Ok(true),
            Err(e) => { tracing::warn!(host=%self.host.host, "host key rejected: {e}"); Ok(false) }
            // log THEN Ok(false): returning Err loses the specific reason (research note)
        }
    }
}

pub async fn connect_and_exec(host: &SSHHostConfig, creds: &SSHCredentials, verifier: Arc<HostKeyVerifier>, command: &str)
    -> Result<CommandResult, SshBridgeError>
{
    let mut cfg = Config::default();
    cfg.inactivity_timeout = Some(Duration::from_secs(host.operation_timeout_secs));
    let handler = ClientHandler { verifier, host: host.clone() };
    let mut session: Handle<ClientHandler> = tokio::time::timeout(
        Duration::from_secs(host.connect_timeout_secs),
        client::connect(Arc::new(cfg), (host.host.as_str(), host.port), handler),
    ).await.map_err(|_| SshBridgeError::ConnectionTimeout(host.connect_timeout_secs))??;

    let key_str = String::from_utf8_lossy(&creds.key_data).to_string();
    let pass = creds.passphrase.as_ref().map(|s| s.expose_secret().as_ref());
    let key = russh_keys::decode_secret_key(&key_str, pass)
        .map_err(|e| SshBridgeError::InvalidKeyFormat(e.to_string()))?;
    if !session.authenticate_publickey(&host.user, Arc::new(key)).await? {
        return Err(SshBridgeError::AuthenticationFailed { user: host.user.clone(), host: host.host.clone() });
    }

    let mut channel = session.channel_open_session().await?;
    channel.exec(true, command.as_bytes()).await?;
    let (mut stdout, mut stderr, mut exit) = (Vec::new(), Vec::new(), None::<i32>);
    // wrap this loop in tokio::time::timeout(operation_timeout_secs) + a max-output cap
    loop {
        match channel.wait().await {
            Some(ChannelMsg::Data { data }) => stdout.extend_from_slice(&data),
            Some(ChannelMsg::ExtendedData { data, ext }) if ext == 1 => stderr.extend_from_slice(&data),
            Some(ChannelMsg::ExitStatus { exit_status }) => exit = Some(exit_status as i32),
            Some(ChannelMsg::Eof) | Some(ChannelMsg::Close) | None => break,
            _ => {}
        }
    }
    session.disconnect(Disconnect::ByApplication, "", "").await.ok();
    Ok(CommandResult { stdout, stderr, exit_code: exit.unwrap_or(-1) })
}
```
(Signatures confirmed against docs.rs russh 0.45: `client::connect(config, addrs, handler) -> Result<Handle<H>, H::Error>`; `authenticate_publickey(user, Arc<KeyPair>) -> Result<bool>`; `channel_open_session() -> Channel<Msg>`; `Channel::exec(want_reply, cmd)`; `ChannelMsg::{Data,ExtendedData{ext==1=stderr},ExitStatus}`.)

**New: `ic/src/tools/builtin/ssh.rs`** — the `Tool` impl (following the `SecretListTool::new(Arc<…>)` DI pattern, `registry.rs:486`):

```rust
pub struct SshTool { ssh_bridge: Arc<tokio::sync::RwLock<SSHBridge>> }
impl SshTool { pub fn new(b: Arc<tokio::sync::RwLock<SSHBridge>>) -> Self { Self { ssh_bridge: b } } }

#[async_trait]
impl Tool for SshTool {
    fn name(&self) -> &str { "ssh" }
    fn description(&self) -> &str { "Run a command on a configured remote SSH host (host must be in [[ssh.hosts]])." }
    fn parameters_schema(&self) -> serde_json::Value { /* schema above */ }
    async fn execute(&self, params: serde_json::Value, _ctx: &JobContext) -> Result<ToolOutput, ToolError> {
        let start = std::time::Instant::now();
        let host = require_str(&params, "host")?;
        let command = require_str(&params, "command")?;
        let bridge = self.ssh_bridge.read().await;                    // hold read guard briefly
        let host_cfg = bridge.get_host_config(host).await            // ssh.rs:404 — rejects unknown host
            .map_err(|e| ToolError::NotAuthorized(format!("unknown ssh host '{host}': {e}")))?;
        let creds = bridge.load_key(host).await                       // NEW accessor (see §2)
            .map_err(|e| ToolError::ExecutionFailed(e.to_string()))?
            .ok_or_else(|| ToolError::NotAuthorized(format!("no key for host '{host}'")))?;
        let verifier = bridge.host_key_verifier();                    // NEW accessor
        drop(bridge);                                                 // release before long session
        let r = ssh_client::connect_and_exec(&host_cfg, &creds, verifier, command).await
            .map_err(map_ssh_err)?;                                   // -> Timeout/NotAuthorized/ExecutionFailed
        Ok(ToolOutput::success(serde_json::json!({
            "output": String::from_utf8_lossy(&r.stdout), "stderr": String::from_utf8_lossy(&r.stderr),
            "exit_code": r.exit_code, "success": r.exit_code == 0, "host": host
        }), start.elapsed()))
    }
    fn requires_approval(&self, _p: &serde_json::Value) -> ApprovalRequirement { ApprovalRequirement::Always }
    fn requires_sanitization(&self) -> bool { true }                 // remote output is untrusted
    fn domain(&self) -> ToolDomain { ToolDomain::Orchestrator }      // in-process, NOT Container
    fn execution_timeout(&self) -> std::time::Duration { std::time::Duration::from_secs(120) }
    fn rate_limit_config(&self) -> Option<ToolRateLimitConfig> { Some(ToolRateLimitConfig::new(30, 300)) }
}
```
Error mapping mirrors `ShellTool::execute_command` (`shell.rs:773-822`): map `SshBridgeError::{ConnectionTimeout}` → `ToolError::Timeout`, `{AuthenticationFailed,HostKeyMismatch,UnknownHostKey}` → `ToolError::NotAuthorized`, else `ToolError::ExecutionFailed`.

**Changed: `ic/src/tools/builtin/mod.rs`** — `mod ssh;` + `pub use ssh::SshTool;` (alongside `pub use shell::ShellTool;`).

**Changed: `ic/src/tools/registry.rs`** — add helper mirroring `register_secrets_tools` (`registry.rs:486`), and add `"ssh"` to `PROTECTED_TOOL_NAMES` (`registry.rs:39`) so an installed dynamic tool can't shadow it:

```rust
pub fn register_ssh_tool(&self, bridge: Arc<tokio::sync::RwLock<SSHBridge>>) {
    self.register_sync(Arc::new(crate::tools::builtin::SshTool::new(bridge)));
    tracing::debug!("Registered ssh tool");
}
```

**Changed: `ic/src/app.rs`** — **late registration**, no init reordering (the `tools: Arc<ToolRegistry>` is still in scope where `ssh_bridge` is built; `register_sync` takes `&self`). Insert right after the `ssh_bridge` let-binding (built at `app.rs:1055`, returned at `app.rs:1136`) and before the `AppComponents { … }` return:

```rust
if let Some(ref bridge) = ssh_bridge {
    tools.register_ssh_tool(Arc::clone(bridge));
}
```
No change to `AppComponents` (the `ssh_bridge` field already exists at `app.rs:64`).

### 4. Data flow end-to-end

1. Agent emits `ssh(host, command)` tool call.
2. `ApprovalGate` sees `requires_approval()==Always` → `GateDecision::Pause`, emits `approval_needed` SSE; loop pauses until the operator approves (`gate/approval.rs`).
3. `execute()` acquires `bridge.read().await`, resolves `SSHHostConfig` via `get_host_config` (`ssh.rs:404`) — **unknown host is rejected here** (the SSH egress allowlist).
4. Loads `SSHCredentials` (zeroized key bytes) via the new `load_key` accessor (`ssh_secrets.rs:121`); grabs the `HostKeyVerifier`; drops the read guard.
5. `ssh_client::connect_and_exec` opens the russh session; `check_server_key` invokes `verify_from_config` (`ssh_hostkeys.rs:267`) → Strict/AcceptFirst byte comparison → accept/reject.
6. Authenticates with the decoded `KeyPair`; opens a session channel; runs the command; drains `stdout`/`stderr`/`exit`, bounded by `operation_timeout_secs` and a max-output cap.
7. Returns `ToolOutput`; framework applies sanitization (`requires_sanitization()==true`) before the output re-enters LLM context.

**In-process vs worker-mounted-socket (Option 1):** Option 1 bind-mounts `get_agent_socket_path()` (`ssh.rs:554`) into a container and the *container's* ssh/git binary signs via the agent, with a container spin-up per task. Option 2 runs russh **in the gateway process** — no container, lower latency, but the SSH exchange (and, in the recommended path, the decoded key bytes) live in the gateway process (see §5 tradeoff).

### 5. Security

- **Approval:** `requires_approval()` → `ApprovalRequirement::Always` (remote code execution ≥ local shell). Consider `risk_level_for()` → `RiskLevel::High`. Default is `Never` (`tool.rs:325`) — forgetting the override silently ships unattended RCE. Because `tool_definitions_excluding` auto-filters any tool whose `requires_approval() != Never` (`registry.rs:327`), `ssh` is automatically excluded from lightweight/autonomous routine tool lists.
- **Egress policy:** `NetworkPolicyDecider` governs only the Docker sandbox proxy (`sandbox/proxy/policy.rs:88`) and the WASM allowlist governs only WASM tools — **neither covers in-process built-in tools.** The SSH tool self-enforces egress by resolving only configured hosts via `get_host_config`. Since operator-configured SSH hosts are typically on private networks (harness sets `ALLOW_PRIVATE_IPS=1`), the plan **restricts to configured hosts only and skips the private-IP block** (this resolves the research open question about honoring `ALLOW_PRIVATE_IPS`; the `http.rs:211 is_disallowed_ip` model is deliberately *not* applied).
- **Redaction:** declare `sensitive_params()` for any secret-bearing param — but the schema deliberately carries none (keys come from the store by host alias). `redact_params` (`tool.rs:459`) covers *input* params only; remote **stdout/stderr can still leak secrets** and is not covered — `requires_sanitization()==true` handles prompt-injection but operators may still see secret-bearing output in SSE. Consider output scrubbing (open item).
- **Key zeroization:** `SSHCredentials.key_data` is `Zeroizing<Vec<u8>>` (`ssh.rs:240`); the decoded `KeyPair` and the `String::from_utf8_lossy` copy in `connect_and_exec` are transient — minimize their lifetime; do not log them.
- **Attack-surface tradeoff (from the proposal):** SSH now executes in the gateway process rather than a sandboxed container. This is the deliberate cost of the in-process optimization — lower isolation than Option 1, in exchange for no container spin-up and lower latency.
- **RSA limitation (research):** russh 0.45 `authenticate_publickey` signs RSA keys with `ssh-rsa` (SHA-1), which modern OpenSSH rejects (wants `rsa-sha2-256/512`). **Ed25519/ECDSA work; flag RSA as a known limitation** (open question: "Is RSA host support required, or is Ed25519 sufficient for launch?").

### 6. Config / agent surface

- **Enablement:** the tool is registered only when `ssh_bridge` exists, i.e. `config.ssh.hosts` non-empty **and** a secrets store is present (`app.rs:1055`). No new config flag needed.
- **Per-host allow:** the `[[ssh.hosts]]` TOML map (`config/ssh.rs`, `to_host_map()`) *is* the allowlist — the tool rejects any `host` param not in it.
- **Tool description** explicitly states host must be pre-configured, steering the LLM away from arbitrary targets.

### 7. Phased tasks, tests, risks, effort

**Tasks**
1. Add `SSHBridge::load_key` + `host_key_verifier()` accessors; have `SSHBridge` own `Arc<HostKeyVerifier>` (close the two wiring gaps).
2. Lift `parse_key` decode into a shared helper (`ssh_agent.rs:62`).
3. Write `ssh_client.rs` (russh connect/auth/exec + `check_server_key` → `HostKeyVerifier`, timeouts, output cap).
4. Write `builtin/ssh.rs` `Tool` impl; export in `mod.rs`; add `register_ssh_tool` + `"ssh"` to `PROTECTED_TOOL_NAMES`.
5. Late registration in `app.rs` after `ssh_bridge` build.
6. (Phase 2) `ssh_git` tool: shell out via `tokio::process::Command` with `SSH_AUTH_SOCK=get_agent_socket_path()` and `GIT_SSH_COMMAND` referencing a `known_hosts` materialized from `HostKeyVerifier::list_hosts()`.

**Test plan**
- **Unit:** parameter validation; unknown-host rejection; error mapping. `HostKeyVerifier` already unit-tested (`ssh_hostkeys.rs`).
- **Integration (this is where `HostKeyVerifier` is finally exercised in a live path):** stand up a local `sshd` or an in-process russh **server** in the test; assert (a) Strict mode rejects an unknown key with `NotAuthorized`, (b) AcceptFirst TOFU pins then matches, (c) command stdout/exit captured, (d) timeout kills a hanging command. Per repo policy every fix needs a test — the research explicitly flags "No regression test exists for the live client path."

**Risks / open questions (from research, not invented):** credential path decision (bridge `load_key` vs agent socket); RSA/SHA-1 limitation; unbounded output buffering (mitigated by cap); `RwLock` read/write contention during long sessions (mitigated by dropping the guard early); multi-tenant — `SSHBridge` is per-tenant (`config.owner_id`), a multi-tenant gateway needs per-user bridge resolution (WorkspacePool-style resolver) — **single-tenant sufficient for now**.

**Effort:** ~**3–5 engineer-days** (bulk = `ssh_client.rs` russh integration + the live integration test).

---

## Option 3 — WASM SSH tool

### 1. Why raw SSH cannot run in the WASM sandbox

WASM tools are `wasm32-wasip2` components under wasmtime with an **empty `WasiCtx`** (`WasiCtxBuilder::new().build()`, `wrapper.rs:180`) — **no filesystem, no env, no network sockets.** The only host capabilities are the 6 functions in the `near:agent/host` WIT interface (`wit/tool.wit:18` — log, now-millis, workspace-read, http-request, tool-invoke, secret-exists); **there is no raw-socket primitive.** Additionally `russh`/`russh-keys` cannot compile to `wasm32` (ring/aws-lc crypto + tokio). SSH needs a bidirectional TCP stream to port 22 plus the ssh-agent Unix socket — **the guest can reach neither.**

Therefore the only viable design is: **guest = thin RPC shim; host = the real SSH work.** Add a **new custom host function** (`ssh-exec`) whose implementation drives the *exact same Option 2 `ssh_client.rs`* host-side. The guest just serializes `{host, command}` and calls it.

**Split:**
- **Guest** (`tools-src/ssh/`): ~50 lines — parse `{host, command}` params, call `near::agent::host::ssh_exec(...)`, marshal the result into the tool `response`.
- **Host** (`wrapper.rs`/`host.rs`): resolve the alias against the per-tenant `SSHBridge`, run russh via `ssh_client::connect_and_exec`, verify host key with `HostKeyVerifier`, leak-scan output, return across the boundary. **Keys and the agent never cross into the guest.**

### 2. New host function, WIT, allowlist, guest

**WIT addition — `ic/wit/tool.wit`, `host` interface (`tool.wit:18`), package `near:agent@0.3.0`:**

```wit
ssh-exec: func(host: string, command: string) -> result<ssh-result, string>;

record ssh-result { exit-code: s32, stdout: list<u8>, stderr: list<u8> }
```
This is a **breaking interface bump** — every guest tool and the sibling `channel.wit` world regenerate bindings.

**Host impl — `ic/src/tools/wasm/wrapper.rs`, `impl near::agent::host::Host for StoreData`** (follow the `http_request` pattern at `wrapper.rs:326-563`): validate `host` against a new SSH allowlist capability (mirror `http_request`'s `check_http_allowed` → `AllowlistValidator`, `host.rs:255`), then run the SSH exchange on a dedicated current-thread runtime inside `spawn_blocking` (as `http_request` does, `wrapper.rs:475-563`), calling `ssh_client::connect_and_exec`. **Leak-scan `stdout`/`stderr`** before returning (same as HTTP responses, `wrapper.rs:551-556`).

**Plumbing:** thread an `Arc<tokio::sync::RwLock<SSHBridge>>` into `StoreData`/`HostState` at instantiation (analogous to how `host_credentials`/secrets are threaded today), plus a new `SshCapability` in `Capabilities`, populated from a `capabilities.json` `ssh` block by the loader (`loader.rs:221-266`). The allowlist should reuse the `[[ssh.hosts]]` aliases as the reachable set.

**Guest — `ic/tools-src/ssh/`:** `Cargo.toml` (`crate-type=cdylib`, deps `serde`/`serde_json`/`wit-bindgen`), `src/lib.rs` with `wit_bindgen::generate!({ world: "sandboxed-tool", path: "../../wit/tool.wit" })` implementing `Guest for SshTool` (`execute`/`schema`/`description`), plus `ssh-tool.capabilities.json` declaring the `ssh` allowlist and `registry/tools/ssh.json` (`source.dir`/`crate_name`). Built with `cargo component build --release --target wasm32-wasip2` (`scripts/build-wasm-extensions.sh:46-59`); loader picks up `<name>.wasm` + `<name>.capabilities.json` sidecars.

### 3. Files, data flow, security, config

**New:** `wit/tool.wit` addition; host impl in `wrapper.rs` + capability plumbing in `host.rs`/`loader.rs`; `tools-src/ssh/` (guest crate + capabilities); `registry/tools/ssh.json`; **reuses** Option 2's `ssh_client.rs` verbatim host-side.

**Data flow:** guest `execute` → `near::agent::host::ssh_exec(host, command)` → host validates alias against SSH allowlist → resolves `SSHHostConfig` (`ssh.rs:404`) + loads key (`ssh_secrets.rs:121`) → `ssh_client::connect_and_exec` (russh, `check_server_key` → `HostKeyVerifier` `ssh_hostkeys.rs:267`) → leak-scan → `ssh-result` back across the boundary → guest marshals to `response`.

**Security:** the guest has no key access, no socket, no agent — all privileged work is host-side (mirrors `credential_injector.rs`'s zero-exposure model, `credential_injector.rs:274`). Egress is gated by the new SSH allowlist (reusing configured aliases). Approval `Always` is enforced on the *outer* WASM tool wrapper (same `Tool` machinery). Honest caveat from research: **the WASM sandbox provides essentially no isolation for the actual SSH operation** — it only sandboxes argument marshalling, because russh must run host-side regardless.

**Config/agent surface:** same `[[ssh.hosts]]` source of truth; the guest is gated by a `capabilities.json` `ssh` block (like `http.allowlist`).

### 4. Phased tasks, tests, risks, effort

**Tasks:** (1) do all of Option 2 first (`ssh_client.rs` is a hard prerequisite); (2) extend `tool.wit` + regenerate all bindings; (3) implement `ssh_exec` host fn + `SshCapability` + loader plumbing; (4) build the guest crate + capabilities + registry entry; (5) wire the per-tenant `SSHBridge` Arc into `StoreData`.

**Tests:** everything in Option 2's plan, plus WIT-regeneration compile checks across all guests/channels, an allowlist-rejection test (unconfigured host blocked at the host boundary), and a guest→host round-trip integration test.

**Risks / open questions (research):** breaking WIT bump touches every guest and `channel.wit`; `http_request` (and thus `ssh_exec`) is **synchronous+blocking** on a `spawn_blocking` thread — a long SSH command holds that thread and interacts with fuel/epoch timeouts and the 300s cap (`runtime.rs:1011-1017`); **streaming/interactive SSH (PTYs) does not fit** the one-shot `execute()->response` model; the guest cannot reach the agent socket (reinforces host-side-only). Open questions the research left unanswered: whether Option 3 wants git-over-ssh (would need a separate host fn); whether `ssh-exec` should be a general `host`-interface method vs a **separate capability-gated WIT world** so only explicitly-granted tools can reach it; **and whether there is any real requirement driving Option 3 over Option 2 at all.**

**Effort:** ~**8–12 engineer-days** — Option 2's full effort **plus** WIT churn, a new host capability type, loader/capabilities plumbing, the `cargo component` guest, and cross-guest regeneration — "for near-zero security benefit" (research verdict).

---

## Comparison & recommendation

| Dimension | Option 1 (shipped: worker socket) | Option 2 (built-in Rust tool) | Option 3 (WASM tool) |
|---|---|---|---|
| **Isolation of SSH exec** | High (container) | Low (gateway process) | Low — russh runs host-side anyway; WASM only sandboxes marshalling |
| **Latency** | High (container spin-up) | Low (in-process) | Low exec, but blocks a `spawn_blocking` thread; 300s cap |
| **Deploy complexity** | Needs container + bind-mount | None beyond gateway | Highest: WIT bump + regen all guests + `cargo component` build |
| **Attack surface** | SSH confined to worker | SSH + (recommended) decoded key in gateway process | Same host-side surface as Opt 2 **plus** WIT/host-fn plumbing |
| **Reuse of existing harness** | Uses agent socket | Uses `SSHBridge`/`SshSecretsManager`/**wires `HostKeyVerifier`** | Same as Opt 2 + threads bridge into `StoreData` |
| **Effort** | Done | ~3–5 days | ~8–12 days (⊇ Opt 2) |

**Recommendation:** Ship **Option 2** as the useful optimization — inline SSH with no container spin-up, reusing the entire harness and, critically, **finally wiring `HostKeyVerifier` (`ssh_hostkeys.rs:267`) into a live `check_server_key` path** and exercising the russh client for the first time. Treat **Option 3 as exploratory / max-isolation only**: it *is* Option 2's `ssh_client.rs` plus a host-function bridge plus WASM plumbing, and the research is unambiguous that it "adds WIT churn… and a second build toolchain for near-zero security benefit," since russh must run host-side regardless. Build Option 2 first; Option 3 is strictly downstream of it.

**What BOTH options unlock that Option 1 does not:** (1) the first **live wiring of `HostKeyVerifier`** — today it is built + unit-tested but referenced by no connection path (the "single most important safety gap" per research); (2) the first real **russh 0.45 client** usage (`Cargo.toml:153`, unused today); (3) inline SSH with **no container spin-up / no bind-mount**, callable directly from a chat turn under `ApprovalRequirement::Always`.

**Unresolved decisions to settle before coding (research open questions, not invented):** credential path — `SSHBridge::load_key` + direct decode (recommended) vs agent-socket auth; RSA/SHA-1 support at launch (Ed25519/ECDSA work, RSA needs `rsa-sha2` verification on russh 0.45); `ssh_git` as a distinct tool vs generic `ssh_exec`; remote-output secret scrubbing beyond `requires_sanitization`; and whether Option 3 is in scope at all given Option 1 already covers the container/worker story.
