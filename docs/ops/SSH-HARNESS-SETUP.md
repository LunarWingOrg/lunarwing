# SSH Harness — Setup & Operations

How to give LunarWing workers (nanocode/pebble/codex), routines, and git
operations SSH access to remote hosts, using the SSH agent harness.

For the design and internals, see
[`docs/architecture/SSH_AGENT_HARNESS.md`](../architecture/SSH_AGENT_HARNESS.md).

## What you get

- SSH **host config** in `config.toml` (non-sensitive, reviewable).
- SSH **private keys** in the encrypted secrets store (AES-256-GCM, never on
  disk in plaintext).
- An in-process **ssh-agent** on a per-tenant Unix socket
  (`/home/<tenant>/lunarwing/run/ssh-agent.sock`), bind-mounted into worker
  containers as `SSH_AUTH_SOCK`. Workers run plain `git`/`ssh`; signing happens
  inside the daemon and keys never enter the container.

## Prerequisites

- The SSH bridge only initializes when **both** are true:
  1. `config.toml` has at least one `[[ssh.hosts]]` entry, **and**
  2. the daemon has a secrets store (i.e. a master key is available via
     `SECRETS_MASTER_KEY` or the OS keychain).
- If either is missing, the bridge and its HTTP API are silently skipped — this
  is by design (SSH is optional and fail-soft).

---

## Path A — Multi-tenant, via `mt-admin` (recommended)

For production multi-tenant deployments, `ic/scripts/lunarwing-mt-admin.sh`
automates the whole flow. It is idempotent.

### New tenant (SSH provisioned automatically)

`add-tenant` writes the `[[ssh.hosts]]` block, generates an ed25519 key pair,
adds the public key to the tenant's `authorized_keys`, and uploads the private
key to the secrets store after the daemon starts:

```bash
sudo ic/scripts/lunarwing-mt-admin.sh add-tenant <name>
```

By default this provisions a self-referential host `127.0.0.1` with user
`<name>` — enough for the tenant's workers to SSH back into the tenant account
(the common "worker runs git over SSH" case).

### Existing tenant — add / change the SSH host

```bash
sudo ic/scripts/lunarwing-mt-admin.sh configure-ssh <name> \
  [--host <host-or-ip>] [--user <ssh-user>]
```

`configure-ssh` runs two steps (`mt-admin`: `ensure_ssh_config` +
`provision_tenant_ssh_key`):

1. **`ensure_ssh_config`** appends a `[[ssh.hosts]]` block to the tenant's
   `config.toml` (idempotent, append-only — never overwrites existing config).
2. **`provision_tenant_ssh_key`** generates
   `/home/<name>/.ssh/id_ed25519_lunarwing`, adds the public key to
   `authorized_keys`, and stages the private key at
   `<env_dir>/ssh_key_staged` (mode 0600).

The staged private key is uploaded to the secrets store and then deleted on the
next `up`/start of the tenant (`mt-admin`: `upload_tenant_ssh_key`, which POSTs
to the SSH API and removes the staged file on success).

### How the socket reaches the worker

`mt-admin` handles this for you, in this order (order matters):

1. Pre-creates the socket path as a touch-file so podman bind-mounts a **file**,
   not a directory.
2. Starts the **daemon first** — it removes the touch-file and binds the real
   Unix socket.
3. Starts **workers after**, each with:
   ```
   -v /home/<tenant>/lunarwing/run/ssh-agent.sock:/tmp/ssh-agent.sock \
   -e SSH_AUTH_SOCK=/tmp/ssh-agent.sock
   ```

---

## Path B — Single instance, manual

### 1. Declare the host in `config.toml`

Under `LUNARWING_BASE_DIR/config.toml`:

```toml
[ssh]
# Global defaults (optional — these are the built-in defaults)
connect_timeout_secs = 10
operation_timeout_secs = 30
keepalive_interval_secs = 60
keepalive_max_misses = 3

[[ssh.hosts]]
host = "git.example.com"
port = 22
user = "git"
key_type = "ed25519"            # ed25519 | ecdsa | rsa  (lowercase)
host_key_mode = "Strict"        # Strict | AcceptFirst   (PascalCase)
known_host_key = "ssh-ed25519 AAAA..."   # optional: pin the server's host key
# Optional per-host timeout overrides:
# connect_timeout_secs = 15

[[ssh.hosts]]
host = "192.168.1.100"
port = 2222
user = "admin"
key_type = "ecdsa"
host_key_mode = "AcceptFirst"
```

Notes:
- `host`, `user`, and `key_type` are **required** for every host entry.
- There is **no `enabled` flag** — having a non-empty `[[ssh.hosts]]` list *is*
  the enable switch.
- `key_type` casing is lowercase; `host_key_mode` casing is PascalCase.
- ⚠️ Do **not** copy the TOML from the unit tests in `ic/src/config/ssh.rs` —
  those parse a bare `SshConfig` and use top-level `[[hosts]]` (no `ssh.`
  prefix). Real config uses `[[ssh.hosts]]` as shown above.

### Host-key verification: pin your servers (recommended)

When you connect, the remote server presents an identity ("host key") that
proves it's really that server and not an impostor. Two modes control how that's
checked:

- **`host_key_mode = "Strict"` + `known_host_key = "..."` (recommended).** You
  record the server's identity in the config up front, and every connection is
  checked against it. No first-time guessing. Use this for anything important.
- **`host_key_mode = "AcceptFirst"` (convenience).** Trusts whatever identity
  the server shows on the first connection. Note: for the **`ssh_git` tool** this
  is **best-effort** — it re-trusts on each run rather than remembering, so it
  will **not** catch a changed server key between runs. Prefer Strict for
  repeated or sensitive use.

To get a server's `known_host_key`, run this from a machine you trust and copy
the `ssh-ed25519 AAAA...` part into the config:

```bash
ssh-keyscan git.example.com
# git.example.com ssh-ed25519 AAAA...   <- copy the "ssh-ed25519 AAAA..." part
```

### 2. Start the daemon and store the key

With the host declared and a master key present, the daemon exposes the SSH API
on its HTTP port (merged into the webhook server, no `/ssh` prefix). Store the
private key — the secret name is derived from the host
(`ssh_key_<sanitized-host>`, non-alphanumerics → `_`):

```bash
# The API accepts raw PEM/OpenSSH key text as a JSON string (no base64).
jq -n --arg key "$(cat ~/.ssh/id_ed25519)" '{key_data: $key}' \
  | curl -sf -X POST "http://127.0.0.1:<http-port>/hosts/git.example.com/key" \
      -H 'Content-Type: application/json' -d @-

# Encrypted, passphrase-protected key:
jq -n --arg key "$(cat ~/.ssh/id_ed25519)" --arg pass 'secret' \
  '{key_data: $key, passphrase: $pass}' \
  | curl -sf -X POST "http://127.0.0.1:<http-port>/hosts/git.example.com/key" \
      -H 'Content-Type: application/json' -d @-
```

### 3. ⚠️ Restart the daemon after uploading a key

> **mt-admin handles this automatically.** `start-tenant` uploads the staged
> key and bounces the daemon in one pass, so multi-tenant deployments need no
> manual restart. The rest of this section applies to manual/API uploads on a
> running daemon.

**Keys become usable for signing only when the agent starts.** Uploading a key
to an already-running agent stores it (encrypted) and makes it show up in
`/agent/status`, but it is **not** usable for signing until the **next daemon
restart**, when the agent reloads keys from the secrets store into its live
keystore.

So the reliable sequence for a brand-new key is: **upload → restart daemon**.
(The `mt-admin` flow uploads after startup and immediately bounces the daemon itself — see the note above.)

---

## Verifying it works

### From the host: check the API

```bash
# Agent status: running, socket path, and how many keys are loaded.
curl -s http://127.0.0.1:<http-port>/agent/status | jq
# => {"success":true,"data":{"running":true,
#      "socket_path":"/home/<tenant>/lunarwing/run/ssh-agent.sock",
#      "keys_loaded":1}}

# List configured hosts (has_key reflects the secrets store):
curl -s http://127.0.0.1:<http-port>/hosts | jq

# Key present for a host?
curl -s http://127.0.0.1:<http-port>/hosts/git.example.com/key/status | jq
```

Confirm the socket exists and is a socket:

```bash
ls -l /home/<tenant>/lunarwing/run/ssh-agent.sock   # should show a 's' (socket) type
```

### Inside a worker (e.g. nanocode)

The socket is mounted at `/tmp/ssh-agent.sock` with `SSH_AUTH_SOCK` pointing at
it. Standard SSH tooling picks it up automatically:

```bash
echo "$SSH_AUTH_SOCK"          # => /tmp/ssh-agent.sock
ssh-add -l                     # lists the loaded identity/identities
ssh -T git@git.example.com     # authenticates via the daemon's agent
git clone git@git.example.com:org/repo.git
```

If `ssh-add -l` says "The agent has no identities" but the host key is present
in the store, the daemon almost certainly needs a restart (see step 3).

---

## Agent-facing SSH tools

Beyond worker mode, the agent has built-in tools that run SSH **in the gateway
process** (no container). All take a configured `host` alias and require
approval on every call. Full details + when-to-use each:
[`../architecture/SSH_DELIVERY_MECHANISMS.md`](../architecture/SSH_DELIVERY_MECHANISMS.md).

- **`ssh`** — run one command on a configured host: `{host, command}` →
  `{output, stderr, exit_code, success}`. Ed25519/ECDSA keys only.
- **`ssh_git`** — git `clone`/`fetch`/`pull`/`push` over SSH:
  `{operation, host, repo, path, ref?, depth?}`. Local paths are confined under
  `<base_dir>/ssh-git/`; `pull` is fast-forward-only; force-push is blocked.
- **`ssh` (WASM)** — the same one-command exec, but a sandboxed WASM tool with a
  per-tool host allowlist. Needs its guest wasm built (below).

The two built-in tools are available automatically once `[[ssh.hosts]]` is
configured and a secrets store exists (same prerequisites as the harness).

### Building / enabling the WASM `ssh` tool

The WASM tool needs its guest component built (requires `rustup` +
`wasm32-wasip2` + `cargo-component`):

```bash
cd ic
rustup target add wasm32-wasip2
cargo install cargo-component --locked        # once
cargo component build --release --target wasm32-wasip2 \
  --manifest-path tools-src/ssh/Cargo.toml
# -> tools-src/ssh/target/wasm32-wasip2/release/ssh_tool.wasm
```

On mt-admin tenants the installed sidecar's `capabilities.ssh.allowed_hosts`
is patched automatically from the tenant's `[[ssh.hosts]]` (by `install-wasm`
/ `build-tenant --with-wasm` / `configure-ssh`). For manual installs, edit
`tools-src/ssh/ssh-tool.capabilities.json` before installing.
In dev mode the tool is auto-discovered from `tools-src/ssh/`; the registry entry is `registry/tools/ssh.json`.

## Full HTTP API reference

Base URL is the daemon's HTTP port (no prefix). All responses are
`{"success": bool, "data": ..., "error": ...}`.

| Method + path | Purpose |
|---|---|
| `GET /hosts` | list configured hosts (with `has_key`) |
| `POST /hosts` | add a host (body: `HostRequest`) |
| `GET /hosts/{host}` | get one host |
| `DELETE /hosts/{host}` | remove host **config** (does **not** delete the key secret) |
| `POST /hosts/{host}/key` | upload/replace the key (body: `{key_data, passphrase?}`) |
| `DELETE /hosts/{host}/key` | delete the key (and its passphrase) |
| `GET /hosts/{host}/key/status` | `{host, exists}` |
| `GET /agent/status` | `{running, socket_path, keys_loaded}` |
| `GET /agent/keys` | list of hostnames the agent reports |

`POST /hosts` body (`HostRequest`):

```json
{
  "host": "git.example.com",
  "port": 22,
  "user": "git",
  "key_type": "ed25519",
  "host_key_mode": "Strict",
  "known_host_key": "ssh-ed25519 AAAA..."
}
```

> Hosts added via `POST /hosts` get **hardcoded** timeouts (10/30/60/3). To
> control timeouts, declare the host in `config.toml` instead.

---

## Key rotation

1. `POST /hosts/{host}/key` with the new key (overwrites the stored secret).
2. **Restart the daemon** so the new key is loaded into the live agent.

(Online rotation without a restart is a known limitation — the runtime add path
only updates status reporting, not the signing keystore. See the architecture
doc §7.)

---

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| No SSH API on the HTTP port | `config.toml` has no `[[ssh.hosts]]`, or no master key/secrets store. Both are required. |
| `agent/status` → `running:false` | Agent failed to start; check the daemon log for `SSH agent server failed to start` (fail-soft warn). |
| `keys_loaded: 0` but key was uploaded | Upload happened while the agent was running; **restart the daemon** (mt-admin's start-tenant does this automatically after upload). |
| Worker: "agent has no identities" | Same as above — restart the daemon after uploading. |
| Worker: `SSH_AUTH_SOCK` unset / socket missing | Worker container was created before the socket existed, or the bind-mount is a stale touch-file. Recreate the worker container **after** the daemon is up (mt-admin orders this for you; a plain `restart` may reuse a stale container). |
| Socket exists but worker can't use it | Permissions: the socket is `0o666`, but the run dir must be tenant-owned and readable by the worker's UID. |
| `git`/`ssh` prompts about host authenticity (worker mode) | In **worker mode** host-key verification is the worker's own `ssh` client — manage its `known_hosts`, or pin `known_host_key` per host. (The in-process `ssh`/`ssh_git` tools instead use the harness's `HostKeyVerifier`; a Strict host with no known key is *refused*, not prompted.) |

### Where things live

| Item | Path |
|---|---|
| Agent socket | `/home/<tenant>/lunarwing/run/ssh-agent.sock` |
| Socket inside worker | `/tmp/ssh-agent.sock` (`SSH_AUTH_SOCK`) |
| Host config | `LUNARWING_BASE_DIR/config.toml` → `[[ssh.hosts]]` |
| Private key (at rest) | encrypted secrets store, secret name `ssh_key_<sanitized-host>` |
| Passphrase (at rest) | secret name `ssh_key_<sanitized-host>_passphrase` |
| Generated key (mt-admin) | `/home/<tenant>/.ssh/id_ed25519_lunarwing` |

---

## Security notes

- Private keys are stored only as AES-256-GCM ciphertext; they are decrypted
  into memory inside the daemon and zeroized on drop. Workers get **signing
  capability only**, never the key bytes.
- The SSH management API has **no built-in authentication** — protect it at the
  network layer. In the `mt-admin` model it is reached only over
  `127.0.0.1:<tenant-http-port>`; do not expose the daemon's HTTP port publicly
  without an auth proxy.
- Never paste key material into logs, issues, or chat. `POST /hosts/{host}/key`
  takes the key in the request body; run it locally against `127.0.0.1`.
