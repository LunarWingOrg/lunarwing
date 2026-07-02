# mt-admin SSH Setup Streamlining Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `add-tenant → build-tenant --with-wasm → start-tenant` yields a tenant whose SSH harness fully works (keys signable, WASM allowlist correct) with zero further commands.

**Architecture:** Five in-place changes to the single bash orchestrator `ic/scripts/lunarwing-mt-admin.sh` (~6140 lines): reorder `start_tenant` with a conditional daemon-only bounce, derive the WASM ssh allowlist from `[[ssh.hosts]]`, extract the existing toolchain installer into a reusable preflight, add warn-only sshd probes, and end `start-tenant` with a live ready-state summary. Spec: `docs/superpowers/specs/2026-07-01-mt-admin-ssh-streamlining-design.md`.

**Tech Stack:** bash (`set -euo pipefail`), jq, curl, awk; systemd (`systemctl --user` via `_systemctl_user`) and OpenRC (`rc-service`) — every service-touching change must handle both.

## Global Constraints

- **Warn-and-continue:** every NEW step warns loudly and continues; no new `die` paths. Warnings go to stderr: `say "WARNING: ..." >&2`.
- **Both init systems:** any service operation needs a systemd branch (`_systemctl_user "$name" ...`) and an OpenRC branch (`rc-service lunarwing-${name} ...`), selected via `ensure_init_system` + `$INIT_SYSTEM`.
- **Never print secret values** (key material, tokens) in any new output.
- **No `sed -i`** — write to a temp file and `mv` (repo cross-platform rule).
- **Output via `say()`** (`printf '%s\n' "$*"`); helpers follow the existing `lower_snake` / `_lower_snake` naming.
- **Verification per task:** `bash -n ic/scripts/lunarwing-mt-admin.sh` must pass; new-function micro-tests run where the function is pure enough to extract. mt-admin has no test harness — Task 7 is the live verification record.
- All work happens on branch `sshagentoption3-1`; commit after each task from the repo root `/var/lib/paseo/.paseo/worktrees/claudecode/lunarwing`.
- Line numbers below are as of commit `a5881c87`; re-locate with the given `grep` anchors if they drift.

---

### Task 1: `ensure_tenant_wasm_toolchain` helper + build-tenant preflight

**Files:**
- Modify: `ic/scripts/lunarwing-mt-admin.sh` — `create_tenant_user()` (toolchain block at `:1353-1376`; anchor: `grep -n 'Install rustup for tenant user'`) and `build_tenant()` (`:1480`; anchor: `grep -n '^build_tenant()'`).

**Interfaces:**
- Produces: `ensure_tenant_wasm_toolchain <name>` — idempotent; installs/verifies rustup, default toolchain, `wasm32-wasip1`/`wasm32-wasip2` targets, `cargo-component`; returns 0 if the toolchain is usable, 1 (after loud warning) if not. Task 7 relies on the warning text containing `WASM toolchain incomplete`.

- [ ] **Step 1: Extract the helper.** Insert this new function directly ABOVE `create_tenant_user()` (anchor: `grep -n '^create_tenant_user()'`):

```bash
# Idempotent: install/verify the tenant user's WASM build toolchain (rustup,
# stable default, wasm32-wasip1/wasip2 targets, cargo-component, wasm-tools).
# Called from create_tenant_user (add-tenant) and as a build-tenant --with-wasm
# preflight, so a partial install (network hiccup, killed add-tenant) is
# repaired instead of silently disabling WASM builds forever.
# Returns 0 when the toolchain is usable, 1 (after a loud warning) when not.
ensure_tenant_wasm_toolchain() {
  local name="$1"
  local cargo_src='if [ -f "$HOME/.cargo/env" ]; then . "$HOME/.cargo/env"; else export PATH="$HOME/.cargo/bin:$PATH"; fi;'

  # Install rustup for tenant user if not already present
  if ! sudo -u "$name" bash -c "${cargo_src} command -v rustup" &>/dev/null; then
    say "installing rustup for $name ..."
    sudo -u "$name" bash -c 'curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y' \
      || { say "WARNING: rustup installation failed for $name" >&2; }
  fi

  # Ensure a default toolchain is set (rustup install may leave none configured)
  if ! sudo -u "$name" bash -c "${cargo_src} rustup show active-toolchain" &>/dev/null; then
    say "setting default toolchain to stable for $name ..."
    sudo -u "$name" bash -c "${cargo_src} rustup default stable" \
      || say "WARNING: failed to set default toolchain for $name" >&2
  fi

  # Ensure WASM targets and cargo-component are installed
  say "ensuring WASM toolchain for $name ..."
  sudo -u "$name" bash -c "${cargo_src} rustup target add wasm32-wasip1 wasm32-wasip2 2>&1" || true
  if ! sudo -u "$name" bash -c "${cargo_src} command -v cargo-component" &>/dev/null; then
    say "installing cargo-component and wasm-tools for $name ..."
    sudo -u "$name" bash -c "${cargo_src} cargo install cargo-component wasm-tools --locked 2>&1" || true
  fi

  # Final verification — loud, actionable, never fatal.
  local missing=()
  sudo -u "$name" bash -c "${cargo_src} command -v cargo-component" &>/dev/null || missing+=("cargo-component")
  sudo -u "$name" bash -c "${cargo_src} rustup target list --installed 2>/dev/null | grep -q wasm32-wasip2" \
    || missing+=("wasm32-wasip2 target")
  if ((${#missing[@]} > 0)); then
    say "" >&2
    say "WARNING: WASM toolchain incomplete for $name — missing: ${missing[*]}" >&2
    say "         WASM extensions will NOT build. To fix, run:" >&2
    say "           sudo -u $name bash -lc 'rustup target add wasm32-wasip1 wasm32-wasip2'" >&2
    say "           sudo -u $name bash -lc 'cargo install cargo-component wasm-tools --locked'" >&2
    say "         then re-run: $0 build-tenant $name --with-wasm" >&2
    say "" >&2
    return 1
  fi
  return 0
}
```

- [ ] **Step 2: Replace the inline block in `create_tenant_user`.** Delete the current lines from `# Install rustup for tenant user if not already present` through the closing `fi` of the cargo-component install (the block ending just before `create_tenant_user`'s final `}` — currently `:1353-1376`), and replace with:

```bash
  ensure_tenant_wasm_toolchain "$name" || true
```

Note: the old block used `die` on rustup-install failure; the helper deliberately downgrades that to a warning (Global Constraints: no new fatal paths, and add-tenant must not abort a tenant creation over an optional-build toolchain).

- [ ] **Step 3: Add the preflight to `build_tenant`.** In `build_tenant()`, inside the `if [[ "$with_wasm" == "true" ]]; then` branch (anchor: `grep -n 'building WASM extensions for'`), change:

```bash
    if [[ "$with_wasm" == "true" ]]; then
      say "building WASM extensions for $name ..."
      sudo -u "$name" bash -c "$cargo_env cd '$repo' && bash scripts/build-wasm-extensions.sh" || true

      say "installing WASM extensions for $name ..."
      install_wasm_tenant "$name"
    fi
```

to:

```bash
    if [[ "$with_wasm" == "true" ]]; then
      if ensure_tenant_wasm_toolchain "$name"; then
        say "building WASM extensions for $name ..."
        sudo -u "$name" bash -c "$cargo_env cd '$repo' && bash scripts/build-wasm-extensions.sh" \
          || say "WARNING: WASM extension build reported errors for $name (some extensions may be missing; re-run '$0 build-tenant $name --with-wasm' after fixing)" >&2

        say "installing WASM extensions for $name ..."
        install_wasm_tenant "$name"
      else
        say "WARNING: skipping WASM build for $name (toolchain incomplete — see above)" >&2
      fi
    fi
```

- [ ] **Step 4: Syntax check.**

Run: `bash -n ic/scripts/lunarwing-mt-admin.sh && echo SYNTAX-OK`
Expected: `SYNTAX-OK`

- [ ] **Step 5: Structural checks.**

Run: `grep -c '^ensure_tenant_wasm_toolchain()' ic/scripts/lunarwing-mt-admin.sh`
Expected: `1`
Run: `grep -c 'ensure_tenant_wasm_toolchain "\$name"' ic/scripts/lunarwing-mt-admin.sh`
Expected: `2` (one in `create_tenant_user`, one in `build_tenant`)
Run: `grep -n 'Install rustup for tenant user' ic/scripts/lunarwing-mt-admin.sh | wc -l`
Expected: `1` (comment now lives only inside the helper)

- [ ] **Step 6: Commit.**

```bash
git add ic/scripts/lunarwing-mt-admin.sh
git commit -m "refactor(mt-admin): extract ensure_tenant_wasm_toolchain, preflight --with-wasm

build-tenant --with-wasm now repairs/verifies the tenant WASM toolchain
(reusing the add-tenant installer) and warns loudly instead of silently
skipping WASM when it is incomplete. [skip-regression-check]"
```

---

### Task 2: WASM ssh allowlist auto-patch

**Files:**
- Modify: `ic/scripts/lunarwing-mt-admin.sh` — new helpers near `ensure_ssh_config()` (`:2364`; anchor: `grep -n '^ensure_ssh_config()'`), call sites in `install_wasm_tenant()` (after the tools loop `chown`, anchor: `grep -n 'chown -R "\$name:\$name" "\$channels_dir" "\$tools_dir"'`) and the `configure-ssh` dispatcher (anchor: `grep -n 'SSH harness configured for tenant'`).

**Interfaces:**
- Produces: `_ssh_hosts_from_config <name>` — prints one configured `[[ssh.hosts]]` host value per line (empty output if none). `patch_ssh_tool_allowlist <name>` — rewrites the installed `ssh-tool.capabilities.json` allowlist to exactly those hosts; no-ops (with a `say` note) when the sidecar or hosts are absent. Task 5 and Task 7 rely on these names.

- [ ] **Step 1: Add the helpers.** Insert directly BELOW the closing `}` of `ensure_ssh_config()`:

```bash
# Print the host values of every [[ssh.hosts]] block in the tenant's
# config.toml, one per line. mt-admin writes this file itself (ensure_ssh_config),
# so the shape is known: a `host = "..."` line inside each [[ssh.hosts]] block.
_ssh_hosts_from_config() {
  local name="$1" config_path
  config_path="$(tenant_state_dir "$name")/config.toml"
  [[ -f "$config_path" ]] || return 0
  awk '
    /^\[\[ssh\.hosts\]\]/ { inblk = 1; next }
    /^\[/                 { inblk = 0 }
    inblk && /^host[ ]*=[ ]*"/ {
      line = $0
      sub(/^host[ ]*=[ ]*"/, "", line)
      sub(/".*$/, "", line)
      print line
    }
  ' "$config_path"
}

# Point the installed WASM ssh tool's capability allowlist at the tenant's
# configured [[ssh.hosts]] hosts (the sidecar ships with a "myhost" placeholder).
# Idempotent: always derived from config.toml. Warn-and-continue on any failure.
patch_ssh_tool_allowlist() {
  local name="$1" caps_path hosts_json tmp
  caps_path="$(tenant_state_dir "$name")/tools/ssh-tool.capabilities.json"

  [[ -f "$caps_path" ]] || return 0  # WASM ssh tool not installed — nothing to patch

  hosts_json="$(_ssh_hosts_from_config "$name" | jq -R . | jq -s .)"
  if [[ "$hosts_json" == "[]" ]]; then
    say "  ssh-tool allowlist: no [[ssh.hosts]] in config.toml — leaving sidecar as shipped"
    return 0
  fi

  tmp="$(mktemp)"
  if jq --argjson hosts "$hosts_json" '.capabilities.ssh.allowed_hosts = $hosts' \
       "$caps_path" >"$tmp" 2>/dev/null; then
    mv "$tmp" "$caps_path"
    chown "$name:$name" "$caps_path"
    say "  ssh-tool allowlist set to: $(jq -c . <<<"$hosts_json")"
  else
    rm -f "$tmp"
    say "WARNING: failed to patch ssh-tool allowlist at $caps_path (edit .capabilities.ssh.allowed_hosts manually)" >&2
  fi
}
```

- [ ] **Step 2: Micro-test the pure parsing logic** (helpers are self-contained enough to extract):

```bash
cd /tmp && mkdir -p allowtest && cd allowtest
cat > config.toml <<'EOF'
# header
[[sandbox.external_workers]]
name = "nanocode"
url = "ws://localhost:9090/ws/agent"

[[ssh.hosts]]
host = "127.0.0.1"
port = 22
user = "sshtest"

[[ssh.hosts]]
host = "git.example.com"
port = 22
EOF
awk '
  /^\[\[ssh\.hosts\]\]/ { inblk = 1; next }
  /^\[/                 { inblk = 0 }
  inblk && /^host[ ]*=[ ]*"/ {
    line = $0
    sub(/^host[ ]*=[ ]*"/, "", line)
    sub(/".*$/, "", line)
    print line
  }
' config.toml
```

Expected output — exactly:
```
127.0.0.1
git.example.com
```
(Note the worker block's `name`/`url` lines are NOT matched.) Then the jq patch:

```bash
echo '{"version":"0.3.0","capabilities":{"ssh":{"allowed_hosts":["myhost"]}}}' > caps.json
jq --argjson hosts '["127.0.0.1","git.example.com"]' '.capabilities.ssh.allowed_hosts = $hosts' caps.json
```

Expected: JSON with `"allowed_hosts": ["127.0.0.1", "git.example.com"]`. Clean up: `cd /tmp && rm -rf allowtest`.

- [ ] **Step 3: Wire the call sites.** (a) In `install_wasm_tenant()`, immediately AFTER the line `chown -R "$name:$name" "$channels_dir" "$tools_dir"`, add:

```bash
  patch_ssh_tool_allowlist "$name"
```

(b) In the `configure-ssh` dispatcher case, after `provision_tenant_ssh_key "$name" "$ssh_host" "$ssh_user"`, add:

```bash
      patch_ssh_tool_allowlist "$name"
```

- [ ] **Step 4: Syntax + structural checks.**

Run: `bash -n ic/scripts/lunarwing-mt-admin.sh && echo SYNTAX-OK`
Expected: `SYNTAX-OK`
Run: `grep -c 'patch_ssh_tool_allowlist "\$name"' ic/scripts/lunarwing-mt-admin.sh`
Expected: `2`

- [ ] **Step 5: Commit.**

```bash
git add ic/scripts/lunarwing-mt-admin.sh
git commit -m "feat(mt-admin): auto-patch WASM ssh-tool allowlist from [[ssh.hosts]]

install-wasm and configure-ssh now derive ssh-tool.capabilities.json's
allowed_hosts from the tenant's config.toml instead of shipping the
'myhost' placeholder that required a manual edit. [skip-regression-check]"
```

---

### Task 3: `start_tenant` reorder + conditional daemon bounce

**Files:**
- Modify: `ic/scripts/lunarwing-mt-admin.sh` — `start_tenant()` (`:5396`; anchor: `grep -n '^start_tenant()'`), new helpers above it.

**Interfaces:**
- Consumes: `upload_tenant_ssh_key <name>` (existing: uploads staged key at `$(tenant_env_dir)/ssh_key_staged`, deletes the file on success), `ports_get <name> http`, `_systemctl_user`, `ensure_init_system`/`$INIT_SYSTEM`.
- Produces: `_wait_tenant_gateway <name>` — polls `/agent/status` up to 30s, returns 0 when reachable. `_restart_tenant_daemon <name>` — bounces ONLY `lunarwing-<name>` (both init systems). Task 5 inserts its summary at the end of the new `start_tenant`.

- [ ] **Step 1: Add the two helpers** directly ABOVE `start_tenant()`:

```bash
# Poll the tenant gateway's /agent/status until reachable (up to ~30s).
_wait_tenant_gateway() {
  local name="$1" http_port i=0
  http_port="$(ports_get "$name" http)"
  while ! curl -sf --max-time 2 "http://127.0.0.1:${http_port}/agent/status" >/dev/null 2>&1; do
    i=$((i + 1))
    [[ $i -lt 15 ]] || return 1
    sleep 2
  done
  return 0
}

# Restart ONLY the lunarwing daemon unit for a tenant (not the full stack).
# Used by start_tenant to make a freshly-uploaded SSH key signable: the agent
# loads keys from the secrets store at startup only ("runtime key add is
# status-only" — see docs/architecture/SSH_AGENT_HARNESS.md §7).
_restart_tenant_daemon() {
  local name="$1"
  ensure_init_system
  if [[ "$INIT_SYSTEM" == "systemd" ]]; then
    _systemctl_user "$name" restart "lunarwing-${name}.service"
  else
    rc-service "lunarwing-${name}" restart
  fi
}
```

- [ ] **Step 2: Reorder `start_tenant`.** Replace the tail of `start_tenant()` — everything from the `# Workers start AFTER the daemon ...` comment through the final `upload_tenant_ssh_key "$name" || true` — with:

```bash
  # Upload the staged SSH key to the secrets store (if one was provisioned by
  # add-tenant but not yet uploaded), BEFORE the workers start. If a key was
  # actually ingested, bounce the daemon once so the agent loads it (keys are
  # only read from the secrets store at startup); the workers then bind-mount
  # the post-bounce socket inode, so they are never left on a stale socket.
  local staged_key
  staged_key="$(tenant_env_dir "$name")/ssh_key_staged"
  if [[ -f "$staged_key" ]]; then
    upload_tenant_ssh_key "$name" || true
    if [[ ! -f "$staged_key" ]]; then
      # Upload succeeded (upload_tenant_ssh_key deletes the staged file).
      say "restarting lunarwing-${name} so the SSH agent loads the new key ..."
      if _restart_tenant_daemon "$name"; then
        if _wait_tenant_gateway "$name"; then
          say "lunarwing-${name} restarted; SSH key active"
        else
          say "WARNING: gateway not reachable after SSH-key restart (check 'status $name')" >&2
        fi
      else
        say "WARNING: daemon restart failed after SSH key upload; run '$0 restart-tenant $name' manually" >&2
      fi
    fi
  fi

  # Workers start AFTER the daemon (and after any SSH-key bounce) so the SSH
  # agent socket is already a real, current Unix socket when podman bind-mounts it.
  start_tenant_nanocode "$name"
  start_tenant_pebble "$name"
```

(The `# Start the daemon BEFORE the workers ...` comment earlier in the function stays accurate and unchanged; `local staged_key` is fine mid-function — bash allows `local` anywhere inside a function, and `env_path` is already declared the same way at the top.)

- [ ] **Step 3: Syntax + structural checks.**

Run: `bash -n ic/scripts/lunarwing-mt-admin.sh && echo SYNTAX-OK`
Expected: `SYNTAX-OK`
Run: `awk '/^start_tenant\(\)/,/^}/' ic/scripts/lunarwing-mt-admin.sh | grep -n 'start_tenant_nanocode\|upload_tenant_ssh_key' | head -4`
Expected: `upload_tenant_ssh_key` appears BEFORE `start_tenant_nanocode` in the function body.

- [ ] **Step 4: Commit.**

```bash
git add ic/scripts/lunarwing-mt-admin.sh
git commit -m "feat(mt-admin): start-tenant uploads SSH key, bounces daemon, then starts workers

Removes the manual restart-tenant step: the staged key is uploaded right
after the daemon comes up, the daemon is bounced once (only when a key was
actually ingested) so the agent can sign, and workers start last so they
always bind-mount the current agent socket inode. [skip-regression-check]"
```

---

### Task 4: sshd preflight (doctor + warn-only probes)

**Files:**
- Modify: `ic/scripts/lunarwing-mt-admin.sh` — helper above `ensure_ssh_config()`, probe calls in `add_tenant` (ssh block, anchor: `grep -n 'Provisioning SSH harness'`) and `start_tenant` (before the upload block from Task 3), doctor check (anchor: `grep -n '"podman available" podman info'`).

**Interfaces:**
- Produces: `_probe_tcp <host> <port>` (0 = open) and `warn_if_sshd_unreachable <name>` (warn-only; probes each configured `[[ssh.hosts]]` entry that is `127.0.0.1`). Consumes `_ssh_hosts_from_config` from Task 2.

- [ ] **Step 1: Add the helpers** directly BELOW `patch_ssh_tool_allowlist()` (from Task 2):

```bash
# True if a TCP connect to host:port succeeds within 2s (pure bash /dev/tcp).
_probe_tcp() {
  local host="$1" port="$2"
  timeout 2 bash -c "exec 3<>/dev/tcp/${host}/${port}" 2>/dev/null
}

# Warn (never fail) if the tenant's configured loopback SSH host has no sshd
# listening. Only 127.0.0.1 entries are probed: remote hosts may legitimately
# be unreachable from this box (firewalls, jump hosts).
warn_if_sshd_unreachable() {
  local name="$1" host
  while IFS= read -r host; do
    [[ "$host" == "127.0.0.1" ]] || continue
    if ! _probe_tcp "$host" 22; then
      say "WARNING: no sshd listening on ${host}:22 — the tenant's SSH tools target this host." >&2
      say "         Enable it with: systemctl enable --now sshd   (or 'ssh' on Debian/Ubuntu)" >&2
    fi
  done < <(_ssh_hosts_from_config "$name")
}
```

(The configured port is always 22 today — `ensure_ssh_config` hardcodes `port = 22`; parsing the port can come later if that changes.)

- [ ] **Step 2: Micro-test the probe.**

Run: `bash -c 'timeout 2 bash -c "exec 3<>/dev/tcp/127.0.0.1/22" 2>/dev/null && echo OPEN || echo CLOSED'`
Expected on this box (sshd running): `OPEN`. Also verify the negative:
Run: `bash -c 'timeout 2 bash -c "exec 3<>/dev/tcp/127.0.0.1/1" 2>/dev/null && echo OPEN || echo CLOSED'`
Expected: `CLOSED`

- [ ] **Step 3: Wire the probes.** (a) In `add_tenant`'s ssh block, after `provision_tenant_ssh_key "$name"`, add:

```bash
    warn_if_sshd_unreachable "$name"
```

(b) In `start_tenant` (Task 3's new block), immediately BEFORE the `if [[ -f "$staged_key" ]]; then` line, add:

```bash
  warn_if_sshd_unreachable "$name"
```

(c) In `doctor`, after the `_check "podman available" podman info` block, add:

```bash
  _check "sshd listening on 127.0.0.1:22 (needed for loopback SSH tenants)" \
    bash -c 'timeout 2 bash -c "exec 3<>/dev/tcp/127.0.0.1/22"'
```

- [ ] **Step 4: Syntax check.**

Run: `bash -n ic/scripts/lunarwing-mt-admin.sh && echo SYNTAX-OK`
Expected: `SYNTAX-OK`

- [ ] **Step 5: Commit.**

```bash
git add ic/scripts/lunarwing-mt-admin.sh
git commit -m "feat(mt-admin): warn when the loopback SSH target has no sshd

add-tenant, start-tenant, and doctor now probe 127.0.0.1:22 (warn-only)
instead of letting the operator discover a missing sshd at first tool
use. [skip-regression-check]"
```

---

### Task 5: Ready-state summary at the end of `start-tenant`

**Files:**
- Modify: `ic/scripts/lunarwing-mt-admin.sh` — new `_ssh_ready_summary()` above `start_tenant()`, called as `start_tenant`'s last line; `add_tenant`'s port-block ssh line (anchor: `grep -n 'key will be uploaded on start-tenant'`).

**Interfaces:**
- Consumes: `ports_get`, `_ssh_hosts_from_config` (Task 2), `tenant_state_dir`, the gateway SSH API (`/agent/status`).

- [ ] **Step 1: Add the summary helper** above `start_tenant()`:

```bash
# Print a post-start SSH readiness block sourced from the live API. Warn-only:
# a missing/failed API must never fail start-tenant.
_ssh_ready_summary() {
  local name="$1" http_port status keys hosts
  hosts="$(_ssh_hosts_from_config "$name" | paste -sd, -)"
  [[ -n "$hosts" ]] || return 0  # SSH not configured for this tenant

  http_port="$(ports_get "$name" http)"
  status="$(curl -sf --max-time 3 "http://127.0.0.1:${http_port}/agent/status" 2>/dev/null)" || status=""
  keys="$(jq -r '.data.keys_loaded // "?"' <<<"$status" 2>/dev/null)" || keys="?"

  say ""
  say "--- SSH readiness ---"
  say "  hosts:        $hosts"
  if [[ "$keys" != "?" && "$keys" -ge 1 ]] 2>/dev/null; then
    say "  agent:        running, $keys key(s) loaded — ssh/ssh_git tools ready"
  else
    say "  agent:        keys_loaded=$keys — if a key upload just failed, re-run '$0 start-tenant $name'"
  fi
  if [[ -f "$(tenant_state_dir "$name")/tools/ssh-tool.wasm" ]]; then
    say "  wasm ssh:     installed (activate it in the web panel: Settings → Extensions → ssh)"
  fi
  say "  verify:       curl -s http://127.0.0.1:${http_port}/agent/status | jq"
}
```

- [ ] **Step 2: Call it** as the LAST line of `start_tenant()` (after `start_tenant_pebble "$name"` from Task 3):

```bash
  _ssh_ready_summary "$name" || true
```

- [ ] **Step 3: Update add-tenant's ssh status line.** Change the text `enabled (key will be uploaded on start-tenant)` to `enabled (key upload + activation handled by start-tenant)`.

- [ ] **Step 4: Syntax check.**

Run: `bash -n ic/scripts/lunarwing-mt-admin.sh && echo SYNTAX-OK`
Expected: `SYNTAX-OK`

- [ ] **Step 5: Commit.**

```bash
git add ic/scripts/lunarwing-mt-admin.sh
git commit -m "feat(mt-admin): SSH readiness summary at end of start-tenant

start-tenant now reports live keys_loaded, configured hosts, and the WASM
ssh activation pointer, so the operator sees at a glance whether SSH is
ready. [skip-regression-check]"
```

---

### Task 6: Documentation updates

**Files:**
- Modify: `docs/ops/SSH-HARNESS-SETUP.md` (restart-after-upload section, anchor: `grep -n 'Restart the daemon after uploading a key'`; troubleshooting rows mentioning restart; the WASM allowlist edit in "Building / enabling the WASM `ssh` tool").
- Modify: `docs/ops/MULTITENANCY-PRODUCTION.md` (walkthrough — no step change needed, but add the SSH note under Step 4/5).
- Modify: `docs/architecture/SSH_DELIVERY_MECHANISMS.md` (Mechanism 3 "How to enable / build" — allowlist auto-patch note).

- [ ] **Step 1: SSH-HARNESS-SETUP.md.** In the `### 3. ⚠️ Restart the daemon after uploading a key` section, add this paragraph at the top of the section:

```markdown
> **mt-admin handles this automatically.** `start-tenant` uploads the staged
> key and bounces the daemon in one pass, so multi-tenant deployments need no
> manual restart. The rest of this section applies to manual/API uploads on a
> running daemon.
```

In the troubleshooting table, update the `keys_loaded: 0` row's fix text from `**restart the daemon**` to `**restart the daemon** (mt-admin's start-tenant does this automatically after upload)`. In "Building / enabling the WASM `ssh` tool", replace the sentence about editing `allowed_hosts` in `ssh-tool.capabilities.json` with:

```markdown
On mt-admin tenants the installed sidecar's `capabilities.ssh.allowed_hosts`
is patched automatically from the tenant's `[[ssh.hosts]]` (by `install-wasm`
/ `build-tenant --with-wasm` / `configure-ssh`). For manual installs, edit
`tools-src/ssh/ssh-tool.capabilities.json` before installing.
```

- [ ] **Step 2: MULTITENANCY-PRODUCTION.md.** After the Step 4 (start services) command block, add:

```markdown
> `start-tenant` also uploads the tenant's staged SSH key and bounces the
> daemon once so the SSH agent can sign immediately — no manual
> `restart-tenant` needed. It ends with an "SSH readiness" summary; if
> `keys_loaded` is 0 there, re-run `start-tenant`.
```

- [ ] **Step 3: SSH_DELIVERY_MECHANISMS.md.** In Mechanism 3's "How to enable / build" paragraph, after the sentence about the capability sidecar declaring `ssh.allowed_hosts`, add:

```markdown
On mt-admin tenants the installed copy's allowlist is auto-patched to the
tenant's `[[ssh.hosts]]` hosts; the shipped `"myhost"` placeholder only needs
hand-editing for non-mt-admin installs.
```

- [ ] **Step 4: Verify links/anchors still resolve.**

Run: `grep -n 'start-tenant' docs/ops/SSH-HARNESS-SETUP.md | head -5`
Expected: the new auto-handling note appears.

- [ ] **Step 5: Commit.**

```bash
git add docs/ops/SSH-HARNESS-SETUP.md docs/ops/MULTITENANCY-PRODUCTION.md docs/architecture/SSH_DELIVERY_MECHANISMS.md
git commit -m "docs(ssh): reflect mt-admin auto key-activation and allowlist patching"
```

---

### Task 7: Live verification on the test box (operator-run)

**Files:** none (verification record). These commands run as root on the deployment box (`cablemanagement`), with the runtime forced: prefix every mt-admin call with `sudo env LUNARWING_CONTAINER_RUNTIME=podman`. The tenant repo clone must contain the Task 1-5 script before `add-tenant` runs — mt-admin is invoked FROM the admin checkout, so only the checkout needs the changes (the script itself is not copied into the tenant).

- [ ] **Step 1: Clean slate.**

```bash
sudo env LUNARWING_CONTAINER_RUNTIME=podman ic/scripts/lunarwing-mt-admin.sh remove-tenant sshtest --purge
```

- [ ] **Step 2: The three commands — and nothing else.**

```bash
sudo env LUNARWING_CONTAINER_RUNTIME=podman ic/scripts/lunarwing-mt-admin.sh add-tenant sshtest --docker-group
sudo env LUNARWING_CONTAINER_RUNTIME=podman ic/scripts/lunarwing-mt-admin.sh build-tenant sshtest --with-wasm --with-nanocode
sudo env LUNARWING_CONTAINER_RUNTIME=podman ic/scripts/lunarwing-mt-admin.sh start-tenant sshtest
```

Expected during `start-tenant`: `SSH key uploaded ...` → `restarting lunarwing-sshtest so the SSH agent loads the new key ...` → `lunarwing-sshtest restarted; SSH key active` → workers start → `--- SSH readiness ---` block with `1 key(s) loaded`.

- [ ] **Step 3: Assertions.**

```bash
curl -s http://127.0.0.1:10001/agent/status | jq -e '.data.keys_loaded >= 1'   # true, NO manual restart happened
sudo jq -e '.capabilities.ssh.allowed_hosts == ["127.0.0.1"]' /home/sshtest/lunarwing/state/tools/ssh-tool.capabilities.json
sudo env LUNARWING_CONTAINER_RUNTIME=podman ic/scripts/lunarwing-mt-admin.sh status sshtest   # nanocode active
sudo -u sshtest env SSH_AUTH_SOCK=/home/sshtest/lunarwing/run/ssh-agent.sock \
  ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes sshtest@127.0.0.1 'whoami'          # prints: sshtest
```

- [ ] **Step 4: Idempotence — immediate second start.**

```bash
sudo env LUNARWING_CONTAINER_RUNTIME=podman ic/scripts/lunarwing-mt-admin.sh start-tenant sshtest
```

Expected: NO `restarting lunarwing-sshtest ...` line (no staged key → no bounce), no errors, readiness block still shows the key.

- [ ] **Step 5: Record.** Paste the outputs into the PR description as the verification record (mt-admin has no automated test harness).

---

## Self-Review (completed)

- **Spec coverage:** §1→Task 3, §2→Task 2, §3→Task 1, §4→Task 4, §5→Task 5, docs→Task 6, testing→Task 7 + per-task checks. Backlog items intentionally unplanned.
- **Placeholders:** none — every step carries its code/commands.
- **Type/name consistency:** `ensure_tenant_wasm_toolchain`, `patch_ssh_tool_allowlist`, `_ssh_hosts_from_config`, `_probe_tcp`, `warn_if_sshd_unreachable`, `_wait_tenant_gateway`, `_restart_tenant_daemon`, `_ssh_ready_summary` — each defined once, call sites match; Task 4/5 consume Task 2's `_ssh_hosts_from_config`, so Tasks 2 → 4 → 5 must land in that order (1 and 3 are order-free, but keep the numbering for simplicity).
