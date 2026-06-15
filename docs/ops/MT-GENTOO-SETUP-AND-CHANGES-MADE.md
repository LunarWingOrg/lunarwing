# Multi-Tenant on Gentoo + OpenRC + Podman — Setup & Changes Made

This document records the setup of a 3-tenant LunarWing multi-tenant deployment on a
**Gentoo / OpenRC** host using **Podman** (instead of Docker), and every change made along
the way. It is the experimental counterpart to the validated production path documented in
[`MULTITENANCY-PRODUCTION.md`](MULTITENANCY-PRODUCTION.md), which assumes systemd + Docker.

- **Host:** Gentoo, OpenRC (PID 1 = `init`), no systemd
- **Container runtime:** Podman 5.8.2 (rootful, run by the admin script as root)
- **Tenants:** `zeus` (ports 10000–10009), `mars` (10010–10019), `ate` (10020–10029)
- **Branch:** `2026-06-15-eris-gentoo-1-1.1.4` — all changes for this Gentoo+Podman work land here
- **Code change:** commit `1314cca9` (`ic/scripts/lunarwing-mt-admin.sh`)

> This is best-effort on OpenRC. The upstream `MULTITENANCY-HARNESS.md` notes the OpenRC path is
> "not yet fully validated"; this session is part of validating it.

---

## 1. Host prerequisites installed

The admin script (`lunarwing-mt-admin.sh`) requires `jq` and a container runtime; neither was
present. On Gentoo:

```bash
# iptables needs the nftables USE flag for containers-common/podman.
# Written to /etc/portage/package.use/lunarwing-mt:
#   net-firewall/iptables nftables
sudo emerge --quiet-build=y app-misc/jq app-containers/podman
```

Podman's image resolution had to be pointed at Docker Hub so the unqualified
`pgvector/pgvector:pg16` image (hardcoded in the admin script) resolves without a TTY prompt.
Written to `/etc/containers/registries.conf.d/zz-lunarwing-docker-io.conf`:

```toml
unqualified-search-registries = ["docker.io"]
```

Then pre-pulled the Postgres image (optional, but avoids a stall during `add-tenant`):

```bash
sudo podman pull pgvector/pgvector:pg16
```

`doctor` notes (all benign on this host):

- `[FAIL] rustup installed` — the host has Rust via portage, not rustup. **Not a blocker:**
  `add-tenant` installs a per-tenant rustup toolchain into each tenant's `~/.cargo`/`~/.rustup`,
  and tenant builds use that, not the host toolchain.
- `[FAIL] port registry exists` — created on the first `add-tenant`.
- `[FAIL] nanocode/pebble worker image exists` — not using the worker containers.

---

## 2. Code change: env-file corruption (OpenRC-fatal, systemd-latent)

**Commit `1314cca9`.** This is the most important fix.

### Symptom

After `add-tenant`, the main daemon failed to start under OpenRC. The init script's `load_env()`
does a shell `. source` of `lunarwing.env`, which errored with a flood of
`command not found` / `syntax error` lines referring to `LS_COLORS`, `SUDO_COMMAND`, etc.

### Root cause

`write_tenant_lunarwing_env()` wrote `lunarwing.env` with an **unquoted** heredoc delimiter
(`cat > "$path" <<ENVEOF`) and a comment line containing a literal backtick expression:

```sh
# channel (via the capabilities `env` source). ADAPTER_PORT/WEECHAT_ADAPTER_PORT
```

Because the heredoc was unquoted, the shell executed the backticked `env` command **at file-write
time** and injected the entire process environment into the file. The injected newlines broke out
of the `#` comment, so the env file ended up with dozens of bare lines like `LS_COLORS=...` and
`SUDO_COMMAND=... add-tenant zeus`.

### Why it's OpenRC-specific

- **systemd** loads env via `EnvironmentFile=`, whose parser treats each line as `KEY=VALUE`,
  ignores comments, and skips malformed lines — so the junk is silently tolerated and the daemon
  starts. **The bug is latent there.**
- **OpenRC** `load_env()` does `. "$file"` (a shell *source*), which **executes** the injected
  lines → the service fails to start.

This is why the same script "works" on the systemd/Docker production leg but breaks here.

### Fix

Replace the backticks with single quotes so nothing is executed:

```diff
-# channel (via the capabilities `env` source). ADAPTER_PORT/WEECHAT_ADAPTER_PORT
+# channel (via the capabilities 'env' source). ADAPTER_PORT/WEECHAT_ADAPTER_PORT
```

Only `lunarwing.env`'s heredoc was affected — `proxy.env`/`xmpp-bridge.env` have no backticks, and
the `config.toml` writer uses a *quoted* `<<'HDR'` heredoc (safe). **Recommend upstreaming**: the
bug exists for all hosts; it's only fatal on OpenRC.

---

## 3. Code change: HTTP webhook hardening

**Same commit `1314cca9`.** The env generator set `HTTP_PORT` but not `HTTP_HOST`, so the inbound
HTTP webhook bound to `0.0.0.0` (all interfaces) — a divergence from the "all HTTP services bind
`127.0.0.1`" policy. It also never set `HTTP_WEBHOOK_SECRET`, so the `http` channel failed to start
and logged an ERROR every boot.

Fix — `write_tenant_lunarwing_env()` now emits:

```
HTTP_HOST=127.0.0.1
HTTP_PORT=$http_port
HTTP_WEBHOOK_SECRET=$webhook_secret   # generated per tenant
```

Result: the webhook binds localhost-only and the `http` channel starts cleanly
(`HTTP channel ready (127.0.0.1:10001)`).

---

## 4. OpenRC operational notes

### `start-tenant` and the WeeChat units

`start_tenant_openrc()` starts **five** services in order — `weechat-<t>`,
`lunarwing-weechat-adapter-<t>`, `lunarwing-proxy-<t>`, `xmpp-bridge-<t>`, `lunarwing-<t>` —
and does **not** guard them with `|| true`. If the `weechat` binary or the Python `aiohttp`
package is missing, the weechat/adapter services fail and `start-tenant` aborts **before**
starting the main daemon.

The main daemon does **not** actually require WeeChat: its `depend()` is only
`need net localmount` (weechat is soft `after`-ordering), and the `lunarwing_rc_need` variable in
`/etc/conf.d/lunarwing-<t>` is inert (nothing reads it).

**If you don't need the WeeChat channel,** start the three core services directly and skip
weechat + adapter:

```bash
sudo rc-service lunarwing-proxy-<t>   start
sudo rc-service xmpp-bridge-<t>       start
sudo rc-service lunarwing-<t>         start
```

To enable the full documented `start-tenant` flow (incl. WeeChat) instead, install the deps:
`emerge net-irc/weechat dev-python/aiohttp` (this host already had `tmux` + `weechat`; only
`aiohttp` was missing).

### Boot persistence (implemented)

Reboot survival on OpenRC needs two pieces:

**1. Postgres containers.** The OpenRC units don't start the per-tenant Postgres container, and
Podman (unlike Docker) has no daemon to honor `--restart unless-stopped` — so after a reboot the
containers would stay stopped and the daemons couldn't connect. The fix is a small OpenRC service,
`lunarwing-pg` (committed as [`../../ic/systemd/lunarwing-pg.openrc`](../../ic/systemd/lunarwing-pg.openrc)),
that auto-discovers every `lunarwing-pg-*` container, `podman start`s them, and blocks until each
accepts connections. It declares `before` the daemons so they start against a ready DB:

```bash
sudo install -m 0755 ic/systemd/lunarwing-pg.openrc /etc/init.d/lunarwing-pg
sudo rc-update add lunarwing-pg default
```

> The script ships with `before lunarwing-zeus lunarwing-mars lunarwing-ate`; edit that line (or
> set `rc_before` in `/etc/conf.d/lunarwing-pg`) when your tenant set changes.

**2. Per-tenant services.** Add each tenant's three core services to the default runlevel (skip
weechat/adapter unless their deps are installed):

```bash
for t in zeus mars ate; do
  sudo rc-update add lunarwing-proxy-$t default
  sudo rc-update add xmpp-bridge-$t     default
  sudo rc-update add lunarwing-$t       default
done
```

Verify ordering is PG → proxy/bridge → daemon:

```bash
sudo rc-service lunarwing-pg ibefore     # -> lunarwing-zeus lunarwing-mars lunarwing-ate
sudo rc-service lunarwing-zeus iafter    # -> xmpp-bridge-zeus lunarwing-proxy-zeus lunarwing-pg
```

> A future improvement is to bake both pieces into `lunarwing-mt-admin.sh` directly (render the
> Postgres-start into the daemon's OpenRC `start_pre` and `rc-update add` on `start-tenant`) so no
> manual steps are needed — see the discussion in the session notes.

---

## 5. Gotchas observed (not bugs)

### The gateway token shown in the log can be stale

The startup banner (with the `http://127.0.0.1:PORT/?token=...` URL) is written to
`logs/lunarwing.log` only on the **first** boot and is **not** rewritten on restart. An old token
can therefore linger in the log and look authoritative.

**The authoritative gateway token is `GATEWAY_AUTH_TOKEN` in `lunarwing.env`**, which is exactly
what `lunarwing-mt-admin.sh tokens <t>` reports. Verified: the env token authenticates
(`GET /api/gateway/status` → HTTP 200) while the stale log token is rejected (401). Auth is via
`Authorization: Bearer <tok>` (or `?token=` on SSE/WS endpoints only; see
`ic/src/channels/web/auth.rs`). `/api/health` is unauthenticated.

### Orphaned `supervise-daemon` after a failed start

When the daemon failed the first time (env bug), `supervise-daemon` had still forked the binary,
which kept holding the gateway port. A subsequent `remove`/`re-add` lost the supervisor tracking,
so OpenRC reported "stopped" while the orphan kept running ("already running" on next start). If
you hit this, kill the orphan supervisor + child (`kill <supervisor-pid>`; verify with
`pgrep -u <t> -f target/release/lunarwing`) before restarting.

---

## 6. Tenant inventory

| Tenant | Base | Gateway | HTTP | Bridge | PG | Proxy | Orchestrator |
|--------|------|---------|------|--------|----|-------|--------------|
| zeus | 10000 | 10000 | 10001 | 10002 | 10003 | 10004 | 10006 |
| mars | 10010 | 10010 | 10011 | 10012 | 10013 | 10014 | 10016 |
| ate  | 10020 | 10020 | 10021 | 10022 | 10023 | 10024 | 10026 |

All HTTP services bind `127.0.0.1`. Postgres containers: `lunarwing-pg-<t>` on
`127.0.0.1:<pg-port>:5432`. Access a gateway via SSH forward
(`ssh -L 10000:127.0.0.1:10000 user@host`) and the token from `mt-admin.sh tokens <t>`.

---

## 7. Quick reference — full sequence used

```bash
# 0. host prereqs (one time)
echo 'net-firewall/iptables nftables' | sudo tee /etc/portage/package.use/lunarwing-mt
sudo emerge --quiet-build=y app-misc/jq app-containers/podman
echo 'unqualified-search-registries = ["docker.io"]' \
  | sudo tee /etc/containers/registries.conf.d/zz-lunarwing-docker-io.conf
sudo podman pull pgvector/pgvector:pg16

# 1. per tenant
sudo ic/scripts/lunarwing-mt-admin.sh add-tenant   <t>     # user, toolchain, clone, env, PG, units
sudo ic/scripts/lunarwing-mt-admin.sh build-tenant <t>     # release build (flock-serialized)
# start CORE services directly (skip weechat/adapter unless aiohttp is installed):
sudo rc-service lunarwing-proxy-<t> start
sudo rc-service xmpp-bridge-<t>     start
sudo rc-service lunarwing-<t>       start

# 2. verify
sudo ic/scripts/lunarwing-mt-admin.sh list-tenants
sudo ic/scripts/lunarwing-mt-admin.sh tokens <t>
curl -s -o /dev/null -w '%{http_code}\n' \
  -H "Authorization: Bearer $(sudo ic/scripts/lunarwing-mt-admin.sh tokens <t> | grep -oE '[a-f0-9]{64}')" \
  http://127.0.0.1:<gateway-port>/api/gateway/status      # -> 200
```
