# Release Notes for LunarWing v1.1.8 — Codename `Tatara`

**Release Date:** 2026-07-XX *(to be set before tag — see GOALS_1.1.8 #29)*

> Codename *Tatara* (たたら / 踏鞴) — the traditional Japanese clay smelting furnace used to produce tamahagane, the high-purity steel forged into katana. The *tatara-ba* (踏鞴場, literally "treading-bellows place") is the whole ironworks — the forge where raw material is refined through fire into something sharp and enduring. The word *tatara* originally referred to the foot-operated bellows that workers pumped in shifts before expanding to mean the entire furnace operation. v1.1.8 is a **feature + polish** release with a brand-new **opencode external worker**. Additionally, 1.1.8 brings the full completion of the **Agent SSH tooling** (delivery Options 2 and 3 plus hardening), and the **hard-disable of DarkIRC** unless explicitly opted in, since it can be rather resource intensive on certain hardware. Beneath those headline changes, the release folds in a round of multi-tenant admin streamlining (SSH provisioning folded into `start-tenant`, persistent runtime detection, `add-tenant`/`add-tenants` enhancement flags), the removal of the default GitHub WASM tool and bundled MCP manifests from the fresh-install registry, routine-engine improvements carried over from v1.1.7, and more.

## Overview

1. **The opencode external worker** (`opencode4lunarwing/`) — a persistent [opencode](https://opencode.ai) (sst/opencode) worker container speaking the `ironclaw-agent-v1` WebSocket protocol, with the `@opencode-ai/sdk`, optional Paseo MCP integration, git/ssh key support, and health endpoints. It is the third external worker container (joining nanocode and pebble). The daemon-side `ExternalWorkerManager` was already generic, so **no Rust changes were required** to add it — only the container, the port-registry v10→v11 migration (`opencode_wss` / `opencode_health`), and the full `lunarwing-mt-admin.sh` lifecycle (`build-opencode-worker`, `configure-opencode`, start/stop/doctor/status, `--with-opencode`, `--opencode-model`/`--opencode-base-url`). Opencode is mostly the same as the current Nanocode worker (since Nanocode was originally a fork of Opencode).

2. **Agent SSH tooling — delivery Options 2 and 3.** v1.1.7 introduced the Agent SSH Harness (the per-tenant `ssh-agent` socket + encrypted secrets store). v1.1.8 completes the tool surface so agents and workers can actually *use* that harness: a **built-in in-process Rust SSH tool** (Option 2, phase 1) and a **`ssh_git` tool** for git-over-SSH through the harness agent (Option 2, phase 2), plus a **WASM `ssh` guest tool** (Option 3) with a host function bridge. The `mt-admin` SSH provisioning was also streamlined: `start-tenant` now uploads the staged key, bounces the daemon once so the agent loads it, and starts workers *after* the socket is real (see *SSH harness streamlining*).

The fairly useless default GitHub WASM tool and the bundled MCP server manifests from the fresh-install registry catalog have been removed. The `add-tenant` command has some new flags such as `--llm-model` / `--gateway-host` / `--xmpp-allow-from`. A new method of persisting the detected container-runtime choice was added so `LUNARWING_CONTAINER_RUNTIME` only needs to be set once.

This release **does not** add database schema changes.

---

## Changes

### Opencode External Worker

A persistent external worker container built on [opencode](https://opencode.ai) (the sst/opencode agentic coding tool), speaking the same `ironclaw-agent-v1` WebSocket protocol as the nanocode and pebble workers. It brings the external-worker count to three and is the first worker added since the External Worker Enhancement suite in v1.1.6.

Full live validation log: `docs/proposals/DEFERRED-2026-07-02-OPENCODE-EXTERNAL-WORKER.md`.

#### What landed (`commit 6fe0ec3e` + follow-ups)

- **`opencode4lunarwing/`** — a new top-level directory containing the Dockerfile, entrypoint, bridge scripts (`lunarwing_bridge.ts`, `lunarwing_runtime.ts`, `opencode_task_executor.ts`), a Python health server, `config/opencode.json`, `docker-compose.yml`, `.env.example`, and a smoke test. The bridge uses the `@opencode-ai/sdk`; the health server exposes `/health` and `/ready` (with `websocket.listening:true`) on the standard worker health port.
- **Port registry v10 → v11 migration.** Adds two extended-block slots: `opencode_wss` (= `extended_base + 7`) and `opencode_health` (= `extended_base + 8`). Delivered as both a standalone migrator (`ic/scripts/migrate-ports-v10-to-v11.sh`) and the in-`mt-admin` `ports_migrate_v11()` call (auto-runs on any mt-admin invocation). The migrator was brought to parity with the v8/v9/v10 standalone migrators: strict `version < 10` gate, timestamped backup, collision-uniqueness validation, rollback hint.
- **Full `lunarwing-mt-admin.sh` lifecycle:** `build-opencode-worker [--no-cache]`, `configure-opencode <name> [--model <m>] [--base-url <url>]`, start/stop/register/render for the worker, `doctor` checks, `status` / `list` / uninstall listings, and the `--with-opencode` flag threaded through `build-tenant` (banner + consistency). Quadlet and OpenRC rendering paths both covered.
- **Optional Paseo MCP integration** wired behind `PASEO_URL` / `PASEO_TOKEN` env vars.
- **No Rust changes.** The daemon-side `ExternalWorkerManager` (`ic/src/orchestrator/external_worker.rs`) is already generic over the `ironclaw-agent-v1` protocol, so opencode is purely a container + config + ports + lifecycle addition.

#### Model reference format fix (`commit 4a42af17`)

The first live dispatch failed with `Model not found: tensorzero::function_name::<fn>/.` Root cause: opencode's `Model.parse` splits the model string on the first `/`, so a reference must be `<provider>/<model-id>`. The baked `config/opencode.json` had the bare function name with no slash, so opencode parsed the whole string as the provider and the model id as empty. Fixed in two parts: the default config now uses the correct `provider/model` shape, and `entrypoint.sh`'s `OPENCODE_MODEL` override now detects a bare function name and constructs the correct `<provider>/<fn>` reference (and registers the model in the provider's map so opencode can resolve it). The `OPENCODE_MODEL` env var keeps the bare-function-name convention (matching the daemon's `LLM_MODEL`), so `configure-opencode --model` is unaffected.

#### Single-target build optimization (`commit 0236ca51`)

The opencode Dockerfile now passes `-- --single` to `bun run build`, filtering opencode's 12-target cross-compile to the native platform only (~5–15+ min → ~1–3 min). Rationale and caveats in `docs/proposals/OPENCODE-WORKER-SINGLE-TARGET-BUILD.md`: cross-arch tenant hosts are not supported by this change, which matches the current same-host `podman save | load` distribution model.

#### Review-blocker fixes landed before merge (PRs #131–#135)

- **#2 readiness** — worker is not reported ready until the WebSocket listener is actually up.
- **#3 honest result** — task results faithfully reflect success/failure rather than masking errors.
- **#4 crash-safety** — the bridge handles worker-exit mid-task without dropping the result.
- **#5 upgrade wiring** — `migrate-ports-v10-to-v11.sh` resolves opencode ports for tenants still on the v10 schema (`commit abf8955c`).
- **#6 build-time SDK import assertion** — the build verifies the `@opencode-ai/sdk` import resolves (`commit cc088dfa`).
- **#7 duplicate `task_id` guard** — prevents double-dispatch races (`commit cc088dfa`).

#### Rootless Podman compatibility (fleet-wide audit)

Auditing the opencode launch path surfaced two issues shared by **all three** worker types (nanocode/pebble/opencode use identical launch patterns):

- **SSH agent socket SELinux label — FIXED, fleet-wide.** All worker launch sites (imperative `_ctr run` for nanocode/pebble/opencode + the Quadlet `render_worker_quadlet`) mounted the SSH agent socket without a `:z` SELinux label. On SELinux-Enforcing Fedora hosts, `container_t` is denied access to the tenant-home-labeled socket, breaking SSH/git-push from workers despite the `0666` socket mode. Added `:z` to all four socket-mount sites.
- **Workspace file ownership — DEFERRED, by design.** Workers run as non-root `USER` directives (system accounts via `useradd -r`, unpredictable UIDs). Under rootless userns, files written to `/workspace` appear owned by a host subuid. `--userns=keep-id` does not fix this for non-root `USER` directives. The current `chmod 777` on the workspace dir is the working workaround (DAC permits access regardless of owner). The UID-pinning + `keep-id:uid=` hardening pass is deferred as a larger, separate change touching all three worker Dockerfiles. See *Known Issues*.

#### Self-heal pipeline fixes for opencode

Three opencode-specific regressions were found and fixed in the health/self-heal infrastructure that `mt-admin` provisions units for:

- `ic-infrastructure-health-check/health-openrc.sh` — `unit_tenant()` now strips the `opencode-` prefix (was misclassifying stopped opencode workers as `skipped` instead of `critical`).
- `ic-infrastructure-health-check/lunarwing-self-heal.sh` — `unit_tenant()` now handles `lunarwing-opencode-*` before the generic catch-all (was resolving to a bogus tenant, routing restarts to system-scope where they fail for user-Quadlet units).
- `ic-infrastructure-health-check/health-systemd.sh` — the deep container-health probe now includes `lunarwing-opencode-*` (was only triggering for pg/nanocode/pebble, so a Running-but-wedged opencode container reported healthy).

#### Minor follow-up (non-blocking)

- opencode's PostHog telemetry emits `ConnectionRefused` / `PostHogFetchNetworkError` lines in the worker log under rootless network isolation. Purely cosmetic — the worker continues and tasks complete normally. Silencable with a `DISABLE_TELEMETRY`-style env var if desired (tracked separately).

### Agent SSH Tooling — Delivery Options 2 and 3

v1.1.7 shipped the **harness** (the `ssh-agent` socket + encrypted secrets store + host-key verification + audit trait). v1.1.8 ships the **tools** that consume it, so agents and workers can perform SSH and git-over-SSH operations through the harness without ever holding private key material.

Full design: `docs/proposals/SSH_HARNESS_DELIVERY_OPTIONS.md` and `docs/proposals/SSH_HARNESS_OPTION_2_3_IMPLEMENTATION.md`. As-built consolidation: `docs/architecture/SSH_DELIVERY_MECHANISMS.md`.

#### Option 2, phase 1 — Built-in in-process SSH tool (`commit bf7ed931`)

A native Rust tool (`ic/src/tools/ssh/` — the `ssh` builtin) that runs in the main process (tool domain `Orchestrator`). It connects through the per-tenant `ssh-agent` socket, performs host-key verification per the configured `HostKeyMode`, and executes remote commands. Because it runs in-process, it has direct access to the secrets store and the agent socket without any IPC boundary.

#### Option 2, phase 2 — `ssh_git` tool (`commit d5948164`)

A native Rust tool for git operations over SSH through the harness agent. This is the worker→host git-push / git-clone path that the SSH harness was designed to enable: a worker container can push to a host git repo authenticated by the agent socket, with the private key never touching the worker's filesystem.

- **Hermetic transport** (`commit cb03b8ca`) — `ssh_git` ignores the host/user `ssh_config` by passing `-F /dev/null`, so the operation is reproducible and not at the mercy of an ambient ssh config.
- **AcceptFirst pin persistence** — the chosen design is `Strict` + pinned `known_host_key` (option "B"). Building actual first-connect pin persistence remains an option for a future cycle (see *Known Issues* / deferred).

#### Option 3 — WASM `ssh` guest tool (`commit 037113c5`)

A WASM `ssh` tool with a host-function bridge, for sandboxed SSH execution. The guest crate is in `ic/tools-src/ssh/` (instantiation smoke test added, `commit 2b29f158`); the host function is registered in the bridge module (`ic/src/bridge/ssh_client.rs`, declaration alphabetized per rustfmt — `commit c4102403`). This lets a sandboxed WASM tool perform SSH through the harness without the private key ever entering the WASM linear memory.

### SSH Harness Streamlining (`lunarwing-mt-admin.sh`)

The v1.1.7 SSH provisioning had a chicken-and-egg: the staged key could only be uploaded *after* the daemon started (the SSH API is served by the gateway), and workers had to bind-mount a socket that did not yet exist. v1.1.8 closes that with a sequenced `start-tenant`:

- **`start-tenant` uploads the SSH key, bounces the daemon once, then starts workers** (`commit 1f0bcb86`). The daemon starts first (so the SSH API is up and the socket is created), the staged key is POSTed to the API and the staged copy deleted, the daemon is bounced once so `add_identity` loads the key, and **then** the workers start — so they bind-mount the now-real socket inode rather than a stale/absent one.
- **SSH readiness summary at the end of `start-tenant`** (`commit b98aac7a`) — prints the socket path, the loaded key count, and the configured hosts.
- **Warn when the loopback SSH target has no sshd** (`commit 491c5add`, `a2ff57b0`) — if `[[ssh.hosts]]` points at `127.0.0.1` but no `sshd` is listening, `start-tenant` warns rather than silently letting worker SSH/git-push fail later.
- **Auto-patch the WASM ssh-tool allowlist from `[[ssh.hosts]]`** (`commit a78a8edf`) — `patch_ssh_tool_allowlist` rewrites the WASM `ssh` tool's network allowlist to include the configured SSH hosts, so the tool is permitted out-of-the-box. Every failure path in the patcher is guarded (`commit b76ce59c`).
- **`preflight --with-wasm` extracts `ensure_tenant_wasm_toolchain`** (`commit bee17b3e`) — shared build tooling.

> **Note on the deferred root fix:** the `start-tenant` auto-bounce is a reliable *fallback*. The bigger remaining item — making `SshAgentServer::add_key` drive `add_identity` at runtime so uploaded keys are signable without any restart, for every consumer (API, web panel) — is **deferred** to a future cycle. See *Known Issues* and `docs/proposals/DEFERRED-2026-07-02-MT-ADMIN-SSH.md`.

### DarkIRC Hard-Disable

Previously the DarkIRC disabled flag was advisory: services could still be rendered and the worker still built. v1.1.8 makes the disable **fail-closed**.

- DarkIRC services are **not created** unless `--enable-darkirc` is passed to `add-tenant` / `start-tenant`.
- The darkirc binary is **not built** unless `build-darkirc` is explicitly invoked.
- Investigation and rationale: `docs/ops/DARKIRC-DISABLE-INVESTIGATION.md`.

This means DarkIRC is now opt-in by default for fresh installs. Existing tenants that previously rendered DarkIRC units are unaffected until their units are re-rendered.

### Removal of Default GitHub WASM Tool and Bundled MCP Manifests

Two fresh-install-registry changes:

- **GitHub WASM tool removed from the default registry catalog** (`commit 205bb179`). The tool is not deleted from the codebase, but it no longer appears in the registry catalog that a fresh install ships with. Operators who want it can add it back through the normal extension-install path.
- **Bundled MCP server manifests removed from the default registry catalog** (`commit 257f15c8`). Same treatment: the MCP capability is unchanged, but the fresh-install catalog no longer ships pre-bundled MCP server manifests.

Both align with the privacy-first posture (no proprietary-platform defaults) and reduce the fresh-install surface. See GOALS_1.1.8 items #2 and #3.

### Multi-Tenant Admin Enhancements

#### `add-tenant` / `add-tenants` flags (PR #114, `commit 59a7da24` + follow-ups)

Three new flags threaded through `add-tenant` and `add-tenants`:

- **`--llm-model <m>`** — writes the model into the tenant's `lunarwing.env` (`write_tenant_lunarwing_env`).
- **`--gateway-host <host>`** — sets the gateway host for the tenant.
- **`--xmpp-allow-from <cidr>`** — writes the XMPP bridge allow-from list (`write_tenant_bridge_env`), via new `build_xmpp_allow_from[_json]` helpers.

A CLI dispatch parsing smoke check was added (`commit bef6b247`) and the flags are documented in `usage()` (`commit 46bfeb79`).

#### Persistent container-runtime choice (PR #127)

`LUNARWING_CONTAINER_RUNTIME` previously had to be exported for every command. v1.1.8 persists the detected/explicit runtime choice:

- **`feat(mt-admin): persist explicit container-runtime choice`** (`commit 41f50609`) — the chosen runtime is saved to a state file so subsequent commands pick it up automatically.
- **`feat(mt-admin): persist explicit runtime choice on every command`** (`commit eaa7ffe6`) — the choice is reconciled on every invocation, not just `add-tenant`.
- **`doctor` survives runtime-less hosts** (`commit 2672f782`) and prints a clearer runtime-source line (`commit 351f5e7a`).

#### Opencode port resolution for unmigrated tenants (`commit abf8955c`)

Tenants still on the v10 port schema would not resolve opencode ports. `migrate-ports-v10-to-v11.sh` and the in-`mt-admin` migration now handle this, and `start_tenant_opencode` falls back gracefully.

### Routine Engine Improvements (carried from v1.1.7)

Three routine-engine improvements landed in the v1.1.7 cycle and are included here (the proposals and tests were finalized in this window). Full detail in `docs/proposals/ROUTINE_ENGINE_IMPROVEMENTS.md`:

1. **State-contamination prevention** — hallucinated tool-call markers (`<function=`, `<parameter=`, etc.) are detected and stripped from `state.md` and conversation output before persistence, breaking the self-reinforcing loop where a malformed LLM response was loaded as "Previous State" and mimicked on subsequent runs.
2. **Retry policy fires for all trigger types** — event- and webhook-triggered routines now actually retry (previously only cron-triggered routines retried, because there was no cron tick to pick them up). The engine `tokio::spawn`s a sleep-then-refire task independent of trigger type.
3. **`dedup_window` guardrail enforced** — the previously-defined-but-unused dedup window is now consulted in both `check_event_triggers` (message events) and `emit_system_event` (system events).

The v1.1.7-era `ROUTINE_FALLBACK_RETRY_IMPROVEMENTS.md` proposal was folded into `ROUTINE_ENGINE_IMPROVEMENTS.md` and the standalone file deleted (`commit 9da2c05b`).

### Documentation Housekeeping

- **SSH harness docs rewritten** to match the shipped 1.1.8 implementation (`commit c8dac526`), with stale `/tmp` socket-path comments corrected to the real run-dir path (`commit c05ebfbe`), the dev-mode note restored in the ops guide (`commit 8219889d`), and the mt-admin auto key-activation + allowlist patching reflected (`commit 9b083b62`). All three delivery options consolidated in `docs/architecture/SSH_DELIVERY_MECHANISMS.md` (`commit 045682b6`).
- **Build-constraints doc corrected** for the Fedora dev VM (16 threads) (`commit e38defa5`), reflected in `AGENTS.md` (`commit 5073b2be`).
- **`COMMUNITY.md`** and the README community section updated (`commits 5f00bc33`, `86b0a715`, `68e53cab`).
- **Worker-container docs** (`docs/ops/WORKER-CONTAINERS.md`) updated for opencode (`commit 36b64c78`).
- **Repo root README** — see GOALS #17; partial updates landed (`commit e2189e74`, `18ab3466`); a full v1.1.8 pass is in progress.
- **`HOWTOCHANGECONFIG.md`** added (`commit 5f24d5f3`).
- **Git hooks repaired** (`commit d59ee488`) + an install script (`scripts/install-githooks.sh`) and a `GITHOOKS_HOW_TO.md` guide (`commit 7bfcd747`). A tree-wide `cargo fmt --all` accompanied the hook repair (`commit 344f6eeb`).

---

## Bug Fixes

- **`ac5b9d6c` — don't bail on `ChannelMsg::Eof` yet.** A russh-channel handling path was treating `Eof` as fatal prematurely. Adjusted to not bail on `Eof`.
- **`cb03b8ca` — `ssh_git` hermetic transport.** `ssh_git` now ignores ambient host/user `ssh_config` via `-F /dev/null`, so git-over-SSH operations are reproducible and not influenced by an operator's local ssh config.
- **`abf8955c` — opencode ports for unmigrated (v10) tenants.** `start_tenant_opencode` and the v10→v11 migrator now resolve opencode ports for tenants that had not yet migrated.
- **`907be1c8` — opencode worker in self-heal tenant resolution.** The health/self-heal pipeline now correctly classifies and restarts opencode worker units on both systemd and OpenRC (three regression fixes in the health scripts — see *Opencode External Worker*).
- **`4a42af17` — opencode model reference format.** The baked `config/opencode.json` used a bare function name that opencode's `Model.parse` mis-parsed; fixed to the `provider/model` shape, and the `OPENCODE_MODEL` override now constructs the correct reference.
- **`cc088dfa` — opencode build-time SDK import assertion + duplicate `task_id` guard.** The build now verifies the `@opencode-ai/sdk` import resolves, and the bridge guards against double-dispatch of the same `task_id`.
- **`7e3137f9` — opencode review blockers #2–#5.** Readiness gating, honest task results, crash-safety on worker exit, and upgrade wiring for v10 tenants.
- **`0236ca51` — single-target build.** opencode's 12-target cross-compile filtered to native-only, cutting build time from ~5–15+ min to ~1–3 min.
- **`2672f782` / `351f5e7a` / `eaa7ffe6` — `mt-admin` runtime persistence.** The container-runtime choice is now persisted and reconciled on every command, `doctor` survives runtime-less hosts, and the runtime-source line is clearer.
- **`b76ce59c` — guard every failure path in `patch_ssh_tool_allowlist`.** The WASM ssh-tool allowlist patcher no longer aborts the surrounding operation if a single host entry fails to patch.
- **`a2ff57b0` — explicit return in `warn_if_sshd_unreachable`.** The warning helper now returns explicitly rather than falling through.
- **`c773a11d` — drop stray review scratch files.** Cleaned up stray review scratch files from the mt-admin SSH streamlining work; `doctor` now emits a single runtime warning.

---

## Some of the new documentation changes

- `docs/proposals/SSH_HARNESS_DELIVERY_OPTIONS.md` — the three SSH delivery options survey.
- `docs/proposals/SSH_HARNESS_OPTION_2_3_IMPLEMENTATION.md` — implementation plan for Options 2 and 3.
- `docs/architecture/SSH_DELIVERY_MECHANISMS.md` — as-built consolidation of all three options.
- `docs/architecture/SSH_AGENT_HARNESS.md` — the harness design (updated).
- `docs/ops/SSH-HARNESS-SETUP.md` — operator setup guide (Strict + pinned known_host_key recommendation, `commit 73bc5090`).
- `docs/proposals/DEFERRED-2026-07-02-MT-ADMIN-SSH.md` — deferred SSH-harness and mt-admin items.
- `docs/proposals/DEFERRED-2026-07-02-OPENCODE-EXTERNAL-WORKER.md` — opencode live-validation log + deferred follow-ups.
- `docs/proposals/OPENCODE-WORKER-SINGLE-TARGET-BUILD.md` — single-target build rationale.
- `docs/proposals/CARGO_TESTS_FIX.md` — test-fix status (updated this cycle).
- `docs/proposals/LLM-PROVIDER-REMOVAL.md` — forward-looking plan for v1.1.9.
- `docs/proposals/LLM_HOT_RELOAD_ALTERNATIVE.md` — hot-reload alternatives survey.
- `docs/ops/DARKIRC-DISABLE-INVESTIGATION.md` — DarkIRC hard-disable investigation.
- `docs/ops/ROADMAP_2026.md` — updated for accuracy across the cycle.
- `docs/ops/GOALS_1.1.8.md` — the v1.1.8 pre-release checklist.

---

## Known Issues (not a complete list — see `docs/bugs` and `docs/proposals` for more)

### Resolved since v1.1.7

- **No third external worker container — resolved.** The opencode external worker (`opencode4lunarwing/`) is now available alongside nanocode and pebble, with full `mt-admin` lifecycle and live-validated end-to-end on tenant `octest`.
- **SSH harness provisioning chicken-and-egg — resolved (with a deferred root fix).** `start-tenant` now uploads the staged key, bounces the daemon once to load it, and starts workers after the socket is real. The deferred root fix (runtime `add_identity` so no restart is needed at all) remains open — see *New in v1.1.8*.
- **DarkIRC services rendered despite the disabled flag — resolved.** DarkIRC is now hard-disabled: services are not created unless `--enable-darkirc` is set, and the binary is not built unless `build-darkirc` is invoked.
- **Worker SSH agent socket denied by SELinux on Fedora — resolved, fleet-wide.** All worker launch sites now mount the SSH agent socket with a `:z` SELinux label.
- **opencode worker misclassified by self-heal — resolved.** The health/self-heal pipeline now correctly handles `lunarwing-opencode-*` units on systemd and OpenRC.

### New in v1.1.8

- **SSH uploaded keys require a daemon restart to become signable.** `SshAgentServer::add_key` does not drive `add_identity` at runtime. The `start-tenant` auto-bounce is a reliable fallback, but the API/web-panel upload path still needs a restart for the key to take effect. This is the biggest remaining SSH-harness item; tracked in `docs/proposals/DEFERRED-2026-07-02-MT-ADMIN-SSH.md`.
- **Production `AuditLogger` is not yet implemented.** SSH events still go to `NullAuditLogger`. The "auditable access" goal needs a persistent implementation.
- **`DELETE /hosts/{host}` orphans the key secret.** `ssh_key_<host>` stays in the secrets store after the host is removed. Manual cleanup is required until this is fixed.
- **RSA key support is blocked.** Needs a `russh` upgrade (0.45 signs ssh-rsa with SHA-1). Ed25519 and ECDSA are supported.
- **opencode telemetry log noise.** PostHog emits `ConnectionRefused` / `PostHogFetchNetworkError` lines under rootless network isolation. Cosmetic only; tasks complete normally.
- **opencode workspace file ownership under rootless userns — deferred by design.** Workers run as non-root `USER` directives; files written to `/workspace` appear owned by a host subuid. The current `chmod 777` workaround is functional; the UID-pinning + `keep-id:uid=` hardening pass is deferred (touches all three worker Dockerfiles).
- **`ssh_git` ref=null serialization.** When the agent omits the `ref` parameter, the tool-call serialization layer may convert the absent value to the literal string `"null"`, causing `git clone --branch null` to fail. The Rust tool code itself handles `None` correctly; the bug is in the serialization layer. Workaround: always pass `ref` explicitly (e.g. `ref: main`). See `docs/bugs/BUG-ssh-git-null-ref-serialization.md`.
- **`ssh_git` clone fails on bare repos with mismatched HEAD.** Bare repos initialized with `git init --bare` default HEAD to `refs/heads/master`; if the only branch is `main`, cloning without `--branch` fails or produces an empty checkout. Workaround: normalize bare repos with `git symbolic-ref HEAD refs/heads/main`, or always pass `ref` explicitly. See `docs/bugs/BUG-ssh-git-bare-repo-head-mismatch.md`.
- **Interactive onboarding walkthrough is unbuilt.** The guided setup mode for fresh operators remains a stated goal; runtime persistence (shipped this cycle) removes one of its biggest hazards, but the walkthrough itself is not yet built.
- **Kawarimi import script does not support `--with-opencode`.** `import-tenant.sh` exposes `--with-nanocode` and `--with-pebble` flags for building external worker images during migration, but does not expose `--with-opencode`. The opencode worker image must be built separately via `build-opencode-worker` after the import completes. Additionally, the script does not accept `--with-wasm` as a flag (it hardcodes `--with-wasm` internally — always on), which can confuse operators expecting parity with `build-tenant`'s flag surface.
- **opencode worker does not expand `~` in workspace paths.** When the agent creates files using `~/`-relative paths inside the opencode container, the shell does not expand the tilde — a literal `~` directory is created under `/workspace` instead. This affects any worker task that writes to `$HOME`-relative paths. The workspace root is `/workspace`, not `$HOME`, so `~` resolution doesn't apply. Discovered during live validation on tenant `orca` (Gentoo/OpenRC, rootless Podman). The same pattern likely affects nanocode and pebble workers since they share the workspace-mount model.
- **Agent loop blocks on synchronous (`wait=true`) external worker jobs.** When the agent dispatches a job to an external worker (opencode, nanocode, pebble) via `create_job` with `wait=true`, the entire conversational turn blocks until the job completes. A multi-minute worker task (e.g. a 4.5-minute repo analysis) leaves the agent idle — it cannot perform other actions in parallel or service other conversations. The existing `wait=false` path exists but offers no way to poll for completion mid-conversation without losing the turn. The fix is an agent-loop / orchestrator-level change: an async job registry that allows the agent to fire off worker jobs and check back on them later in the same or subsequent turns, enabling parallel worker dispatch and non-blocking tool execution.

### Carried forward (unchanged in v1.1.8)

- **DarkIRC PM length limitation.** DarkFi's P2P event-graph metering caps and silently drops multi-event PM bursts; the `DARKIRC_PRIVMSG_INTERVAL` rate limiter (default 7 s) mitigates but does not fully resolve. Long agent responses over DarkIRC may be truncated, out-of-order, or incomplete. (Note: with DarkIRC now hard-disabled by default, this only affects tenants that explicitly opt in.) (Carried from v1.1.6.)
- **XMPP inbound file transfer — live e2e validation still pending.** The full receive pipeline is unit-tested and the bridge builds in release, but has not been exercised end-to-end against a real server. See `docs/ops/XMPP_KNOWN_ISSUES.md` and `docs/architecture/XMPP_FILE_TRANSFERS.md`. (Carried since v1.1.2.)
- **Inbound XMPP downloads have no SSRF guard.** The client fetches sender-supplied OOB / `aesgcm://` URLs without blocking private/loopback/metadata IPs; deployments rely on the network boundary and the `ALLOW_PRIVATE_IPS` model. (Carried.)
- **Rootless container supervision gap (crash-recovery latency).** On rootless Podman, per-tenant containers are health-monitored but not parent-supervised, so a crash after `start()` returns is only recovered by the next 15-minute self-heal sweep (~30 min worst case) rather than in seconds. The `podman wait` babysitter proposed in v1.1.6 remains deferred. (Carried.)
- **WeeChat health-glob flap.** An optional/stopped weechat backend matches the `lunarwing-*` health-discovery glob and can report critical / flap / escalate. Workaround: only render/enable weechat units for tenants that use it. (Carried.)
- **`podman save | load` image distribution is slow.** Seeding worker images into each tenant's isolated rootless store takes minutes per tenant per image; a shared read-only `additionalimagestore` remains a future optimization. (Carried.)
- **`/api/logs/download` has no UI button.** The endpoint exists as a backend API; the gateway UI "download logs" button has not been added. (Carried since v1.1.2.)
- **Multica bridge remains pre-release/experimental.** Requires further refinements despite technically working. (Carried.)
- **Kawarimi cross-machine migration is PostgreSQL-only.** libSQL tenants are refused by the machine-migration tooling. (Carried from v1.1.5.)
- **Machine migration is a cutover with per-tenant downtime.** (Carried from v1.1.5.)
- **Hardcoded `DEFAULT_TENSORZERO_URL` (192.168.1.157).** Override via `LUNARWING_MT_TENSORZERO_URL`; the nanocode baseURL is separately configurable per tenant. (Carried from v1.1.6, tracked as L2.)
- **Six non-critical cargo tests fail (deferred, documented).** Tracked in `docs/proposals/CARGO_TESTS_FIX.md`. All other tests pass — the v1.1.8 run is **4087 lib tests green, 0 failed, 4 ignored**, plus the remaining integration binaries and doctests. The six deferred failures are: the **4 `multi_tenant_system_prompt` tests** (`tests/multi_tenant_system_prompt.rs`), which fail due to a known architectural issue — the agent loop uses a single shared workspace, so per-user identity files (`IDENTITY.md`, `SOUL.md`, `USER.md`) seeded under per-user IDs are invisible (fixing requires plumbing per-user workspaces through the agent loop, out of scope for a test-fix pass); and the **2 `e2e_advanced_traces` bootstrap-greeting tests** (`bootstrap_greeting_fires`, `bootstrap_onboarding_clears`), which fail because the bootstrap-greeting broadcast mechanism does not fire under the test harness. None of the six affect the v1.1.8 feature surface. (Updated this cycle; the three previously-stale `lib` test failures — `registry::embedded::tests::test_load_embedded_parses`, `cli::tests::test_help_output`, `cli::tests::test_long_help_output` — were fixed by updating the github-tool sentinel to `tools/ssh` and accepting the rebranded CLI snapshots.)

---

## Upgrade Notes

1. **No new database *schema* migrations.** v1.1.8 adds no SQL schema changes; existing migrations run automatically on first startup. PostgreSQL 15+ remains required, and **back up your database before upgrading** as a matter of course.
2. **Ports registry auto-migrates v10 → v11.** Any `lunarwing-mt-admin.sh` invocation runs `ports_migrate_v11()` automatically. The standalone `ic/scripts/migrate-ports-v10-to-v11.sh` can also be run explicitly (it backs up, validates, is idempotent, and refuses to run on a registry below v10). Existing tenants' port numbers are unchanged (the migration only adds the `opencode_wss` / `opencode_health` slots if they are absent).
3. **To add the opencode worker to an existing tenant.** Run `migrate-ports-v10-to-v11.sh` (or any mt-admin command, which auto-migrates), then `build-opencode-worker` and `configure-opencode <name>` (optionally `--opencode-model` / `--opencode-base-url`), then `start-tenant <name> --with-opencode` (or re-render units). The image is synced into the tenant's rootless store via `podman save | load` automatically.
4. **DarkIRC is now opt-in.** Fresh tenants no longer render DarkIRC services. Existing tenants are unaffected until their units are re-rendered. To explicitly enable DarkIRC on a tenant, pass `--enable-darkirc` to `add-tenant` / `start-tenant` and run `build-darkirc`.
5. **SSH harness: existing tenants.** If you adopted the SSH harness in v1.1.7, the new `start-tenant` sequencing (upload key → bounce daemon → start workers) applies automatically on your next `start-tenant`. The built-in `ssh` tool, the `ssh_git` tool, and the WASM `ssh` tool are new; the WASM ssh-tool allowlist is auto-patched from `[[ssh.hosts]]` on `start-tenant`.
6. **GitHub WASM tool and bundled MCP manifests no longer in the default registry.** Fresh installs no longer ship these in the catalog. They are not deleted from the codebase; reinstall through the normal extension path if needed.
7. **Container-runtime choice is now persisted.** If you previously exported `LUNARWING_CONTAINER_RUNTIME` for every command, you only need to set it once now (or let `mt-admin` detect it). The choice is saved to a state file and reconciled on every invocation.

---

## Release Cadence

**A brief note about release cadence.** LunarWing abides by a release cadence to organize `feature`- and `polish`-focused releases. For details see `docs/ops/RELEASE_CADENCE.md`. Occasionally, exceptions may be made, but the goal is to stay within this paradigm.

## Testing

### In accordance with developer guidelines, a testing period precedes each release.

##### Once evaluation begins in earnest, no new changes besides urgent fixes will be accepted into staging during the evaluation period.

#### What was run this cycle

- **Library unit tests:** `cargo test --all-features --lib` — **4087 passed, 0 failed, 4 ignored** (Fedora dev host, Rust 1.96.1 stable). Includes the three formerly-stale failures fixed this cycle (github→ssh registry sentinel; rebranded CLI snapshots accepted).
- **Integration test binaries + doctests:** `cargo test --all-features --no-fail-fast` — all pass except the two known-deferred binaries (`e2e_advanced_traces`, `multi_tenant_system_prompt`), documented above under *Known Issues*.
- **Opencode external worker:** live end-to-end validated on tenant `octest` (rootless Podman, systemd) — full `add-tenant` → `build-tenant --with-opencode` → `start-tenant` lifecycle, image sync via `podman save | load`, orchestrator WebSocket handshake, gateway dispatch (`POST /api/chat/send` → `create_job mode:"opencode"`), result returned via SSE. See `docs/proposals/DEFERRED-2026-07-02-OPENCODE-EXTERNAL-WORKER.md`.

---
