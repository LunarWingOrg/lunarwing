# SSH Harness — Implementation Plan

## Phase 1: Core Struct (`src/bridge/ssh.rs`)

### 1.1 Define Types

```rust
pub struct SSHBridge {
    hosts: HashMap<String, SSHHostConfig>,
}

pub struct SSHHostConfig {
    pub hostname: String,
    pub username: String,
    pub port: u16,
}

pub struct SSHCredentials {
    pub key: String, // Or Vec<u8> for binary key data
}

pub enum BridgeError {
    HostNotFound,
    SecretNotFound(String),
    ValidationFailed(String),
}
```

### 1.2 Implement Methods

```rust
impl SSHBridge {
    pub fn new(hosts: HashMap<String, SSHHostConfig>) -> Self {
        Self { hosts }
    }

    pub fn get_config(&self, host: &str) -> Result<SSHHostConfig, BridgeError> {
        self.hosts.get(host).cloned().ok_or_else(|| BridgeError::HostNotFound)
    }

    pub fn get_credentials(&self, host: &str, secrets: &SecretsStore) -> Result<SSHCredentials, BridgeError> {
        let key_id = format!("ssh_key_{}", host);
        let key = secrets.get(&key_id)?
            .ok_or_else(|| BridgeError::SecretNotFound(key_id))?;
        Ok(SSHCredentials { key })
    }

    pub fn validate(&self) -> Result<(), BridgeError> {
        // Validate host configs
        // Optional: connectivity tests
        Ok(())
    }
}
```

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
