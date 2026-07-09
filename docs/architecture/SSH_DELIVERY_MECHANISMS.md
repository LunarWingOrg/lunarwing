# SSH Delivery Mechanisms

**Status:** As-built (all three mechanisms shipped). Verified against source 2026-07-01.
**Core design:** [`SSH_AGENT_HARNESS.md`](SSH_AGENT_HARNESS.md) — the per-tenant bridge, agent socket, secrets, and host-key verifier that all three mechanisms share.
**Operator setup:** [`../ops/SSH-HARNESS-SETUP.md`](../ops/SSH-HARNESS-SETUP.md)

The SSH harness gives the agent one shared foundation (host config in
`config.toml`, private keys in the encrypted secrets store, an in-process
ssh-agent, and a host-key verifier — see the core design doc). On top of that
foundation there are **three ways the agent actually runs SSH work**. This doc
covers all three as-built: what each is, when to use it, its security posture,
and how to enable it.

> **Shared invariant across all three:** the `host` is always a **configured
> alias** in `[[ssh.hosts]]`. That map is the hard egress allowlist — the agent
> can never target an arbitrary host. Private keys live only in the encrypted
> secrets store and are decrypted only inside the daemon; no mechanism ever
> hands key bytes to the model or to a worker container.

---

## At a glance

| | **Worker mode** (Option 1) | **`ssh` / `ssh_git` tools** (Option 2) | **WASM `ssh` tool** (Option 3) |
|---|---|---|---|
| How the agent invokes it | `create_job(mode="nanocode"…)` with SSH commands | the `ssh` / `ssh_git` built-in tools | the `ssh` WASM tool |
| Runs where | worker **container** | **gateway process** (in-process) | gateway process (host fn) |
| Transport | worker's own `git`/`ssh` via `SSH_AUTH_SOCK` | `ssh`: in-process russh; `ssh_git`: shell-out `git` | host fn reuses the in-process russh client |
| Isolation of the SSH op | **High** (container) | Low (gateway process) | Low (russh runs host-side) |
| Latency | High (container spin-up) | Low | Low |
| Filesystem writes | worker's own FS | `ssh_git` only, confined to `<base_dir>/ssh-git/` | none (one-shot exec) |
| Host-key verification | worker's own `known_hosts` | **`HostKeyVerifier`** (live) | `HostKeyVerifier` (live, host-side) |
| Approval | per the job/tool policy | **Always** | **Always** |
| Key algorithms | anything the worker's ssh supports | **Ed25519 / ECDSA** (RSA rejected) | Ed25519 / ECDSA |
| Enable | `mt-admin` bind-mounts the socket | on when `[[ssh.hosts]]` + secrets store exist | build the guest wasm + grant the `ssh` capability |
| Best for | heavy/long jobs, strong isolation | quick remote command / git ops, no container | capability-scoped per-tool host allowlist; WASM extensibility |

**Quick decision:**
- **A whole task on a remote host** (multi-step, long-running, wants container isolation) → **worker mode**.
- **One remote command, right now, no container** → the **`ssh`** tool.
- **A git operation** (clone/fetch/pull/push) → the **`ssh_git`** tool.
- **You want a per-tool host allowlist / are exploring sandboxed tools** → the **WASM `ssh`** tool.

---

## Mechanism 1 — Worker mode (Option 1)

**What it is.** The agent creates a background job on an external worker
(nanocode/pebble) with `create_job(mode="nanocode", …)`. The worker
container has the harness's ssh-agent socket bind-mounted and `SSH_AUTH_SOCK`
set, so ordinary `git`/`ssh` inside the container authenticate through the
daemon's agent. Keys stay in the daemon; the worker only gets signing capability
via the socket.

**How it's enabled.** `ic/scripts/lunarwing-mt-admin.sh` wires this: it
pre-creates the socket path, starts the daemon (which binds the real socket),
then starts workers with `-v <run_dir>/ssh-agent.sock:/tmp/ssh-agent.sock -e
SSH_AUTH_SOCK=/tmp/ssh-agent.sock`. `<run_dir>` is
`/home/<tenant>/lunarwing/run`. Nothing for the operator to do beyond
provisioning the host + key (see the ops guide).

**Security.** Highest isolation — the SSH operation runs in a separate
container. Host-key verification is whatever the worker's own `ssh` client does
with its container-local `known_hosts` (the harness `HostKeyVerifier` is **not**
in this path). Keys never enter the container.

**When to use.** Multi-step or long-running remote work, or anything that
benefits from container isolation and the worker's toolchain. The cost is
container spin-up latency and resource use.

**Agent usage.** `create_job(title, description, mode="nanocode")` with a
description that runs the git/ssh commands. See the worker docs
(`docs/ops/WORKER-CONTAINERS.md`, `NANOCODE-MULTITENANT.md`).

---

## Mechanism 2 — Built-in Rust tools (Option 2)

Two agent-visible built-in tools that run **in the gateway process** — no
container, low latency. Both take a configured `host` alias, both are
`requires_approval = Always`, both mark their output for sanitization, and both
are the **first live consumers of the harness `HostKeyVerifier`**.

Code: `ic/src/bridge/ssh_client.rs` (russh client), `ic/src/tools/builtin/ssh.rs`
and `ic/src/tools/builtin/ssh_git.rs` (the tools).

### 2a. The `ssh` tool — run a remote command

Runs a single command on a configured host using the in-process **russh 0.45**
client (the first live use of the client half — the harness otherwise only used
`russh-keys`' agent server).

```jsonc
// parameters
{ "host": "prod-web", "command": "systemctl is-active nginx" }
// output
{ "host": "prod-web", "output": "<stdout>", "stderr": "…", "exit_code": 0, "success": true, "truncated": false }
```

- **Auth:** loads the key from the secrets store (`SSHBridge::load_key`) and
  decodes it (`russh_keys::decode_secret_key`) — **credential path (a)**.
- **Host-key verification:** wired into russh's `Handler::check_server_key`,
  delegating to `HostKeyVerifier::verify_from_config` (Strict / AcceptFirst,
  byte-exact comparison of the wire key).
- **Key algorithms:** **Ed25519 and ECDSA only.** RSA is rejected up front
  (russh 0.45 signs `ssh-rsa` with SHA-1, which modern servers reject).
- **Limits:** connect/operation timeouts from the host config; stdout/stderr
  capped at 1 MiB each (`truncated` flag).

**When to use.** A quick one-off remote command where a full worker/container is
overkill.

### 2b. The `ssh_git` tool — git over SSH

Runs `git clone/fetch/pull/push` over SSH by shelling out to the system `git`
binary, authenticating via the harness ssh-agent socket (not by re-decoding the
key). Keys never leave the agent.

```jsonc
// parameters
{ "operation": "clone", "host": "git-host", "repo": "org/project.git", "path": "project", "ref": "main", "depth": 1 }
```

- **Auth:** sets `SSH_AUTH_SOCK` to `SSHBridge::get_agent_socket_path()` — the
  in-process agent signs; git/ssh only ever see the socket.
- **Host-key verification:** materializes an ephemeral `known_hosts` from
  `HostKeyVerifier` pins (else the configured `known_host_key`) and sets
  `GIT_SSH_COMMAND` with `StrictHostKeyChecking` keyed to the host's
  `host_key_mode` (`yes` for Strict, `accept-new` for AcceptFirst). A Strict
  host with no known key is refused.
- **Hermetic SSH config:** invokes `ssh -F /dev/null`, so it ignores the host's
  `/etc/ssh/ssh_config` (and its `ssh_config.d/*` includes) and the user's
  `~/.ssh/config` — everything it needs comes from `[[ssh.hosts]]` + the agent
  socket. This makes `ssh_git` immune to host-side ssh_config breakage (e.g. a
  drop-in with bad owner/permissions, which OpenSSH treats as fatal). The `ssh`
  and WASM tools don't read `/etc/ssh` at all (russh), so this class of failure
  only ever reached `ssh_git`.
- **Filesystem sandbox:** the local `path` is confined under
  `<base_dir>/ssh-git/` via the `validate_path` helper (absolute paths, `..`
  traversal, and symlink escape are rejected).
- **Safety extras:** env-scrubbed subprocess (no gateway secrets leak to git),
  `GIT_TERMINAL_PROMPT=0`, `pull --ff-only`, **force-push (`+ref`) blocked**,
  option-injection guards, 64 KiB output cap, timeout + child kill.

**When to use.** Any git operation over SSH from a chat turn, without a worker.

> **Known limitation (both tools):** RSA is unsupported (Ed25519/ECDSA only).
> For `ssh_git`, AcceptFirst is best-effort — it re-trusts per run rather than
> persisting the pin (use Strict + a pinned `known_host_key` for anything
> sensitive; see the ops guide).

---

## Mechanism 3 — WASM `ssh` tool (Option 3)

**What it is.** A sandboxed WASM tool that runs a remote command. Because raw
SSH can't run in the wasm32 sandbox (no sockets; russh doesn't compile to
wasm32), the design is a **thin guest that calls a host function**: the guest
(`ic/tools-src/ssh/`) parses `{host, command}` and calls `ssh-exec`; the host
implementation (`ic/src/tools/wasm/wrapper.rs`) runs it by **reusing the same
`ssh_client::connect_and_exec` as the `ssh` tool**. Keys, the agent, and
host-key verification stay host-side — the guest never sees key material.

```jsonc
{ "host": "prod-web", "command": "uptime" }
```

- **Capability model:** a WASM tool must be granted the `ssh` capability with a
  per-tool **host allowlist** (`SshCapability.allowed_hosts`) — a second,
  tool-scoped narrowing on top of `[[ssh.hosts]]`.
- **Approval:** any WASM tool granted the `ssh` capability is forced to
  `requires_approval = Always` (WASM tools otherwise default to no approval).
- **Output:** stdout/stderr are leak-scanned host-side before crossing back into
  WASM.
- **WIT:** adds an `ssh-exec` import to `wit/tool.wit` at package `@0.3.0` — a
  pure import addition, so **existing WASM guests do not need rebuilding**.

**How to enable / build.** The guest wasm must be built (needs `rustup` +
`wasm32-wasip2` + `cargo-component`):

```bash
cd ic
cargo component build --release --target wasm32-wasip2 \
  --manifest-path tools-src/ssh/Cargo.toml
# -> tools-src/ssh/target/wasm32-wasip2/release/ssh_tool.wasm
# or, registry-driven for all tools: scripts/build-wasm-extensions.sh --tools
```

The registry entry is `ic/registry/tools/ssh.json`; the capability sidecar
(`tools-src/ssh/ssh-tool.capabilities.json`) declares the `ssh.allowed_hosts`
list. On mt-admin tenants the installed copy's allowlist is auto-patched to the
tenant's `[[ssh.hosts]]` hosts; the shipped `"myhost"` placeholder only needs
hand-editing for non-mt-admin installs. In dev mode the tool is auto-discovered from `tools-src/ssh/`.

**Honest caveat.** The WASM sandbox adds **near-zero isolation for the SSH
operation itself** — russh runs host-side with full privilege inside the host
function. The boundary only bounds the *guest* (CPU/memory) and narrows access
to the single `ssh-exec` waist. Also: one-shot exec only (no PTY/interactive/
streaming). This mechanism is best seen as **exploratory / capability-scoped**;
for most cases the `ssh` built-in tool (Mechanism 2a) does the same job with less
plumbing.

---

## Shared foundation & security summary

All three mechanisms sit on the same harness (see
[`SSH_AGENT_HARNESS.md`](SSH_AGENT_HARNESS.md)):

- **Host config** in `config.toml` `[[ssh.hosts]]` — the egress allowlist.
- **Private keys** in the AES-256-GCM secrets store; decrypted only inside the
  daemon; workers/guests never receive key bytes.
- **In-process ssh-agent** at `/home/<tenant>/lunarwing/run/ssh-agent.sock`.
- **`HostKeyVerifier`** — used live by the `ssh` and WASM tools; the worker path
  uses the worker's own `known_hosts`.
- **Per-tenant isolation** — `tenant_id = UUIDv5(NAMESPACE_DNS, owner_id)`;
  secrets scoped per tenant; socket in the tenant-owned run dir.

Security posture by mechanism:
- **Worker mode** — best isolation (container), but host-key checking is the
  worker's responsibility.
- **`ssh` / `ssh_git`** — run in the gateway process (lower isolation), but with
  live host-key verification, Always-approval, Ed25519/ECDSA-only, output
  sanitization, and (for `ssh_git`) a filesystem sandbox + force-push block. The
  `ssh` tool's credential path (a) briefly holds decoded key bytes in the
  gateway process.
- **WASM `ssh`** — same host-side surface as the `ssh` tool plus a per-tool host
  allowlist; the sandbox does not contain the SSH op itself.

**Recommended host-key posture for all mechanisms:** pin `known_host_key` per
host and use `host_key_mode = "Strict"`. AcceptFirst is a convenience.

---

## File reference

| Concern | File |
|---|---|
| Harness core (bridge/agent/secrets/host-key/API) | `ic/src/bridge/ssh*.rs` |
| In-process russh client (used by `ssh` + WASM tool) | `ic/src/bridge/ssh_client.rs` |
| `ssh` built-in tool | `ic/src/tools/builtin/ssh.rs` |
| `ssh_git` built-in tool | `ic/src/tools/builtin/ssh_git.rs` |
| WASM `ssh-exec` host function + capability | `ic/src/tools/wasm/wrapper.rs`, `capabilities.rs`, `host.rs` |
| WASM `ssh` guest | `ic/tools-src/ssh/` + `ic/registry/tools/ssh.json` |
| WIT (`ssh-exec` import) | `ic/wit/tool.wit` |
| Worker socket injection | `ic/scripts/lunarwing-mt-admin.sh` |
| Core design | [`SSH_AGENT_HARNESS.md`](SSH_AGENT_HARNESS.md) |
| Operator setup | [`../ops/SSH-HARNESS-SETUP.md`](../ops/SSH-HARNESS-SETUP.md) |
