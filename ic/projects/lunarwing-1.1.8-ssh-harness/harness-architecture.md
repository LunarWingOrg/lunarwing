# SSH Harness — Architecture (as built)

**Status:** Shipped in 1.1.8. Verified against source 2026-07-01.
**Canonical doc:** [`docs/architecture/SSH_AGENT_HARNESS.md`](../../../docs/architecture/SSH_AGENT_HARNESS.md)
**Operator guide:** [`docs/ops/SSH-HARNESS-SETUP.md`](../../../docs/ops/SSH-HARNESS-SETUP.md)

> This file records the architecture **as it was actually built**, which differs
> from the original design sketch. The most important change: credentials are
> **not** handed to workers via a `get_credentials()` call. Instead the daemon
> runs an in-process ssh-agent on a Unix socket and workers authenticate through
> `SSH_AUTH_SOCK`. Keys never leave the daemon.

## Problem it solves

- SSH keys were scattered, sometimes on disk.
- No central config for hosts.
- Credentials were passed to workers/routines manually.
- No per-tenant isolation.

## Goal (achieved unless noted)

- ✅ Centralized SSH host config (`config.toml`).
- ✅ Keys stored encrypted in the secrets store; never on disk in plaintext.
- ✅ Auto-injection into workers via a mounted agent socket.
- ✅ Per-tenant isolation (tenant-scoped secrets + tenant-owned socket).
- ✅ Git-over-SSH from workers.
- ⏳ Host-key pinning enforcement — verifier built but not yet wired (see below).

## As-built architecture

```text
┌──────────────────────── LunarWing daemon (per tenant) ─────────────────────────┐
│  config.toml [[ssh.hosts]]  ──►  SSHBridge (host map)                            │
│  Secrets store (AES-256-GCM) ─►  decrypt keys into memory (Zeroizing)           │
│                                    │                                            │
│                                    ▼                                            │
│                          SshAgentServer (russh_keys agent)                      │
│                          Unix socket: /home/<tenant>/lunarwing/run/ssh-agent.sock│
│  HTTP mgmt API (/hosts,/agent) ────┘  (mounted into the webhook server)         │
└──────────────────────────────────────┬──────────────────────────────────────────┘
                                        │ podman bind-mount + SSH_AUTH_SOCK
                                        ▼
                        worker container: git/ssh → SSH_AUTH_SOCK → sign
```

## Modules (`ic/src/bridge/`)

| File | Role |
|------|------|
| `ssh.rs` | `SSHBridge` core + all types (`SSHHostConfig`, `SSHKeyType`, `HostKeyMode`, `SSHCredentials`, `SshBridgeError`, `SshEvent`, `AuditLogger`); host CRUD; `start_agent_server()`. |
| `ssh_agent.rs` | `SshAgentServer` — in-process ssh-agent over `russh_keys::agent::server::serve` on a Unix socket. |
| `ssh_secrets.rs` | `SshSecretsManager` — store/load/delete keys + passphrases in the encrypted secrets store. |
| `ssh_hostkeys.rs` | `HostKeyVerifier` — Strict / AcceptFirst host-key verification (built + unit-tested, not yet wired live). |
| `ssh_api.rs` | axum HTTP CRUD for hosts, keys, and agent status. |
| `config/ssh.rs` | `SshConfig` / `SshHostEntry` TOML parsing + `to_host_map()`. |

Wiring: constructed in `app.rs` (`AppComponents.ssh_bridge`), API mounted in
`main.rs`, socket injected into workers by `ic/scripts/lunarwing-mt-admin.sh`.

## Data flow

1. **Config load:** `config.toml [[ssh.hosts]]` → `SshConfig` → (in `AppBuilder`,
   only if hosts non-empty **and** a secrets store exists) → `SSHBridge::new`.
2. **Agent start:** `start_agent_server()` decrypts `ssh_key_<host>` from the
   store into memory and hands the keys to `SshAgentServer::start`, which binds
   the Unix socket and `add_identity`s each key into russh's keystore.
3. **Injection:** `mt-admin` bind-mounts the socket into worker containers as
   `/tmp/ssh-agent.sock` + `SSH_AUTH_SOCK`.
4. **Remote ops:** the worker's `git`/`ssh` sign via the daemon's agent — keys
   stay in the daemon's memory.

## Security model

| Component | Storage | Encryption |
|-----------|---------|-----------|
| Host config | `config.toml` | none (non-sensitive) |
| SSH keys | secrets store | AES-256-GCM at rest |
| Runtime keys | daemon memory (`Zeroizing`) | not persisted; zeroized on drop |
| Agent socket | tenant run dir, mode `0o666` | isolated by tenant-owned dir + rootless-podman UID mapping |

Per-tenant isolation: `tenant_id = UUIDv5(NAMESPACE_DNS, owner_id)`; secrets
scoped by tenant; socket in the tenant's own run dir.

## Deltas from the original sketch

- **No `SSHBridge::get_credentials(host, secrets)` API.** Replaced by the
  agent-socket model — workers get an `SSH_AUTH_SOCK`, not key bytes.
- **Config is `[[ssh.hosts]]` (array of tables), not `[ssh.hosts.<name>]`
  (named tables).** Field names are `host`/`user` (not `hostname`/`username`).
  There is no `enabled` flag.
- **Socket lives in the tenant run dir, not `/tmp`** (PrivateTmp-safe).
- **`SSHBridge` is far richer** than the sketched struct (audit events, host-key
  modes, connection/keepalive config, error taxonomy).

## Known gaps

- `HostKeyVerifier` is not wired into a live connection path yet — runtime
  host-key checking is whatever the worker's `ssh` client does.
- Runtime key upload to a running agent is status-only; a key becomes signable
  on the next daemon restart.
- Only `NullAuditLogger` is wired — audit events are defined but not persisted.

See the canonical architecture doc for full detail, file:line references, and
the security sharp-edges list.
