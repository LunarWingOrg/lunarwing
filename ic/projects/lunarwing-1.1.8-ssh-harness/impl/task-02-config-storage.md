# Implementation Task 02: Config Storage

**File:** `src/config.rs` (extend existing)  
**Effort:** 0.5 days  
**Priority:** High (required for Phase 2)  
**Status:** Not started  
**Depends on:** Task 01 (Core SSHBridge Struct)

---

## Objective

Extend the existing configuration system to support SSH host definitions in `config.toml`. This task handles parsing the `[ssh.hosts.*]` sections and converting them into the `HashMap<String, SSHHostConfig>` format that `SSHBridge::new()` expects.

---

## Deliverables

### 1. Config Schema Definition

Add the following schema to `config.toml`:

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

[ssh.hosts.dev]
hostname = "192.168.1.100"
username = "root"
port = 2222
```

#### Schema Rules

| Field | Type | Required | Default | Notes |
|-------|------|----------|---------|-------|
| `enabled` | bool | No | `false` | Master switch for SSH harness |
| `hosts.*.hostname` | string | Yes | — | FQDN or IP address |
| `hosts.*.username` | string | Yes | — | SSH username |
| `hosts.*.port` | integer | No | `22` | SSH port (1-65535) |

---

### 2. Config Struct Definitions

Add to `src/config.rs`:

#### `SshConfig` (top-level SSH section)
```rust
#[derive(Debug, Clone, Deserialize)]
pub struct SshConfig {
    #[serde(default = "default_ssh_enabled")]
    pub enabled: bool,
    
    #[serde(default)]
    pub hosts: HashMap<String, SshHostEntry>,
}

fn default_ssh_enabled() -> bool {
    false
}
```

#### `SshHostEntry` (per-host config from TOML)
```rust
#[derive(Debug, Clone, Deserialize)]
pub struct SshHostEntry {
    pub hostname: String,
    pub username: String,
    
    #[serde(default = "default_ssh_port")]
    pub port: u16,
}

fn default_ssh_port() -> u16 {
    22
}
```

#### Conversion Method

Add impl block to convert `SshHostEntry` → `SSHHostConfig`:

```rust
impl From<SshHostEntry> for crate::bridge::ssh::SSHHostConfig {
    fn from(entry: SshHostEntry) -> Self {
        Self {
            hostname: entry.hostname,
            username: entry.username,
            port: entry.port,
        }
    }
}
```

---

### 3. Config Parsing Logic

Extend `AppBuilder::load_config()` or equivalent:

```rust
// After loading main config:
let ssh_enabled = config.ssh.enabled;
let ssh_hosts: HashMap<String, SSHHostConfig> = if ssh_enabled {
    config
        .ssh
        .hosts
        .into_iter()
        .map(|(name, entry)| (name, entry.into()))
        .collect()
} else {
    HashMap::new()
};

// Pass to SSHBridge builder (Phase 4)
```

---

### 4. Validation (Config-Level)

Add validation in `AppBuilder::validate_config()`:

```rust
fn validate_ssh_config(config: &SshConfig) -> Result<(), ConfigError> {
    if !config.enabled {
        return Ok(()); // Skip validation if disabled
    }

    if config.hosts.is_empty() {
        return Err(ConfigError::SshNoHostsConfigured);
    }

    for (name, entry) in &config.hosts {
        // Validate hostname format
        if entry.hostname.is_empty() {
            return Err(ConfigError::SshEmptyHostname(name.clone()));
        }

        // Validate username
        if entry.username.is_empty() {
            return Err(ConfigError::SshEmptyUsername(name.clone()));
        }

        // Validate port range
        if entry.port == 0 {
            return Err(ConfigError::SshInvalidPort(name.clone(), entry.port));
        }
    }

    Ok(())
}
```

#### New Error Variants

Add to `ConfigError` enum:
```rust
SshNoHostsConfigured,
SshEmptyHostname(String),  // host name
SshEmptyUsername(String),  // host name
SshInvalidPort(String, u16),  // host name, port
```

---

### 5. Unit Tests

Create tests in `src/config_tests.rs` or inline:

#### Test: `test_ssh_config_parse_enabled()`
- Parse config with `enabled = true` and hosts
- Verify hosts are loaded correctly

#### Test: `test_ssh_config_parse_disabled()`
- Parse config with `enabled = false`
- Verify hosts are ignored (empty map)

#### Test: `test_ssh_config_parse_default_port()`
- Host without explicit port
- Verify port defaults to 22

#### Test: `test_ssh_config_parse_custom_port()`
- Host with `port = 2222`
- Verify custom port is used

#### Test: `test_ssh_config_validation_empty_hosts()`
- `enabled = true` but no hosts
- Verify `ConfigError::SshNoHostsConfigured`

#### Test: `test_ssh_config_validation_empty_hostname()`
- Host with empty `hostname = ""`
- Verify `ConfigError::SshEmptyHostname`

#### Test: `test_ssh_config_validation_empty_username()`
- Host with empty `username = ""`
- Verify `ConfigError::SshEmptyUsername`

#### Test: `test_ssh_config_validation_invalid_port()`
- Host with `port = 0` or `port = 70000`
- Verify `ConfigError::SshInvalidPort`

---

### 6. Documentation Updates

#### `docs/config-schema.md` (or equivalent)

Add SSH section:
```markdown
## SSH Configuration

The `[ssh]` section configures the SSH harness for remote host access.

### `[ssh]` Options

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `enabled` | bool | `false` | Enable SSH harness |

### `[ssh.hosts.*]` Options

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `hostname` | string | — | FQDN or IP address |
| `username` | string | — | SSH username |
| `port` | integer | `22` | SSH port |

### Example

```toml
[ssh]
enabled = true

[ssh.hosts.production]
hostname = "prod.lunarwing.org"
username = "deploy"
port = 22
```
```

---

## Dependencies

| Module | Dependency Type | Notes |
|--------|-----------------|-------|
| `SSHBridge` (Task 01) | Required | For type conversion |
| `toml` / `serde` | Existing | Config parsing |
| `ConfigError` | Existing | Error handling |

---

## Acceptance Criteria

- [ ] `SshConfig` and `SshHostEntry` structs defined
- [ ] TOML parsing works for all valid inputs
- [ ] Default values applied correctly (port=22, enabled=false)
- [ ] Validation catches all error cases
- [ ] All unit tests passing
- [ ] Documentation updated
- [ ] No breaking changes to existing config

---

## Notes

- This task is **purely config parsing** — no SSH connections yet
- Keep the schema simple — can add more fields later (e.g., `identity_file`, `proxy_jump`)
- `HashMap` iteration order is non-deterministic — don't rely on ordering
- Consider adding `#[serde(rename_all = "kebab-case")]` if TOML uses `ssh-host` style

---

## Related Documents

- `../harness-architecture.md` — Full architecture overview
- `task-01-core-struct.md` — Previous task (SSHBridge types)
- `task-03-secrets-integration.md` — Next task (secrets store wiring)
- `task-04-gateway-wiring.md` — Phase 4 (AppBuilder integration)

---

*Last updated: 2026-06-XX*  
*Author: Kageho + Christopher*
