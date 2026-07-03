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

## Test 2: `ssh_git` Tool (Option 2, Phase 2)

Git-over-SSH through the harness agent. Clones, pushes, and pulls from a remote git repo authenticated by the ssh-agent socket. The private key never touches disk — the `GIT_SSH_COMMAND` uses `SSH_AUTH_SOCK` pointing at the harness agent.

**Setup — create a test bare repo on the host:**

```bash
sudo -u <tenant> bash -c '
  cd /home/<tenant>/lunarwing
  git init --bare test-repo.git
  git --git-dir=test-repo.git symbolic-ref HEAD refs/heads/main
  cd /tmp && rm -rf test-seed && git clone /home/<tenant>/lunarwing/test-repo.git test-seed
  cd test-seed
  echo "# Test repo for SSH git tool" > README.md
  git add . && git commit -m "initial"
  git branch -M main
  git push origin main
'
```

> **Important:** The `repo` parameter is relative to the SSH user's home directory (scp-form URL: `user@host:repo`). For a repo at `/home/<tenant>/lunarwing/test-repo.git`, use `repo: lunarwing/test-repo.git`. The tool strips leading `/` — do not pass an absolute path.

> **Important:** The `path` parameter is relative to the ssh-git sandbox (`<base_dir>/ssh-git/`), NOT `/workspace/` or an absolute path. The tool rejects absolute paths and `..` traversal.

**Prompt:**
```
Use the ssh_git tool with these exact parameters:
- operation: clone
- host: 127.0.0.1
- repo: lunarwing/test-repo.git
- path: test-repo-clone
- ref: main

After the clone succeeds, create a file called ssh-git-test.txt with the content "ssh_git tool works" inside the cloned repo at the ssh-git sandbox path test-repo-clone. Then commit it and use the ssh_git tool again with:
- operation: push
- host: 127.0.0.1
- path: test-repo-clone
- ref: main
```

> **Note:** `ssh_git` only handles clone/fetch/pull/push. To create files and commit inside the cloned repo, the agent uses the built-in `ssh` tool to run `git add`, `git commit`, etc. inside the sandbox clone path. This is expected behavior.

**Expected result:**
- Clone succeeds (exit_code 0)
- File created and committed in the sandbox clone
- Push succeeds (exit_code 0)

**Verify on the host:**
```bash
sudo -u <tenant> bash -c 'cd /home/<tenant>/lunarwing/test-repo.git && git log --oneline'
sudo -u <tenant> bash -c 'cd /home/<tenant>/lunarwing/test-repo.git && git show HEAD:ssh-git-test.txt'
```

## Notes

- All three tools authenticate through the same ssh-agent socket — they differ only in execution context (in-process vs sandboxed vs git subprocess).
- The SSH harness is enabled by default for new tenants. Disable with `--no-ssh` on `add-tenant`.
- `ssh_git` repo paths use scp-form (relative to SSH home). `path` is sandbox-relative. Always pass `ref` explicitly to avoid the `null` serialization issue (see `docs/bugs/BUG-ssh-git-null-ref-serialization.md`).
- Seed bare repos with `git symbolic-ref HEAD refs/heads/main` so HEAD points at `main` from the start.
