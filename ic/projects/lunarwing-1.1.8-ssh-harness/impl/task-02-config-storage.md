# Task 02: Config Storage — as built

**File:** `ic/src/config/ssh.rs` (+ `ic/src/settings.rs`, `ic/src/app.rs`)
**Status:** ✅ Done (shipped 1.1.8; verified 2026-07-01)

> The original spec used named tables (`[ssh.hosts.production]`, a `HashMap`)
> with `hostname`/`username` fields and an `enabled` bool. The shipped schema is
> an **array of tables** (`[[ssh.hosts]]`) with `host`/`user` fields, per-host
> timeout overrides, and **no `enabled` flag**. This file documents what exists.

## TOML schema (real)

```toml
[ssh]
# Global defaults (all optional; these are the built-in values)
connect_timeout_secs = 10
operation_timeout_secs = 30
keepalive_interval_secs = 60
keepalive_max_misses = 3

[[ssh.hosts]]
host = "prod-server.example.com"    # required
port = 22                            # default 22
user = "deploy"                     # required
key_type = "ed25519"                # required: ed25519 | ecdsa | rsa (lowercase)
host_key_mode = "Strict"            # Strict | AcceptFirst (PascalCase)
known_host_key = "ssh-ed25519 AAAA..."   # optional pin
# optional per-host overrides: connect_timeout_secs / operation_timeout_secs /
# keepalive_interval_secs / keepalive_max_misses

[[ssh.hosts]]
host = "192.168.1.100"
port = 2222
user = "admin"
key_type = "ecdsa"
host_key_mode = "AcceptFirst"
```

There is **no `enabled` key** — a non-empty `[[ssh.hosts]]` list is the enable
switch (`app.rs:1055` guards on `!config.ssh.hosts.is_empty()`).

## Types (`config/ssh.rs`)

### `SshConfig` (`:38`, derives `Default`)

```rust
pub struct SshConfig {
    #[serde(default)] pub hosts: Vec<SshHostEntry>,
    #[serde(default = "..")] pub connect_timeout_secs: u64,   // 10
    #[serde(default = "..")] pub operation_timeout_secs: u64,  // 30
    #[serde(default = "..")] pub keepalive_interval_secs: u64, // 60
    #[serde(default = "..")] pub keepalive_max_misses: u32,    // 3
}
```

### `SshHostEntry` (`:74`, does **not** derive `Default`)

Mandatory `host` / `user` / `key_type`; `port` defaults to 22; per-host timeout
fields are `Option<..>` overrides (fall back to the `SshConfig` global).

### Conversion — `to_host_map()` (`:122`) and `get_host()` (`:152`)

`to_host_map()` returns `HashMap<String, SSHHostConfig>`, resolving each entry's
`Option` overrides against the global defaults. `get_host(name)` does the same
for a single host.

## Wiring

- **Settings** (`settings.rs:196`): `pub ssh: crate::config::SshConfig`, with
  `#[serde(default)]`. Loaded from `config.toml` / `settings.json`.
- **App build** (`app.rs:1054-1105`): if `hosts` non-empty **and** a secrets
  store exists, `config.ssh.to_host_map()` feeds `SSHBridge::new`; the bridge is
  then validated and its agent started (all fail-soft). Result stored on
  `AppComponents.ssh_bridge`.

## mt-admin

`ic/scripts/lunarwing-mt-admin.sh` writes the `[[ssh.hosts]]` block into the
tenant's `config.toml` (append-only, idempotent) via `ensure_ssh_config` /
`configure-ssh`, defaulting to a self-referential host `127.0.0.1` / user
`<tenant>`.

## Tests (`#[cfg(test)]`, 2)

`test_parse_ssh_config`, `test_to_host_map`.

> ⚠️ Both tests parse a **bare** `SshConfig`, so their TOML uses top-level
> `[[hosts]]` (no `ssh.` prefix). That is **not** the real `config.toml` shape —
> real config nests under `[[ssh.hosts]]`. Don't copy the test TOML.

## Deltas from the original spec

- `[[ssh.hosts]]` array of tables, not `[ssh.hosts.<name>]` named tables.
- Fields `host`/`user`, not `hostname`/`username`.
- No `enabled` flag; enablement = non-empty list.
- Extra fields shipped: `key_type`, `host_key_mode`, `known_host_key`, timeouts,
  keepalive.
- The planned `ConfigError` variants (`SshNoHostsConfigured`, `SshEmptyHostname`,
  …) were **not** added; validation lives in `SSHBridge::validate` and is
  warn-only.
