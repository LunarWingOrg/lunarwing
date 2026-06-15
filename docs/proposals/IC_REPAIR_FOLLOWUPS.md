# Self-Heal Repair Followups (triaged)

Followups for the host-global health-check + self-heal pipeline
(`ic-infrastructure-health-check/`: `infrastructure-health-check.sh` → `lunarwing-self-heal.sh`,
paged by `send-notification.sh`, wired into `ic/scripts/lunarwing-mt-admin.sh`).

**Triaged 2026-06-15** against the actual scripts. The original list mixed three different kinds of
work — real edits to the self-heal mechanism, ops/release tasks, and live validation — and a couple
of items were already done. This rewrite separates them: **only 3 of the 10 are code changes to the
self-heal mechanism** (§A); the rest are tracked elsewhere (§B). File:line anchors are included so
each item is directly actionable.

## At a glance

| # | Item | Self-heal code? | Difficulty | Action |
|---|------|:---:|---|---|
| 6c | Notifier timeout | ✅ | trivial | **FIXED** `2b462f95` |
| 6b | Truncated-state recovery | ✅ | easy | **FIXED** `(pending commit)` |
| 2 | systemd `.timer/.service` scheduling | ✅ | moderate | **do now** |
| 6a | Escalation cooldown / rate-limit | ✅ | moderate | do now (one design choice) |
| 10 | Per-tenant app-level health (Pattern C) | ✅ | involved | **defer** (own design pass) |
| 1 | Propagate 4 fixes to staging/prod | ❌ ops | n/a | mostly done — redeploy only |
| 3 | Version bump 1.1.3→1.1.4 + test sweep | ❌ release | n/a | release prep |
| 4 | Live escalation→page demo | ❌ validation | n/a | validation pass |
| 5 | Reboot re-validation | ❌ validation | n/a | validation pass |
| 7 | WeeChat relay configure/prune | ❌ channel cfg | n/a | channel config |
| 8 | Prune noisy WASM channels | ❌ channel cfg | n/a | channel config |
| 9 | Document pipeline + `health.env` toggles | ❌ docs | easy | docs task |

---

## §A. Self-heal mechanism changes

These are the only items that edit the pipeline. **Recommended order: 6c → 6b → 2 → 6a.**

### Quick wins — do now

#### 6c. Notifier timeout — *trivial (~3–6 lines)* ✅ FIXED (commit `2b462f95`)
The notifier is invoked unguarded at `lunarwing-self-heal.sh:474`. A hung Gotify endpoint stalls the
whole self-heal tick.

- **Change:** wrap the call —
  `timeout "${SELF_HEAL_ESCALATE_TIMEOUT:-30}" "$notify_script" "$status" "$report_path" >&2 || log WARNING …`
- Guard with `command -v timeout` (fall back to a bare call) — GNU `timeout` is absent on
  macOS/launchd by default.
- The existing `|| log WARNING` already absorbs exit 124, so no extra error handling is needed.
- Keep the `>&2` redirect: `escalate_service` runs inside `remediate_component`, whose **stdout is the
  returned state JSON** — stray stdout corrupts state (the documented `:474` hazard).
- *(curl itself is already bounded at `send-notification.sh:66` via `--connect-timeout 10 --max-time 15`.)*

#### 6b. Truncated-state recovery — *easy (~8 lines, mostly already there)* ✅ FIXED
Recovery already half-exists: `load_state` falls back to `{}` on parse failure and
`save_state` is atomic (mktemp + mv). The gap was that a corrupt file was **silently** discarded
— which is exactly what drops `escalated:true` and causes re-paging.

- **Change:** in `load_state`, on jq parse failure log a WARNING and
  `mv "$STATE_FILE" "$STATE_FILE.corrupt.<ts>"` before emitting `{}`, so corruption is visible and
  preserved for forensics. Per-run single-slot rename (timestamps differ across runs, so
  the file can still be there for next time).
- **Tests:** added section O in `test-self-heal-matrix.sh` (O1: detect + rename + recover, O2:
  empty state isn't flagged, O3: bounded accumulation).

#### 2. Wire systemd `.timer/.service` scheduling — *moderate, self-contained in one file*
`ensure_health_pipeline()` is OpenRC-only, so the prod systemd leg gets the hardened scripts but no
auto-scheduling (G1/G2 stay open there). The launcher (`/usr/local/sbin/lunarwing-mt-health`) and all
pipeline scripts are **already init-agnostic** — only the scheduling layer needs a systemd branch.
All edits are in `ic/scripts/lunarwing-mt-admin.sh`:

1. Delete the hard non-OpenRC skip at `:2235-2238`. Steps 1–4 (sync scripts, mkdir report dir, write
   `health.env`, write launcher) are already init-agnostic and stay shared.
2. Change the hardcoded `LUNARWING_SERVICE_MANAGER=openrc` (`:2260`) to `$INIT_SYSTEM`, so self-heal
   picks the right `health-*.sh` + remediation path.
3. Replace the unconditional `_install_health_cron` (`:2297`) with a
   `case "$INIT_SYSTEM" in openrc) … ;; systemd) _install_health_systemd_timer ;; esac`.
4. Add `_install_health_systemd_timer()` modeled on `ic/systemd/lunarwing-watchdog.{service,timer}`
   (and mt-admin's existing inline-heredoc unit idiom): a `Type=oneshot` service running
   `$HEALTH_LAUNCHER`, plus a timer `OnBootSec=5min` / `OnCalendar=*:0/${HEALTH_INTERVAL_MIN}`
   (matches the `*/15` cron) / `Persistent=true` / `WantedBy=timers.target`, then `daemon-reload` +
   `enable --now`.
5. Mirror teardown in `remove_health_pipeline` (`:2301`, replace the OpenRC-only early-return) and
   update the `doctor` scheduled-check (`:2667`) to also accept `systemctl is-enabled
   lunarwing-mt-health.timer`.

- **Use a root SYSTEM-level timer** (`/etc/systemd/system`), **not** `systemctl --user` — the pipeline
  is host-global and runs as root, even though per-tenant tenant units are user-level.
- **Follow-on (separate change, verify before declaring systemd closed):** self-heal *remediating*
  user-scoped tenant units on systemd needs `systemctl --user` with the right `XDG_RUNTIME_DIR`/uid —
  that lives in `lunarwing-self-heal.sh` / `health-systemd.sh`, not in this scheduling wiring.
- Minor edge: `health.env` is write-if-absent (`:2254`), so a host that ran OpenRC first then switched
  to systemd keeps a stale `LUNARWING_SERVICE_MANAGER=openrc` line. Irrelevant on a fresh systemd host.

### Needs one design choice — do now

#### 6a. Escalation cooldown / rate-limit — *moderate (~12–16 lines)*
No cooldown exists today: `escalatedAt` is written at `:413` but never read, and escalate fires
unconditionally at `:550` (flapping) and `:557` (max retries). A flap→recover→reflap loop can flood
Gotify.

- **Change:** add `SELF_HEAL_ESCALATE_COOLDOWN="${SELF_HEAL_ESCALATE_COOLDOWN:-3600}"` near the
  `FLAP_*` config block (~`:49`). Gate the page in `_send_notification` (`:464-478`): read a persisted
  last-page epoch, and if `now - last < COOLDOWN`, skip the notifier (still keep `escalated=true` /
  still write the escalation report) and log to stderr; on a sent page, write `now`.
- **Design decision — must use a sidecar file, not a state.json field:** store the timestamp in
  `$SELF_HEAL_STATE_DIR/.last_escalation_page`. A per-service cooldown in `state.json` would be erased
  by `clear_service_state` (`:418`) and `prune_state` (`:449`) — which is exactly the flap cycle this
  targets. `SELF_HEAL_STATE_DIR` is already per-tenant, so the sidecar is MT-isolated for free.
- Keep all logic on stderr (the `:474` stdout-is-state-JSON hazard again).
- *Alternative to weigh:* a purely-global cooldown can suppress a legitimately-distinct second
  service's first page in the same outage — consider per-run aggregation into a single page instead.
  Spec the sidecar approach first; it's still small enough to land with 6b/6c.

### Defer — needs its own design pass

#### 10. Per-tenant app-level health (Pattern C) — *involved*
The host-global pipeline checks service **liveness** only. `health-gateway.sh` today doesn't curl
anything — it just stats local session files (`health-gateway.sh:9,55-64,107-120`). True app-level
self-heal means deep-checking each tenant's authed `/api/gateway/status` `.channel_health` (endpoint
confirmed at `server.rs:514 → 2528`, returns `Option<HashMap<name,{healthy,error}>>`; **authed**, so a
per-tenant token is required or it 401s).

- **Clean half (straightforward):** a new `health-tenant-gateway.sh` modeled on the tenant loop in
  `health-systemd.sh:91-118` — iterate `ports.json` (`.tenants[name].ports.gateway`, `.user`), read
  each tenant's `GATEWAY_AUTH_TOKEN` from `…/lunarwing/env/lunarwing.env`, curl the status endpoint,
  emit a `tenant_gateway` component. Keying targets to `lunarwing-<tenant>` routes through the existing
  `unit_tenant()/tenant_user()` restart path (`:169-184`) unchanged.
- **Messy half (why it's involved):**
  - *Liveness-vs-app conflict:* the svcmgr check can report `lunarwing-<tenant>` healthy (process up)
    while the app check says degraded (dead channel); the report-as-truth recovery (`:714-724`) would
    clear the app-degraded state on the same tick. App-degraded must win for the same unit — the core
    work.
  - *Correct remedy map:* a dead `xmpp`/`weechat` channel usually means the per-tenant **bridge**
    (`xmpp-bridge-<tenant>`) is down, not the gateway — needs a channel→service map, new logic.
  - *Secrets:* must read per-tenant `GATEWAY_AUTH_TOKEN` (root + path convention) and never log it.
  - *Absence handling:* `channel_health` is `None` when no channel manager — treat as "no signal", not
    degraded, or channel-less tenants flap.
  - *Performance:* N tenants × curl with small `--max-time`, ideally parallel, under the orchestrator's
    30s timeout (`infrastructure-health-check.sh:68`).
- **Recommendation:** don't ride this into 1.1.4. Give it a dedicated change with tests in
  `ic-infrastructure-health-check/tests/test-self-heal-matrix.sh`. Note `SELF_HEAL_REMEDY_LOGICAL`
  (`:68`) already gates off the gateway→lunarwing logical map under MT, so the new check must map
  straight to `lunarwing-<tenant>` units.

---

## §B. Not self-heal mechanism changes (tracked elsewhere)

#### 1. Propagate the 4 health-stack fixes — *mostly done; ops redeploy only*
All four fix commits — `c2c50b6b` (lock-fd leak), `7f592a95` (dead notifier), `bb8bbc57`
(lost escalation state), `1314cca9` (OpenRC env-file) — are **already on `staging` / `origin/staging`**
(staging is an ancestor of this branch). The fixes live in init-agnostic scripts, and the env-file fix
is in the **ungated** `write_tenant_lunarwing_env` (called at `mt-admin.sh:2344` with no `INIT_SYSTEM`
gate), so the systemd leg is **already covered in source**.

> ⚠️ Outdated framing: "propagate to the canonical release/staging branch" is done, and "the systemd
> leg has the env-file bug latent and notifier/escalation bugs active" only holds for a host running a
> **stale checkout**. The residual is a redeploy of the fixed scripts to the systemd+Docker prod hosts
> — a deployment task, not a self-heal code change.

#### 3. Version bump + test sweep — *release prep*
Bump 1.1.3 → 1.1.4 (workspace + 5 WASM channel crates), then run `ic/scripts/release-test.sh`,
`cargo test`/`--features integration`, clippy/fmt, e2e. Mechanical; no self-heal edit.

#### 4. Definitive live escalation→page demo — *validation*
Stage a throwaway OpenRC unit (respawn disabled + always-fail command) so a real restart fails →
escalate → Gotify, closing the single staging gap. Exercises the existing path; doesn't modify it.

#### 5. Reboot re-validation — *validation*
Reboot the staging host; confirm the fcron `*/15` schedule, escalation, and weechat-on-all all return
cleanly (earlier reboot test predated them). Observational.

#### 7. Resolve WeeChat — *channel config*
Configure the relay per tenant (Quickstart Part 2) or prune it per the consistency proposal. Channel
config, not a self-heal edit.

#### 8. Prune noisy WASM channels — *channel config*
Disable/configure telegram/darkirc/multica (error every poll with no token/daemon) per the pruning
proposal to quiet the logs.

#### 9. Document the pipeline + `health.env` toggles — *docs (easy)*
Add pipeline docs to `docs/ops/MULTITENANCY-PRODUCTION.md` plus a `health.env` toggles reference.
Toggles confirmed real: `HEALTHCHECK_NOTIFY` (`infrastructure-health-check.sh:274`),
`SELF_HEAL_REMEDY_LOGICAL` (`lunarwing-self-heal.sh:68,687`), and the report-age toggle — whose env
var is actually **`SELF_HEAL_MAX_REPORT_AGE`** (`lunarwing-self-heal.sh:72,644-648`), not the
`MAX_REPORT_AGE` shorthand; get the spelling right in the reference.
