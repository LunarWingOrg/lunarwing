# Task 01: Core SSHBridge Struct — as built

**File:** `ic/src/bridge/ssh.rs`
**Status:** ✅ Done (shipped 1.1.8; verified 2026-07-01)

> The original spec sketched a minimal `SSHBridge { hosts }` with a
> `get_config()`/`get_credentials()` API and a 4-variant `BridgeError`. The
> shipped struct is substantially richer, and credential delivery was
> re-architected to the agent-socket model (there is no `get_credentials()`).
> This file documents what exists.

## Types (`ssh.rs`)

### `SSHBridge` (`:313`)

```rust
pub struct SSHBridge {
    tenant_id: Uuid,                                       // UUIDv5(NAMESPACE_DNS, owner_id)
    tenant_name: String,                                   // owner_id; used for the socket path
    hosts: Arc<RwLock<HashMap<String, SSHHostConfig>>>,
    secrets_store: Arc<dyn SecretsStore + Send + Sync>,
    audit_logger: Arc<dyn AuditLogger + Send + Sync>,
    agent_server: Option<Arc<SshAgentServer>>,             // None until start_agent_server()
}
```

### `SSHHostConfig` (`:153`)

`host`, `port` (default 22), `user`, `key_type: SSHKeyType`,
`host_key_mode: HostKeyMode` (default `Strict`), `known_host_key: Option<String>`,
`connect_timeout_secs` (10), `operation_timeout_secs` (30),
`keepalive_interval_secs` (60), `keepalive_max_misses` (3). Serde defaults let
`config.toml` omit everything but `host`/`user`/`key_type`.

### `SSHKeyType` (`:199`) / `HostKeyMode` (`:218`)

- `SSHKeyType` = `Ed25519 | Ecdsa | Rsa` (serde lowercase; `Display`).
- `HostKeyMode` = `Strict` (default) | `AcceptFirst` (serde PascalCase). No
  `AcceptAny` — deliberately omitted as insecure.

### `SSHCredentials` (`:240`)

```rust
pub struct SSHCredentials {
    pub key_data: Zeroizing<Vec<u8>>,   // raw PEM/OpenSSH bytes, zeroized on drop
    pub passphrase: Option<SecretString>,
}
```

### `SshBridgeError` (`:78`) + `Result<T>` (`:145`)

`thiserror` enum spanning config / secret / key / host-key / connection / agent
/ internal errors. Only `Io` has `#[from]`. Far larger than the sketched
`BridgeError`.

### Audit: `SshEvent` (`:253`) + `AuditLogger` trait (`:293`)

Event enum (`HostAdded`, `HostRemoved`, `ConnectionAttempt`, `CommandExecuted`,
`KeyRotated`, `HostKeyChanged`, `AgentStarted`, `AgentStopped`) and an
async-trait logger. `NullAuditLogger` (`:299`) is the only production impl today.

## Methods (`impl SSHBridge`)

```rust
pub async fn new(tenant_id, tenant_name, hosts, secrets_store, audit_logger) -> Result<Self>  // :338
pub async fn validate(&self) -> Result<()>                       // :363  (empty -> Ok; hostname/port!=0/user checks)
pub async fn get_host_config(&self, hostname: &str) -> Result<SSHHostConfig>  // :404
pub async fn list_hosts(&self) -> Vec<SSHHostConfig>             // :413
pub async fn add_host(&self, config: SSHHostConfig) -> Result<()>            // :419  (+ audit HostAdded)
pub async fn remove_host(&self, hostname: &str) -> Result<()>   // :438  (+ audit HostRemoved)
pub async fn start_agent_server(&mut self) -> Result<()>        // :464  (loads keys, starts SshAgentServer)
pub async fn stop_agent_server(&mut self) -> Result<()>         // :546  (drops the Arc)
pub fn get_agent_socket_path(&self) -> Option<String>           // :554
pub fn agent_server(&self) -> Option<Arc<SshAgentServer>>       // :561  (for the API state)
```

Helpers: `is_valid_hostname` (`:571`); `sanitize_secret_name` (`:587`,
`#[allow(dead_code)]` — the same logic is inlined in `start_agent_server` and in
`ssh_secrets::secret_name_for_host`, a small duplication worth consolidating).

Notable behavior:
- **`validate()` returns `Ok` on an empty host map** and does **not** check that
  key secrets exist (keys may be uploaded later; there's a TODO at `:397`). This
  differs from the spec, which wanted `ValidationFailed` on empty hosts.
- **`start_agent_server` is the load-bearing method.** It computes the run-dir
  socket path, decrypts each host's key from the store into `Zeroizing`, and
  hands the map to `SshAgentServer::start`. Missing/unreadable keys are skipped
  fail-soft. See [task-03](task-03-secrets-integration.md) and
  [`ssh_agent.rs`](../../../src/bridge/ssh_agent.rs).

## Tests (`#[cfg(test)]`, 4)

`test_valid_hostname`, `test_sanitize_secret_name`, `test_create_bridge`,
`test_add_host`.

## Deltas from the original spec

- No `SSHBridge::get_credentials(host, secrets)` — replaced by the agent socket.
- Field names are `host`/`user` (spec said `hostname`/`username`).
- `SSHBridge` holds `secrets_store`, `audit_logger`, and a live `agent_server`
  (spec had only `hosts`).
- `SshBridgeError` is a large taxonomy, not the sketched 4 variants.
