# WeeChat Channel Architecture

How LunarWing connects to IRC through WeeChat: the components, the end-to-end message
flow, the ingestion/latency model, the configuration-precedence rules (and the trap they
create), and the known issues with their fix status.

> **Why this doc exists.** A multi-hour debugging session upgrading the `sunburst` tenant
> showed that message delivery through this channel has several independent, *invisible*
> failure modes, and that the "WebSocket adapter" was actually drained by slow HTTP polling
> (since replaced by a long-poll path, §3). Every incident re-derived the data flow and config
> rules from scratch. This is the authoritative reference so that doesn't happen again.

Line numbers below drift; treat them as hints, not contracts. Source of truth:
`lunarwing_weechat_wss/weechat_relay/src/lib.rs` (the WASM channel), `…/ws_adapter.py`
(the adapter), and `ic/src/channels/wasm/` (the host runtime).

---

## 1. Components

| Component | Where | Role |
|-----------|-------|------|
| **WeeChat** | per-tenant, runs in `tmux` (`weechat-<tenant>.service`) | The actual IRC client. Exposes the **relay `api`** plugin on the `weechat` port (MT: base+5). |
| **`ws_adapter.py`** | per-tenant Python process (`lunarwing-weechat-adapter-<tenant>.service`), `lunarwing_weechat_wss/weechat_relay/ws_adapter.py` | Holds a **WebSocket** to WeeChat's relay, subscribes to updates, buffers lines, and re-serves them over a small **HTTP API** on the `weechat_adapter` port (MT: base+9). |
| **WeeChat WASM channel** | in the LunarWing daemon; source `lunarwing_weechat_wss/weechat_relay/src/lib.rs` → `wasm32-wasip2`; loaded/run by `ic/src/channels/wasm/{loader,wrapper,runtime,setup}.rs` | Sandboxed channel that **long-polls (or polls) the adapter over HTTP**, applies policy, and emits `IncomingMessage`s to the agent; sends replies back to WeeChat. |

### The three hops — only one is a WebSocket

```
        WebSocket (+ /api/sync push)        HTTP long-poll (/api/wait, near real-time;
WeeChat  ⇇———————————————————————————⇉  ws_adapter.py   3s poll fallback on old adapters)
 relay   real-time, adapter-buffered      (:base+9)    ⇇——————————————————⇉  LunarWing daemon
(:base+5)                                                request/response       (WASM channel)
```

The **adapter↔WeeChat** hop is a real WebSocket and is real-time; the adapter even holds a
`/api/sync` subscription (`buffers`, `lines`). The **daemon↔adapter** hop is **HTTP** — the
sandboxed WASM can only make request/response calls (`channel_host::http_request`), so it cannot
hold a socket open. Instead of fixed-interval polling it issues a **blocking long-poll**
(`GET /api/wait`, §3) that returns the instant a line arrives, falling back to ~3s polling only
against an adapter that lacks the endpoint. "ws-adapter" describes the *upstream* link, not the
daemon's link.

**Implication:** IRC messages reach the adapter instantly and are buffered there; in long-poll
mode the daemon picks them up within a network round-trip (~ms), so end-to-end inbound latency is
near real-time. In the polling fallback, latency ≈ the poll cadence instead (see §3).

---

## 2. End-to-end message flow

### Inbound (IRC → agent)

1. A message arrives in an IRC buffer in WeeChat (buffer name `irc.<network>.<target>`, e.g.
   `irc.sobes.#chan` or, for a DM/query, `irc.sobes.<nick>`).
2. The adapter (subscribed via WS/`/api/sync`) captures it, buffers it per-buffer, and appends it
   to a **global event log** with a monotonic `seq` (§3).
3. The WASM channel's `on_poll` runs (host-driven, §3) and dispatches by ingest mode:
   - **Long-poll (default):** `do_longpoll` issues `GET /api/wait?cursor=<n>` and receives the new
     lines across **all** buffers in one response (refreshing `/api/config` policy on heartbeat
     ticks, see §4).
   - **Poll (fallback):** `do_poll` refreshes `GET /api/config` (see §4) and then fetches
     `GET /api/buffers/<buf>/lines?limit=10` for each known buffer; `poll_buffer` keeps only lines
     with id > the per-buffer watermark in `state/last_seen_ids`.
4. `handle_inbound_line` filters and applies policy, in order:
   - **Tag filter (mirror-loop guard):** require the `irc_privmsg` tag; drop `self_msg`/`no_log`
     (`tags_allow_ingest`). This lives in `handle_inbound_line` so **both** ingest paths are covered
     — `do_longpoll` feeds lines straight here, and a `self_msg` slipping through is a mirror loop
     (the agent answers its own replies, which arrive as new lines, forever). The poll path's
     `poll_buffer` also pre-filters the same tags. See §5.
   - parse `irc.<net>.<target>` → `network_allowed` (allowlist; empty/`all`/`*` = all) →
     exclude-networks → non-empty text → **DM vs group** (`is_dm` = target not starting with
     `#`/`&`/`!`) → `dm_policy`/`group_policy` + `allow_from` / pairing store.
5. Survivors are emitted via `channel_host::emit_message`; the host (`wrapper.rs`) dispatches
   them to the agent. `on_poll completed … emitted_count=N` is logged.

### Outbound (agent → IRC)

`on_respond` parses the reply's `metadata_json` (buffer/network/target/nick), chunks the text
to `max_chunk_length` (default 420), and `POST`s each chunk to the WeeChat **relay** `/api/input`
(via `relay_url`, not the adapter). Replies therefore go straight to WeeChat.

### Watermarks & new buffers (poll mode only)

In the polling fallback, `do_poll` seeds a per-buffer watermark the **first time** it sees a
buffer and does **not** emit that first batch (avoids replaying history on startup). See §5 for the
consequence on freshly-created DM/query buffers. Long-poll mode has no per-buffer watermarks — it
tracks a single global cursor seeded to the adapter's current `event_cursor` at `on_start`, so it
neither replays history nor needs per-buffer discovery.

---

## 3. Ingestion & latency

The daemon consumes the adapter in one of two modes, chosen at `on_start` by probing
`GET /api/health` for an `event_cursor` field (`detect_and_seed_ingest_mode` in `lib.rs`).

### Long-poll mode (default when the adapter supports it) — near real-time

The adapter keeps a **global ordered event log** (`event_seq` + `event_log`) and records every
`buffer_line_added` into it. A line names its buffer by `buffer_id`; for a **brand-new** query/DM
buffer not yet in the adapter's cached buffer list, the adapter refreshes the list
**synchronously and retries** before recording, so the *first* line in a new buffer is captured
rather than dropped (see §5 — that drop was the real first-DM bug, below both the cursor and the
WASM). Its blocking endpoint **`GET /api/wait?cursor=<n>&timeout=<s>`** returns immediately with
all events `seq > cursor`, or blocks until a line arrives (or a ~20s heartbeat). If
`cursor > event_seq` (the adapter restarted and its in-memory seq reset below the client) it
**replays the post-restart backlog** (treats the cursor as 0) instead of reporting "caught up", so
a line recorded right after a restart isn't skipped. `on_start` seeds the WASM's
`state/event_cursor` to the adapter's current cursor so buffered history isn't replayed at daemon
start.

`on_poll → do_longpoll`: issue `GET /api/wait` (HTTP timeout 25s), feed each returned line to
`handle_inbound_line`, advance the cursor, repeat. Because the call returns the instant a line is
recorded, **inbound latency ≈ a network round-trip (~ms)**, not the poll interval — and because
the adapter now captures a new buffer's first line, a brand-new DM/query buffer's first message
arrives through the same stream with **no discovery delay**.

**Timeout hierarchy (hard constraint):** `adapter wait ≤20s  <  WASM HTTP 25s  <  host
callback_timeout 30s`. The host loop below is unchanged; each `on_poll` simply blocks in
`/api/wait` up to ~20s and re-issues immediately on return. If `/api/wait` is missing (old
adapter) or returns an unparseable body, the WASM logs it and falls back to **poll mode** for the
rest of the session.

### Poll mode (fallback / old adapters) — ~3s

Used when the adapter has no `/api/wait`. `on_poll → do_poll` fetches each buffer per cycle.

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

This same host loop drives **both** modes. In long-poll mode `cycle_duration` is *intentionally*
the ~20s `/api/wait` block, so `MissedTickBehavior::Skip` just re-issues the wait the instant it
returns — there is no idle 3s gap, which is exactly what gives near-real-time delivery. In poll
mode the cycle is short and the 3s tick paces it.

### Per-cycle cost (poll mode)

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

### Seeing the real cadence (poll mode)

```bash
sudo -u <tenant> XDG_RUNTIME_DIR=/run/user/$(id -u <tenant>) \
  journalctl --user -u lunarwing-<tenant>.service -f \
  | grep --line-buffered "Polling .* buffers via"
```

The gap between consecutive lines is the actual cadence. To measure how long a single cycle
takes, compare `calling on_poll channel=weechat` → `on_poll completed channel=weechat`.

In **long-poll mode** there is no fixed cadence to measure; liveness is the adapter's
`event_cursor` climbing as lines arrive (`curl -s …/api/health`, §5) and `emitted_count` on the
`on_poll completed` lines.

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

### At runtime (`refresh_policy_config` → `/api/config`)

On each poll cycle, `refresh_policy_config` fetches `GET /api/config` from the adapter (served from
`weechat_local_config.json` next to `ws_adapter.py`) and, if present, overwrites the workspace
state for `dm_policy`, `group_policy`, `allow_from`, and `networks`. Both ingest paths call it —
`do_poll` every cycle, `do_longpoll` on each `/api/wait` return (event batch or ~20s heartbeat).
Ports (`relay_url`/`ws_adapter_url`) are **not** refreshed this way — they are set only at
`on_start`.

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
| **Poll cadence balloons to ~30s** | Long, irregular gaps between polls | `tick` + `poll` sequential ⇒ cadence = `max(3s, cycle)`; cycle could approach the 30s `callback_timeout`; default `Burst` then fired catch-up bursts. | **Fixed** — long-poll (`/api/wait`, §3) removes the per-cycle per-buffer fan-out entirely, so there is no cadence to balloon. The problem only survives on the polling fallback, where `MissedTickBehavior::Skip` + tightened per-call timeouts keep it bounded. |
| **`poll_interval_ms` ignored** | Configuring the interval did nothing | Caps `config` key was `poll_interval_ms` but the struct field is `poll_interval_seconds` — different name ⇒ value dropped, struct default (3) used. | **Fixed** — caps key renamed to `poll_interval_seconds`. |
| **First DM in a new buffer swallowed** | First message after a query buffer is created never reaches the agent; the *second* does | A DM/query buffer is created *by* the first message. The **adapter** resolves a line's buffer by `buffer_id` against a cached `buffer_list` that doesn't include the new buffer yet, so it **dropped the first line entirely** — never recorded to `line_buffer` *or* the event log. Nothing downstream (neither the long-poll cursor nor the poll path) can deliver a line the adapter never recorded. (The poll path additionally seed-skipped a new buffer's first batch.) | **Fixed** — the adapter now refreshes its buffer list **synchronously and retries** before recording, so a new buffer's first line is captured (`record_event`); the long-poll global cursor then delivers it immediately (§3). `/api/wait` also replays the post-restart backlog so a DM right after an adapter restart isn't skipped. The poll fallback still emits the first batch for new **DM/query** buffers (`is_dm_buffer`). |
| **Mirror loop (long-poll mode)** | Agent answers its own messages endlessly; `event_cursor` climbs steadily with no human input | The `irc_privmsg`/`self_msg`/`no_log` tag filter lived **only** in `poll_buffer`. `do_longpoll` feeds events straight to `handle_inbound_line`, which had no tag check — so in long-poll mode the agent's own `self_msg` replies were ingested and re-answered, each reply becoming the next event. Shipped in the original long-poll commit; not the adapter work. | **Fixed** — tag filter moved into `handle_inbound_line` (`tags_allow_ingest`), the single choke point **both** ingest paths share; `poll_buffer` keeps its pre-filter. Regression test `test_tags_allow_ingest`. |
| **Password is the *second* blocker** | After ports are fixed, the adapter returns 401 | The adapter authenticates incoming WASM requests against the per-tenant `RELAY_PASSWORD` (`check_auth`); the WASM must send it. | Handled by the port fix (relay_password injection) — see archived `WEECHAT-MULTITENANT-PORT-BUG.md` in `docs/internal/history/archive/ops/`. |
| **Stale `setup_fields` shadowing** | Caps/env edits "don't take" | Highest-precedence DB layer (§4). | Documented (§4); see §6 for the proposed precedence redesign. |

### How to actually see what's happening

- Channel logs: set `debug_logging=true` (caps `config`) — now visible at `RUST_LOG=lunarwing=info`.
  For per-poll `Debug` lines, use `RUST_LOG=lunarwing=info,lunarwing::channels::wasm=debug`.
- Adapter health: `curl -s http://127.0.0.1:<base+9>/api/health` → `ws_connected: true` means the
  adapter↔WeeChat WebSocket is live; `event_cursor` is the global long-poll cursor and should climb
  as IRC lines arrive (its presence is also what makes the WASM choose long-poll over polling).
- Raw line tags (bypasses channel logging): `curl` `…/api/buffers/<buf>/lines` with
  `Authorization: Basic base64("plain:"+RELAY_PASSWORD)`.

---

## 6. Recommendations

**Applied in this change (P0/P1):**

- **Near real-time ingestion (long-poll):** adapter global event log + blocking `GET /api/wait`;
  WASM `do_longpoll` consuming it with a capability probe and automatic fallback to per-buffer
  polling against old adapters (`ws_adapter.py`, `lib.rs`, with a `parse_wait_response` test).
  This is the former "P2 — real-time push" recommendation, delivered as a long-poll (which the
  sandboxed WASM *can* do) rather than a held socket (which it cannot). Largest latency win, and
  it subsumes the batched-lines idea below.
- Faithful guest-log level mapping (`wrapper.rs`).
- `MissedTickBehavior::Skip` + tightened per-call timeouts (`wrapper.rs`, `lib.rs`) — now govern
  only the **polling fallback**: keep its cadence ≈ 3s and bound a stalled cycle well under the
  30s `callback_timeout`.
- `network_allowed()` wildcard for `all`/`*` (`lib.rs`, with a regression test).
- `poll_interval_seconds` caps key fix (`weechat.capabilities.json`).
- **First-DM delivery (real fix is at the adapter):** the adapter refreshes its buffer list
  **synchronously and retries** before recording, so a new buffer's first line is captured into the
  event log instead of dropped (`ws_adapter.py`); the long-poll cursor then delivers it, and
  `/api/wait` replays the post-restart backlog. The poll fallback still emits the first batch for
  new **DM/query** buffers (`is_dm_buffer`, `lib.rs`, with a regression test).
- **Mirror-loop guard:** the `irc_privmsg`/`self_msg`/`no_log` tag filter now lives in
  `handle_inbound_line` (`tags_allow_ingest`) — the choke point **both** ingest paths share — so the
  long-poll path can no longer re-ingest the agent's own `self_msg` replies (`lib.rs`, with
  `test_tags_allow_ingest`).

**Open / recommended next:**

- **P2 — Batched "all new lines" endpoint for the fallback path.** `/api/wait` already returns all
  new lines across buffers in one call, so the long-poll path no longer fans out per buffer; only
  the polling fallback still issues N sequential `/lines` fetches. Low priority now.
- **P2 — Config-precedence redesign:** make `env`-declared deployment fields win over a stale
  `setup_fields` row (or have `mt-admin patch-env`/upgrade clear stale weechat `setup_fields`),
  and extend `ic/scripts/lunarwing-weechat-preflight.sh` to surface the *effective* value
  (DB `setup_fields` + workspace state), not just the env file.

---

## 7. Rollout note

These changes split across three artifacts:

- **Host** (log mapping, `MissedTickBehavior`): `cargo build --release --bin lunarwing` → deploy binary.
- **WASM channel** (long-poll consumer, **mirror-loop tag filter `tags_allow_ingest`**, timeouts,
  `network_allowed`, caps key): `scripts/build-wasm-extensions.sh` →
  `lunarwing-mt-admin.sh install-wasm <tenant>`.
- **Adapter** (`ws_adapter.py`: `/api/wait`, global event log, `/api/health` cursor, **first-line
  capture for new buffers**, **post-restart replay**): a plain Python file that runs from the
  **tenant's own clone**, so it ships with a `git pull` in the tenant home and takes effect when
  its service restarts.

The adapter and WASM must update **together** (the WASM probes `/api/health` for the adapter's
`event_cursor` and only long-polls if present; otherwise it falls back to polling). Per tenant:
`git pull` in the tenant home → `build-tenant <t> --with-wasm` → `install-wasm <t>` →
`restart-tenant <t>` (restarts both the daemon and the adapter service). New tenants created via
`create-tenant-*` get all three from the start. No behavior changes until they are redeployed.

---

## Cross-references

- `docs/ops/WEECHAT-SERVICES.md` — services, ports, env vars, day-to-day ops.
- `WEECHAT-MULTITENANT-PORT-BUG.md` — the per-tenant port/password fix and the
  env-sourced-fields mechanism (archived to `docs/internal/history/archive/ops/`).
- `docs/proposals/WEECHAT_WS_ADAPTER_SYNC_PROTOCOL.md`,
   `docs/proposals/WEECHAT_WS_ADAPTER_MISSING_DEPENDENCY_AND_AUTOMATION.md` — the adapter sync protocol,
   dependency + automation.
- `ic/scripts/lunarwing-weechat-preflight.sh` — read-only env-vs-registry pre-flight.
- Code: `lunarwing_weechat_wss/weechat_relay/src/lib.rs`, `…/ws_adapter.py`,
  `ic/src/channels/wasm/{setup,wrapper,runtime,loader}.rs`.
