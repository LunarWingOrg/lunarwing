# WeeChat Channel Architecture

How LunarWing connects to IRC through WeeChat: the components, the end-to-end message
flow, the polling/latency model, the configuration-precedence rules (and the trap they
create), and the known issues with their fix status.

> **Why this doc exists.** A multi-hour debugging session upgrading the `sunburst` tenant
> showed that message delivery through this channel has several independent, *invisible*
> failure modes, and that the "WebSocket adapter" is actually drained by slow HTTP polling.
> Every incident re-derived the data flow and config rules from scratch. This is the
> authoritative reference so that doesn't happen again.

Line numbers below drift; treat them as hints, not contracts. Source of truth:
`ironclaw_weechat_wss/weechat_relay/src/lib.rs` (the WASM channel), `…/ws_adapter.py`
(the adapter), and `ic/src/channels/wasm/` (the host runtime).

---

## 1. Components

| Component | Where | Role |
|-----------|-------|------|
| **WeeChat** | per-tenant, runs in `tmux` (`weechat-<tenant>.service`) | The actual IRC client. Exposes the **relay `api`** plugin on the `weechat` port (MT: base+5). |
| **`ws_adapter.py`** | per-tenant Python process (`lunarwing-weechat-adapter-<tenant>.service`), `ironclaw_weechat_wss/weechat_relay/ws_adapter.py` | Holds a **WebSocket** to WeeChat's relay, subscribes to updates, buffers lines, and re-serves them over a small **HTTP API** on the `weechat_adapter` port (MT: base+9). |
| **WeeChat WASM channel** | in the LunarWing daemon; source `ironclaw_weechat_wss/weechat_relay/src/lib.rs` → `wasm32-wasip2`; loaded/run by `ic/src/channels/wasm/{loader,wrapper,runtime,setup}.rs` | Sandboxed channel that **polls the adapter over HTTP**, applies policy, and emits `IncomingMessage`s to the agent; sends replies back to WeeChat. |

### The three hops — only one is a WebSocket

```
        WebSocket (+ /api/sync push)            HTTP polling (every ~3s)
WeeChat  ⇇———————————————————————————⇉  ws_adapter.py  ⇇——————————————————⇉  LunarWing daemon
 relay   real-time, adapter-buffered      (:base+9)        request/response       (WASM channel)
(:base+5)
```

The **adapter↔WeeChat** hop is a real WebSocket and is real-time; the adapter even holds a
`/api/sync` subscription (`buffers`, `lines`). The **daemon↔adapter** hop is **HTTP polling** —
the sandboxed WASM can only make request/response calls (`channel_host::http_request`), so it
cannot hold a socket open. "ws-adapter" describes the *upstream* link, not the daemon's link.

**Implication:** IRC messages reach the adapter instantly and are buffered there; the daemon
only sees them on its next poll. End-to-end inbound latency ≈ the poll cadence (see §3).

---

## 2. End-to-end message flow

### Inbound (IRC → agent)

1. A message arrives in an IRC buffer in WeeChat (buffer name `irc.<network>.<target>`, e.g.
   `irc.sobes.#chan` or, for a DM/query, `irc.sobes.<nick>`).
2. The adapter (subscribed via WS/`/api/sync`) captures it and buffers it per-buffer.
3. The WASM channel's `on_poll` runs (host-driven, §3): `resolve_poll_url` picks the adapter
   (auto/websocket mode) or the relay directly (http mode), then `do_poll`:
   - `GET /api/config` — refresh `dm_policy`/`group_policy`/`allow_from`/`networks` (see §4).
   - For each known buffer, `GET /api/buffers/<buf>/lines?limit=10`.
4. `poll_buffer` keeps only **new** lines (id > per-buffer watermark in `state/last_seen_ids`)
   that carry the `irc_privmsg` tag and are **not** `self_msg`/`no_log`.
5. `handle_inbound_line` applies policy in order: parse `irc.<net>.<target>` → `network_allowed`
   (allowlist; empty/`all`/`*` = all) → exclude-networks → non-empty text → **DM vs group**
   (`is_dm` = target not starting with `#`/`&`/`!`) → `dm_policy`/`group_policy` + `allow_from`
   / pairing store.
6. Survivors are emitted via `channel_host::emit_message`; the host (`wrapper.rs`) dispatches
   them to the agent. `on_poll completed … emitted_count=N` is logged.

### Outbound (agent → IRC)

`on_respond` parses the reply's `metadata_json` (buffer/network/target/nick), chunks the text
to `max_chunk_length` (default 420), and `POST`s each chunk to the WeeChat **relay** `/api/input`
(via `relay_url`, not the adapter). Replies therefore go straight to WeeChat.

### Watermarks & new buffers

`do_poll` seeds a per-buffer watermark the **first time** it sees a buffer and does **not**
emit that first batch (avoids replaying history on startup). See §5 for the consequence on
freshly-created DM/query buffers.

---

## 3. Polling & latency

### The loop (`ic/src/channels/wasm/wrapper.rs`, `start_polling` / `execute_poll`)

Each channel gets its own polling task:

```
loop {
    interval_timer.tick().await;     // poll_interval (3s), MissedTickBehavior::Skip
    execute_poll().await;            // runs the WASM on_poll to completion
}
```

`tick` and `execute_poll` are **sequential**, so:

```
effective cadence  =  max(poll_interval, cycle_duration)
```

- **`poll_interval` = 3s**, hard floor (`default_poll_interval()=3`; `.max(3000)` in `lib.rs`;
  host `min_poll_interval_ms: 3000`). It cannot go below 3s.
- **`cycle_duration`** is bounded above by **`callback_timeout` = 30s**
  (`ic/src/channels/wasm/runtime.rs`), the `tokio::time::timeout` wrapping the WASM call.

So a slow cycle stretches the gap between polls all the way to ~30s. (Before the fixes below,
`MissedTickBehavior` was the default `Burst`, which then fired a burst of catch-up polls.)

### Per-cycle cost

Everything inside one `on_poll` is **sequential**, each call with its own timeout. A fresh
WASM instance is also created per poll (`create_store` + `instantiate_component`; the runtime
"instantiates fresh per callback").

| Step | Call | Timeout (after fixes) | Frequency |
|------|------|----------------------:|-----------|
| Adapter health probe | `GET /api/version` | **1.5s** (was 2s) | every poll (auto/websocket mode) |
| Config refresh | `GET /api/config` | **2s** (was 3s) | every poll |
| Per-buffer lines | `GET /api/buffers/<buf>/lines` | **2s** (was 5s) | every poll, ×N buffers |
| Buffer-list refresh | `GET /api/buffers` | 5s | every ~30 polls, or when empty |

Worst-case cycle ≈ `1.5 + 2 + 2·N` s (was `2 + 3 + 5·N`). In the normal case (responsive local
adapter) each call returns in milliseconds and the cadence is ~3s.

### Seeing the real cadence

```bash
sudo -u <tenant> XDG_RUNTIME_DIR=/run/user/$(id -u <tenant>) \
  journalctl --user -u lunarwing-<tenant>.service -f \
  | grep --line-buffered "Polling .* buffers via"
```

The gap between consecutive lines is the actual cadence. To measure how long a single cycle
takes, compare `calling on_poll channel=weechat` → `on_poll completed channel=weechat`.

> Channel debug logs are gated twice: by the `debug_logging` capability flag **and** by the
> daemon's `RUST_LOG`. See §5 — they used to be invisible at the default `RUST_LOG`.

---

## 4. Configuration & precedence

WeeChat config lives in several places; understanding the precedence is essential because a
stale value in a high-precedence layer silently overrides everything below it.

### At channel start (`load_channel_setup_field_overrides`, `ic/src/channels/wasm/setup.rs`)

For each capability `required_field`, the effective value is resolved **highest-first**:

| Precedence | Source | Notes |
|-----------:|--------|-------|
| 1 (highest) | DB `extensions.weechat.setup_fields` | Saved by the setup wizard / written by ops. |
| 2 | DB `setting_path` | If the field declares one. |
| 3 | `env` (capability `env` key) | **Gated to bundled channels** for security. Multi-tenant ports come from here (`RELAY_URL`, `WS_ADAPTER_URL`). |
| 4 (lowest) | capabilities `config` block | Defaults shipped in `weechat.capabilities.json`. |

Resolved overrides are merged on top of the caps `config` block and handed to `on_start`,
which persists them to channel workspace state (`state/relay_url`, `state/dm_policy`, …).

### At runtime (`do_poll` `/api/config`)

On **every poll**, `do_poll` fetches `GET /api/config` from the adapter (served from
`weechat_local_config.json` next to `ws_adapter.py`) and, if present, overwrites the workspace
state for `dm_policy`, `group_policy`, `allow_from`, and `networks`. Ports
(`relay_url`/`ws_adapter_url`) are **not** refreshed this way — they are set only at `on_start`.

So the live precedence is:

- **Ports:** `setup_fields` > `setting_path` > `env` > caps defaults (start-time only).
- **Policy (`dm_policy`/`group_policy`/`allow_from`/`networks`):** adapter `/api/config` (if it
  provides the key) > start-time value (above).

### ⚠ The shadowing trap

A leftover `extensions.weechat.setup_fields` row **shadows the caps config and the env for
every field it contains**. The classic symptom: *"I edited the installed `capabilities.json`
(or the env) and nothing changed."* This caused hours of confusion on `sunburst` — stale
`dm_policy` and `networks` values in that row overrode every edit.

Inspect and clear it (the `value` column is **`jsonb`**):

```bash
PGURL=$(sudo grep '^DATABASE_URL=' /home/<tenant>/lunarwing/env/lunarwing.env | cut -d= -f2-)
# inspect
sudo env PGSSLMODE=disable psql "$PGURL" -c \
  "SELECT value FROM settings WHERE key='extensions.weechat.setup_fields';"
# clear (caps + env then govern) OR surgically fix one key:
sudo env PGSSLMODE=disable psql "$PGURL" -c \
  "DELETE FROM settings WHERE key='extensions.weechat.setup_fields';"
sudo env PGSSLMODE=disable psql "$PGURL" -c \
  "UPDATE settings SET value = value || '{\"dm_policy\":\"open\"}'::jsonb \
   WHERE key='extensions.weechat.setup_fields';"
```

Then restart the daemon so `on_start` re-resolves.

---

## 5. Known issues & gotchas

| Issue | Symptom | Root cause | Status |
|-------|---------|------------|--------|
| **`networks="all"` matched literally** | Every message dropped: `line dropped (network not in allowlist): network=…, allowed=["all"]` | The allowlist compared names literally; `"all"` matched no real network. Convention was *empty = all*, but `"all"` is the obvious thing to type. | **Fixed** — `network_allowed()` treats `all`/`*` as wildcards (empty still = all). |
| **Channel debug logs invisible** | `debug_logging=true` produced nothing in the journal | The host forwarded all guest `Info/Debug/Trace` logs via `tracing::debug!`, dropped by the default `RUST_LOG=lunarwing=info`. | **Fixed** — faithful level mapping (`Info→info!`, `Trace→trace!`); `debug_logging` is now visible at `info`. |
| **Poll cadence balloons to ~30s** | Long, irregular gaps between polls | `tick` + `poll` sequential ⇒ cadence = `max(3s, cycle)`; cycle could approach the 30s `callback_timeout`; default `Burst` then fired catch-up bursts. | **Mitigated** — `MissedTickBehavior::Skip` + tightened per-call timeouts (§3). Real-time push is the deeper fix (§6). |
| **`poll_interval_ms` ignored** | Configuring the interval did nothing | Caps `config` key was `poll_interval_ms` but the struct field is `poll_interval_seconds` — different name ⇒ value dropped, struct default (3) used. | **Fixed** — caps key renamed to `poll_interval_seconds`. |
| **First DM in a new buffer swallowed** | First message after a query buffer is created never reaches the agent; the *second* does | A DM/query buffer is created *by* the first message; `do_poll` treated a brand-new buffer as "first sighting" and seeded its watermark **without emitting** that batch. | **Fixed** — `do_poll` now emits the first batch for new **DM/query** buffers (`is_dm_buffer`); channel buffers still seed-skip (they may load join backlog). |
| **Password is the *second* blocker** | After ports are fixed, the adapter returns 401 | The adapter authenticates incoming WASM requests against the per-tenant `RELAY_PASSWORD` (`check_auth`); the WASM must send it. | Handled by the port fix (relay_password injection) — see `WEECHAT-MULTITENANT-PORT-BUG.md`. |
| **Stale `setup_fields` shadowing** | Caps/env edits "don't take" | Highest-precedence DB layer (§4). | Documented (§4); see §6 for the proposed precedence redesign. |

### How to actually see what's happening

- Channel logs: set `debug_logging=true` (caps `config`) — now visible at `RUST_LOG=lunarwing=info`.
  For per-poll `Debug` lines, use `RUST_LOG=lunarwing=info,lunarwing::channels::wasm=debug`.
- Adapter health: `curl -s http://127.0.0.1:<base+9>/api/health` → `ws_connected: true` means the
  adapter↔WeeChat WebSocket is live.
- Raw line tags (bypasses channel logging): `curl` `…/api/buffers/<buf>/lines` with
  `Authorization: Basic base64("plain:"+RELAY_PASSWORD)`.

---

## 6. Recommendations

**Applied in this change (P0/P1):**

- Faithful guest-log level mapping (`wrapper.rs`).
- `MissedTickBehavior::Skip` + tightened per-call timeouts (`wrapper.rs`, `lib.rs`) to keep
  cadence ≈ 3s and bound a stalled cycle well under the 30s `callback_timeout`.
- `network_allowed()` wildcard for `all`/`*` (`lib.rs`, with a regression test).
- `poll_interval_seconds` caps key fix (`weechat.capabilities.json`).
- **First-DM delivery:** `do_poll` emits the first batch for newly-created **DM/query**
  buffers (`is_dm_buffer`) instead of seed-skipping it; channel buffers still seed-skip to
  avoid replaying join backlog (`lib.rs`, with a regression test).

**Open / recommended next:**

- **P2 — Adopt the adapter `/api/sync` push for real-time delivery** instead of 3s polling
  (the adapter already supports it — see `docs/proposals/WEECHAT_WS_ADAPTER_SYNC_PROTOCOL.md`).
  Needs a host-side consumption model, since the sandboxed WASM cannot hold a socket. Largest
  latency win.
- **P2 — Batched "all new lines" endpoint** to replace N sequential per-buffer `/lines` fetches.
- **P2 — Config-precedence redesign:** make `env`-declared deployment fields win over a stale
  `setup_fields` row (or have `mt-admin patch-env`/upgrade clear stale weechat `setup_fields`),
  and extend `ic/scripts/lunarwing-weechat-preflight.sh` to surface the *effective* value
  (DB `setup_fields` + workspace state), not just the env file.

---

## 7. Rollout note

These changes split across two build artifacts:

- **Host** (log mapping, `MissedTickBehavior`): `cargo build --release --bin lunarwing` → deploy binary.
- **WASM channel** (timeouts, `network_allowed`, caps key): `scripts/build-wasm-extensions.sh`
  → `lunarwing-mt-admin.sh install-wasm <tenant>` → `restart-tenant <tenant>`.

No behavior changes until both are redeployed per tenant.

---

## Cross-references

- `docs/ops/WEECHAT-SERVICES.md` — services, ports, env vars, day-to-day ops.
- `docs/ops/WEECHAT-MULTITENANT-PORT-BUG.md` — the per-tenant port/password fix and the
  env-sourced-fields mechanism.
- `docs/proposals/WEECHAT_WS_ADAPTER_SYNC_PROTOCOL.md`,
  `docs/proposals/WEECHAT_LOCAL_WS_ADAPTER_ISSUE.md` — the adapter sync protocol and adapter
  port history.
- `ic/scripts/lunarwing-weechat-preflight.sh` — read-only env-vs-registry pre-flight.
- Code: `ironclaw_weechat_wss/weechat_relay/src/lib.rs`, `…/ws_adapter.py`,
  `ic/src/channels/wasm/{setup,wrapper,runtime,loader}.rs`.
