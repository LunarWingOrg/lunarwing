# Quadlet Review Notes — v1.1.4 Staging

*Baud's review of the systemd Quadlet .container templates in `lunarwing-mt-admin.sh:render_pg_quadlet()` and `render_worker_quadlet()`, 2026-06-16*

### Some of these are already implemented. 

---

## 1. Worker Quadlet Has No Health Check — **P1**

The PG quadlet has `HealthCmd`, `HealthInterval`, `HealthTimeout`, `HealthRetries`, `HealthStartPeriod`. The worker quadlet has none.

**Risk:** If a nanocode/pebble worker process dies inside the container (segfault, OOM, frozen agent loop), the container will appear "running" but the agent is dead. The self-heal pipeline can't detect it through any existing probe because no probe curls the container's internal health endpoint.

**Fix:** Add to `render_worker_quadlet()` `[Container]` section:
```
HealthCmd=curl -f http://127.0.0.1:${health_port}/health || exit 1
HealthInterval=10s
HealthTimeout=3s
HealthRetries=3
```

Note: `${health_port}` is already available in the function (default `8443`).

---

## 2. No `TimeoutStartSec` on Worker Quadlet — **P2**

The PG quadlet has `TimeoutStartSec=120` in `[Service]`. Workers don't.

**Risk:** On first boot with cold image pulls or slow storage, systemd will kill the worker container before it finishes starting. Default systemd timeout is 90s, which is tight for a cold pull + container init.

**Fix:** Add to worker `[Service]`:
```
TimeoutStartSec=120
```

---

## 3. No `KillMode=process` on Worker Quadlet — **P2**

Default kill mode on podman quadlets is `mixed` (SIGTERM main, then KILL cgroup). For workers that may spawn sub-processes or worker threads, `KillMode=process` lets children exit cleanly on stop.

**Risk:** Orphaned temp files, stale socket locks, or un-flushed agent state if children are killed before main process cleans up.

**Fix:** Add to worker `[Service]`:
```
KillMode=process
```

**Note:** Only if workers actually spawn sub-processes. If they're single-process, this is cosmetic.

---

## 4. Inlined Secrets in Quadlet Files — **Low Risk / Awareness**

Both `render_pg_quadlet()` and `render_worker_quadlet()` embed `POSTGRES_PASSWORD`, `AGENT_AUTH_TOKEN`, and `TENSORZERO_API_KEY` directly into the `.container` file.

**Mitigation already in place:** `chmod 0600` on the quadlet file, `chown <tenant>:<tenant>` on `~/.config/containers/`. These secrets also exist in `lunarwing.env` (also `0600`), so this is a wash — not a regression.

**Risk:** Root can always read `0600` files. A root compromise exposes the token regardless of whether it's in the quadlet or the env file. Same attack surface.

**No action needed** — just worth documenting for security reviews.

---

## 5. No Explicit Volume Creation for PG Named Volume — **P3**

The PG quadlet references `Volume=lunarwing-pg-${name}:/var/lib/postgresql/data` but the named volume is never explicitly created. Podman auto-creates it on first run.

**Risk:** Rootless podman maps the container's UID 0 (postgres inside the container) to the tenant's subuid range. If the PG image's entrypoint initializes with a different UID, the volume may be owned by the wrong host UID. Works with `pgvector/pgvector:pg16` but may break on image updates.

**Mitigation:** Add explicit `podman volume create lunarwing-pg-${name}` as the tenant user in `add_tenant()` before the quadlet render, or document the auto-creation behavior.

**Observation:** Higher risk for rootless than rootful because subuid mapping adds complexity.

---

## 6. Worker Quadlet Missing `Environment= for Worker Mode — P2

The worker quadlet conditions on `$worker == "nanocode"` to emit `Exec=--mode websocket` but does not set the equivalent environment variable that the imperative `_ctr run` path sets for nanocode mode.

**Current code** (from `start_tenant_nanocode()` imperative path):
```
--env NANOCODE_MODE=websocket
```

The quadlet path *does* emit this — I misread during the review. ✅ No fix needed.

---

## 7. `WantedBy=default.target` — Correct ✅

Both quadlets target `default.target`, which is correct for user-level systemd units (`systemctl --user`). This ensures the lingering user manager starts them at boot. No change needed.

---

## 8. `Image=` Without Registry Prefix — **P3**

Worker quadlet uses `Image=lunarwing-worker-nanocode:latest` and `Image=lunarwing-worker-pebble:latest`. These are local images built from the repo, not pulled from a registry. Works for the current setup.

**Risk:** If the image is ever built through CI and pushed to a registry, the `Image=` key needs a full registry prefix (e.g., `ghcr.io/LunarWingOrg/worker-nanocode:latest`). Podman won't auto-search registries for names without a prefix.

**No action needed** — just a note for future CI/CD integration.

---

## Summary

| # | Item | Priority | Risk |
|---|------|----------|------|
| 1 | Worker health check missing | **P1** | Self-heal blind to dead agent in running container |
| 2 | Worker TimeoutStartSec missing | **P2** | Cold-boot kill on slow image pulls |
| 3 | KillMode=process missing | **P2** | Orphaned temp files on stop |
| 4 | Inlined secrets in quadlet files | **Low** | Same as env file, not a regression |
| 5 | PG volume not explicitly created | **P3** | May break on image change (rootless subuid) |
| 6 | Nanocode mode env | **✅ OK** | Already emitted correctly |
| 7 | WantedBy=default.target | **✅ OK** | Correct for user-level units |
| 8 | Image= without registry prefix | **P3** | Future CI/CD concern |

**Recommended first fix:** Item 1 — 4 lines in the quadlet template, highest impact.

---

— Baud 🦄
