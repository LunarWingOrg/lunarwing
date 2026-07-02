# mt-admin SSH Setup Streamlining — Design

**Date:** 2026-07-01
**Status:** Approved design, pending implementation
**Target:** `ic/scripts/lunarwing-mt-admin.sh` (plus doc updates)
**Origin:** Live end-to-end SSH test of a fresh `sshtest` tenant (branch `sshagentoption3-1`). Getting SSH working required manual steps beyond `add-tenant → build-tenant → start-tenant`: a mandatory daemon restart after key upload, a hand-edit of the WASM ssh tool's capability allowlist, an unverified sshd assumption, and silently-skippable WASM prerequisites.

## Goal

`add-tenant <name>` → `build-tenant <name> --with-wasm` → `start-tenant <name>` yields a tenant whose SSH harness is fully working — `keys_loaded ≥ 1`, built-in `ssh`/`ssh_git` tools usable, WASM ssh tool installed with a correct allowlist — with **zero further commands**. The only remaining deliberate act is activating the WASM ssh tool in the web panel (kept manual on purpose: loading an SSH-capable sandboxed tool should be a human decision).

## Decisions (from brainstorm)

| Decision | Choice |
|---|---|
| Overall shape | Fix each existing stage in place; no new `up` command; add-tenant stays provision-only |
| Restart elimination | Script-side reorder of `start_tenant`; daemon-side live key-add (root fix for "runtime key add is status-only") deferred as backlog |
| WASM ssh tool activation | Stays manual in the web panel; mt-admin prints a pointer |
| Toolchain gap | Reuse the existing installer as a `build-tenant --with-wasm` preflight (see §3 — auto-install already exists in add-tenant) |
| `LUNARWING_CONTAINER_RUNTIME` persistence | Out of scope (separate improvement; related to the future mt-admin onboarding walkthrough idea) |
| Error philosophy | Every new step warns-and-continues; no new fatal paths |

## Changes

### 1. `start_tenant` reorder + conditional auto-bounce

**Problem:** A key uploaded to a running agent is stored but not signable until the next daemon restart (daemon limitation, documented). Today `start_tenant` (≈`:5413-5448`) runs: socket pre-create → postgres → vision → daemon → **workers** → `upload_tenant_ssh_key || true`, so the operator must run `restart-tenant` afterwards — and that restart in turn leaves workers bind-mounted to a stale socket inode unless they are also recreated.

**Change:** New order: socket pre-create → postgres → vision → daemon → **upload staged key** → *iff a staged key file existed and the upload succeeded*: restart **only the lunarwing daemon unit** (via the same init-system-aware service stop/start helpers the other commands use — not a full `restart-tenant`) and re-wait for `/agent/status` `running:true` → **then start workers**.

- Idempotent: second `start-tenant` has no staged key (deleted on successful upload) → no bounce.
- Workers always come up against the post-bounce socket inode — this also closes the pre-existing stale-socket hazard.
- Upload failure: loud warning (keep existing text, add the exact retry command), no bounce, workers still start.
- `restart-tenant` unchanged (still the manual belt).

### 2. WASM ssh allowlist auto-patch in `install_wasm_tenant`

**Problem:** `ssh-tool.capabilities.json` ships with `allowed_hosts: ["myhost"]`; the WASM ssh tool refuses the tenant's real host until the operator hand-edits the installed copy.

**Change:** In `install_wasm_tenant`, after copying the ssh tool's capabilities sidecar: parse the `host = "..."` values from the tenant's `[[ssh.hosts]]` blocks in `config.toml` (a file mt-admin itself writes — predictable shape) and `jq`-patch `.capabilities.ssh.allowed_hosts` to exactly that list. Ownership chown at the end of the function already covers the patched file.

- No `[[ssh.hosts]]` present → leave the sidecar as shipped and say so.
- `configure-ssh` re-runs the patch after changing hosts, so the allowlist follows config.
- Only the ssh tool's sidecar is touched; derivation from config.toml makes re-runs idempotent.

### 3. WASM toolchain preflight in `build_tenant --with-wasm`

**Finding:** add-tenant already auto-installs the full tenant toolchain — `create_tenant_user` (`:1301`) installs rustup (fatal on failure), sets `rustup default stable`, adds `wasm32-wasip1`/`wasm32-wasip2`, and `cargo install cargo-component wasm-tools --locked` (`:1353-1376`). The gap is only that the target/cargo-component steps run under `|| true` and `build-tenant --with-wasm` never re-checks — a partial add-tenant install (network hiccup, killed run) silently disables WASM builds forever.

**Change:** Extract `:1353-1376` into an idempotent `ensure_tenant_wasm_toolchain <name>` helper. Call it from `create_tenant_user` (behavior unchanged) and as a preflight in `build_tenant` when `--with-wasm` is set. If the toolchain is still unusable after the preflight, emit a **bold multi-line warning** naming exactly what is missing and the `sudo -u <name> …` commands to fix it, then continue the daemon build. The WASM build step's own failure also warns loudly instead of being swallowed.

### 4. sshd preflight

**Problem:** The default `[[ssh.hosts]]` entry targets `127.0.0.1:22`, but nothing verifies an sshd is listening; the operator discovers it at first tool use.

**Change:**
- `doctor`: new informational check — sshd listening (TCP probe of `127.0.0.1:22`).
- `add_tenant` ssh block and `start_tenant`: when the configured ssh host is `127.0.0.1`, TCP-probe the configured port; if closed, warn with the `systemctl enable --now sshd` hint. Never fatal (the host may be intentionally remote-only later).

### 5. Ready-state summary output

**Change:** `start_tenant` ends with an SSH status block sourced from the live API: host alias(es), `keys_loaded` from `/agent/status`, sshd reachability, and the one remaining deliberate step — "WASM ssh tool installed; activate it in the web panel (Settings → Extensions)". `add_tenant`'s "Next steps" text updated to match (no more implicit restart step).

## Testing

- `bash -n` on the script; shellcheck on touched functions where shellcheck is available.
- Live re-verification on the existing test box: `remove-tenant sshtest --purge`, then the three commands; confirm `keys_loaded:1` with **no** manual restart, patched allowlist (`jq .capabilities.ssh.allowed_hosts` = the tenant's hosts), workers healthy after the bounce, and the summary block accurate.
- Idempotence: immediate second `start-tenant` (no staged key → no bounce, no errors); re-run `install-wasm` (allowlist re-derived, unchanged).
- Degraded paths: `start-tenant` with the gateway blocked (upload warning, no bounce, workers still start); `--with-wasm` with cargo-component removed (loud preflight warning, daemon still builds).
- mt-admin has no automated test harness; the live walkthrough above is the verification record (note in the PR).

## Docs to update

- `docs/ops/SSH-HARNESS-SETUP.md` — setup flow collapses; "restart the daemon after uploading a key" becomes "handled automatically by `start-tenant`" (manual API uploads still need it); WASM allowlist edit step removed.
- `docs/ops/MULTITENANCY-PRODUCTION.md` — walkthrough steps updated.
- `docs/architecture/SSH_DELIVERY_MECHANISMS.md` — WASM enablement section: allowlist is auto-patched by mt-admin; manual edit only for non-mt-admin installs.

## Backlog (explicitly out of scope)

- **Daemon-side live key loading** — fix `SshAgentServer` so `add_key` drives `add_identity` at runtime; removes the restart for *all* consumers (API, panel), after which §1's bounce becomes a no-op fallback.
- **`LUNARWING_CONTAINER_RUNTIME` persistence** in `/etc/lunarwing` (set once, env var overrides).
- **Interactive mt-admin onboarding walkthrough** (user goal, pre-1.1.8/1.1.9).
