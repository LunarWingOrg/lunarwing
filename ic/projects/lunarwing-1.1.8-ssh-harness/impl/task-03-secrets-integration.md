# Implementation Task 03: Secrets Integration

**File:** `src/secrets/store.rs` (extend) + `src/bridge/ssh.rs` (new)  
**Effort:** 0.5 days  
**Priority:** High (required for Phase 3)  
**Status:** Not started  
**Depends on:** Task 01 (Core SSHBridge Struct), Task 02 (Config Storage)

---

## Objective

Integrate SSH key storage with the existing secrets system. This task defines the naming convention for SSH keys in the secrets store and ensures they're retrieved securely without disk writes.

---

## Background

The existing secrets module (`src/secrets/`) already handles:
- Encrypted storage of sensitive data
- Key-value lookups
- Tenant-scoped secrets

We're extending this to support SSH keys as a specific secret type.

---

## Deliverables

### 1. Secrets Naming Convention

Establish a consistent naming pattern for SSH keys:

```
ssh_key_<host_name>
```

Where `<host_name>` matches the key used in `config.toml`:

```toml
[ssh.hosts.production]
# Host name: "production"
# Secret key: "ssh_key_production"
```

#### Examples

| Config Host | Secret Key | Description |
|-------------|------------|-------------|
| `production` | `ssh_key_production` | Production SSH private key |
| `staging` | `ssh_key_staging` | Staging SSH private key |
| `dev` | `ssh_key_dev` | Development SSH private key |
| `192.168.1.100` | `ssh_key_192_168_1_100` | IP-based host (sanitize dots) |

---

### 2. Secret Validation

Add validation in `src/secrets/store.rs` or create a helper:

```rust
/// Validate that an SSH key secret exists for the given host
pub fn validate_ssh_key_secret(store: &SecretsStore, host: &str) -> Result<(), SecretError> {
    let secret_key = format!("ssh_key_{}", sanitize_host_name(host));
    
    if store.get(&secret_key)?.is_none() {
        return Err(SecretError::NotFound(secret_key));
    }
    
    Ok(())
}

/// Sanitize host name for use as secret key (replace invalid chars)
fn sanitize_host_name(host: &str) -> String {
    host.replace('.', "_").replace('-', "_")
}
```

---

### 3. SSHBridge Integration

Update `SSHBridge::get_credentials()` (from Task 01) to use the secrets store:

```rust
// In src/bridge/ssh.rs (or wherever SSHBridge is defined)

use crate::secrets::store::SecretsStore;

impl SSHBridge {
    pub fn get_credentials(
        &self,
        host: &str,
        secrets: &SecretsStore,
    ) -> Result<SSHCredentials, BridgeError> {
        let secret_key = format!("ssh_key_{}", sanitize_host_name(host));
        
        let key_data = secrets
            .get(&secret_key)?
            .ok_or_else(|| BridgeError::SecretNotFound(secret_key))?;
        
        // Validate key format (optional but recommended)
        Self::validate_ssh_key_format(&key_data)?;
        
        Ok(SSHCredentials { key: key_data })
    }
    
    fn validate_ssh_key_format(key: &str) -> Result<(), BridgeError> {
        // Check for valid OpenSSH/PKCS8 header
        if !key.starts_with("-----BEGIN") {
            return Err(BridgeError::InvalidKeyFormat);
        }
        
        Ok(())
    }
}

// Add new error variant
pub enum BridgeError {
    // ... existing variants
    InvalidKeyFormat,
}
```

---

### 4. Secrets Store Extension (Optional)

If the secrets store doesn't already support binary data, add support for SSH keys:

```rust
// In src/secrets/types.rs or src/secrets/store.rs

pub enum SecretValue {
    String(String),
    Binary(Vec<u8>),  // For SSH keys, certificates, etc.
}

// Or if using base64 encoding:
pub struct Secret {
    pub value: String,  // Base64-encoded for binary data
    pub encoding: SecretEncoding,
}

pub enum SecretEncoding {
    Utf8,
    Base64,
}
```

---

### 5. Unit Tests

Create tests in `src/secrets/tests.rs` or `src/bridge/ssh_tests.rs`:

#### Test: `test_ssh_key_secret_naming()`
- Input: host = "production"
- Expected secret key: "ssh_key_production"
- Verify naming convention

#### Test: `test_ssh_key_secret_sanitization()`
- Input: host = "192.168.1.100"
- Expected secret key: "ssh_key_192_168_1_100"
- Verify dots are replaced

#### Test: `test_get_credentials_found()`
- Mock secrets store with `ssh_key_production`
- Call `get_credentials("production", &secrets)`
- Verify `SSHCredentials` returned

#### Test: `test_get_credentials_not_found()`
- Mock secrets store without key
- Call `get_credentials("missing", &secrets)`
- Verify `BridgeError::SecretNotFound`

#### Test: `test_validate_ssh_key_format_valid()`
- Input: Valid OpenSSH key header
- Verify: `Ok(())`

#### Test: `test_validate_ssh_key_format_invalid()`
- Input: Random string without header
- Verify: `BridgeError::InvalidKeyFormat`

#### Test: `test_no_disk_write_for_keys()`
- Integration test: Verify keys are never written to disk
- Check temp dir, logs, and any file handles

---

### 6. Documentation Updates

#### `docs/secrets.md` (or equivalent)

Add SSH key section:

```markdown
## SSH Keys

SSH private keys are stored as secrets with the naming convention `ssh_key_<host>`.

### Example

```toml
# config.toml
[ssh.hosts.production]
hostname = "prod.example.com"
username = "deploy"
```

```bash
# Store the key
lunarwing secrets set ssh_key_production < private_key.pem
```

### Security Notes

- SSH keys are **never** written to disk in plaintext
- Keys are loaded into memory only during use
- Keys are scoped per-tenant (no cross-tenant access)
```

---

### 7. Migration / Setup Guide

#### For Existing Tenants

```bash
# 1. List current hosts
lunarwing config get ssh.hosts

# 2. For each host, store the SSH key
for host in production staging dev; do
    echo "Storing key for $host..."
    lunarwing secrets set "ssh_key_$host" < ~/.ssh/id_rsa
done

# 3. Verify
lunarwing secrets list | grep ssh_key
```

#### For New Tenants

Document in onboarding guide:
- SSH keys must be stored before first use
- Use the `ssh_key_<host>` naming convention
- Keys can be rotated by updating the secret

---

## Dependencies

| Module | Dependency Type | Notes |
|--------|-----------------|-------|
| `SecretsStore` (existing) | Required | For key retrieval |
| `SSHBridge` (Task 01) | Required | For `get_credentials()` |
| `SSHHostConfig` (Task 02) | Required | Host name source |

---

## Acceptance Criteria

- [ ] Naming convention documented and enforced
- [ ] `get_credentials()` retrieves keys from secrets store
- [ ] Key format validation implemented
- [ ] No disk writes for SSH keys (verified via tests)
- [ ] All unit tests passing
- [ ] Documentation updated
- [ ] Migration guide created

---

## Security Considerations

1. **Memory Safety:** SSH keys should be zeroed out after use
2. **Logging:** Never log SSH key contents (redact in logs)
3. **Tenant Isolation:** Keys are scoped to the tenant that stored them
4. **Key Rotation:** Support updating keys without changing host config

---

## Notes

- This task assumes the secrets store already exists and works
- If the secrets store needs extension (e.g., binary support), that's a separate pre-requisite
- Consider adding a `SecretError::InvalidEncoding` if base64 decoding fails

---

## Related Documents

- `../harness-architecture.md` — Full architecture overview
- `task-01-core-struct.md` — Previous task (SSHBridge types)
- `task-02-config-storage.md` — Previous task (config parsing)
- `task-04-gateway-wiring.md` — Next task (AppBuilder integration)

---

*Last updated: 2026-06-XX*  
*Author: Kageho + Christopher*
