# Gentoo Package List — Live Multi-Tenant Environment

Packages needed to run a live LunarWing multi-tenant deployment on **Gentoo + OpenRC** via
`ic/scripts/lunarwing-mt-admin.sh`, including the infra health-check + self-heal pipeline.

This list reflects what an actual Gentoo/OpenRC/Podman MT bring-up required. Atoms are Gentoo
package names; adjust for your profile (e.g. `clang` moved to `llvm-core/` on newer profiles).

> Tip: run `sudo ic/scripts/lunarwing-mt-admin.sh doctor` — it reports most of these as
> `[PASS]`/`[FAIL]`. A `[FAIL] rustup installed` on the host is benign (see Build toolchain).

---

## 1. Core (required)

The admin script, the per-tenant daemons, and the health/self-heal pipeline need these:

| Package | Why |
|---------|-----|
| `app-misc/jq` | Port registry (`/etc/lunarwing/ports.json`), health-check JSON, self-heal, send-notification |
| `dev-vcs/git` | Per-tenant repo clones |
| `dev-lang/python` (python3) | TensorZero proxy, WeeChat WS adapter, all `health-*.sh` scripts |
| `net-misc/curl` | Self-heal Gotify pages, `health-models` probe, gateway deep-checks |
| `sys-apps/util-linux` | Provides `flock` — build lock + self-heal single-instance lock (usually already installed) |

```bash
sudo emerge app-misc/jq dev-vcs/git net-misc/curl
```

## 2. Container runtime (required) — Podman or Docker

Each tenant's PostgreSQL runs as a container, so one runtime is **required**. This deployment uses
**Podman**:

```bash
# Podman needs the nftables USE flag on iptables (pulled in by containers-common):
echo 'net-firewall/iptables nftables' | sudo tee /etc/portage/package.use/lunarwing-mt
sudo emerge app-containers/podman      # pulls containers-common, netavark, aardvark-dns,
                                       # crun, conmon, fuse-overlayfs, passt, ...
```

Then point Podman's unqualified image search at Docker Hub so the hardcoded
`pgvector/pgvector:pg16` image resolves without a TTY prompt:

```bash
echo 'unqualified-search-registries = ["docker.io"]' \
  | sudo tee /etc/containers/registries.conf.d/zz-lunarwing-docker-io.conf
sudo podman pull pgvector/pgvector:pg16   # optional pre-pull; add-tenant does it otherwise
```

(Docker alternative: `app-containers/docker` + `app-containers/docker-cli`, added to a runlevel.)

> The `pgvector/pgvector:pg16` **container image** is pulled, not emerged.

## 3. Cron daemon (required for the health/self-heal schedule)

The host-global health-check → self-heal pipeline is scheduled via cron/fcron by
`ensure_health_pipeline()`. Without a cron daemon the schedule never fires:

```bash
sudo emerge sys-process/fcron      # or sys-process/cronie, or sys-process/dcron
```

`mt-admin` adds the cron daemon to the `default` runlevel automatically when it installs the
schedule (`*/15` by default). `fcron` is preferred (supports catch-up of missed runs).

## 4. Rust build toolchain (per-tenant builds)

| Package | Notes |
|---------|-------|
| `dev-util/rustup` | **Optional on the host** — `add-tenant` auto-installs rustup *per tenant* (via rustup.sh into the tenant's home) and sets the stable toolchain + `wasm32-wasip1`/`wasm32-wasip2` targets. The `doctor` `[FAIL] rustup installed` for the host is therefore harmless. |
| `sys-devel/clang` (or `llvm-core/clang`) | Provides `libclang`, needed by Rust crates that use `bindgen`/`-sys` native bindings during the build. (`gcc` is already present for the C toolchain.) |

`cargo-component` + `wasm-tools` (for `build-tenant --with-wasm`) are installed **per tenant** via
`cargo install` by `add-tenant` — not Gentoo packages.

## 5. WeeChat channel (optional — only if using WeeChat)

Required only if you enable the WeeChat relay channel + its services; the core MT stack and the
health pipeline do **not** need these:

| Package | Why |
|---------|-----|
| `net-irc/weechat` | The IRC client the agent talks to |
| `app-misc/tmux` | The `weechat-<tenant>` OpenRC unit runs weechat inside a tmux session |
| `dev-python/aiohttp` | Required by the WeeChat WS adapter (`lunarwing-weechat-adapter-<tenant>`); without it the adapter crashes on import |

```bash
sudo emerge net-irc/weechat app-misc/tmux dev-python/aiohttp
```

> If WeeChat deps are missing, `start-tenant` skips those services non-fatally (the core daemon
> does not depend on them).

---

## One-shot install (Podman + fcron + WeeChat)

```bash
echo 'net-firewall/iptables nftables' | sudo tee /etc/portage/package.use/lunarwing-mt
sudo emerge \
  app-misc/jq dev-vcs/git net-misc/curl sys-apps/util-linux \
  app-containers/podman \
  sys-process/fcron \
  sys-devel/clang \
  net-irc/weechat app-misc/tmux dev-python/aiohttp
echo 'unqualified-search-registries = ["docker.io"]' \
  | sudo tee /etc/containers/registries.conf.d/zz-lunarwing-docker-io.conf
```

`rustup`, `cargo-component`, `wasm-tools`, and the wasm32 targets are handled per-tenant by
`add-tenant`, so they're intentionally omitted above.

## Already expected on a Gentoo/OpenRC host

`bash` (>= 4), `coreutils`, `findutils`, `sed`, `gawk`, `gcc`, OpenRC (`rc-service`, `rc-update`),
and a running network. These are assumed present and not listed above.

---

## Cross-reference

- Setup walkthrough: [`../ops/MT-GENTOO-SETUP-AND-CHANGES-MADE.md`](../ops/MT-GENTOO-SETUP-AND-CHANGES-MADE.md)
- Admin quickstart: [`MT-ADMIN-QUICKSTART.md`](MT-ADMIN-QUICKSTART.md)
- Production reference: [`../ops/MULTITENANCY-PRODUCTION.md`](../ops/MULTITENANCY-PRODUCTION.md)
