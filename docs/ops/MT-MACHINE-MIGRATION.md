# Multi-Tenant Machine Migration (old host → fresh v1.1.4 host)

**When to use this instead of the in-place upgrade
(`docs/proposals/MT-1.1.0-TO-1.1.4-UPGRADE.md`):** when you'd rather stand up a
clean v1.1.4 host and move tenants onto it. This runs each tenant through the
**QA'd `add-tenant` path**, sidesteps the rootful→rootless flip entirely, and keeps
the **old host as a perfect rollback**. Recommended for a small number of important
tenants.

**Tools:** `ic/scripts/export-tenant.sh` (old host) and `ic/scripts/import-tenant.sh`
(new host).

**Cross-init:** both scripts work for **systemd and OpenRC**. Export touches no init
units; import delegates all init/runtime-specific work to `lunarwing-mt-admin.sh`,
which auto-detects systemd vs OpenRC and rootless-podman vs rootful-docker. The new
host's init system does not need to match the old host's.

---

## What moves, and why

| Item | Where it lives | Carried by |
|------|----------------|------------|
| Conversations, memory, routines, reflexes, settings, **encrypted secret rows** | PostgreSQL | `db.dump` (`pg_dump -Fc` → `pg_restore`) |
| **`SECRETS_MASTER_KEY`** | env | manifest — **MUST** match the DB, or every encrypted secret row is unrecoverable |
| **OMEMO store** (encrypted-XMPP device identity/sessions) | `state/xmpp/` on disk | `state.tar.gz` |
| Workspace identity/memory files, WASM tool storage | `state/` on disk | `state.tar.gz` |
| `XMPP_JID` + `XMPP_PASSWORD` | env | manifest — same account login |
| `GATEWAY_AUTH_TOKEN`, `XMPP_BRIDGE_TOKEN`, `HTTP_WEBHOOK_SECRET`, `RELAY_PASSWORD`, `LLM_API_KEY` | env | manifest — so external clients holding them keep working |
| XMPP rooms / allowlist / encrypted-rooms / plaintext-fallback, `LLM_BASE_URL`/`MODEL` | env (+ bridge `*_JSON`) | manifest |
| WASM tool/channel artifacts | `state/tools`, `state/channels` | **rebuilt** on the new host (`build-tenant --with-wasm` + `install-wasm`) |
| Ports, paths, host-specific URLs | `ports.json` / env | **regenerated** by `add-tenant` on the new host |

Host-specific values are intentionally *not* carried — the new host allocates its
own ports and paths.

---

## Prerequisites on the new (standalone) host

A fully self-contained v1.1.4 host: PostgreSQL via rootless Podman (≥ 4.6 for Quadlet
supervision), TensorZero proxy, reachability to the same XMPP server, Gotify (for
self-heal escalation), and `lunarwing-mt-admin.sh` from the v1.1.4 tag. See
`docs/ops/MULTITENANCY-PRODUCTION.md` and `docs/guides/MT-ADMIN-QUICKSTART.md` for the
base host setup. Confirm `jq`, `tar`, and the container runtime are present on both
hosts.

---

## Procedure (per tenant — canary first)

### 1. Export on the OLD host
```bash
sudo ic/scripts/export-tenant.sh <tenant>            # --dry-run first to preview
# writes /var/lib/lunarwing-migrate/<tenant>-migrate-<stamp>.tar  (0600, root)
```
The tenant's DB container must be running so `pg_dump` can run. The bundle contains
secrets (incl. `SECRETS_MASTER_KEY`) — it is mode `0600`.

### 2. Transfer the bundle securely
```bash
# from the new host (or via a trusted relay) — over ssh, preserving perms:
rsync -av -e ssh old-host:/var/lib/lunarwing-migrate/<tenant>-migrate-<stamp>.tar /var/lib/lunarwing-migrate/
```
Treat the bundle like a key. Delete it from both hosts once the import is verified.

### 3. Import on the NEW host (stages, does not start)
```bash
sudo ic/scripts/import-tenant.sh /var/lib/lunarwing-migrate/<tenant>-migrate-<stamp>.tar \
     [--with-nanocode] [--with-pebble]      # --dry-run first to preview
```
This runs `add-tenant --no-health` → `build-tenant` → injects the carried secrets
(incl. `SECRETS_MASTER_KEY`) → `restore-tenant` (DB) → restores `state/` (OMEMO) →
`install-wasm`. It **stages** the tenant but does **not** start the daemon, because
the new daemon uses the **same XMPP JID** as the old one and two simultaneous logins
conflict.

### 4. Cut over
```bash
# on the OLD host — stop the tenant so the JID is free:
sudo ic/scripts/lunarwing-mt-admin.sh stop-tenant <tenant>
# on the NEW host — start it:
sudo ic/scripts/lunarwing-mt-admin.sh start-tenant <tenant>
sudo ic/scripts/lunarwing-mt-admin.sh status-tenant <tenant>
```
(Or run the import with `--start`, which prompts you to confirm the old side is
stopped before starting.)

### 5. Verify
A message round-trips; conversation history is present; routines and channels load;
**OMEMO encrypted chat decrypts** (may take a few messages after first start — known
behavior). Soak the canary before migrating the rest.

### 6. After all tenants are migrated
Enable self-heal fleet-wide on the new host (only once everything is up):
```bash
sudo ic/scripts/enable-health-fleet.sh --gotify-url <url> --gotify-token-file <path>
```

---

## Cutover & rollback

- **Cutover window:** the only moment of overlap risk is the same-JID double login.
  Keep it brief: stop old → start new. DNS / reverse-proxy / tunnel pointing at the
  old host's gateway should be repointed at the new host's gateway port at cutover.
- **Rollback is trivial:** the old host is untouched by this procedure (export is
  read-only; the bundle is a copy). If anything looks wrong after cutover, stop the
  new tenant and `start-tenant` on the old host again.
- Don't decommission the old host until every migrated tenant has soaked and you've
  confirmed encrypted secrets decrypt (i.e. `SECRETS_MASTER_KEY` carried correctly).

---

## Security notes

- The bundle and both manifests are mode `0600`, root-owned. Secrets (`SECRETS_MASTER_KEY`,
  XMPP password, tokens) live only in those files — never on a command line or in logs
  (the scripts inject from files via `awk ENVIRON`, and log key *names* only).
- Transfer over ssh; delete bundles from both hosts after verification.
