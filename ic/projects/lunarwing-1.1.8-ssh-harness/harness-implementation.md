# SSH Harness — Implementation Plan

**Status:** Phase 1 complete (2026-06-25)

## Phase 1: Core Struct (`src/bridge/ssh.rs`) ✅ COMPLETE

### 1.1 Types Implemented

```rust
pub struct SSHBridge {
    tenant_id: Uuid,
    hosts: Arc<RwLock<HashMap<String, SSHHostConfig>>>,
    secrets_store: Arc<dyn SecretsStore + Send + Sync>,  // Used in Phase 3+
    audit_logger: Arc<dyn AuditLogger + Send + Sync>,
    agent_server: Option<Arc<SSHAgentServer>>,
}

pub struct SSHHostConfig {
    pub host: String,
    pub port: u16,
    pub user: String,
    pub key_type: SSHKeyType,  // Ed25519, Ecdsa, Rsa
    pub host_key_mode: HostKeyMode,  // Strict, AcceptFirst
    pub known_host_key: Option<String>,
    pub connect_timeout_secs: u64,
    pub operation_timeout_secs: u64,
    pub keepalive_interval_secs: u64,
    pub keepalive_max_misses: u32,
}

pub struct SSHCredentials {
    pub key_data: Vec<u8>,
    pub passphrase: Option<String>,  // Support for encrypted keys
}

pub enum SshBridgeError {
    // Config errors
    HostNotFound(String),
    InvalidHostConfig(String),
    ValidationFailed(String),
    // Secret errors
    SecretNotFound(String),
    SecretDecryptionFailed(String),
    // Key errors
    InvalidKeyFormat(String),
    KeyValidationFailed(String),
    PassphraseRequired,
    PassphraseIncorrect,
    // Host key errors
    HostKeyMismatch { expected: String, actual: String },
    UnknownHostKey { fingerprint: String },
    // Connection errors
    ConnectionTimeout(u64),
    ConnectionRefused(String),
    AuthenticationFailed { user: String, host: String },
    PermissionDenied(String),
    // Agent errors
    AgentSocketUnavailable,
    AgentProtocolError(String),
    // Internal
    Internal(String),
    Io(std::io::Error),
}
```

### 1.2 Additional Infrastructure Built

- **`SshEvent` enum** — Audit events (HostAdded, HostRemoved, ConnectionAttempt, CommandExecuted, KeyRotated, HostKeyChanged, AgentStarted, AgentStopped)
- **`AuditLogger` trait** — Pluggable audit logging with `NullAuditLogger` for testing
- **`SSHAgentServer` struct** — Placeholder for Phase 6 (worker integration)
- **Helper functions** — `is_valid_hostname()`, `sanitize_secret_name()`

### 1.3 Methods Implemented

```rust
impl SSHBridge {
    pub async fn new(...) -> Result<Self>
    pub async fn validate(&self) -> Result<()>
    pub async fn get_host_config(&self, hostname: &str) -> Result<SSHHostConfig>
    pub async fn list_hosts(&self) -> Vec<SSHHostConfig>
    pub async fn add_host(&self, config: SSHHostConfig) -> Result<()>
    pub async fn remove_host(&self, hostname: &str) -> Result<()>
    pub async fn start_agent_server(&mut self) -> Result<()>  // Placeholder
    pub async fn stop_agent_server(&mut self) -> Result<()>
    pub fn get_agent_socket_path(&self) -> Option<String>
}
```

### 1.4 Tests

- `test_valid_hostname` ✅
- `test_sanitize_secret_name` ✅
- `test_create_bridge` ✅
- `test_add_host` ✅

**Notes:**
- Phase 1 exceeded scope slightly (added audit logging, host key verification modes, connection config)
- All code compiles and tests pass
- `secrets_store` field marked `#[allow(dead_code)]` — used in Phase 3
- `sanitize_secret_name` unused until Phase 3

---

## Phase 2: Config Storage (Next)

## Phase 2: Config Storage

### 2.1 Update `config.toml` Schema

```toml
[ssh]
enabled = true

[ssh.hosts.production]
hostname = "prod.lunarwing.org"
username = "deploy"
port = 22

[ssh.hosts.staging]
hostname = "staging.lunarwing.org"
username = "deploy"
port = 22
```

### 2.2 Parse Config in `AppBuilder`

```rust
let ssh_hosts: HashMap<String, SSHHostConfig> = config
    .ssh
    .hosts
    .into_iter()
    .map(|(name, cfg)| (name, cfg))
    .collect();
```

## Phase 3: Secrets Integration

### 3.1 Naming Convention

- `ssh_key_<host>` → SSH private key for host

### 3.2 Secrets Store Access

```rust
let key = secrets.get(&format!("ssh_key_{}", host))?;
```

## Phase 4: Gateway Wiring (`src/app.rs`)

### 4.1 Build Bridge

```rust
let ssh_bridge = SSHBridge::new(ssh_hosts);
ssh_bridge.validate()?;
```

### 4.2 Inject into Context

```rust
app.routine_context.add_bridge("ssh", ssh_bridge);
```

## Phase 5: Routine API

### 5.1 Usage Example

```rust
// Inside a routine or worker:
let config = ctx.bridge.ssh.get_config("production")?;
let creds = ctx.bridge.ssh.get_credentials("production", &ctx.secrets)?;

// Use config + creds for SSH operations
```

## Phase 6: Remote Worker Integration

### 6.1 Nanocode/Pebble Integration

```rust
let host_config = ssh_bridge.get_config("production")?;
let creds = ssh_bridge.get_credentials("production", &secrets)?;

// Mount SSH key to worker container (in-memory)
// Execute git ops or remote commands
```

## Phase 7: Migration

### 7.1 Update Existing Routines

- Remove manual `ssh_host`, `ssh_key` from routine context
- Update routines to use `ctx.bridge.ssh`

### 7.2 Deprecate Old Patterns

- Add warnings for manual SSH config
- Timeline: 1.1.8 → 1.1.9 deprecation cycle

## Phase 8: Testing

### 8.1 Unit Tests

- `get_config` for valid/invalid hosts
- `get_credentials` for valid/missing secrets
- `validate` for config correctness

### 8.2 Integration Tests

- Full SSH connection test
- Multi-tenant isolation test
- Secret rotation test

## Phase 9: Documentation

### 9.1 User Docs

- SSH harness setup guide
- Config.toml schema
- Secrets naming convention
- Routine usage examples

### 9.2 Developer Docs

- `SSHBridge` API reference
- Architecture overview
- Migration guide

---

## Timeline Estimate

| Phase | Effort | Notes |
|-------|--------|-------|
| Phase 1 | 1-2 days | Core struct |
| Phase 2 | 0.5 days | Config parsing |
| Phase 3 | 0.5 days | Secrets integration |
| Phase 4 | 0.5 days | Gateway wiring |
| Phase 5 | 1 day | Routine API |
| Phase 6 | 1-2 days | Worker integration |
| Phase 7 | 0.5 days | Migration |
| Phase 8 | 1-2 days | Testing |
| Phase 9 | 0.5 days | Docs |
| **Total** | **~7-10 days** | |

---

*See `harness-architecture.md` for architecture overview.*
