# Implementation Task 01: Core SSHBridge Struct

**File:** `src/bridge/ssh.rs`  
**Effort:** 1-2 days  
**Priority:** Critical (foundation for all other phases)  
**Status:** Not started

---

## Objective

Create the `SSHBridge` struct and associated types that form the foundation of the SSH harness. This is the core data structure that will hold host configurations and provide methods for retrieving configs and credentials.

---

## Deliverables

### 1. Type Definitions

Create the following types in `src/bridge/ssh.rs`:

#### `SSHBridge` (main struct)
```rust
pub struct SSHBridge {
    hosts: HashMap<String, SSHHostConfig>,
}
```

#### `SSHHostConfig` (host configuration)
```rust
pub struct SSHHostConfig {
    pub hostname: String,
    pub username: String,
    pub port: u16,
}
```

#### `SSHCredentials` (sensitive key data)
```rust
pub struct SSHCredentials {
    pub key: String, // Or Vec<u8> for binary key data
}
```

#### `BridgeError` (error handling)
```rust
pub enum BridgeError {
    HostNotFound(String),
    SecretNotFound(String),
    ValidationFailed(String),
    ConfigParseError(String),
}

impl std::fmt::Display for BridgeError { ... }
impl std::error::Error for BridgeError { ... }
```

---

### 2. Public API Methods

Implement the following methods on `SSHBridge`:

#### `new()`
```rust
pub fn new(hosts: HashMap<String, SSHHostConfig>) -> Self
```
- **Input:** HashMap of host name → config
- **Output:** New `SSHBridge` instance
- **Notes:** No validation here — that's done in `validate()`

#### `get_config()`
```rust
pub fn get_config(&self, host: &str) -> Result<SSHHostConfig, BridgeError>
```
- **Input:** Host name (e.g., "production", "staging")
- **Output:** `SSHHostConfig` or `BridgeError::HostNotFound`
- **Notes:** Clones the config — no references to internal state

#### `get_credentials()`
```rust
pub fn get_credentials(
    &self,
    host: &str,
    secrets: &SecretsStore
) -> Result<SSHCredentials, BridgeError>
```
- **Input:** Host name + reference to secrets store
- **Output:** `SSHCredentials` or error
- **Notes:** 
  - Key naming convention: `ssh_key_<host>`
  - Does NOT write key to disk — returns in-memory only

#### `validate()`
```rust
pub fn validate(&self) -> Result<(), BridgeError>
```
- **Input:** None (uses `&self`)
- **Output:** `Ok(())` or `BridgeError::ValidationFailed`
- **Checks:**
  - At least one host configured
  - All hostnames are valid format (FQDN or IP)
  - All usernames are non-empty
  - All ports are in valid range (1-65535)
  - Optional: connectivity test (ping/SSH handshake)

#### `list_hosts()`
```rust
pub fn list_hosts(&self) -> Vec<&str>
```
- **Input:** None
- **Output:** List of configured host names
- **Notes:** Useful for debugging, admin commands

---

### 3. Module Exports

Update `src/bridge/mod.rs`:
```rust
pub mod ssh;
pub use ssh::{SSHBridge, SSHHostConfig, SSHCredentials, BridgeError};
```

---

### 4. Unit Tests

Create tests in `src/bridge/ssh.rs` (or `src/bridge/ssh_tests.rs`):

#### Test: `test_new_bridge()`
- Empty hosts map → valid bridge
- Single host → valid bridge
- Multiple hosts → valid bridge

#### Test: `test_get_config_found()`
- Request existing host → returns config

#### Test: `test_get_config_not_found()`
- Request non-existent host → `BridgeError::HostNotFound`

#### Test: `test_get_credentials_found()`
- Mock secrets store with key → returns credentials

#### Test: `test_get_credentials_missing()`
- Mock secrets store without key → `BridgeError::SecretNotFound`

#### Test: `test_validate_empty()`
- Empty hosts → `ValidationFailed`

#### Test: `test_validate_valid()`
- Valid hosts → `Ok(())`

#### Test: `test_validate_bad_hostname()`
- Invalid hostname format → `ValidationFailed`

#### Test: `test_validate_bad_port()`
- Port 0 or >65535 → `ValidationFailed`

---

## Dependencies

| Module | Dependency Type | Notes |
|--------|-----------------|-------|
| `SecretsStore` | Required | For `get_credentials()` |
| `BridgeError` | Internal | Defined in this task |
| `HashMap` | std | Rust standard library |

---

## Acceptance Criteria

- [ ] All types defined and compile
- [ ] All methods implemented
- [ ] All unit tests passing
- [ ] Module exports wired
- [ ] No disk writes for keys (in-memory only)
- [ ] Error messages are actionable

---

## Notes

- This is the **foundation** — all other phases depend on this
- Don't skip tests — the error handling here matters
- Keep the API surface minimal — only what's needed for Phase 2+
- `Vec<u8>` vs `String` for key data: decide based on how secrets are stored

---

## Related Documents

- `../harness-architecture.md` — Full architecture overview
- `task-02-config-storage.md` — Next task (config parsing)
- `task-03-secrets-integration.md` — Secrets store wiring

---

*Last updated: 2026-06-XX*  
*Author: Kageho + Christopher*
