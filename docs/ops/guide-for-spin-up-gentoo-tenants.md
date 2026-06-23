# Spawn one live LunarWing tenant `luna1` (podman + OpenRC, Gentoo)

Grounded in `ic/scripts/lunarwing-mt-admin.sh` and `docs/ops/MULTITENANCY-PRODUCTION.md`. Gaps are flagged inline rather than guessed.

The whole flow is basically **four mt-admin subcommands**: `add-tenant` → `build-tenant` → `start-tenant` → `status`. Everything else is sanity-checking around them.

Run from repo root (`/home/eris/lunarwing`). Mutating subcommands require root (the script exits unless `EUID==0`), so they're shown with `sudo`. Read-only ones (`doctor`/`status`/`tokens`/`list-tenants`) don't. Example tenant name is `luna1` — swap it everywhere.

---

## 0. Preconditions — pin selection, gate on `doctor`

There is **no `--init-system` flag**; selection is env-override + autodetect, so export both to make the run deterministic.

```bash
cd /home/eris/lunarwing

export LUNARWING_SERVICE_MANAGER=openrc      # systemd | openrc
export LUNARWING_CONTAINER_RUNTIME=podman    # docker | podman  (podman => rootless per-tenant)

ls -l /run/openrc/softlevel && command -v rc-service rc-update
command -v podman && podman info >/dev/null && echo "podman OK"
test -f /etc/lunarwing/ports.json && jq '.tenants' /etc/lunarwing/ports.json || echo "no registry yet (add-tenant creates it)"

# Dependency + health gate — clear every [FAIL] before step 1
sudo LUNARWING_SERVICE_MANAGER=openrc LUNARWING_CONTAINER_RUNTIME=podman \
  ic/scripts/lunarwing-mt-admin.sh doctor
```

## 1. Create the tenant

Creates the OS user, allocates the 10-port block in `/etc/lunarwing/ports.json`, clones the repo to `/home/luna1/lunarwing/ic`, generates env, starts the per-tenant Postgres container, and renders the OpenRC units.

```bash
sudo LUNARWING_SERVICE_MANAGER=openrc LUNARWING_CONTAINER_RUNTIME=podman \
  ic/scripts/lunarwing-mt-admin.sh add-tenant luna1 --docker-group
```

Optional `add-tenant` flags (all take a value except booleans `--docker-group`/`--no-health`): `--xmpp-jid <jid>` (default `luna1@xmpp.localhost`), `--xmpp-password <pass>`, `--llm-api-key <key>`, `--llm-base-url <url>`, `--tensorzero-url <url>`, `--gotify-url <url>`, `--no-health`.

## 2. Build everything (binary + WASM + workers)

One canonical command. `build-tenant` is flock-serialized (OOM-safe) and builds in order: `lunarwing` binary → xmpp-bridge → WASM (built **and installed** with `--with-wasm`) → nanocode + pebble worker images. Worker images are host-global and must exist before `start-tenant` will launch those workers. **This is the slow first build** — if base images were wiped by a `podman system reset`, rust/debian/bun re-pull and recompile here.

```bash
sudo LUNARWING_SERVICE_MANAGER=openrc LUNARWING_CONTAINER_RUNTIME=podman \
  ic/scripts/lunarwing-mt-admin.sh build-tenant luna1 --with-wasm --with-nanocode --with-pebble
```

Standalone rebuilds of the shared worker images, if ever needed:

```bash
sudo LUNARWING_CONTAINER_RUNTIME=podman ic/scripts/lunarwing-mt-admin.sh build-nanocode-worker   # [--no-cache]
sudo LUNARWING_CONTAINER_RUNTIME=podman ic/scripts/lunarwing-mt-admin.sh build-pebble-worker     # [--no-cache]
sudo ic/scripts/lunarwing-mt-admin.sh install-wasm luna1   # only if WASM built without install
```

Manual fallback ONLY where mt-admin doesn't reach — the exact podman commands mt-admin would run (nanocode needs its source copied first because `COPY` can't follow symlinks; `--network=host --format docker` are podman-only):

```bash
# nanocode image (context = lunarcode4lunarwing/)
cp -rL /home/eris/lunarwing/nanocode-config/nanocode /home/eris/lunarwing/lunarcode4lunarwing/nanocode
podman build --network=host --format docker -t lunarwing-worker-nanocode:latest \
  /home/eris/lunarwing/lunarcode4lunarwing

# pebble image (Dockerfile in pebble4lunarwing/, context = repo root)
podman build --network=host --format docker -t lunarwing-worker-pebble:latest \
  -f /home/eris/lunarwing/pebble4lunarwing/Dockerfile /home/eris/lunarwing
```

### 2b. Only if using pebble — configure it before starting

`configure-pebble` writes `pebble.env` (mode 600), read by the worker container on next start, so this must precede `start-tenant`.

```bash
sudo ic/scripts/lunarwing-mt-admin.sh configure-pebble luna1 --nanogpt-api-key <key>   # optional: --model openai/gpt-5.2
```

> **Gap:** the `codex` worker is not wired into mt-admin — it's manual-only from `codex4lunarwing/` (`docker build -t lunarwing-worker-codex:latest .` or `docker compose up --build`) and not part of this OpenRC/podman path.

## 3. Start + enable services (OpenRC)

`start-tenant` runs the whole sequence itself: `rc-update add lunarwing-luna1 default`, then starts pg → (optional weechat/adapter) → proxy → xmpp-bridge → daemon in dependency order, then boot-enables every unit that came up. Workers start only if their images exist (step 2).

```bash
sudo LUNARWING_SERVICE_MANAGER=openrc LUNARWING_CONTAINER_RUNTIME=podman \
  ic/scripts/lunarwing-mt-admin.sh start-tenant luna1
```

Manual fallback (the boot-persistence part mt-admin already covers, if wiring a unit by hand):

```bash
rc-update add lunarwing-luna1 default
rc-service lunarwing-luna1 start
rc-service lunarwing-luna1 status
```

## 4. Verify it's live

```bash
sudo ic/scripts/lunarwing-mt-admin.sh status luna1        # ports + pg/worker container state + OpenRC service states
sudo ic/scripts/lunarwing-mt-admin.sh list-tenants        # all tenants + port allocations
sudo ic/scripts/lunarwing-mt-admin.sh tokens luna1        # gateway auth token for the web UI

rc-service lunarwing-luna1 status
rc-service lunarwing-pg-luna1 status

# First tenant on an empty registry => gateway port 10000, but read the real value from status/list-tenants
curl -sS -o /dev/null -w 'gateway HTTP %{http_code}\n' http://127.0.0.1:10000/

# Optional re-run of the dependency/health gate
sudo LUNARWING_SERVICE_MANAGER=openrc LUNARWING_CONTAINER_RUNTIME=podman \
  ic/scripts/lunarwing-mt-admin.sh doctor

tail -f /home/luna1/lunarwing/logs/lunarwing.log
```

> Any HTTP code (`200`/`401`) = gateway up; connection-refused = not live. Log in by pasting the `tokens luna1` value into `http://127.0.0.1:<gateway-port>`.

---

## Notes / placeholders

- **Tenant name** is lowercased and sanitized to `[a-z0-9-]`. Reserved prefixes `pg-*`, `proxy-*`, `nanocode-*`, `pebble-*`, `weechat-*` are rejected. Substitute your own name everywhere `luna1` appears, including rendered unit names `lunarwing-<name>`, `lunarwing-pg-<name>`, `xmpp-bridge-<name>`, `lunarwing-proxy-<name>`, `lunarwing-weechat-<name>`, `lunarwing-weechat-adapter-<name>`, and worker units `lunarwing-nanocode-<name>` / `lunarwing-pebble-<name>`.
- **Ports** auto-allocated by `add-tenant` into `/etc/lunarwing/ports.json` (range `10000–19999`, 10-port aligned blocks; first block base `10000` on a fresh registry). Offsets within the block: `gateway=base+0`, `http=+1`, `bridge=+2`, `postgres=+3`, `proxy=+4`, `weechat=+5`, `orchestrator=+6`, `nanocode_wss=+7`, `pebble_wss=+8`, `weechat_adapter=+9`. Always read the actual numbers from `status`/`list-tenants`.
- **Base dir / layout** for `luna1`: home `/home/luna1`; LunarWing root `/home/luna1/lunarwing`; repo clone `/home/luna1/lunarwing/ic`; env dir `/home/luna1/lunarwing/env` (holds `lunarwing.env`, `pg.secret`, and `pebble.env` if configured); **state dir = `LUNARWING_BASE_DIR` = `/home/luna1/lunarwing/state`**; logs `/home/luna1/lunarwing/logs`; run/pids `/home/luna1/lunarwing/run`.
- **Init-system / runtime selection** — no `--init-system` flag. Selection is the env override `LUNARWING_SERVICE_MANAGER=openrc|systemd` (else autodetected: `/run/openrc/softlevel` ⇒ openrc) and `LUNARWING_CONTAINER_RUNTIME=podman|docker` (else autodetected). Exporting both, as in step 0, makes the run deterministic. With podman the script sets `MT_ROOTLESS=true`: all per-tenant pg/worker containers run as the tenant user against their own rootless store (override with `LUNARWING_MT_ROOTLESS` if ever needed). Per-tenant image cleanup later lives in `/home/luna1/.local/share/containers`, **not** root's store.
- **OpenRC vs systemd caveat** — on OpenRC the units are **system-level** init scripts in `/etc/init.d/` using `supervise-daemon` with `command_user=<tenant>`; logs go to `/home/luna1/lunarwing/logs/lunarwing.log` (tail it, there is no `journalctl --user`). Boot persistence is `rc-update add lunarwing-luna1 default` (already done by `start-tenant`). The systemd-only concepts in the docs — `~/.config/systemd/user/` units, `loginctl enable-linger`, podman Quadlet `.container` files — do **not** apply here. One overlap: `add-tenant` still calls `loginctl enable-linger luna1`, which works under elogind to keep the rootless runtime dir across reboots (not a systemd dependency).
- **TensorZero proxy** is **not** a container under OpenRC — it runs as a `python3` process under `supervise-daemon` owned by the tenant, from the tenant's own `tensorzero-proxy-configurations/lunarwing-proxy.py`. Only Postgres and the workers are podman containers.
- **WeeChat / weechat-adapter** are optional; `start-tenant` skips them non-fatally if their deps are missing, and the main daemon does not depend on them.
- **`doctor`** returns non-zero if any check fails and includes a "root" assertion — run it via `sudo` so that check passes, and clear every `[FAIL]` before step 1.
