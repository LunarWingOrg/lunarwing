# Proposal: MT WeeChat Service Consistency & WASM Channel Pruning

*Drafted 2026-06-15, for the Gentoo + OpenRC + Podman multi-tenant deployment on branch
`2026-06-15-eris-gentoo-1-1.1.4`. Tenants: zeus / mars / ate.*

## Scope

Two related hygiene issues surfaced after installing WASM extensions (`build-all --with-wasm`)
across the three tenants. Neither is breaking — all tenants are healthy and reboot-proven — but
both are worth resolving before the next phase. This proposal documents the current state and the
options; nothing here has been applied.

Related docs: [`../ops/MT-GENTOO-SETUP-AND-CHANGES-MADE.md`](../ops/MT-GENTOO-SETUP-AND-CHANGES-MADE.md),
[`../guides/MT-ADMIN-QUICKSTART.md`](../guides/MT-ADMIN-QUICKSTART.md) (WeeChat setup is Part 2).

---

## Issue 1: WeeChat service consistency

### Current state (verified 2026-06-15)

| Tenant | `weechat-<t>` | `lunarwing-weechat-adapter-<t>` |
|--------|---------------|---------------------------------|
| zeus   | **enabled + started** | **enabled + started** |
| mars   | not enabled, stopped | not enabled, stopped |
| ate    | not enabled, stopped | not enabled, stopped |

### How we got here

- mars/ate were boot-enabled (`rc-update add`) only for the three **core** services
  (`lunarwing-proxy-<t>`, `xmpp-bridge-<t>`, `lunarwing-<t>`).
- zeus *additionally* picked up `weechat-zeus` + `lunarwing-weechat-adapter-zeus` because an
  earlier `start_tenant_openrc zeus` test started them (weechat + tmux were present, and `aiohttp`
  is now installed), and the baked-in auto-enable loop `rc-update add`s whatever is running.

So the inconsistency is an artifact of the rollout sequence, not a deliberate per-tenant choice.

### Important caveat

Even on zeus the WeeChat path is **not functional yet** — the `weechat-zeus` (tmux/weechat) and
adapter services run, but the WeeChat relay and the `weechat.capabilities.json` channel config have
not been set up (see `MT-ADMIN-QUICKSTART.md` Part 2). So zeus currently runs WeeChat services that
do nothing useful.

### Options

**A — WeeChat on none (recommended for now; simplest, matches "core stack only").**
Retire WeeChat services on zeus so all three match:

```bash
sudo rc-service lunarwing-weechat-adapter-zeus stop
sudo rc-service weechat-zeus stop
sudo rc-update del lunarwing-weechat-adapter-zeus default
sudo rc-update del weechat-zeus default
```
(The init scripts can stay on disk; they just won't be enabled/started.)

**B — WeeChat on all three.**
Enable + start on mars/ate and actually configure the relay everywhere:

```bash
for t in mars ate; do
  sudo rc-service weechat-$t start
  sudo rc-service lunarwing-weechat-adapter-$t start
  sudo rc-update add weechat-$t default
  sudo rc-update add lunarwing-weechat-adapter-$t default
done
# then configure each tenant's WeeChat relay + weechat.capabilities.json per
# MT-ADMIN-QUICKSTART.md Part 2 (relay add api, RELAY_PASSWORD, relay_url, etc.)
```

### Recommendation

Option **A** unless WeeChat is actually wanted on this deployment. WeeChat enablement should be a
deliberate per-tenant decision, not a rollout side-effect.

---

## Issue 2: WASM channel sprawl & log noise

### Current state (verified 2026-06-15)

`build-all --with-wasm` installed **all five** channels into every tenant's `state/channels/`:

```
zeus / mars / ate:  darkirc  multica  telegram  weechat  xmpp
```

The daemon loads and starts **every** channel present in `state/channels/` on boot. Only `xmpp`
is wired for this deployment; the rest have no backing config:

| Channel | Why it errors | Symptom |
|---------|---------------|---------|
| telegram | no bot token | `Bot token validation failed: HTTP 404` |
| darkirc | no darkirc daemon on :6680 | connection refused, repeated |
| weechat | relay not configured (:10005) | connection refused, repeated |
| multica | not configured | connect failures |
| xmpp | OK — loads & starts | (functional channel) |

### Impact

The unconfigured channels poll on a timer and log an ERROR on every failed attempt
(~600+ ERROR lines per tenant within minutes of boot), and the daemon log is **not truncated on
restart** → unbounded log growth on a persistent host. Not harmful to the daemons, but noisy and a
slow disk risk.

### Options (not mutually exclusive)

**1 — Prune to what's used (recommended: keep `xmpp` only).**
Remove the unused channel artifacts from each tenant, then restart so they stop loading:

```bash
for t in zeus mars ate; do
  for ch in darkirc multica telegram weechat; do
    sudo rm -f /home/$t/lunarwing/state/channels/$ch.wasm \
               /home/$t/lunarwing/state/channels/$ch.capabilities.json
  done
  sudo rc-service lunarwing-$t restart
done
```

**2 — Configure the ones you keep** so they stop erroring (per-channel: bot token, darkirc daemon,
WeeChat relay, etc.).

**3 — Log rotation** as a backstop regardless of the above (e.g. logrotate on
`/home/<t>/lunarwing/logs/*.log` + `*.err`).

### Interaction with Issue 1

The WeeChat **channel** (WASM, in `state/channels/`) and the WeeChat **services**
(`weechat-<t>` + adapter) are two halves of one feature. Keep both or drop both:
- If pruning the `weechat` channel (Option 1 above), also take Issue 1 → Option A (retire the
  services).
- If keeping WeeChat (Issue 1 → Option B), do **not** prune the `weechat` channel, and configure
  both halves.

### Durability caveat

Pruning `state/channels/` is undone by the next `install-wasm` / `build-tenant --with-wasm` (which
reinstalls **all** channels). A durable fix would be a selective install (e.g. an allowlist of
channels per tenant in the admin script). Worth considering as a follow-up if the channel set is
meant to stay curated.

---

## Suggested combined plan

For a clean, quiet, consistent fleet matching the current "xmpp-only" reality:

1. Issue 2 → Option 1: prune all tenants down to `xmpp` (+ keep tools), restart.
2. Issue 1 → Option A: retire WeeChat services on zeus.
3. Add log rotation (Option 3) as a standing backstop.
4. (Follow-up) consider a per-tenant channel allowlist in `lunarwing-mt-admin.sh` so pruning
   survives future `--with-wasm` rebuilds.

## Open questions

- Which channels does this deployment actually want long-term (just `xmpp`, or also darkirc/multica
  for the planned darkirc work)?
- Should channel selection become a first-class admin-script option rather than post-hoc pruning?
