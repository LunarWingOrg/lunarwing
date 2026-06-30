# DRAFT Release Notes for LunarWing v1.1.7 — Codename `Takamaru (タカ丸)`

**Information in this is very out of date now**

**Release Date:** To Be Determined

> Codename *Takamaru* (タカ丸) — the messenger hawk of Sunagakure (鷹, *Taka* = "hawk"). In shinobi folklore, hawks are the trusted long-distance couriers between hidden villages, crossing miles of hostile territory no other messenger could safely reach. With the release of 1.1.7, the **Agent SSH Harness** is introduced. **The Agent SSH Harness** makes a trusted, off-disk courier of its own: a per-tenant `ssh-agent` socket carries authentication between isolated worker containers and the host, vaults the secret material in the encrypted store, and never lets the message — the private key — rest where an enemy could read it. Furthermore, within v1.1.7 introduces the first few of many, many major improvements to come for the XMPP communication bridge within LunarWing. As one of LunarWing's greatest flagship features, it was about time that it started to get some serious developer attention. From the sand village... to your federated self-hosted prosody servers... all the way to your phone or tablet... this bird is fast...

The rest of the release rides behind this ultrafast bird. Some of the other changes include port-registry polish, Tesseract OCR sidecar hardening, improvements to LunarVision, and even some new scripts to help developers do more.

## Overview

Per the release cadence (`docs/ops/RELEASE_CADENCE.md`), **odd-numbered releases focus on bug fixes, security improvements, and polishing**. v1.1.7 is a polish/bug-fix release, and the bulk of the cycle was spent hardening, reconciling, and cleaning up after the v1.1.6 feature spurt (the External Worker Enhancement suite, DarkIRC multi-tenant hardening, and the v8 ports schema). However, an exception in the release cadence has been made for 1.1.7 and it does introduce a brand new feature...

The single new feature introduced, deliberately breaking the otherwise pure-polish posture, is the **Agent SSH Harness**: a centralized, per-tenant SSH bridge that keeps worker-side SSH keys off disk, in the encrypted secrets store (AES-256-GCM), and exposes them to worker containers through a per-tenant `ssh-agent` Unix socket. It lets a worker container authenticate to a host (or to itself, self-referentially) over SSH without ever holding the private key material. The harness has been **live-validated end-to-end on both systemd and OpenRC hosts** and has undergone extensive testing: secrets store → agent socket → worker container → SSH → host. The **Agent SSH Harness** is enabled by default for new tenants; to disable it, leave the `[ssh]` section empty in `config.toml`. It can also be enabled on existing tenants which do not have the SSH harness.

A second focus is **port-registry schema housekeeping**: the v8 schema left an unnamed extended slot unused, and v9 dedicates it as the per-tenant **LunarVision / OCR sidecar API port** (`vision_service`) so the vision service can be registry-allocated and reached by WASM tools. Furthermore, **v10 adds a second dedicated port** (`vision_health`) for the host self-heal pipeline to probe `/health` independently of OCR traffic.

A third focus is the **LunarVision (OCR / vision-language) sidecar**: migrated to rootless Podman with a real `HEALTHCHECK`, gained disk-backed cache persistence, an API-versioned HTTP surface with an OpenAPI spec, a wired-in health endpoint, and a Prometheus metrics endpoint scaffold. The companion `vision-analyze` WASM tool was rewritten from scratch and re-added to the tool registry.

A fourth focus on the routine system.

Additional work includes **dev-mode operator helper scripts** (sandbox config + tool permissions tuners, with prominent "not for end users" warnings), a **`configure-ssh` subcommand** wired into `lunarwing-mt-admin.sh` (and SSH provisioning folded into `add-tenant`), and several other minor improvements across the board.

This release **does not** add database schema changes, but a small non-destructive data migration (which is done automatically) will be necessary in order to support the new Agent SSH Harness.

---

## Changes

### XMPP Security Improvements

The XMPP channel with OMEMO-aware inbound handling remains stable.

### XMPP File Transfers

Changes to XMPP File Transfers

### Agent SSH Harness — Centralized Per-Tenant SSH for Workers

The flagship new feature. A self-contained SSH bridge that lets worker containers authenticate to a host over SSH **without the private key ever touching disk inside the container** (or on the host outside the encrypted secrets store).

Full plan: `docs/proposals/AGENT_SSH_DEV_HARNESS.md`.

In the future, there are plans to further extend the Agent SSH Harness so it is not simply limited to workers.

#### Security Model

- **Non-sensitive host configuration** (`host`, `port`, `user`, `key_type`, host-key verification mode, timeouts, keepalives) lives in `config.toml` under `[ssh]` / `[[ssh.hosts]]`, parsed by `ic/src/config/ssh.rs::SshConfig`.
- **Sensitive material (private keys, optional passphrases)** lives only in the **encrypted secrets store** (AES-256-GCM), addressed by a `ssh_key_<sanitized_host>` secret name. It is decrypted only when the agent server loads it, held in a `Zeroizing<Vec<u8>>` / `SecretString`, and never persisted to disk.
- **Keys are served to workers over a per-tenant `ssh-agent` Unix socket.** Workers set `SSH_AUTH_SOCK` to the bind-mounted socket path and use a standard SSH client / `ssh2` to authenticate; the agent signs challenges in memory. Key material never leaves the agent's address space.
- **Host-key verification is fail-closed.** Two modes via `HostKeyMode`: `Strict` (default — unknown hosts rejected, must be explicitly added) and `AcceptFirst` (accept on first connect, pin thereafter). There is deliberately **no `AcceptAny` mode** — it would be insecure.
- **Audit logging** is first-class: an `AuditLogger` trait records `HostAdded/Removed`, `ConnectionAttempt`, `CommandExecuted`, `KeyRotated`, `HostKeyChanged`, `AgentStarted/Stopped` events. A `NullAuditLogger` is provided for tests.

#### Components

- `ic/src/bridge/ssh.rs` — `SSHBridge` core: per-tenant host map, secrets-store access, audit logger, agent-server lifecycle (`validate()` / `start_agent_server()` / `stop_agent_server()`). `SSHCredentials` wraps `Zeroizing<Vec<u8>>` key data + `Option<SecretString>` passphrase.
- `ic/src/bridge/ssh_agent.rs` — `SshAgentServer` speaking the `russh-keys` agent protocol over a `UnixListener`. Keys held as `Arc<KeyPair>` behind a `tokio::Mutex`. `Drop` aborts the listener task and best-effort clears keys via `try_lock` (avoids panicking if `Drop` runs while a lock is held).
- `ic/src/bridge/ssh_secrets.rs` — `SshSecretsManager`: loads keys from the encrypted store, validates format (OpenSSH/Ed25519/ECDSA/RSA), supports passphrase-protected keys, supports rotation.
- `ic/src/bridge/ssh_hostkeys.rs` — host-key verification helpers.
- `ic/src/bridge/ssh_api.rs` — gateway HTTP endpoints for SSH host + key management (`POST /hosts`, `GET/DELETE /hosts/{host}`, `POST/DELETE /hosts/{host}/key`, `GET /hosts/{host}/key/status`, `GET /agent/status`, `GET /agent/keys`). The `lunarwing-mt-admin.sh` upload path uses this API to ingest the staged tenant key after the daemon starts.

#### Socket Path — PrivateTmp-safe

The agent socket lives at `<tenant_home>/lunarwing/run/ssh-agent.sock`, **not** `/tmp`. The daemon runs with `PrivateTmp=true`, so a `/tmp` socket would be invisible to rootless Podman containers and couldn't be bind-mounted into workers. The `mt-admin` script predicts this path for the bind-mount (`-v <socket>:/tmp/ssh-agent.sock -e SSH_AUTH_SOCK=/tmp/ssh-agent.sock` on the imperative path, and `Volume=`/`Environment=` lines in the rendered Quadlet).

#### Wiring into AppBuilder

`Config::build()` now reads the actual `[ssh]` section from `config.toml` (commit `eae770f1`) so the bridge initializes from real config rather than always-defaults. In `AppBuilder` (`ic/src/app.rs`), the SSH bridge is constructed when `config.ssh.hosts` is non-empty: tenant UUID + tenant name are derived, the `SSHBridge` is created against the secrets store, `validate()` is called (warnings logged, not fatal), and `start_agent_server()` is invoked so `SSH_AUTH_SOCK` is available to workers by the time the gateway serves traffic. The bridge handle is stored on `App` as `pub ssh_bridge: Option<Arc<RwLock<SSHBridge>>>` for the `ssh_api` router to mount.

#### Multi-Tenant Admin — `configure-ssh` + Provisioning

`ic/scripts/lunarwing-mt-admin.sh` gained:

- **`ensure_ssh_config <name> [<host> <user>]`** — appends an idempotent `[[ssh.hosts]]` block to the tenant's `config.toml` (defaults to `127.0.0.1` / `<tenant_name>` for self-referential worker-to-host access). Append-only — never overwrites existing config.
- **`provision_tenant_ssh_key <name> [<host> <user>]`** — generates an ed25519 key pair under `~<tenant>/.ssh/id_ed25519_lunarwing`, adds the public key to the tenant's `authorized_keys`, and stages the private key `0600` in the tenant's env dir for upload after the daemon starts. Idempotent.
- **`upload_tenant_ssh_key <name>`** — waits for the gateway to be reachable on the tenant HTTP port, then `POST`s the staged key to the SSH API so it lands in the secrets store, and deletes the staged copy so no key material persists on disk. Init-system-agnostic — pure HTTP, works on both systemd and OpenRC.
- **`add-tenant` now calls `ensure_ssh_config` + `provision_tenant_ssh_key` during provisioning**, prior to uploading the tenant SSH key **after** `start-tenant` (chicken-and-egg: the API server must be up to accept the upload). Existing tenants: `configure-ssh <name> [--host <host>] [--user <user>]`.

#### OpenRC + systemd

SSH provisioning was implemented and **live-validated on two seperate testing environments** — systemd (`tiggie`) and OpenRC (`ninejane`). The end-to-end path `secrets store → agent socket → worker container → SSH → host` is confirmed working (commit `0961ef25`).

#### Regression Fixes Encountered While Wiring

Several latent issues surfaced and were fixed during integration (see *Bug Fixes*):
- `skip_serializing` on `auth_token` in `ic/src/settings.rs` and `ic/src/config/sandbox.rs` was **removed** — it caused severe auth failures and is redundant with the `secrecy` redaction guarantees.
- `russh_keys::format::decode_secret_key` → `russh_keys::decode_secret_key` (API drift).
- `crate::secrets::types::SecretError` → `crate::secrets::SecretError` (module path).
- `socket_path` was moved twice in `ssh_agent.rs` (closure capture).
- An `Arc`-copy issue in `ssh_agent.rs`.
- The `blocking_lock()` `Drop` impl in `ssh_agent.rs` was retried several times before settling on the `try_lock`-based best-effort clear that won't panic if `Drop` fires mid-lock.
- A **data migration** was needed in the secrets store due to the SSH-related schema/key changes.

### v9 + v10 Ports Schema — Dedicated LunarVision / OCR Sidecar Ports

The v8 schema (shipped in v1.1.6) named `extended_ports.reserved_3` and `reserved_4` as `nanocode_health` and `pebble_health`, but left `reserved_5`..`reserved_9` unnamed. The OCR/vision sidecar was reachable only via a hardcoded URL, so it couldn't be registry-allocated per tenant and had no direct host-side `/health` probe path.

**v9** dedicates `extended_ports.reserved_5 → vision_service` (= `extended_base + 5`). Each tenant's sidecar container is bound `127.0.0.1:<vision_service>`, and the in-tree `vision-analyze` WASM tool reaches it via `$VISION_SERVICE_URL`.

**v10** dedicates a **separate** `extended_ports.reserved_6 → vision_health` (= `extended_base + 6`) so the host self-heal pipeline can probe `/health` independently of OCR traffic. The vision sidecar listens on two internal ports: `8088` (OCR_PORT — main API) and `8089` (OCR_HEALTH_PORT — `/health` only). Each tenant maps `vision_service (host) → 8088 (container)` and `vision_health (host) → 8089 (container)`.

- **Standalone migrations** — `ic/scripts/migrate-ports-v9.sh` and `ic/scripts/migrate-ports-v10.sh`. Both are idempotent (no-op if already at the target version or newer), refuse to run on a registry below their prerequisite (v9 refuses below v8, v10 refuses below v9), back up first, validate port-uniqueness post-migration, and swap atomically. Falls back to `extended_base + N` when the reserved slot is missing (e.g., a tenant block predating the reserved range).
- **`ports_migrate_v9()` + `ports_migrate_v10()`** wired into `lunarwing-mt-admin.sh` (auto-runs on any mt-admin invocation), mirroring the v8 pattern.
- **`ports_allocate`** now emits both the `vision_service` and `vision_health` slots for fresh tenants.

This closes the v8-followup the v1.1.6 notes flagged as deferred.

### LunarVision (OCR / Vision-Language) Sidecar Hardening & Polish

Substantial work on `projects/ocr-sidecar/`:

- **Podman rootless migration** (commit `309308a4`). Init templates (systemd + OpenRC) switched from `docker` to `podman` (`docker.service` → `podman.service`, `docker-compose` → `podman compose`). The systemd unit was rebuilt for rootless (`WantedBy=default.target`, user-unit install path), and the OpenRC `depend()` now needs `podman`. A new OCI-standard `compose.yaml` (podman-compose default filename) replaces `docker-compose.yml` and passes through the full env-var set incl. `VL_TIMEOUT_SECS`, `ENABLE_PROMETHEUS`, and a named volume for cache persistence.
- **`HEALTHCHECK` added to the Dockerfile** (`curl /health`, 30 s interval, 3 retries) so the container self-reports health regardless of orchestration method.
- **Cache persistence (disk-backed)** — analysis results cached to a named volume so restarts don't lose the cache. The Prometheus metrics endpoint scaffold was added alongside it (further instrumentation tracked for a later release).
- **API versioning + OpenAPI spec** — the HTTP surface is now versioned and exposes an OpenAPI document. Healthcheck wiring was completed alongside.
- **Fail-fast design** — the `vision-analyze` WASM tool makes a single HTTP request with no retry; retries belong in the host/agent layer, not in the WASM sandbox (which has no threading or sleep primitives).
- **Self-heal alignment** — the host-side init-template names were reconciled to `ocr-sidecar` so the self-heal pipeline discovers the right unit names (commit `eff1f541`).
- **Dockerfile / `.dockerignore` adjustments** + `libssl` added to the image (commits `20cdad97`, `ad0e394f`).

### `vision-analyze` WASM Tool — Rewrite + Re-registration

The `vision-analyze` WASM tool (`ic/tools-src/vision-analyze/`) was **rewritten from scratch** (commit `3fa0d629`) and a `vision-analyze.tools` manifest added so it registers with the rest of the WASM toolset. The earlier in-registry copy was removed mid-cycle as unviable and is now replaced by the rewrite. The tool-registry path and the mt-admin WASM setup were re-added in lockstep.

### Routine changes

Summarize routine changes here.

### Dev-Mode Operator Helper Scripts — Sandbox Config + Tool Permissions

Two operator tuning scripts were added under `ic/scripts/`:
- **`set-sandbox-config.sh`** — upserts agent sandbox settings (`sandbox_enabled`, `sandbox_policy`, `sandbox_timeout_secs`, `sandbox_image`) into the tenant's `settings` table inside `lunarwing-pg-<tenant>` via `sudo` → `podman exec … psql`. Honors `--dry-run`. SQL values are server-side `to_jsonb()`-encoded; bash-side escaping is kept minimal.
- **`set-tool-permissions.sh`** — tunes per-tool permission tiers.

Both carry a **prominent header warning: "THIS IS A DEV TOOL SCRIPT. NORMAL USERS HAVE NO REASON TO EVER RUN THIS SCRIPT."** They are operator/dev conveniences for shaking out configurations against a running tenant, not part of the supported onboarding path. For users looking for something similar to what these dev tool scripts do, please check out the nanocode worker, as you can likely get something that can most likely satisfy your desires... safely...

### `lunarwing-mt-admin.sh` — SSH Provisioning Folded Into `add-tenant`

In addition to the new `configure-ssh` subcommand (above), `add-tenant` now invokes `ensure_ssh_config` + `provision_tenant_ssh_key` during provisioning so a fresh tenant comes up with the SSH harness pre-wired. A helper function was added to fix in-place upgrades for existing nanocode, pebble, and vision tenants (commit `ff4fadec`).

### Shell Tool — `~/.ssh` Removed from `DANGEROUS_PATTERNS`

`ic/src/tools/builtin/shell.rs::DANGEROUS_PATTERNS` previously blocked any command containing the literal `~/.ssh` substring. That blocked the SSH harness use case (workers legitimately need to read `~/.ssh/known_hosts`, arrange per-user SSH config, etc.). The pattern was removed (commit `a789983c`); `id_rsa`, `/etc/passwd`, `/etc/shadow`, `.bash_history`, `sudo `, ` | sh`, `eval `, `$(curl`, `$(wget`, and the `NEVER_AUTO_APPROVE_PATTERNS` set are unchanged. This is security-relevant — operators who relied on `~/.ssh` being a blocked pattern should re-tune their tool-tier policy.

### LLM Timeout Variable Adjustments

Several LLM-related timeout knobs in the agent and config layers were adjusted for consistency across `ic/src/agent/dispatcher.rs`, `ic/src/config/agent.rs`, `ic/src/config/llm.rs`, and `ic/src/settings.rs` (commit `0d642157`). No behavioral default flips beyond internal alignment.

### Documentation Housekeeping & IronClaw → LunarWing Rename Sweep

- **Reconciled and archived stale documentation** — three stale ops tracking files archived to `docs/ops/history/`; the `docs/DOCS_AUDIT.md`, `docs/DOCS_AUDIT_GLM.md`, `docs/DOCS_REORG_CHECKLIST.md`, `docs/KUMOGAKURE-DOC-REVIEW.md`, `docs/KUMOGAKURE-POST-1.1.6-REVIEW`, and `docs/OUTSIDE-DOCS-DOC-AUDIT.md` leftovers were deleted after their action items were folded into the living tree.
- **Bug-tracker renames** — `BUG-WEECHAT-WARNINGS.md` → `BUG-FIXED-WEECHAT-WARNINGS.md`, `BUG-LAPSE.md` → `BUG-FIXED-LAPSE.md`, `BUG-workspace-concurrency-fixes-v1.1.0.md` → `BUG-FIXED-workspace-concurrency-fixes-v1.1.0.md` (closed-bug naming convention).
- **IronClaw → LunarWing renames** in `FEATURE_PARITY.md`, the GitHub tool docs, the XMPP channel docs, XMPP test docs, the e2e tests, and the OCR sidecar docs. The WeeChat channel/adapter and Gotify tool renames remain deliberately deferred to a later polish cycle.
- **`docs/ops/ROADMAP_2026.MD`** updated to reflect current accuracy (commit `03e17258`).
- **`docs/ops/GOALS_1.1.7.md`** — the v1.1.7 pre-release checklist, created and iterated.
- **Plans under `docs/plans/`** swept/removed (`rm rf plans in docs`); the working plan moved to a tracked `docs/proposals/` proposal.

---

## Bug Fixes

- **`auth_token` had `#[serde(skip_serializing)]` applied in `ic/src/settings.rs` and `ic/src/config/sandbox.rs`.** It caused severe authentication failures and was redundant with the `secrecy::SecretString` `Debug`-redaction guarantees anyway. Removed (commit `b3fdf105`).
- **`russh_keys::format::decode_secret_key` no longer exists.** Updated call sites to `russh_keys::decode_secret_key` (API drift in `russh-keys`).
- **`crate::secrets::types::SecretError` path moved.** Updated to `crate::secrets::SecretError` (module restructure).
- **`socket_path` moved twice in `ssh_agent.rs`.** A closure captured and moved the path that was also used later in the same scope. Fixed.
- **`Arc`-copy issue in `ssh_agent.rs`.** Key-pair `Arc` sharing across the listener task and the outer server was corrected.
- **`SSHBridge::blocking_lock()` `Drop` impl could panic.** The `Drop` impl for `SshAgentServer` originally used `blocking_lock()`, which panics if called while the mutex is held (e.g., if `Drop` runs inside an async context that already holds the lock). Replaced with a best-effort `try_lock` clear. This was the third or so attempt at the fix; the `try_lock`-based version is the keeper.
- **Port migration v8 → v9 logic had a bug.** The standalone `migrate-ports-v9.sh` and the in-`mt-admin` path were corrected (commit `39e6732b`).
- **WASM build broken mid-cycle.** Fixed after the tool-registry re-add and the `vision-analyze` rewrite (commit `eaf2fdc6`).
- **Routing bug in the sidecar / general path.** Fixed (commit `258a674f`).
- **mt-admin was mis-provisioning on upgrades for nanocode, pebble, vision.** A helper function was added to fix in-place upgrades for those three worker types (commit `ff4fadec`).

---

## Some of the new documentation changes

- `docs/proposals/AGENT_SSH_DEV_HARNESS.md` — the Agent SSH Harness proposal (design note; can be expanded post-release).
- `projects/ocr-sidecar/DOCUMENTATION.md`, `projects/ocr-sidecar/PODMAN_DEPLOYMENT.md`, `projects/ocr-sidecar/README.md` — updated to reflect the Podman rootless migration and `compose.yaml` rename.
- `BUG-*.md` → `BUG-FIXED-*.md` renames in `docs/bugs/` to mark resolved bugs in the tracker's naming convention.
- Archived/stale ops tracking files moved to `docs/ops/history/`.

---

## Known Issues (not a complete list — see `docs/bugs` and `docs/proposals` for more)

### Resolved since v1.1.6

- **No dedicated per-tenant OCR/vision sidecar ports — resolved.** Closed by the v9 ports schema (`vision_service` at `extended_base + 5`) and v10 (`vision_health` at `extended_base + 6`).
- **`vision-analyze` WASM tool was unviable / removed from registry — resolved.** Replaced by a from-scratch rewrite that is re-registered with the rest of the WASM toolset.
- **OCR sidecar had no self-reported health — resolved.** The Dockerfile `HEALTHCHECK` + the rootless-Podman init-template alignment give the self-heal pipeline a direct probe path.
- **No general SSH path for worker containers — resolved.** The Agent SSH Harness provides a centralized, secrets-store-backed, per-tenant `ssh-agent` socket. Live-validated on both systemd and OpenRC.
- **SSH harness provisioning has a chicken-and-egg with the daemon start.** `provision_tenant_ssh_key` stages the private key on disk `0600` for upload to the secrets store **after** the daemon comes up (the SSH API is served by the gateway). `upload_tenant_ssh_key` deletes the staged copy after a successful ingest. If the gateway isn't reachable within ~30 s, the staged key is left on disk and a warning is logged — re-run `configure-ssh <name>` to retry the upload. The staged copy is tenant-owned and `0600`, but it is the only window in which SSH private-key material exists on disk.

### New in v1.1.7

- **SSH bridge is constructed only when `[ssh] hosts` is non-empty.** An empty `[ssh]` section silently skips the bridge (no agent socket is created). This is intentional but worth knowing: workers that expect `SSH_AUTH_SOCK` will find it unset on tenants with no SSH host configured.
- **ssh_agent server `Drop` is best-effort, not lock-guaranteed.** If `Drop` runs while another task holds the key mutex, the in-memory keys are not synchronously cleared. The keys' `Zeroizing` wrappers still clear them when the mutex is released, so this is a timing nuance rather than a leak.
- **SSH harness data migration is one-way.** The secrets-store migration driven by the SSH schema changes is forward-only; there is no automatic rollback to the pre-SSH secrets layout. Take a secrets-store backup before adopting the harness on an existing tenant.
- **XMPP File transfer note** - Although agents can recieve media files over XMPP, there is no way currently for the media file to immediately be viewed via LunarVision. This will be remedied in a future release.

### Carried forward (unchanged in v1.1.7)

- **DarkIRC PM length limitation.** DarkFi's P2P event-graph metering caps and silently drops multi-event PM bursts; the `DARKIRC_PRIVMSG_INTERVAL` rate limiter (default 7 s) mitigates but doesn't fully resolve. Long agent responses over DarkIRC may be truncated, out-of-order, or incomplete. Workaround: ask for short responses, chunk differently, or use web UI / XMPP / WeeChat / Gotify for detailed output. (Carried from v1.1.6.)
- **XMPP inbound file transfer — live e2e validation still pending.** The full receive pipeline (capability advertisement → OOB / `aesgcm://` extraction → bounded download → decrypt → WASM channel decode) is unit-tested and the bridge builds in release, but it has not been exercised end-to-end against a real server. See `docs/ops/XMPP_KNOWN_ISSUES.md` and `docs/architecture/XMPP_FILE_TRANSFERS.md`. (Carried since v1.1.2.)
- **Inbound XMPP downloads have no SSRF guard.** The client fetches sender-supplied OOB / `aesgcm://` URLs without blocking private/loopback/metadata IPs; deployments rely on the network boundary and the `ALLOW_PRIVATE_IPS` model. (Carried.)
- **Rootless container supervision gap (crash-recovery latency).** On rootless Podman, per-tenant containers are health-monitored but not parent-supervised, so a crash after `start()` returns is only recovered by the next 15-minute self-heal sweep (~30 min worst case) rather than in seconds. The `podman wait` babysitter proposed in v1.1.6 (`docs/proposals/ROOTLESS_PODMAN_CONTAINER_SUPERVISION_GAP.md`) remains deferred — the v1.1.6 babysitter scripts shipped, but the orchestrator-side integration is not yet in.
- **WeeChat health-glob flap.** An optional/stopped weechat backend matches the `lunarwing-*` health-discovery glob and can report critical / flap / escalate. Workaround: only render/enable weechat units for tenants that use it. (Carried; `render-units` remains a footgun until the per-tenant glob gate lands.)
- **`podman save | load` image distribution is slow.** Seeding worker images into each tenant's isolated rootless store still takes minutes per tenant per image; a shared read-only `additionalimagestore` remains a future optimization. (Carried.)
- **`/api/logs/download` has no UI button.** The endpoint exists as a backend API; the gateway UI "download logs" button has not been added. (Carried since v1.1.2.)
- **Multica bridge remains pre-release/experimental.** Requires further refinements despite technically working. (Carried.)
- **Kawarimi cross-machine migration is PostgreSQL-only.** libSQL tenants are refused by the machine-migration tooling. (Carried from v1.1.5.)
- **Machine migration is a cutover with per-tenant downtime.** (Carried from v1.1.5.)
- **Hardcoded `DEFAULT_TENSORZERO_URL` (192.168.1.157).** Override via `LUNARWING_MT_TENSORZERO_URL`; the nanocode baseURL is separately configurable per tenant. (Carried from v1.1.6, tracked as L2.)
- **A few non-critical cargo tests fail** (tracked in `docs/proposals/CARGO_TESTS_FIX.md`), and some env-dependent e2e tests remain pre-existing failures. Not addressed by the v1.1.7 polish scope.

---

## Upgrade Notes

1. **No new database migrations.** v1.1.7 adds no schema changes; the existing migrations still run automatically on first startup. **Back up your database before upgrading** as a matter of course. PostgreSQL 15+ remains required.
2. **Ports registry auto-migrates v8 → v9 → v10.** Any `lunarwing-mt-admin.sh` invocation runs `ports_migrate_v9()` and `ports_migrate_v10()` automatically. The standalone `ic/scripts/migrate-ports-v9.sh` and `ic/scripts/migrate-ports-v10.sh` can also be run explicitly (both back up + validate + are idempotent + refuse to run on a registry below their prerequisite). Existing tenants' port numbers are unchanged (rename-only: `reserved_5 → vision_service`, `reserved_6 → vision_health`).
3. **To gain the dedicated OCR/vision sidecar ports, re-render + restart sidecar units.** After the v9/v10 migration, run `render-units <tenant>` (or restart the sidecar) so both the `vision_service` (main API) and `vision_health` (health probe) slots are applied to the bind.
4. **Existing tenants: opt into the SSH harness with `configure-ssh`.** `configure-ssh <name> [--host <host>] [--user <user>]` writes the `[[ssh.hosts]]` block, generates the ed25519 key pair, and stages the private key for upload after the next daemon start. New `add-tenant` runs run the full SSH provisioning automatically. The `[ssh]` section is inert until at least one host entry exists, so tenants that don't need SSH are unaffected.
5. **SSH `~/.ssh` paths are now allowed by the shell tool's dangerous-pattern filter.** Re-tune tool-tier policy if you previously relied on `~/.ssh` being rejected. The other dangerous patterns (`id_rsa`, `/etc/passwd`, `/etc/shadow`, `.bash_history`, `sudo `, ` | sh`, `eval `, `$(curl`, `$(wget`) and all `NEVER_AUTO_APPROVE_PATTERNS` are unchanged.
6. **OCR sidecar now runs rootless Podman.** If you were running the sidecar under `docker`, follow `projects/ocr-sidecar/PODMAN_DEPLOYMENT.md` for the systemd/OpenRC init-template changes (`docker.service` → `podman.service`, `docker-compose` → `podman compose`, new `compose.yaml`). The container's `HEALTHCHECK` self-reports health now.

---

## Release Cadence

**A brief note about release cadence.** LunarWing abides by a release cadence to organize `feature`- and `polish`-focused releases — odd-numbered releases (like this one) focus on bug fixes, security improvements, and polishing. For details see `docs/ops/RELEASE_CADENCE.md`. Occasionally, exceptions may be made, but the goal is to stay within this paradigm. The Agent SSH Harness is one such deliberate exception: it's a single contained, security-focused feature whose introduction could not be cleanly deferred without blocking downstream hardening work.

## Testing

### In accordance with developer guidelines, a testing period precedes each release.

#### The pre-release checklist lives in `docs/ops/GOALS_1.1.7.md`; the full checklist is in `docs/ops/PRE-RELEASE-TESTING.md`; automated coverage is driven by `ic/scripts/release-test.sh` and `docs/guides/TESTING_GUIDE.md`. These documents may also reference other documents as well.

##### Once evaluation begins in earnest, no new changes besides urgent fixes will be accepted into staging during the evaluation period.

---

_This is a **working draft**. The two XMPP placeholders near the top of *Changes* (XMPP Security Improvements and XMPP File Transfers) are intentional and to be filled in separately._

