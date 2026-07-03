# SSH Tool Testing Guide

Test prompts for validating the three SSH delivery mechanisms in LunarWing v1.1.8.
See `docs/architecture/SSH_DELIVERY_MECHANISMS.md` for the full design.

## Prerequisites

- Tenant deployed with SSH harness enabled (`--no-ssh` NOT passed to `add-tenant`)
- `start-tenant` completed — SSH key uploaded, agent socket active
- `[[ssh.hosts]]` configured in the tenant's `config.toml` pointing at `127.0.0.1`
- Verify readiness: `curl -s http://127.0.0.1:<http_port>/agent/status | jq` — should show `"keys_loaded": 1`

## Test 1: Built-in `ssh` Tool (Option 2, Phase 1)

In-process Rust tool. Connects through the per-tenant ssh-agent socket, runs a remote command, returns output.

**Prompt:**
```
Use the ssh tool to connect to 127.0.0.1 as user <tenant> and run "hostname && whoami && date". Show me the full output.
```

**Expected result:**
- Hostname of the host machine
- Tenant username
- Current timestamp
- Exit code 0, no stderr

**Verify on the host:**
```bash
sudo grep -i 'sshd.*session' /var/log/auth.log | tail -5
```

Look for a session opened and closed for the tenant user at the matching timestamp.

## Test 3: WASM `ssh` Tool (Option 3)

Sandboxed SSH via host-function bridge. The private key never enters WASM linear memory — the host signs challenges on behalf of the guest.

> **Note:** The WASM ssh tool may need to be activated in the web panel first: Settings → Extensions → enable `ssh`.

**Prompt:**
```
Use the WASM ssh tool to connect to 127.0.0.1 as user <tenant> and run "uname -a && id". Show me the output.
```

**Expected result:**
- Kernel version, architecture, hostname
- User ID, group ID, and groups for the tenant user
- Exit code 0, no stderr

**Verify on the host:**
```bash
sudo grep -i 'sshd.*session' /var/log/auth.log | tail -5
```

## Notes

- Test 2 (`ssh_git` tool) is not included in this guide due to known issues with the host alias resolution interface. See `docs/bugs/` for details.
- All three tools authenticate through the same ssh-agent socket — they differ only in execution context (in-process vs sandboxed vs git subprocess).
- The SSH harness is enabled by default for new tenants. Disable with `--no-ssh` on `add-tenant`.
