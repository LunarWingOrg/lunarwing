# SSH Harness — Implementation (as built)

**Status:** Shipped in 1.1.8. Verified against source 2026-07-01.
**Canonical doc:** [`docs/architecture/SSH_AGENT_HARNESS.md`](../../../docs/architecture/SSH_AGENT_HARNESS.md)
**Operator guide:** [`docs/ops/SSH-HARNESS-SETUP.md`](../../../docs/ops/SSH-HARNESS-SETUP.md)

> This replaces the original phased plan, which described an architecture that
> was not the one shipped. What follows is what actually exists in the tree.
> Per-task detail is in [`impl/`](impl/).

## What shipped

| Area | File(s) | State |
|------|---------|-------|
| Core bridge + types | `ic/src/bridge/ssh.rs` | ✅ Done |
| In-process ssh-agent | `ic/src/bridge/ssh_agent.rs` | ✅ Done |
| Secrets integration | `ic/src/bridge/ssh_secrets.rs` | ✅ Done |
| Host-key verifier | `ic/src/bridge/ssh_hostkeys.rs` | ✅ Built + unit-tested, ⏳ not wired into a live path |
| HTTP management API | `ic/src/bridge/ssh_api.rs` | ✅ Done |
| Config parsing | `ic/src/config/ssh.rs`, `ic/src/settings.rs` | ✅ Done |
| Startup wiring | `ic/src/app.rs`, `ic/src/main.rs` | ✅ Done |
| Worker injection | `ic/scripts/lunarwing-mt-admin.sh` | ✅ Done (bind-mount + `SSH_AUTH_SOCK`) |

Dependencies: `russh` / `russh-keys` `0.45` (`ic/Cargo.toml:153`), plus the
existing `secrets` subsystem, `zeroize`, `secrecy`, `axum`.

## How it fits together

1. **Config** — `[[ssh.hosts]]` in `config.toml` → `SshConfig`
   (`config/ssh.rs`), carried on `Settings.ssh`. `to_host_map()` flattens global
   defaults + per-host overrides into `HashMap<String, SSHHostConfig>`.
2. **Construction** (`app.rs:1054`) — only when `hosts` is non-empty **and** a
   secrets store exists. Derives `tenant_id`/`tenant_name` from `owner_id`,
   builds `SSHBridge`, `validate()`s (warn-only), and `start_agent_server()`s.
   All failures are soft (`warn!`), never fatal.
3. **Agent** (`ssh_agent.rs`) — `SshAgentServer::start` binds the Unix socket at
   `/home/<tenant>/lunarwing/run/ssh-agent.sock`, chmods it `0o666`, runs the
   `russh_keys` agent server, and self-`add_identity`s each key.
4. **API** (`main.rs:525`) — mounts `ssh_api::create_router` into the webhook
   server when the bridge + secrets store are present.
5. **Injection** (`mt-admin`) — pre-creates the socket path, starts the daemon
   before workers, and bind-mounts the socket into each worker as
   `/tmp/ssh-agent.sock` with `SSH_AUTH_SOCK`.

## Public API surface

- **Rust:** `SSHBridge` (host CRUD, `start_agent_server`, `get_agent_socket_path`),
  `SshSecretsManager` (`store_key`/`load_key`/`delete_key`/`key_exists`),
  `SshAgentServer` (`socket_path`, `list_keys`), `HostKeyVerifier`
  (`verify_host_key`/`verify_from_config`). Re-exported from `lib.rs`.
- **HTTP:** `GET/POST /hosts`, `GET/DELETE /hosts/{host}`,
  `POST/DELETE /hosts/{host}/key`, `GET /hosts/{host}/key/status`,
  `GET /agent/status`, `GET /agent/keys`. See the operator guide for bodies.

## Tests

21 in-module unit tests, none in `ic/tests/`:
`ssh.rs` (4), `ssh_agent.rs` (1, empty key map only), `ssh_secrets.rs` (6),
`ssh_hostkeys.rs` (9), `ssh_api.rs` (1), `config/ssh.rs` (2).

Gaps: no real-key agent test, no HTTP-handler tests, no integration coverage of
`HostKeyVerifier` (it isn't wired into a live path).

## Known limitations / follow-ups

1. **Host-key verifier not wired.** `HostKeyVerifier` exists and passes its unit
   tests but has no production caller; runtime host-key checking is currently the
   worker's own `ssh` client.
2. **Runtime key add is status-only.** `SshAgentServer::add_key` updates the
   status map, not russh's signing keystore — a key uploaded to a running agent
   is signable only after the next daemon restart.
3. **No persistent `AuditLogger`.** Only `NullAuditLogger` is wired.
4. **`DELETE /hosts/{host}` orphans the key secret** (removes config, not key).
5. **HTTP API has no auth middleware** — protect at the network layer.
6. **Stale code comments** in `ssh.rs:316-318` and `app.rs:1076-1077` still say
   `/tmp/ssh-agent-<owner>.sock`; the real path is
   `/home/<tenant>/lunarwing/run/ssh-agent.sock`.

## Doc history

The earlier version of this file described a 9-phase plan and marked "Phase 1
complete"; the `impl/task-0*.md` files said "Not started." Both were stale — the
code shipped well past that plan. The docs in this folder and under `docs/` now
describe the as-built system.
