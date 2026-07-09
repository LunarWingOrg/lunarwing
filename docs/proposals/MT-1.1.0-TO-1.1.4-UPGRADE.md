# Multi-Tenant Upgrade: v1.1.0 → v1.1.4 ("Phoenix") on systemd

**Status:** Proposal / runbook for the **rootless-adopt v1.1.0 → v1.1.4 flip** — still **pending operator go-ahead / not yet live-validated**. (Separately, the *same-host* v1.0.9 → v1.1.2 upgrade via `ic/scripts/upgrade-tenant-version.sh` has been **live-validated on a production tenant** — that is a different mechanism from the rootful → rootless flip this proposal covers.) *(Note: as of v1.1.9, the port schema has advanced to v11; the v5→v6 migration described here was the state at v1.1.4.)*
**Date:** 2026-06-18
**Source version:** `v1.1.0` (`17d0feb1`)
**Target version:** `v1.1.4` (`700406d9`, = `release/v1.1.4`; contained in `staging`)
**Audience:** operator of an existing systemd multi-tenant LunarWing fleet provisioned by `ic/scripts/lunarwing-mt-admin.sh`
**Container runtime in scope:** **Podman**, adopting the new **rootless + Quadlet** supervision model

---

## 1. Executive summary

v1.1.4 is an **ops-layer release**. The Rust daemon, the database schema, and the
on-disk config formats are effectively frozen relative to v1.1.0; nearly all the
multi-tenant-relevant change lives in `lunarwing-mt-admin.sh` (+1764 / −116 lines,
now ~4086) and the new `ic-infrastructure-health-check/` self-heal pipeline.

**The upgrade is feasible in place** — there is no DB migration, no dependency
churn, and no config-parse break that would force rebuilding the fleet. But on
**Podman** there is exactly **one critical footgun** that dominates the whole risk
picture:

> v1.1.4 defaults `MT_ROOTLESS=true` on Podman. v1.1.0 ran Postgres **rootful**
> (root's container store, data in the container writable layer, **no named
> volume**). The first `start-tenant` / `restart-tenant` / `add-tenant` under
> v1.1.4 looks in the **tenant's rootless store**, finds nothing, and brings the
> tenant up against a **fresh, empty database**. The v1.1.0 data is **orphaned**
> (recoverable from the old root container until it is `rm`/`reset`/pruned), but
> to the daemon it looks like total data loss.

Because the operator has chosen to **adopt the rootless + Quadlet model** (not
merely stay rootful), the upgrade is a **deliberate per-tenant data migration**:
`pg_dump` the old root-store DB → provision rootless → bring up the empty rootless
Postgres → `pg_restore` into it → start the daemon. This proposal specifies that
flow precisely against the real verb contracts, plus the tooling to automate it
safely.

**This exact scenario (in-place upgrade of a >v1.1.0 production tenant via the rootful → rootless flip) is flagged
by the team's own checklist (`docs/ops/GOALS_1.1.4.md` #11) as not yet validated.**
Only fresh-tenant provisioning has 8/8 green QA. Treat the first tenant as a
canary, with full backups, before touching the fleet.

---

## 2. Method & verification

- Diff range analyzed: `git diff v1.1.0..v1.1.4` — 361 commits, 417 files.
- 8 parallel domain readers (DB/migrations, mt-admin, systemd units, port schema,
  self-heal, WASM extensions, daemon runtime, release/goals docs), then adversarial
  verification of every high/critical claim (16/18 confirmed or partially-true,
  1 refuted, 1 lost to a session limit).
- The load-bearing finding (the Podman rootful→rootless flip) was confirmed by
  three independent verifiers **and** re-read directly in the source.

Key code references (all at `v1.1.4`, `ic/scripts/lunarwing-mt-admin.sh`):

| Behavior | Location |
|---|---|
| `MT_ROOTLESS` defaults `true` (podman) / `false` (docker); `LUNARWING_MT_ROOTLESS` override | `ensure_container_runtime`, lines 274–287 |
| `_ctr` routes rootless ops to the tenant's own store ("separate universes") | lines 321–338 |
| Quadlet path renders + starts the rootless PG on a **named volume in the tenant store** | `start_tenant_postgres` 1978–2008; `render_pg_quadlet` 2265+ (Volume line 2284) |
| Imperative create path (empty new container + named volume) | `start_tenant_postgres` 2020–2058 |
| `ensure_rootless_prereqs` (subuid/subgid, `/run/user`, pause.pid guard, `podman system migrate`) — **only called from `create_tenant_user`** | lines 738–795 |
| `ports_allocate` is **idempotent** (reuses existing block on re-run) | lines 630–640 |
| `add-tenant --no-health` sets `HEALTH_OPT_OUT=true` → skips health pipeline | dispatch line ~163; `add_tenant` 3385 |
| `add_tenant` brings up PG + renders units but **does not start the daemon** | `add_tenant` 3371–3408 |
| `render-units` renders daemon unit (with `Requires=lunarwing-pg-<t>` only on rootless+Quadlet) but **not** the PG Quadlet | `render_tenant_systemd_units` 2384–2534 (esp. 2493–2497, 2526–2530) |
| `backup-tenant` / `restore-tenant` route through `_ctr` (hit whichever store `MT_ROOTLESS` selects) | 2149–2179, 2216–2256 |
| `restore-tenant` requires PG running **and** daemon stopped, needs `--yes`, validates `PGDMP` header | 2216–2256 |

---

## 3. What changed, by risk to an in-place MT upgrade

### Safe (no action required)

- **DB schema / migrations:** `ic/migrations/` is **byte-identical** `v1.1.0..v1.1.4`
  (V1–V21, no V22+). Refinery (Postgres) and the libSQL runner are unchanged and
  idempotent → **zero DDL on first 1.1.4 start**, both backends.
- **Dependencies:** **zero** new `Cargo.lock` entries → build-from-source on the
  host needs no new system deps. Only the `1.1.0→1.1.4` version bump + an
  xmpp-bridge license fix.
- **Config/settings:** no `deny_unknown_fields`; every new field
  (`ws_ping_interval_secs`, `ws_idle_timeout_secs`, …) is `#[serde(default)]`. A
  v1.1.0 `config.toml` / `settings.json` parses unchanged.
- **Port schema v5→v6:** purely additive — mirrors a parallel `20000–29999`
  reserved block, **never moves an existing port**, idempotent, backs up +
  validates (`migrate-ports-v6.sh`). Nothing in v1.1.4 reads the new fields yet.
- **WASM extensions:** removed channels (discord/feishu/slack/relay) + tools
  (gmail/google-*/slack), but **WIT stayed 0.3.0**, host ABI changed only in tests,
  and startup auto-activation treats a missing/removed extension as a **logged
  warning, never fatal**. No version/signature gate rejects an installed extension.

### Benign behavior shifts (expect, don't fix)

- Web-gateway WebSockets now ping every 30s and idle-disconnect at **120s**
  (browsers fine; raise `WS_IDLE_TIMEOUT_SECS`, or set 0, only for long-lived
  non-browser WS clients).
- Gateway history for XMPP/WeeChat rooms **appears to start a fresh thread** (the
  non-UUID scope-leakage fix) — additive and lossless; old history still queryable
  under the legacy assistant conversation.
- Two dead Slack-relay routes now return 404.

### 🔴 CRITICAL — Podman rootful→rootless DB flip orphans tenant data

See §1 and §4. **The single thing that makes this a migration rather than a binary
swap.** Mitigated by the dump→restore flow (this proposal) or by pinning
`LUNARWING_MT_ROOTLESS=false` (keep-rootful alternative, §5-B).

### 🟠 HIGH — No upgrade verb; tenant code/binaries do not auto-update

`clone_tenant_repo` is a no-op on existing clones and `build_tenant` never fetches.
A binary swap or unit re-render leaves each tenant on the **old binary**. You must,
per tenant: `git fetch && checkout v1.1.4` in `/home/<t>/lunarwing` (as the tenant
user) and `build-tenant <t> --with-wasm` (+ worker flags). Re-rendered proxy/adapter
`ExecStart` paths now point at **the tenant's own clone**, so that clone must be
current and contain `tensorzero-proxy-configurations/` and `ironclaw_weechat_wss/`.

### 🟠 HIGH — Re-running `add-tenant` with an *old* script destroys secrets

Only the v1.1.4 `write_tenant_lunarwing_env` is idempotent (preserves
`SECRETS_MASTER_KEY`, `GATEWAY_AUTH_TOKEN`, `HTTP_WEBHOOK_SECRET`,
`XMPP_BRIDGE_TOKEN`, …). Re-running `add-tenant` against an existing tenant with a
**pre-v1.1.4** copy regenerates `SECRETS_MASTER_KEY` → **permanently orphans that
tenant's encrypted DB secrets.** Always invoke the v1.1.4 script.

### 🟡 MEDIUM

- **`render-units` without `restart-tenant` (rootless):** the daemon unit gains
  `Requires=lunarwing-pg-<t>.service` but the PG Quadlet is rendered by
  `start_tenant_postgres`, not `render-units`. Always reach the daemon via
  `start-tenant` (which orders PG first).
- **Self-heal goes host-wide on the first `add-tenant`:** the pipeline is net-new,
  default-on, installed only as a side effect of `add-tenant`/`add-tenants`, with no
  standalone enable verb. A root 15-minute timer then remediates **all** discovered
  units. **Gate every upgrade `add-tenant` with `--no-health`** so self-heal can't
  restart tenants you've intentionally stopped mid-migration. Enable it
  deliberately, fleet-wide, only after the whole fleet is up (§7).
- **HTTP webhook bind:** v1.1.0 env files lack `HTTP_HOST`; the v1.1.4 template sets
  `HTTP_HOST=127.0.0.1` + `HTTP_WEBHOOK_SECRET`. The idempotent `add-tenant` re-run
  in the runbook back-fills these automatically.
- **WeeChat unit rename:** `weechat-<t>` → `lunarwing-weechat-<t>` leaves a stale
  enabled unit to disable/remove; the renamed unit also matches the health glob and
  can flap if the tenant doesn't use WeeChat (render/enable it only for tenants that
  do).
- **Podman < 4.6:** the Quadlet path is silently skipped → PG still runs but with
  **no systemd supervision and no boot persistence** (imperative rootless `_ctr run`,
  `--restart` is a no-op rootless). Verify `podman --version` before adopting
  rootless; on older Podman either upgrade Podman or stay rootful.

### ⚪ Validation gap (not a code blocker)

`docs/ops/GOALS_1.1.4.md` #11 + the RELEASE "Testing" section flag the live in-place
upgrade of a >v1.1.0 production tenant **via the rootful → rootless flip** as **still
open**. (The separate same-host v1.0.9 → v1.1.2 path via `upgrade-tenant-version.sh` is
already live-validated — see *Status* at the top.) You are first to run *this* flip →
canary, backups, soak.

---

## 4. The critical Podman flip — exact mechanics

At **v1.1.0**, `start_tenant_postgres` ran (as root, rootful store):

```
$CONTAINER_RT run -d --name lunarwing-pg-<t> --restart unless-stopped \
  -e POSTGRES_PASSWORD=lunarwing ... pgvector/pgvector:pg16      # NO -v volume
```

At **v1.1.4**, with `MT_ROOTLESS=true` (Podman default) and Podman ≥ 4.6, the same
code path renders a Quadlet and starts it in the **tenant's rootless store** with a
**named volume** `lunarwing-pg-<t>:/var/lib/postgresql/data`. The two stores are
disjoint ("root and rootless podman are separate universes", line 320). The
`_ctr inspect` at line 2010 queries the *empty* tenant store, misses the old
root-owned container, and the create branch makes a **fresh empty DB**. There is no
detection or warning. All of `start-tenant` / `restart-tenant` / `add-tenant` reach
this path.

**Recovery property:** the old data is *orphaned, not destroyed* — the v1.1.0 root
container (and its writable layer) persist in root's store until `rm`/`reset`/prune.
**Never prune the old root container until the migrated tenant is verified.**

---

## 5. Decision matrix & runbooks

| Path | When | Disruption | Data handling |
|---|---|---|---|
| **A. Rootless + Quadlet adopt** *(chosen)* | Want supervised, boot-persistent rootless PG/workers; Podman ≥ 4.6 | Medium (per-tenant dump→restore) | Explicit migrate |
| **B. Keep rootful** | Lowest disruption; defer rootless; or Podman < 4.6 | Low | Reused in place |
| **C. Fresh MT host** | Host can't meet rootless prereqs and you want a clean cut, or you'd rather rebuild | High | Dump→restore onto new host |

> **Always, before the first v1.1.4 invocation on the host:** back up
> `/etc/lunarwing/ports.json` and every tenant DB. Run the v1.1.4 script for every
> invocation. Keep self-heal off (`--no-health`) until the fleet is fully up.

### Runbook A — Podman, adopt rootless + Quadlet (per tenant, canary first)

This is what `ic/scripts/upgrade-tenant.sh` automates. Manual equivalent:

```bash
MT=ic/scripts/lunarwing-mt-admin.sh
T=<tenant>

# 0. Read-only gate
sudo ic/scripts/upgrade-preflight.sh "$T"        # abort on STOP

# 1. Back up the OLD root-store DB (must be running) + registry + env
sudo LUNARWING_MT_ROOTLESS=false "$MT" backup-tenant "$T"   # pg_dump -Fc from root store
sudo cp -a /etc/lunarwing/ports.json /var/lib/lunarwing-backups/ports.json.preupgrade
sudo cp -a /home/$T/lunarwing/env    /var/lib/lunarwing-backups/$T-env.preupgrade
#   note the dump path printed by backup-tenant; verify it begins with "PGDMP"

# 2. Stop the OLD model (daemon + old root PG); old container/volume preserved
sudo LUNARWING_MT_ROOTLESS=false "$MT" stop-tenant "$T"

# 3. Update + rebuild the tenant's own clone (mt-admin does NOT do this)
sudo -u "$T" git -C /home/$T/lunarwing fetch --tags
sudo -u "$T" git -C /home/$T/lunarwing checkout v1.1.4
sudo "$MT" build-tenant "$T" --with-wasm   # add --with-nanocode/--with-pebble if used
sudo "$MT" install-wasm "$T"

# 4. Provision rootless + render units + bring up EMPTY rootless PG (NO daemon, NO health)
sudo "$MT" add-tenant "$T" --no-health
#   idempotent: ensure_rootless_prereqs (subuid/subgid, /run/user, system migrate),
#   preserves all secrets, back-fills HTTP_HOST/HTTP_WEBHOOK_SECRET, starts empty
#   rootless PG quadlet, renders units. Daemon is NOT started.
#   verify: sudo -u "$T" XDG_RUNTIME_DIR=/run/user/$(id -u "$T") podman ps

# 5. Restore the dump into the rootless PG (PG up, daemon stopped → preconditions hold)
sudo "$MT" restore-tenant "$T" <dump-from-step-1> --yes

# 6. Start the tenant (PG already up, then workers + daemon)
sudo "$MT" start-tenant "$T"

# 7. Clean up the orphaned old WeeChat unit (rename left it)
sudo -u "$T" XDG_RUNTIME_DIR=/run/user/$(id -u "$T") \
  systemctl --user disable --now weechat-$T.service 2>/dev/null || true
sudo rm -f /home/$T/.config/systemd/user/weechat-$T.service

# 8. Verify
sudo "$MT" status-tenant "$T"
sudo ic-infrastructure-health-check/infrastructure-health-check.sh   # one pass
#   smoke: message round-trips, history present, routines intact, channels load

# 9. Soak. Only after verification, optionally prune the OLD root container:
#    sudo podman rm -f lunarwing-pg-$T   # (root store) — IRREVERSIBLE; data gone
```

Repeat per tenant. Enable self-heal fleet-wide only after **all** tenants are up (§7).

### Runbook B — Podman, keep rootful (low-disruption alternative)

If you do **not** want the rootless model yet (or Podman < 4.6): pin
`LUNARWING_MT_ROOTLESS=false` on **every** mt-admin invocation (export it in the
admin's environment / a wrapper — it is not persisted anywhere). Then there is **no
flip**: the existing root container is reused and the password is preserved. No
dump/restore needed.

```bash
export LUNARWING_MT_ROOTLESS=false
sudo -E "$MT" backup-tenant "$T"            # safety
sudo -E "$MT" stop-tenant "$T"
sudo -u "$T" git -C /home/$T/lunarwing fetch --tags && checkout v1.1.4
sudo -E "$MT" build-tenant "$T" --with-wasm
sudo -E "$MT" install-wasm "$T"
sudo -E "$MT" add-tenant "$T" --no-health   # idempotent; back-fills HTTP_HOST etc., reuses root PG
sudo -E "$MT" restart-tenant "$T"
# weechat orphan cleanup + verify as in Runbook A steps 7–8
```

`upgrade-tenant.sh --keep-rootful` automates this.

### Runbook C — Fresh MT host

Stand up a clean v1.1.4 host (`add-tenant` per tenant — fully QA'd), then per tenant:
`backup-tenant` on the old host → copy the dump → `add-tenant <t> --no-health` on the
new host → `restore-tenant <t> <dump> --yes` → `start-tenant`. Copy each tenant's
`env/` secrets (`SECRETS_MASTER_KEY` especially) and any workspace/state. The
existing `docs/guides/MIGRATE_IRONCLAW_*` guides cover fresh-tenant flows but **not**
an in-place 1.1.0→1.1.4 upgrade, so this proposal is the reference either way.

---

## 6. Tooling (this proposal ships these)

### `ic/scripts/upgrade-preflight.sh` — read-only fleet/tenant assessor

No mutations. Per tenant (and host-global) emits **GO / CAUTION / STOP** with
reasons. Checks:

- Runtime = podman, `podman --version` ≥ 4.6 (Quadlet) — else CAUTION (rootless
  loses supervision/boot-persistence).
- **The critical check:** does a **rootful root-store** `lunarwing-pg-<t>` container
  exist (`sudo podman ps -a`)? If yes and target is rootless → flag MIGRATION
  REQUIRED (data is in the root store; a naive start would orphan it).
- `/etc/lunarwing/ports.json` present + schema version (note `migrate-ports-v6.sh`
  if < 6).
- mt-admin script is v1.1.4+ (has `MT_ROOTLESS` + `restore-tenant`).
- Tenant clone git rev vs `v1.1.4` (behind → needs git update + build).
- Env file: `SECRETS_MASTER_KEY` present (must preserve), `HTTP_HOST` /
  `HTTP_WEBHOOK_SECRET` present.
- Stale `weechat-<t>.service` (old name) present.
- Tenant linger enabled, `/run/user/<uid>` present, subuid/subgid allocated.
- Old root PG reachable (`pg_isready`) + DB size (dump/restore time estimate).
- `jq` present; passwordless `sudo -n` root→tenant works.

Exit non-zero if any tenant is STOP.

### `ic/scripts/upgrade-tenant.sh` — generalized per-tenant upgrade

Generalizes the hardcoded `upgrade-tenant-starforce.sh` / `-sunburst.sh`. Drives
Runbook A by default (Podman rootless+Quadlet, dump→provision→restore) and Runbook B
with `--keep-rootful`. Safety: runs the preflight as a **gate**, refuses to proceed
unless the backup verifies (`PGDMP` header + non-zero size), `--dry-run` prints the
plan, prints rollback instructions, never prunes the old root container during the
upgrade.

```
upgrade-tenant.sh <tenant> [--target <rev|tag>] [--keep-rootful]
                           [--with-nanocode] [--with-pebble]
                           [--skip-build] [--dry-run] [--yes] [--force]
upgrade-tenant.sh <tenant> --prune-old-root [--yes]   # standalone, post-verify cleanup
```

The standalone `--prune-old-root` mode reclaims the orphaned v1.1.0 root-store PG
container **after** the tenant is migrated and verified. It refuses to act unless the
rootless PG is up and `pg_isready` (so it can never delete your only copy);
**IRREVERSIBLE** once run.

### `ic/scripts/enable-health-fleet.sh` — standalone self-heal enabler

Closes the "no standalone enable verb" gap. Sources `lunarwing-mt-admin.sh` (whose
`main` is guarded, so only functions/config load) and calls the real
`ensure_health_pipeline` — no duplicated logic, can't drift. Adds the safety the
implicit `add-tenant` path lacks: **refuses to arm the host-wide 15-min remediation
timer while any tenant daemon is down** (so self-heal can't fight a maintenance).
Seeds Gotify creds into a fresh `health.env` (preserves an existing one).

```
enable-health-fleet.sh [--gotify-url <url>] [--gotify-token-file <path>]
                       [--allow-down] [--dry-run] [--yes]
```
The escalation token is a secret, so it is **not** accepted on argv (which is
world-readable via `/proc/<pid>/cmdline`): pass `--gotify-token-file`, set
`LUNARWING_MT_GOTIFY_TOKEN`, or edit `health.env` after.

### mt-admin source-level hardening (shipped)

`start_tenant_postgres` now has a **data-orphan guard**: when the target is rootless
(`MT_ROOTLESS=true`, Podman) and a legacy **root-store** `lunarwing-pg-<t>` container
exists while the tenant has **no rootless container yet**, it prints a loud warning
and **refuses by default** rather than silently creating an empty rootless DB. Three
escape hatches: migrate (`upgrade-tenant.sh`), keep rootful
(`LUNARWING_MT_ROOTLESS=false`), or acknowledge an intended fresh DB
(`LUNARWING_MT_ACK_ROOTLESS_FLIP=<tenant>` — a comma-separated list of tenant names,
e.g. `acme,beta`; a global `=1` is intentionally rejected so it can't silence the
guard for other tenants). The guard fires **only** in that exact window, so fresh
tenants and already-migrated tenants are unaffected; `upgrade-tenant.sh` sets the ack
(scoped to the tenant) automatically once it holds a verified backup.

### (Recommended follow-up, not yet built)

- Persist the chosen rootless/rootful model in `ports.json` (or a host config) so it
  survives across mt-admin invocations instead of relying on a per-call env var.
- A `doctor` check that flags any tenant currently in the root-store-present +
  `MT_ROOTLESS=true` state across the fleet.

---

## 7. Self-heal enablement (deliberate, after the fleet is up)

Do **not** let the upgrade enable self-heal implicitly. Every upgrade `add-tenant`
uses `--no-health`. Once **all** tenants are migrated and verified:

```bash
sudo ic/scripts/enable-health-fleet.sh \
  --gotify-url <url> --gotify-token-file /etc/lunarwing/gotify.token   # refuses if any tenant is down
systemctl status lunarwing-mt-health.timer     # verify
```

Prereqs once enabled: `jq` (and `curl`/`flock` if used), passwordless `sudo -n`
root→tenant, Gotify token. The timer remediates/escalates **all** discovered units
every 15 min — confirm no tenant is intentionally down when you enable it.

---

## 8. Pre-upgrade checklist / open questions

- [ ] Confirm runtime = Podman and capture `podman --version` (≥ 4.6 for Quadlet).
- [ ] Confirm tenants were provisioned on the exact `v1.1.0` tag (else they may
      carry a stale `weechat-<t>` unit or an already-randomized PG password).
- [ ] Any tenant using removed channels (slack/discord/relay/google/gmail)? Check
      `wasm_channels` settings and `CHANNEL_RELAY_URL`; scrub for cleanliness.
- [ ] Gotify URL/token available for `health.env` (escalation).
- [ ] Passwordless `sudo -n` root→tenant configured (needed by `_ctr` and self-heal).
- [ ] Any long-lived non-browser WS client (the new 120s idle timeout)?
- [ ] Maintenance window / downtime tolerance per tenant.
- [ ] Backups verified restorable on a copy before touching production.

---

## 9. Rollback (per tenant)

1. `stop-tenant <t>`.
2. Restore the pre-upgrade DB: into the old root container, re-pin
   `LUNARWING_MT_ROOTLESS=false` and `restore-tenant <t> <preupgrade.dump> --yes`
   (or just start the preserved old root container, which still holds the original
   data — nothing was pruned).
3. `git -C /home/<t>/lunarwing checkout <prior-rev>` and `build-tenant <t> --with-wasm`.
4. Restore `env/` from the backup if it was modified.
5. `restart-tenant <t>` (rootful).

The old root-store container is the ultimate safety net — it is never removed by
this procedure.
