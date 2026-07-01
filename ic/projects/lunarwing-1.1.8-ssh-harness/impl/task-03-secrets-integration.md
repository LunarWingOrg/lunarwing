# Task 03: Secrets Integration — as built

**File:** `ic/src/bridge/ssh_secrets.rs`
**Status:** ✅ Done (shipped 1.1.8; verified 2026-07-01)

> The original spec put `get_credentials()` on `SSHBridge` and validated key
> format by checking for a `-----BEGIN` header. The shipped design instead has a
> dedicated `SshSecretsManager`, and the load path used by the agent lives in
> `SSHBridge::start_agent_server`. This file documents what exists.

## Naming convention

Secret name for a host: `ssh_key_<sanitized-host>`, where every non-alphanumeric
character becomes `_` (`secret_name_for_host`, `ssh_secrets.rs:50`).

| Host | Secret name |
|------|-------------|
| `production` | `ssh_key_production` |
| `git.example.com` | `ssh_key_git_example_com` |
| `192.168.1.100` | `ssh_key_192_168_1_100` |

A passphrase, when present, is stored under a **separate** secret
`ssh_key_<sanitized-host>_passphrase`.

> The same sanitization is implemented in three places (`ssh_secrets.rs:50`,
> inline in `ssh.rs::start_agent_server`, and the dead `ssh.rs::sanitize_secret_name`).
> Worth consolidating.

## `SshSecretsManager` (`ssh_secrets.rs:35`)

```rust
pub fn new(secrets_store: Arc<dyn SecretsStore + Send + Sync>, tenant_id: &str) -> Self  // :42

pub async fn store_key(&self, hostname: &str, key_data: &[u8], passphrase: Option<&str>) -> Result<()>  // :67
pub async fn load_key(&self, hostname: &str) -> Result<Option<SSHCredentials>>            // :121
pub async fn delete_key(&self, hostname: &str) -> Result<()>                              // :175  (key + passphrase)
pub async fn key_exists(&self, hostname: &str) -> Result<bool>                            // :202
pub fn validate_key_format(key_data: &[u8]) -> Result<SSHKeyType>                         // :221
pub async fn load_and_validate_key(&self, hostname, expected_type) -> Result<Option<SSHCredentials>>  // :259
```

- **Storage** delegates to the secrets subsystem:
  `secrets_store.create(tenant_id, CreateSecretParams::new(name, value))`. All
  encryption (AES-256-GCM, per-secret HKDF-derived key, master key from
  `SECRETS_MASTER_KEY` or the OS keychain) happens in `crate::secrets` — this
  module never touches crypto directly.
- **Load** uses `get_decrypted`, wrapping bytes in `Zeroizing`; `NotFound`
  becomes `Ok(None)`.
- **`validate_key_format`** is a heuristic on PEM/OpenSSH headers
  (`-----BEGIN OPENSSH/EC/RSA PRIVATE KEY-----`, `ssh-ed25519`, `ssh-rsa`, …).
  Real cryptographic parsing happens later in `ssh_agent::parse_key` via
  `russh_keys::decode_secret_key`.

## The load path the agent actually uses

The running agent does **not** call `SshSecretsManager::load_key`. At startup,
`SSHBridge::start_agent_server` (`ssh.rs:464`) inlines the same lookup
(`get_decrypted` for `ssh_key_<host>` and `..._passphrase`), builds
`SSHCredentials`, and hands them to `SshAgentServer::start`.
`SshSecretsManager` is used by the HTTP API layer (`ssh_api.rs`) for
`store_key`/`delete_key`/`key_exists`.

## How keys get into the store

- **Operator/API:** `POST /hosts/{host}/key` → `store_key`.
- **mt-admin:** `upload_tenant_ssh_key` POSTs the staged private key to that
  same endpoint after the daemon starts, then deletes the on-disk staged copy.

## Tests (`#[cfg(test)]`, 6)

`test_store_and_load_key`, `test_store_with_passphrase`,
`test_key_does_not_exist`, `test_delete_key`, `test_validate_key_format_ed25519`,
`test_validate_key_format_rsa`.

## Security notes / limitations

- Keys are ciphertext at rest; decrypted only into `Zeroizing`/`SecretString`
  in daemon memory; never written to disk in plaintext.
- Tenant isolation: secrets scoped by `tenant_id`.
- **`from_utf8_lossy` on key bytes** (`store_key`, and `parse_key` in
  `ssh_agent.rs`) assumes UTF-8 — fine for PEM/OpenSSH text, but binary key
  material would be corrupted.
- Planned negative tests from the original spec (`test_no_disk_write_for_keys`,
  invalid-format, ECDSA validate) are not present.

## Deltas from the original spec

- Dedicated `SshSecretsManager` instead of `SSHBridge::get_credentials`.
- Format validation returns an `SSHKeyType` (not a bool), and the authoritative
  parse is russh's, not a header check.
- Passphrases are first-class (separate secret), which the spec didn't cover.
