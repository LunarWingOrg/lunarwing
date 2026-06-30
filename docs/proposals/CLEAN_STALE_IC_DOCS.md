# Clean Stale IronClaw References in Documentation

Findings from the v1.1.7 pre-release documentation audit. Covers stale `ironclaw` references, MSRV inconsistencies, broken paths, and deferred renames across active docs and scripts.

## 1. MSRV Inconsistency

`Cargo.toml` declares `rust-version = "1.92"`. Two files say 1.96:

| File | Line | Current | Should Be |
|------|------|---------|-----------|
| `AGENTS.md` (root) | 127 | MSRV 1.96 | 1.92 |
| `ic/AGENTS.md` | 60 | MSRV 1.96 | 1.92 |

`CLAUDE.md`, `PEBBLE.md`, and `docs/guides/MIGRATE_IRONCLAW_TO_LUNARWING.md` already say 1.92 (correct).

## 2. Active Docs with Stale `ironclaw` References

### 2a. WeeChat Docs (blocked on `ironclaw_weechat_wss/` directory rename)

These references stem from the `ironclaw_weechat_wss/` directory name, which is tracked as a deferred rename in `docs/ops/history/PENDING_CLEANUP.md` (targeted v1.1.7 but not yet done). The directory references are correct until the rename lands, but the binary/path/command references inside these docs are stale regardless.

| File | Stale References |
|------|-----------------|
| `docs/guides/ironclaw_weechat_wss/README.md` | `ironclaw pairing approve`, `ironclaw restart`, `ironclaw channels list`, `~/.ironclaw/`, `IRONCLAW_REPO`, `IronClaw Documentation` link |
| `docs/guides/ironclaw_weechat_wss/weechat_relay/INSTALL.md` | `IronClaw installed and running`, `~/.ironclaw/channels/`, `ironclaw pairing approve`, `ironclaw restart`, `ironclaw channels list` |
| `docs/guides/MT-ADMIN-QUICKSTART.md` | Links to `ironclaw_weechat_wss/README.md` and `ironclaw_weechat_wss/weechat_relay/INSTALL.md` |
| `docs/ops/WEECHAT-SERVICES.md` | `ironclaw_weechat_wss/weechat_relay` path in WorkingDirectory and ExecStart |
| `docs/ops/WEECHAT-MULTITENANT-PORT-BUG.md` | `ironclaw_weechat_wss/weechat_relay/src/lib.rs` and `weechat.capabilities.json` path references |
| `docs/architecture/WEECHAT-CHANNEL-ARCHITECTURE.md` | `ironclaw_weechat_wss/weechat_relay/src/lib.rs` path references (3 occurrences) |
| `docs/README.md` | Links to `ironclaw_weechat_wss/README.md`, `ironclaw_weechat_wss/weechat_relay/INSTALL.md`, `ironclaw_weechat_wss/weechat_relay/TROUBLESHOOTING.md` |
| `docs/bugs/history/README.md` | `ironclaw_weechat_wss` crate name |

### 2b. Other Active Docs (not blocked on directory rename)

| File | Stale References |
|------|-----------------|
| `docs/guides/ic_sm/README.md` | `ironclaw has (sometimes) options to interface with secrets` |
| `docs/guides/gotify-wasm/README.md` | `cd ironclaw-gotify-tool` |
| `docs/reference/custom_bridges/XMPP.md` | `kageho_ironclaw_xmpp_and_replv2` reference |
| `docs/proposals/GITWASM/README.md` | `ironclaw-md-git` naming throughout (crate name, title, examples) |
| `docs/proposals/WEECHAT_WS_ADAPTER_SYNC_PROTOCOL.md` | `ironclaw-sync` request ID in adapter log output |
| `docs/proposals/DOCUMENTATION_UPDATING_STATUS.md` | References removed `docs/plans/` directory and stale `~/ironclaw` paths |
| `docs/proposals/PODMAN_WAIT_BABYSITTER_REVIEW.md` | References removed `docs/plans/` directory |
| `docs/internal/COMPONENT_SOURCES.md` | Source repo URLs: `darkirc_channel_for_ironclaw`, `ironclaw_weechat_wss`, `codex4ironclaw`, `ironclaw-md-git` |
| `docs/internal/FORK_CONTEXT.md` | `~/.ironclaw/.env` path reference |
| `docs/guides/darkirc_channel_for_ironclaw/DARKIRC_MT_ADAPTER.md` | `darkirc_channel_for_ironclaw/` directory path references (blocked on directory rename) |
| `docs/ops/DARKIRC-MULTITENANT.md` | Links to `darkirc_channel_for_ironclaw/` path (blocked on directory rename) |
| `docs/bugs/BUG-e2e-oauth-url-parameter-tests.md` | `github.com/nearai/ironclaw/releases/` download URL |

### 2c. DarkIRC docs referencing `darkirc_channel_for_ironclaw/` directory

Blocked on renaming the `darkirc_channel_for_ironclaw/` root directory. Tracked as deferred.

| File | References |
|------|-----------|
| `docs/ops/DARKIRC-MULTITENANT.md` | `darkirc_channel_for_ironclaw/` link |
| `docs/guides/darkirc_channel_for_ironclaw/DARKIRC_MT_ADAPTER.md` | `darkirc_channel_for_ironclaw/` path in ExecStart and config |
| `docs/README.md` | Links to `darkirc_channel_for_ironclaw/` guides |
| `docs/internal/COMPONENT_SOURCES.md` | Source repo URL |

## 3. Scripts with Stale `ironclaw` References

| File | Issue | Fix Difficulty |
|------|-------|---------------|
| `ic/scripts/import-to-pg.sh` | `EXPORT_DIR="/tmp/ironclaw"` | Trivial |
| `ic/scripts/export-libsql.sh` | `LIBSQL_DB="/home/user/.ironclaw/ironclaw.db"`, `EXPORT_DIR="/tmp/ironclaw-export"` | Trivial |
| `ic/scripts/reimport-fixes.sh` | Hardcoded `/home/cmc/kageho_old/.ironclaw/ironclaw.db` (4 occurrences) | Trivial |
| `ic/scripts/setup-instance.sh` | `~/.ironclaw` fallback (intentionally kept — legacy alias) | No change |
| `ic/scripts/install-lunarwing-watchdog.sh` | Legacy `ironclaw-watchdog` cleanup markers (intentionally kept — detects old installs) | No change |
| `ic/scripts/lunarwing-mt-admin.sh` | `ironclaw_weechat_wss/` and `darkirc_channel_for_ironclaw/` paths (actual directory names) | Blocked on directory rename |
| `ic/scripts/lunarwing-xmpp-test-env.sh` | `git-ironclaw-unix-socket-client-repo` path | Blocked on directory rename |

## 4. Stale `docs/plans/` References

The `docs/plans/` directory was removed during the 2026-06 docs reorg. Two files still reference it:

| File | Stale Reference |
|------|----------------|
| `docs/proposals/PODMAN_WAIT_BABYSITTER_REVIEW.md` | `docs/plans/rootless-podman-babysitter.md` |
| `docs/proposals/DOCUMENTATION_UPDATING_STATUS.md` | `docs/plans/` directory reference |

## 5. Migration Guides (intentionally reference `ironclaw`)

These docs document the migration FROM ironclaw TO lunarwing, so references to the old name are intentional and correct in context:

- `docs/guides/MIGRATE_IRONCLAW_TO_LUNARWING.md`
- `docs/guides/MIGRATE_IRONCLAW_TO_MT.md`
- `docs/guides/MIGRATE_IRONCLAW_LIBSQL_TO_MT.md`
- `docs/ops/MT-MACHINE-MIGRATION-REVIEW-NOTES.md` (references pre-rename source named `ironclaw`)

No changes needed for these.

## 6. Intentionally NOT Changed

Explicitly documented as kept per `CLAUDE.md` and `docs/ops/history/PENDING_CLEANUP.md`:

- `ironclaw-agent-v1` WebSocket subprotocol (shared external protocol)
- `tensorzero::function_name::ironclaw` TensorZero function name
- `codex4ironclaw/`, `nanocode-config/` directory names (deprecated but kept)
- `ironclaw.bash`, `ironclaw.fish`, `ironclaw.zsh` shell completions
- `IRONCLAW_BASE_DIR`, `IRONCLAW_SOCKET` legacy env aliases
- Keyring service identifiers in `ic_sm/`
- GCP resource names in `ic/deploy/cloud-sql-proxy.service`
- All `docs/releases/` (immutable historical records)
- All `docs/internal/history/` (archived provenance material)
- `docs/proposals/OLDPROJECT_PORT_ANALYSES/ironclaw-*.md` (upstream analysis)
- `docs/reviews/SWEETIE-ARCH-REVIEW.md` references to `ironclaw-agent-v1`, `ironclaw` TensorZero function names, and `ironclaw_engine` (describing upstream)
- `docs/ops/history/PENDING_CLEANUP.md` (tracks the deferred renames itself)

## 7. Priority Order for Fixes

1. **MSRV fix** (2 files, trivial) — `AGENTS.md` and `ic/AGENTS.md`: change 1.96 → 1.92
2. **Stale `docs/plans/` refs** (2 files, trivial) — update or remove broken paths
3. **Scripts** (3 files, trivial) — update default paths in import/export scripts
4. **Non-blocked docs** (Section 2b) — rename `ironclaw` → `lunarwing` in active docs
5. **WeeChat docs** (Section 2a) — blocked on `ironclaw_weechat_wss/` directory rename
6. **DarkIRC docs** (Section 2c) — blocked on `darkirc_channel_for_ironclaw/` directory rename
7. **`ironclaw_weechat_wss/` directory rename** — root cause of ~30+ references, tracked separately
8. **`darkirc_channel_for_ironclaw/` directory rename** — root cause of ~6 references, tracked separately
