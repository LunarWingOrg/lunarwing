# Worker Container Healthcheck Port Mismatch (nanocode + pebble)

*Drafted by Claude Code (Opus 4.8), 2026-06-13 — surfaced during the `eris` multi-tenant bring-up.*

**Status:** Proposed
**Severity:** Low (cosmetic) — workers are fully functional; the Docker `HEALTHCHECK` reports a false `unhealthy`.
**Scope:** Every tenant's `lunarwing-nanocode-<name>` and `lunarwing-pebble-<name>` container created by `lunarwing-mt-admin.sh`.

## TL;DR

The MT admin script starts both worker containers with `-e HEALTH_PORT="0"`, which moves (effectively disables) the in-container health HTTP server. But the worker images bake in a `HEALTHCHECK` that probes a fixed `http://127.0.0.1:8443/health`. The probe therefore always fails and the container settles into `unhealthy`, even though the WebSocket bridge the daemon actually talks to is up and serving. Fix: either disable the now-stale healthcheck (`--no-healthcheck`) or point the in-container health server back at the port the healthcheck expects (`HEALTH_PORT=8443`, unpublished).

## Symptom

After `start-tenant eris`, both workers report `unhealthy` while their WS ports listen normally:

```
$ docker ps --filter name=eris --format '{{.Names}}\t{{.Status}}'
lunarwing-pebble-eris     Up 2 minutes (unhealthy)
lunarwing-nanocode-eris   Up 2 minutes (unhealthy)
lunarwing-pg-eris         Up 30 minutes

$ docker inspect lunarwing-pebble-eris --format '{{json .State.Health.Log}}' | jq '.[-1]'
exit=1   output: ""        # curl to :8443 returns nothing — connection refused
```

Worker logs show the bridges are actually healthy (WS ports 10047/10048 listening, auth enabled):

```
[pebble4lunarwing] ws=0.0.0.0:10048/ws/agent health=:0 auth=enabled
[bridge] listening on ws://0.0.0.0:10048/ws/agent
[health] listening on http://0.0.0.0:0          # <- health server bound to port 0, not 8443

[bridge] server listening on ws://0.0.0.0:10047/ws/agent
[bridge] subprotocol: ironclaw-agent-v1
```

## Root cause

The image and the launcher disagree on the health port.

**Images hardcode the probe at 8443:**

- `pebble4lunarwing/Dockerfile:32` — `ENV HEALTH_PORT=8443`
- `pebble4lunarwing/Dockerfile:37-38`
  ```dockerfile
  HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
      CMD curl -sf http://127.0.0.1:8443/health || exit 1
  ```
- `lunarcode4lunarwing/Dockerfile:161-162` — identical `HEALTHCHECK` probing `127.0.0.1:8443/health`

**The launcher overrides the port to 0:**

- `ic/scripts/lunarwing-mt-admin.sh:1210` (`start_tenant_nanocode`) — `-e HEALTH_PORT="0" \`
- `ic/scripts/lunarwing-mt-admin.sh:1294` (`start_tenant_pebble`) — `-e HEALTH_PORT="0" \`

The pebble bridge reads this directly: `pebble4lunarwing/src/bridge.rs:35` (`health_port: env_or("HEALTH_PORT", "8443")...`) and binds `0.0.0.0:health_port` in `src/main.rs:36`. With `HEALTH_PORT=0` the `/health` route (`src/health.rs:84`) is no longer reachable at 8443, so the in-container `curl` gets connection-refused → `exit 1` → after `retries=3`, `unhealthy`.

No host port is published for health, but that is irrelevant: a Docker `HEALTHCHECK` `CMD` runs **inside** the container's network namespace, so it only needs the server bound to `127.0.0.1:8443` *within* the container — not on the host, and not in the tenant's 10-port block.

## Impact

- **Functional:** none. `--restart unless-stopped` does **not** restart on health status (only on exit/crash), so there is no flap loop. `create_job(mode: "nanocode"|"pebble")` works because the daemon dials the WS bridge (10047/10048), which is up.
- **Operational:** misleading `unhealthy` in `docker ps` and `mt-admin.sh status`; noise for operators; and any health tooling that keys off Docker health (the infra health-check suite / self-heal work in `SELF_HEALING_IMPROVEMENTS_2.md`) will misreport these containers. Also breaks any future `depends_on: condition: service_healthy` wiring.

## Proposed fix

Both options are one-line edits to the two `docker run` blocks in `lunarwing-mt-admin.sh`. Pick one and apply it to **both** `start_tenant_nanocode` and `start_tenant_pebble`.

### Option 1 — Disable the stale healthcheck (recommended; universal)

Add `--no-healthcheck` to each `docker run`. Works for both worker types regardless of whether their bridge serves `/health`, and removes the false signal immediately.

```diff
       --restart unless-stopped \
+      --no-healthcheck \
       lunarwing-worker-nanocode:latest \
       --mode websocket >/dev/null
```
```diff
       --restart unless-stopped \
+      --no-healthcheck \
       lunarwing-worker-pebble:latest >/dev/null
```

Trade-off: no Docker-level liveness signal. Acceptable because nothing currently consumes it, and liveness is better observed via the WS bridge anyway.

### Option 2 — Re-enable the in-container health server (better observability)

Point the health server at the port the image already probes by changing `0` → `8443` (no `-p` publish needed; the check is in-container):

```diff
-      -e HEALTH_PORT="0" \
+      -e HEALTH_PORT="8443" \
```

- **pebble:** confirmed wired — `bridge.rs` reads `HEALTH_PORT`, `health.rs:84` serves `/health`. This will turn the container `healthy`.
- **nanocode:** **verify first.** No `/health` handler exists in `lunarcode4lunarwing/`'s Rust sources; its bridge differs (it fronts an `opencode` server on :4096). If its health server does not serve `/health` on `HEALTH_PORT`, this option won't fix nanocode — fall back to Option 1 for that worker.

In-container `8443` is safe across tenants because each container has its own network namespace (no host-level conflict).

### Recommendation

Ship **Option 1** for both workers now (resolves the reported symptom with zero risk), and optionally pursue **Option 2** for pebble (and nanocode, if its bridge is taught to serve `/health`) as a later observability enhancement.

## Applying to already-running tenants

A container's healthcheck/env are immutable once created — editing the script alone does not fix running containers. After patching the script, recreate the worker containers:

```bash
sudo /home/sun/lw_new_workspace/lunarwing/ic/scripts/lunarwing-mt-admin.sh stop-tenant <name>
sudo /home/sun/lw_new_workspace/lunarwing/ic/scripts/lunarwing-mt-admin.sh start-tenant <name>
```

`start_tenant_{nanocode,pebble}` only re-creates a container when one does not already exist, and `stop-tenant` stops but does not remove it — so a hard recreate may be needed:

```bash
docker rm -f lunarwing-nanocode-<name> lunarwing-pebble-<name>
sudo /home/sun/lw_new_workspace/lunarwing/ic/scripts/lunarwing-mt-admin.sh start-tenant <name>
```

(Worker workspaces are bind-mounted from the tenant home, so removing the container is non-destructive.)

## Verification

```bash
# Option 1: containers should report no health status (just "Up"), not "unhealthy"
docker ps --filter name=<name> --format '{{.Names}}\t{{.Status}}'

# Option 2 (pebble): exec the same probe the HEALTHCHECK runs
docker exec lunarwing-pebble-<name> curl -sf http://127.0.0.1:8443/health && echo OK
```

## Affected tenants

All tenants with worker containers. Observed on `eris` (2026-06-13). `noko`, `ono`, `cumulus`, `nimbus` will exhibit the same if/when their nanocode/pebble containers are created.

## Open questions

1. Does the nanocode bridge expose `/health` on `HEALTH_PORT` at all? If not, decide whether to (a) teach it to, or (b) accept Option 1 for nanocode permanently.
2. Was `HEALTH_PORT=0` deliberate (e.g., to avoid a perceived port conflict)? If so, document that the in-container probe needs no host port and Option 2 is safe.
3. Should a working healthcheck feed the infra health-check / self-heal tooling, or is the WS-bridge probe the canonical liveness check for workers?

## References

- `ic/scripts/lunarwing-mt-admin.sh` — `start_tenant_nanocode` (L1145), `start_tenant_pebble` (L1239)
- `pebble4lunarwing/Dockerfile`, `pebble4lunarwing/src/{bridge,health,main}.rs`
- `lunarcode4lunarwing/Dockerfile`
- `docs/ops/MULTITENANCY-PRODUCTION.md`
- Related: `docs/proposals/SELF_HEALING_IMPROVEMENTS_2.md`, `docs/proposals/NANOCODE_WORKER_SECRETS.md`, `docs/proposals/PEBBLE.md`
