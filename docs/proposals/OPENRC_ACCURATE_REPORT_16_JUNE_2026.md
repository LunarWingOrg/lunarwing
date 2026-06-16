# OpenRC Self-Heal + Health-Check + Rootless-Podman — Accurate Report (eris leg)

*2026-06-16. Recalibrated from a 49-agent automated review against **read-only
verification of the live host**. Companion to
[`ROOTLESS_PODMAN_CONTAINER_SUPERVISION_GAP.md`](./ROOTLESS_PODMAN_CONTAINER_SUPERVISION_GAP.md)
and the self-healing series ([`SELF_HEALING_IMPROVEMENTS_1.md`](./SELF_HEALING_IMPROVEMENTS_1.md),
[`SELF_HEALING_IMPROVEMENTS_2.md`](./SELF_HEALING_IMPROVEMENTS_2.md)).*

> **Status:** analysis / proposal. No code changed by this document.
> **Scope:** the experimental rootless-podman + OpenRC multi-tenant leg (`eris`,
> Gentoo, OpenRC 0.63.1). The rootful-docker leg is unaffected unless noted.

---

## 0. Headline (calibrated)

**The self-heal system works.** On the live host, the core loop — detect an
unhealthy unit → restart it → verify it came back — functions correctly: **every
`RESTART_BEGIN` in the action log is followed by `RESTART_OK`.** It is *not*
"bricked" or "non-functional"; an earlier automated draft overstated this and is
corrected here.

**What is genuinely degraded is narrower and real:** `state.json` is currently
empty (1 byte), so per-service state never accumulates across cron ticks. The
consequence is that the **stateful resilience features are dormant**:

- exponential **backoff** between retries (never spaced),
- the **flap circuit-breaker** (never counts toward its limit),
- **max-retries escalation** (`retries` is stuck at `0`, never reaches 3).

The happy path is unaffected. The accurate one-liner is the maintainer's own:
**"not perfect, but it works."** The fix for the one live issue is ~2 lines and
self-recovers the current state file.

---

## ✅ Status update — 2026-06-16 (post-merge `2b471720`)

*Added after the original report, reflecting code merged into
`2026-06-16-vm-ic-2-feature-1.1.4-unified`. Most of this landed via the
systemd-parity effort (commit `dd4ec7e4`, "self-heal: systemd remediation parity
+ shared engine fixes"), but the engine fixes are **init-agnostic** and apply to
the OpenRC leg too.*

**The curative trio + its test are now implemented in code — matching this
report's proposals:**

| Item | Proposed | Landed | Where |
|------|----------|--------|-------|
| **Rank 4** `load_state` object guard | `jq -e 'if type=="object" then . else error end'` | ✅ **exactly as proposed** | `lunarwing-self-heal.sh` `load_state()` |
| **Rank 1** restart-stdout redirect | `esac >&2 200>&-` | ✅ **exactly as proposed** | `lunarwing-self-heal.sh` `restart_service()` |
| **Rank 2** escalation renderer | page the escalation shape, don't abort | ✅ **closed** — `send-notification.sh` now branches on `.escalated`, null-defaults every field, and falls back to a plain message (`… 2>/dev/null \|\| message=…`). Differs from the proposed `--raw` flag (in-renderer branch instead); same outcome. | `send-notification.sh` |
| **Rank 3** invert test O2 | assert empty state is quarantined | ✅ **done** — O2 now asserts `state.json is corrupt` + a `state.json.corrupt` sibling + `Self-Healing complete` (O2b whitespace not added separately; the empty-file case covers the live condition) | `tests/test-self-heal-matrix.sh` |

**Related init-agnostic changes that also help the OpenRC leg:**

- **`unit_tenant()` expanded** with specific prefixes (`lunarwing-pg-*`,
  `-nanocode-*`, `-pebble-*`, `-weechat-adapter-*`, `-weechat-*`) **before** the
  generic `lunarwing-*`. Fixes a *latent* mis-targeting bug where
  `lunarwing-pg-<t>` resolved to the bogus tenant `pg-<t>` — strengthening **Rank
  19**. Applies to OpenRC remediation.
- **weechat unit renamed** `weechat-<t>` → `lunarwing-weechat-<t>` on **both**
  systemd (`.service`) and OpenRC (`/etc/init.d/`). On OpenRC the existing
  `health-openrc.sh` `lunarwing-*` discovery glob **now finds weechat**, partially
  addressing **Rank 18** ("weechat invisible to self-heal"). The duplicate
  `lunarwing-*` / `lunarwing-proxy-*` glob still remains.
- **`doctor` per-tenant linger check** — `doctor` now verifies, per tenant, that
  **linger is enabled** (`loginctl show-user … Linger`) and **`/run/user/<uid>`
  exists**, for rootless hosts (added with the status/doctor symmetry work, gated
  on `MT_ROOTLESS` so it runs on the OpenRC leg too). This is most of **Rank 11**;
  the per-tenant `sudo -u <t> podman info` *store* check is still missing.

**systemd-only — does NOT change the OpenRC leg, but closes the same gaps on the
other leg** (see [`MT_SYSTEMD_PARITY.md`](./MT_SYSTEMD_PARITY.md)):

- **Quadlet `.container` supervision** (`render_pg_quadlet` / `render_worker_quadlet`,
  `Restart=on-failure` + start-limit) — the systemd analog of **Rank 30** and of
  [`ROOTLESS_PODMAN_CONTAINER_SUPERVISION_GAP.md`](./ROOTLESS_PODMAN_CONTAINER_SUPERVISION_GAP.md).
  **OpenRC container units remain unsupervised** — that gap is now confirmed
  OpenRC-specific.
- The systemd PG Quadlet uses **`HealthCmd=pg_isready`** — i.e. **Rank 15** on the
  systemd path. The **OpenRC** pg `status()` still checks only `.State.Running`
  (Rank 15 **open on OpenRC**).
- `_systemd_restart` / `_systemd_user_restart` now `reset-failed` before restart
  and use `sudo -n` (systemd start-limit handling); no OpenRC equivalent needed.

**Still open for the OpenRC leg** (`health-openrc.sh` and the OpenRC pg/worker
units were not modified): Ranks **5, 9, 10, 13, 15 (OpenRC), 18 (dup glob), 30,
33**, plus the broader hardening items. (**Rank 11** is now *mostly* addressed —
see the doctor linger bullet above — leaving only the per-tenant `podman info`
store check.)

**Live deployment note:** re-checked
`/var/lib/lunarwing-health/workspace/reports/self-heal/state.json` at **03:15** —
**still 1 byte, no `.corrupt` sibling.** The running host is still on the
**pre-fix deployed copy**; the merged guard will quarantine the empty file and
write a fresh `{}` on the first tick **after the updated `lunarwing-self-heal.sh`
is deployed**. (Fix is in the branch, not yet on the box.)

---

## 1. Live verification (read-only, 2026-06-16)

Gathered directly from `/var/lib/lunarwing-health/workspace/reports/self-heal/`
on the running host (no mutations):

```
-rw-------  root root    1  Jun 16 01:30  state.json      # 1 byte (newline) — empty, no .corrupt sibling
-rw-r--r--  root root 2029  Jun 16 00:15  actions.log
-rw-r--r--  root root    0  Jun 16 01:30  self-heal.lock
```

- **`state.json` is 1 byte and not a JSON object.** Confirms the `load_state`
  empty-file gap is *live*, and `ensure_state_dir` never repairs a present-but-empty
  file. There is no `.corrupt` sibling, i.e. it was never quarantined.
- **The core loop works.** The action log shows **9 restarts, every one followed
  by `RESTART_OK`** (proxy-zeus, xmpp-bridge-zeus, lunarwing-pg-zeus,
  lunarwing-pebble-zeus, lunarwing-creamheart). Services that went unhealthy were
  detected and successfully recovered.
- **State is not persisting.** **Every** `RESTART_BEGIN` line reads `retries=0`,
  and `GRACE` lines read `obs=1/2` every time — counters reset each tick because
  the loaded state is empty.
- **One observed symptom of the missing state:** between **16:22:34 and 16:23:05**
  (≈31 s), `lunarwing-proxy-zeus` was restarted **~5 times back-to-back with no
  backoff** (a healthy state machine would have spaced these via `next_attempt_at`
  or escalated after the flap limit). It **self-resolved** — `RESTART_OK` each
  time, no outage.

**Correction of inflated specifics in the raw draft:** the draft said *"proxy-zeus,
8 restarts in ~31s"* — the log shows **~5**, not 8. The draft's "non-functional /
bricked" framing is withdrawn; the verified state is "works, stateful features
dormant."

**Re-check (03:15, post-merge `2b471720`):** `state.json` is **still 1 byte** with
no `.corrupt` sibling — the running host is still on the **pre-fix deployed copy**.
The `load_state` guard is now merged (see the Status update above) but has not yet
been deployed to this host; it will self-recover the file on the next tick after
deploy.

Tenants present: `zeus`, `creamheart` in `/etc/lunarwing/ports.json`; the action
log also references `mars` and `ate` (weechat-adapter units).

---

## 2. What's actually broken vs. latent

| # | Item | Status on live host | Severity (calibrated) |
|---|------|---------------------|------------------------|
| A | `load_state` treats empty/whitespace file as valid-empty → state never persists → backoff/flap/escalation dormant | ✅ **FIXED in code** (`2b471720`); live host still on pre-fix copy (state.json 1 byte @ 03:15) → self-recovers on redeploy | High — *resolved*; was happy-path-safe |
| B | Restart-command stdout banner can corrupt the captured state JSON (aborts before `save_state`) | ✅ **FIXED in code** (`esac >&2 200>&-`, `2b471720`) | High — *resolved* |
| C | Escalation page silently dropped (`send-notification.sh` can't render escalation JSON shape → jq abort) | ✅ **FIXED in code** (`.escalated` branch + null-defaults + fallback, `2b471720`) | Medium — *resolved* (was latent, masked by A) |
| D–… | The remaining 30 items | **Latent / hardening** — fire on a future incident, reboot, schema skew, or mass outage | Medium→Low |

The two **curative** fixes (A + B) and the escalation fix (C) have **all landed**
in `2b471720` (init-agnostic, so they apply to OpenRC). The remaining items are
hardening or test coverage — and most of the OpenRC-leg ones (Ranks
5/9/10/11/13/30/33) are still open. **The one operational step left on the live
host: deploy the updated `lunarwing-self-heal.sh`** so A self-recovers.

---

## 3. Prioritized recommendations

Generated by the review (6 dimensions → 36 recommendations → adversarial
verification; 0 dropped). Live read-only verification then **recalibrated the
severity** of the top cluster (it did not invalidate the findings). Impact/effort
below reflect the calibrated view.

> **Status (post-merge `2b471720`):** Ranks **1, 2, 3, 4** are now ✅ implemented;
> Rank **19** is helped by the `unit_tenant()` fix and Rank **18** is partially
> addressed by the weechat rename; Ranks **15/30** are addressed on the *systemd*
> leg via Quadlet but **remain open on OpenRC**. See the Status update section
> above. The table preserves the original review priorities.

| Rank | Recommendation | Dimension | Impact | Effort | podman/OpenRC |
|------|----------------|-----------|--------|--------|----------------|
| 1 ✅ | Redirect restart-command stdout (`esac >&2 200>&-`) | selfheal-robustness | high | low | OpenRC |
| 2 ✅ | Fix escalation renderer (jq abort → page) | observability-alerting | high | low | — |
| 3 ✅ | Invert test O2 + ship `load_state` empty/whitespace guard together | testing / selfheal | high | low | — |
| 4 ✅ | `load_state`: treat empty/whitespace/non-object as corrupt | selfheal-robustness | high | low | — |
| 5 | Per-service `timeout` on `rc-service status` (no fleet-blanking) | health-accuracy | high | low | OpenRC+podman |
| 6 | Realistic OpenRC restart mock + state-validity chaos case | testing-chaos | high | low | OpenRC |
| 7 | fd-200 lock-inheritance regression test | testing-chaos | high | medium | OpenRC+podman |
| 8 | Wire `run-all.sh` into CI on `ic-infrastructure-health-check/**` | testing-chaos | high | low | — |
| 9 | Self-heal completion heartbeat (dead-man's switch) | observability-alerting | high | medium | OpenRC |
| 10 | Fix always-zero `rc_exit` capture in `health-openrc` | health-accuracy / openrc | medium | low | OpenRC |
| 11 | doctor: per-tenant rootless store + OpenRC linger check | podman-rootless | medium | low | OpenRC+podman |
| 12 | type-corrupt state regression test + numeric coercion in `load_state` | testing / selfheal | medium | low | — |
| 13 | `health-openrc.sh` test suite (zero coverage today) | testing-chaos | high | medium | OpenRC |
| 14 | `supervise-daemon healthcheck()` for the 4 long-lived units | openrc-integration | medium | medium | OpenRC |
| 15 | pg `status()` probes `pg_isready`, not just `.State.Running` | health-accuracy | medium | low | OpenRC+podman |
| 16 | Preflight rootless net backend (pasta/slirp4netns) | podman-rootless | medium | low | podman |
| 17 | Make flap circuit-breaker reachable (preserve `restart_history`) | selfheal-robustness | medium | medium | — |
| 18 | Dedup discovery globs + add `weechat-*` | health-accuracy / openrc | medium | low | OpenRC |
| 19 | Pre-restart liveness recheck + daemon-after-pg ordering | selfheal-robustness | medium | low | OpenRC+podman |
| 20 | Resolve/recovery notification | observability-alerting | medium | low | — |
| 21 | MT per-tenant rollup in the paging/escalation message | observability-alerting | medium | medium | OpenRC |
| 22 | Escalation tiers + notify cooldown + transition-only per-run page | observability-alerting | medium | medium | — |
| 23 | OpenRC chaos scenario for prod config (`REMEDY_LOGICAL=false`) | testing-chaos | medium | low | OpenRC+podman |
| 24 | self-heal status surface (`status.json` + `actions.log` completeness) | observability-alerting | medium | medium | — |
| 25 | Shared image store (rescope) + `podman image prune` | podman-rootless | medium | medium | podman |
| 26 | XDG/linger lifecycle: loud warn + OpenRC `disable-linger` on teardown | podman-rootless | medium | low | OpenRC+podman |
| 27 | Delete dead conf.d deps (`lunarwing_rc_need`/`xmpp_bridge_rc_before`) | openrc-integration | low | low | OpenRC |
| 28 | clickhouse host-RAM false positive: absence-disable + toggle | health-accuracy | low | low | — |
| 29 | Report dedup (last-processed sidecar) + doc cadence fix | selfheal-robustness | low | medium | — |
| 30 | Supervise container units (flag-gated; try `GRACE_CHECKS=1` first) | openrc-integration | medium | high | OpenRC+podman |
| 31 | `--userns=keep-id` for the nanocode worker (per-worker) | podman-rootless | low | medium | podman |
| 32 | Native podman HEALTHCHECK correctness (`--no-healthcheck` + comments) | podman-rootless | low | low | OpenRC+podman |
| 33 | Fix/drop the dead PID-liveness field in `health-openrc` | openrc-integration | low | low | OpenRC |

---

## 4. The curative trio (detail)

These three fix the one live issue and its co-cause, and re-arm escalation.

### [Rank 4] `load_state`: quarantine empty/whitespace/non-object — ✅ IMPLEMENTED (`2b471720`)
`ic-infrastructure-health-check/lunarwing-self-heal.sh:388-401`

> **Landed exactly as proposed.** `load_state` now uses `jq -e 'if type=="object"
> then . else error end'`. *Recovers the live host* on the next tick after the
> updated script is deployed (still 1 byte as of 03:15).

- **Problem (verified live):** `load_state` branches only on jq's exit code, but
  `jq -r '.'` on a 0-byte or whitespace-only file **exits 0 with empty output**
  (confirmed: `jq 1.8.1`), so it returns `""` and never reaches the `.corrupt`
  rename. Downstream `echo "$state" | jq …` all no-op; `obs=$((old_obs+1))` reads
  `1` each tick; with `GRACE_CHECKS=2` (`:45`) counters never advance.
  `ensure_state_dir` (`:381`) only initialises when the file is *absent*, so a
  1-byte file is never repaired. **Live: `state.json` = 1 byte, no `.corrupt`
  sibling, `retries=0` in every log line.**
- **Fix:** require a non-empty JSON object —
  `jq -e 'if type=="object" then . else error end'` → on failure rename to
  `.corrupt` and echo `{}`. `load_state` gates every path in `main()`, so this
  single change **also recovers the currently-empty host** on the next tick.
- **Risk:** very low — empty/array/scalar is quarantined and replaced with `{}`,
  strictly more correct. (Confirmed: an empty file fails the `type=="object"`
  guard.)

### [Rank 1] Redirect restart-command stdout — ✅ IMPLEMENTED (`2b471720`)
`lunarwing-self-heal.sh:274` (dispatch), `:236` (`_openrc_restart`), `:767` (capture)

> **Landed exactly as proposed:** `esac >&2 200>&-`.

- **Problem:** `remediate_component` returns state via `printf '%s' "$state"`
  (`:633`), captured as `state="$(remediate_component …)"` (`:767`). Inside,
  `if restart_service "$svc"; then` (`:609`) does not consume the command's
  stdout; `_openrc_restart` runs `rc-service "$svc" restart` with **no
  redirection** (`:236`), and OpenRC writes `* Stopping…/* Starting…` to
  **stdout**. That banner leaks into `$state` → `prune_state` (`:770`) jq-fails
  under `set -e` → aborts **before** `save_state` (`:771`). This is the exact
  class as the already-fixed notifier-stdout bug (`:490-507`, commit `bb8bbc57`)
  and a co-cause of the empty `state.json`.
- **Fix:** change the dispatch redirection at `:274` from `esac 200>&-` to
  `esac >&2 200>&-` (manager-agnostic; banner → stderr/logs, fd-200 still closed,
  exit code preserved). Belt-and-suspenders: validate the captured return with
  `jq -e type` before assigning and keep prior state on failure.
- **Risk:** interactive runs no longer echo the banner on stdout (only logs) —
  acceptable; nothing consumes restart stdout today.

### [Rank 2] Escalation pages are silently dropped — ✅ IMPLEMENTED (`2b471720`)
`ic-infrastructure-health-check/send-notification.sh:45-58`, `lunarwing-self-heal.sh:519-527`

> **Closed, via a different shape than proposed:** instead of a `--raw` flag, the
> renderer now branches on `.escalated`, null-defaults every field, and falls back
> to a plain message (`… 2>/dev/null || message="Infrastructure alert …"`). Same
> outcome — escalation JSON can no longer abort the page.

- **Problem (verified by reading the renderer):** `escalate_service` builds
  `{escalated,service,timestamp,retries,reason,action}` (`:519-523`) and calls
  `_send_notification "critical" "$esc_report"`. But the renderer assumes a full
  health-report: `(.overall_status | ascii_upcase)` and `[.components[] …]`
  (`send-notification.sh:49-55`). Against escalation JSON those keys are `null`
  → jq aborts (exit 5) under `set -euo pipefail` → the `message=$(jq …)`
  assignment fails **before** curl → `_send_notification` swallows it with
  `|| log WARNING` (`self-heal:499-502`). **Caveat (calibration):** this only
  bites when `GOTIFY_TOKEN` is set — an empty token exits 0 at
  `send-notification.sh:15-18` *before* the broken jq. And with state dormant
  (Rank 4) escalation never triggers in the first place, which is why it has not
  surfaced live.
- **Fix:** add `send-notification.sh --raw <title> <message> <priority>` and have
  `escalate_service` (which already holds all the context) call it; also harden
  the report renderer with `// {}` / `// []` defaults so a bad shape can't abort
  before curl. (`"critical"` already maps to priority 8, so reason-tiering is
  optional polish.)
- **Risk:** low, additive. Add a test that feeds escalation JSON through the
  notifier.

---

## 5. Detailed findings (remaining dimensions)

> These carry over from the review with file:line groundings intact. The review's
> own adversarial pass already walked back several first-draft overclaims; those
> "Correction:" notes are preserved because they're the accurate version.

### selfheal-robustness

**[Rank 12] Numeric-field hardening** — `lunarwing-self-heal.sh`
A valid-JSON-but-wrong-type counter (e.g. `consecutive_unhealthy:"seven"`) makes
`obs=$((old_obs+1))` (`:565`) and the `retries`/`next_attempt_at` gates
(`:584/:598/:616/:624`) crash under `set -u`; the run aborts before `save_state`
and `cron-wrapper.sh:46 || true` hides it. Coerce **in `load_state`** (not only
`state_get_num` @ `:412`) since `record_unhealthy` (`:448`), `state_push_restart`
(`:463`) and `flap_count` (`:457`) read state inside jq and bypass the getter.
Normalize numeric fields via `numbers // default`, arrays via `arrays // []`, once
at load. Defensive (triggers: schema/version skew, manual edits) — medium impact.

**[Rank 17] Make the flap circuit-breaker reachable** — `lunarwing-self-heal.sh`
Flap fires at `FLAP_MAX_RESTARTS=5` (`:48`) but `clear_service_state` does
`del(.[$svc])` on every successful restart (`:614`) and report-as-truth recovery
deletes the entry on any healthy report (`:750`), wiping `restart_history`. The
recover-then-die pattern the guard targets is exactly where history is destroyed,
so it never reaches 5; and `FLAP_MAX(5) > MAX_RETRIES(3)` means persistent failure
escalates via retries first → flap breaker is effectively dead code
(acknowledged in `docs/proposals/IC_REPAIR_FOLLOWUPS.md:108`). Replace whole-entry
deletion with a `reset_service_state` that clears volatile fields but keeps
`restart_history` trimmed to the window, at both `:614` and `:750`; teach
`prune_state` (`:476-482`) to honor `restart_history`'s max timestamp or the
history-only entry is pruned immediately. Honor `HISTORY_MAX >= FLAP_MAX` (`:52`).

**[Rank 19] Pre-restart liveness recheck + dependency ordering** — `lunarwing-self-heal.sh`
Self-heal restarts every report-flagged unit in raw discovery order
(`:765-768`), verifying only the unit it restarted (`:611`). On OpenRC the daemon
`need`s pg (`lunarwing-mt-admin.sh:2136`), so `rc-service lunarwing-pg-<t> restart`
cascades a daemon bounce; if the daemon is also in the target list it's restarted
twice the same tick. (*Correction:* the bridge/proxy `before` edges and the
`lunarwing_rc_need`/`xmpp_bridge_rc_before` conf.d vars are start-ordering / dead
— only the pg `need` cascades.) Fix: (1) before each restart, `check_service_active`
and skip if already up (~3 lines, the 80%); (2) order targets so `lunarwing-<t>`
is restarted **after** `lunarwing-pg-<t>` only. Effort low; impact situational.

**[Rank 29] Report dedup + cadence doc fix** — `lunarwing-self-heal.sh`, `README.md`
`record_unhealthy` is unconditional (`:566`) and nothing records the last-processed
report (`:642`), so reprocessing one report re-bumps `consecutive_unhealthy`.
(*Correction:* the backoff gate `:597-603` and flap push-on-actual-restart `:607`
prevent repeated *restarts*; the only real effect is collapsing the GRACE window
before the first restart — a grace-correctness issue, not a storm vector, and
narrow on MT (fresh report per tick, idempotent cron, flock).) Doc drift:
`README.md:137` says ~30 min while mt-admin schedules `*/15`. Persist a
last-processed sidecar; skip the observation bump (not report-as-truth recovery)
on an unchanged report; fix the cadence docs; make the flock-absent branch
(`:661-667`) warn loudly. Low impact.

### observability-alerting

**[Rank 9] Self-heal completion heartbeat (dead-man's switch)** — `lunarwing-self-heal.sh`, `cron-wrapper.sh`
The silent-failure surface is broad: `|| true` (`cron-wrapper:46/33`),
`HEALTHCHECK_NOTIFY=false` and `SELF_HEAL_REMEDY_LOGICAL=false`
(`mt-admin:2565/2562`), empty-token notifier exits 0
(`send-notification.sh:15-18`), and three exit-0-without-action paths in `main()`
(stale-report `:676-679`, lock-held `:664-666`, no-report `die` `:670`). Rootless
makes self-heal load-bearing — `--restart` is a no-op under rootless podman
(`mt-admin:1752-1755`). Write a heartbeat **only on clean completion** (after
`:757` and `:771`); age-check it in **cron-wrapper** (outermost, least wedge-prone)
and page **directly** via `send-notification.sh "critical"` (its env has
`GOTIFY_TOKEN`, sourced from `health.env`, `mt-admin:2584-2588`), bypassing the
`HEALTHCHECK_NOTIFY`/`REMEDY_LOGICAL` suppression. **This is the one fix that
*detects* the failure modes the others *prevent*** — e.g. it would have surfaced
the empty-`state.json` condition instead of leaving it silent.

**[Rank 20] Resolve/recovery notification** — `lunarwing-self-heal.sh`, `send-notification.sh`
A previously-escalated service that recovers only emits a stderr `log` line;
report-as-truth clears the entry (`:749-751`) and the `escalated` flag
(`:440/:750`) with no page. Add the resolve check **only** at the report-as-truth
loop (`:747-753`) — an escalated service can never reach the restart path (bails at
`:568-571`). Read `state_get_bool '.escalated'` before `clear_service_state`; gate
on `escalated==true` + `GOTIFY_TOKEN`; add a `"resolved"` case (priority ~3).

**[Rank 21] MT per-tenant rollup in the paging message** — `infrastructure-health-check.sh`, `send-notification.sh`
The human summary (`infrastructure-health-check.sh:236-242`) prints only top-level
component status, collapsing the per-unit `.metrics.services[]` array.
(*Correction:* the `.md` summary it first targeted is write-only; the surface that
actually pages is `send-notification.sh:49-55`.) Retarget the rollup to the
Gotify/escalation message; group by tenant via `unit_tenant()` prefix logic
(`self-heal:174-183`); demote logical components to informational; gate behind a
dedicated `HEALTHCHECK_*` flag (not `REMEDY_LOGICAL`). Keep a flat fallback for
non-MT hosts.

**[Rank 22] Escalation tiers + cooldown + transition-only paging** — `lunarwing-self-heal.sh`, `infrastructure-health-check.sh`, `send-notification.sh`
`escalate_service` always pages `"critical"` (`:525`); re-escalation suppressed
only by the in-state `escalated` flag (cleared on recovery), no cooldown; the
per-run page fires every tick when `overall_status != healthy`
(`infrastructure-health-check.sh:274-280`). Sequence: (c) transition-only per-run
paging first (live on non-eris single-tenant hosts where `HEALTHCHECK_NOTIFY=true`);
(b) a `last_notified_at` cooldown ledger; (a) tiers + fleet consolidation last
(depends on Rank 2). Always page on severity change.

**[Rank 24] self-heal status surface** — `lunarwing-self-heal.sh`, `lunarwing-mt-admin.sh`
Decision events use stderr-only `log()` (`:104-106`) that fcron discards: RECOVERED
(`:751`), SKIP-escalated (`:569`), VERIFY (`:541-543`), end-of-run rollup
(`:773-776`). (*Correction:* `state.json` *is* machine-readable and `log_action`
*does* persist ESCALATE/RESTART_FAIL/GRACE/BACKOFF.) Route RECOVERED through
`log_action`; write an atomic per-tick `self-heal-status.json` (mktemp+mv like
`:403-408`) with counts; add `--status` for `doctor`. Pair with log rotation
(none today).

### podman-rootless

**[Rank 11] doctor: per-tenant rootless store + OpenRC linger** — `lunarwing-mt-admin.sh`
`doctor` validates rootless only generically — `podman info` as **root**
(`:2941`), subuid/subgid bits (`:2945-2950`) — and never runs podman **as a
tenant**, so a broken tenant store / missing `/run/user/<uid>` / dead userns
passes while the live pipeline is broken. `loginctl` is checked only under systemd
(`:2955-2956`); on OpenRC, reboot survival hinges on per-tenant linger, never
confirmed. Iterate `ports.json` and `_check` `sudo -u <t> env … podman info` +
`test -d /run/user/<uid>`; add a linger check (elogind fallback:
`test -e /var/lib/elogind/linger/<name>`). Guard with `id -u <name>` first (`_ctr`
calls `die` on uid-resolution failure, `:241`). **The linger check is the single
highest-value piece for this leg.**

**[Rank 16] Preflight rootless net backend** — `lunarwing-mt-admin.sh`
Every container publishes `-p 127.0.0.1:<port>:…` (PG `:1761`, nanocode `:1611`,
pebble `:1706`), which under rootless requires pasta/slirp4netns. Neither
`ensure_rootless_prereqs` (`:639-668`) nor `doctor` checks for it; the PG unit
discards the real error (`>/dev/null 2>&1` then generic "container start failed",
`:2068`). Assert `command -v pasta || command -v slirp4netns` after migrate and
`die` actionably (`net-misc/passt`); add a non-fatal `doctor` check. Drop the
`{{.Host.NetworkBackend}}` assertion (config backend ≠ forwarder presence).

**[Rank 25] Shared image store (rescope) + image prune** — `lunarwing-mt-admin.sh`
`_ensure_tenant_image` does a full per-tenant `save | _ctr load` (`:267`) — slow,
non-atomic (`:271`); the TODO at `:251-253` says additionalimagestore "isn't wired
yet". No `podman image prune`/`system prune` anywhere → rebuilds orphan layers in
the root store unbounded. **Keep the cheap win:** `podman image prune -f` after
each `build_*` + a `doctor` dangling-image check (only removes untagged). Rescope
the storage-sharing part to a purpose-built **read-only** shared store (or
`podman image scp`) and retain the save|load fallback until validated.

**[Rank 26] XDG/linger lifecycle** — `lunarwing-mt-admin.sh`
Linger is enabled silently best-effort (`:694-698`, no warning, stderr
suppressed); `remove_tenant_user` disables linger only under systemd (`:755-757`),
leaking OpenRC linger state. Keep: loud warn if `loginctl` absent / enable fails +
a doctor linger check; one-line `loginctl disable-linger` on OpenRC teardown.
*Drop* the `checkpath` in `status()` (with linger working the dir persists;
without it conmon already died, so the restart is correct anyway).

**[Rank 31] `--userns=keep-id` for the nanocode worker** — `lunarwing-mt-admin.sh`
Worker workspaces are bind-mounted `:z` (`:1612/:1707`) and `chmod 777`
(`:1592/:1688`). (*Correction:* **pebble runs as root** — under rootless, uid 0
maps to the tenant's real uid, so files are already tenant-owned; `keep-id` would
*break* it. **nanocode runs as non-root** (`USER nanocode`) → files land on a
subuid; fix is `--userns=keep-id:uid=<nanocode_uid>,gid=<nanocode_gid>`, rootless
only.) The rootful docker leg keeps 777. Per-worker, per-runtime branching, recreate
containers. Low impact (hygiene).

**[Rank 32] Native podman HEALTHCHECK correctness** — `lunarwing-mt-admin.sh`
Worker images bake a HEALTHCHECK; comments imply it's meaningful
(`:1594-1598/:1690-1694`), but `podman run` passes no `--health-*` and under
rootless+OpenRC (no systemd timers) podman never schedules it → `.State.Health`
stuck "(starting)". Real liveness is the OpenRC unit probe (`:317-320`). Pass
`--no-healthcheck` on the two worker `podman run` lines, fix the misleading
comments, document that no-systemd means no auto-update/timers. *Drop* the
`podman healthcheck run` rework (nothing reads `.State.Health`).

### openrc-integration

**[Rank 10] Fix always-zero `rc_exit`** — `health-openrc.sh:76-90`
`status_output=$(rc-service "$svc" status 2>&1) || true` then `rc_exit=$?`
captures `true`'s exit (always 0), so the fallback `elif [ $rc_exit -eq 0 ]`
(`:86`) classifies any non-keyword status text as healthy; the `else→stopped`
(`:89`) and `unknown→degraded` (`:108-110`) paths are dead. `.status` is exactly
what self-heal keys on (`self-heal:727-732`). Fix:
`rc_exit=0; status_output=$(rc-service "$svc" status 2>&1) || rc_exit=$?`
(set-e-safe in an if-condition) — activates the existing `else→stopped` branch,
**no edit to the elif/else chain needed**. (*Correction:* do **not** anchor the
greps with `status:\s*started` — mt-admin container units emit bare
`container: started` and would fall through.)

**[Rank 14] `supervise-daemon healthcheck()` for the 4 long-lived units** — `lunarwing-mt-admin.sh`
`lunarwing-<t>`, `xmpp-bridge-<t>`, `lunarwing-proxy-<t>`, `weechat-adapter-<t>`
use `supervise-daemon` + respawn (`:2126/:2190/:2252/:2357`) which restarts only
on **process exit**; a wedged-but-alive daemon waits for the 15-min cron. OpenRC
0.63.1 supports `healthcheck()`/`healthcheck_timer` natively, unused. Per-unit:
**daemon** — curl unauth `/api/health` on `GATEWAY_PORT`; **xmpp-bridge** —
`/v1/status` needs a Bearer token → TCP check or source `XMPP_BRIDGE_TOKEN`;
**proxy** — `/health` passes through to upstream TensorZero → TCP/port only (HTTP
would restart-loop on upstream outage); **weechat-adapter** — TCP. Latency/
redundancy, not a fix for a broken path (cron already recovers).

**[Rank 18] Dedup discovery globs + add `weechat-*`** — `health-openrc.sh:22-27`
`discover_services` globs `lunarwing-*` **and** `lunarwing-proxy-*` with no dedup
→ `lunarwing-proxy-<t>` emitted twice (visible in live reports). `weechat-<t>`
units (created `mt-admin:2287`, enrolled `:2432`) match no glob → invisible to
report and self-heal. Drop the redundant `lunarwing-proxy-*` glob (or `sort -u`);
add `/etc/init.d/weechat-*` with `[ -x ]`, skipping bare `weechat`. (*Correction:*
the duplicate is cosmetic — self-heal dedups via its `seen` map (`:707-731`).
*Defer* registry-aware "missing→critical" reconciliation — it would make self-heal
`rc-service restart` a nonexistent unit → escalation storm.)

**[Rank 27] Delete dead conf.d deps** — `lunarwing-mt-admin.sh:2394/2399`
Render emits `lunarwing_rc_need=…` and `xmpp_bridge_rc_before=…`; OpenRC honors
only unprefixed `rc_need`/`rc_before` in conf.d — the `<name>_rc_*` form matches
nothing and nothing consumes it. **Delete the two inert lines** (intent is
deliberately *soft*: daemon `depend()` uses `after`, not `need`). Do **not**
convert to hard `rc_need` (would cause restart-cascade). Fix doc drift in
`docs/ops/WEECHAT-SERVICES.md:168`.

**[Rank 30] Make container units self-supervising** — `lunarwing-mt-admin.sh`
PG (`:2033-2095`) and worker (`:288-352`) units are plain start/stop/status with
**no** `supervisor=`; rootless omits `--restart`; so a crashed container is
recovered only by cron at `GRACE_CHECKS=2`×`*/15` ≈ 15-30 min MTTR. **Try the
low-risk fallback first** — container-unit `GRACE_CHECKS=1` and/or shorter
`HEALTH_INTERVAL_MIN`. Only then attempt `supervise-daemon` + `podman start
--attach` behind `LUNARWING_MT_SUPERVISE_CONTAINERS`. See the dedicated
[`ROOTLESS_PODMAN_CONTAINER_SUPERVISION_GAP.md`](./ROOTLESS_PODMAN_CONTAINER_SUPERVISION_GAP.md)
for the full design (the `podman wait` babysitter variant). High effort, medium
impact (matters only if containers crash often).

**[Rank 33] Fix/drop the dead PID-liveness field** — `health-openrc.sh:93-103`
The probe searches `/run/<svc>.pid` etc., but MT units write to the tenant run dir
(`mt-admin:2108/:2173/:2236/:2340`), so `pid` is always 0; container units have no
pidfile; the line-3 header claims "PID liveness" but there is no `kill -0`. No
consumer reads `metrics.services[].pid` → prefer drop/explicit-0; fix the comment.

### health-accuracy

**[Rank 5] Per-service probe timeout isolation** — `health-openrc.sh`, `infrastructure-health-check.sh`
The discovery loop runs `rc-service <svc> status` serially with **no per-unit
timeout** (`:76`); container `status()` shells out to untimed `sudo -u <t> … podman
inspect`. The whole component shares one `timeout 30`
(`infrastructure-health-check.sh:68`); a single hung tenant consumes it all →
`{status:unknown}` with **no `metrics.services`** → self-heal yields zero targets
→ no-op. **One broken tenant blanks remediation for all tenants.** Wrap each
probe: `status_output=$(timeout 8 rc-service "$svc" status 2>&1) || rc_exit=$?`
(`timeout -k` so a SIGTERM'd rc-service doesn't orphan the child sudo/podman); map
exit 124 to degraded for that unit only.

**[Rank 15] pg `status()` depth (`pg_isready`)** — `lunarwing-mt-admin.sh:2089`
The pg unit's `status()` classifies "started" solely on `.State.Running`; a
Running-but-rejecting Postgres reports healthy to both the probe and
`verify_restart`. Asymmetric with workers (`_wk_healthy` = Running + `/health`,
`:317-320`) and with pg's own `start()` which already uses `pg_isready` (`:2070`).
Add `_pg_healthy()` requiring `.State.Running` AND `pg_isready -U lunarwing -q -t
3`. `GRACE_CHECKS=2` absorbs transient failures. (See also the supervision-gap
doc, which raises the same point.)

**[Rank 28] clickhouse host-RAM false positive** — `health-clickhouse.sh`
No disable toggle; when `clickhouse-client` is absent (the eris case),
`check_memory()` falls back to system `free` and reports **host RAM** under
`clickhouse memory_pct` (`:60-67`); with `MEMORY_CRITICAL=95` a busy host can drive
the component to critical → phantom `overall_status=critical` with no remediation
and no page. (Latent: live run returned healthy at 34% RAM — RAM-pressure-
conditional.) When both `clickhouse-client` and `/var/lib/clickhouse` are absent,
emit healthy/disabled; add `HEALTH_CLICKHOUSE_ENABLED`/`HEALTH_TENSORZERO_ENABLED`
toggles, false in the MT `health.env`.

### testing-chaos

**[Rank 3] Invert test O2 + ship the `load_state` guard together** — `tests/test-self-heal-matrix.sh`, `lunarwing-self-heal.sh`
O2 (`:458-464`) currently asserts a 0-byte `state.json` is "valid, not flagged"
and the run "completes cleanly" — it **codifies the live empty-state condition**
(Rank 4) and only greps log strings, never that state accumulated. Fix `load_state`
and rewrite O2 in the same change to assert the *recovery* contract — seed 0-byte,
run a degraded report with `GRACE_CHECKS=1` + verify-fail, assert
`state_of <sb> '.lunarwing.retries' == 1`. Add **O2b** (whitespace). (*Correction:*
O2c `null` is **not** a brick — it self-heals during remediation; keep only as a
defensive post-fix test.) Use raw `printf`, not `seed_state` (which pipes through
`jq -n`).

**[Rank 6] Realistic OpenRC restart mock + state-validity chaos** — `tests/lib.sh`, `tests/chaos-harness.sh`
The chaos mock `rc-service restart` is stdout-silent on success
(`lib.sh:205-208`), so it never reproduces the real OpenRC banner that corrupts
captured state (Rank 1). All 14 `run_chaos` calls use `systemd` (also silent) —
which is why the fd-leak and notifier-stdout bugs escaped CI. Make the mock
`restart` branch emit `* Stopping…/* Starting…` to **stdout**; add an OpenRC
scenario. (*Correction:* assert `assert_contains "$o" "=== Self-Healing complete
==="` — logged only after `save_state` at `:775` — not "recovered"/"valid JSON",
which pass even on the set-e abort.)

**[Rank 7] fd-200 lock-inheritance regression** — `tests/chaos-harness.sh`, `tests/lib.sh`
The `200>&-` fix (`self-heal:254-275`) prevents the long-lived restart child from
inheriting the single-instance lock; deleting it passes the whole suite. Add a
case where the mock `rc-service restart` forks a long-lived child holding fd 200,
run self-heal twice, assert run #2 is **not** blocked. **Gotcha:** `run_chaos`
output is captured, so the child must redirect stdio away
(`( exec 1>/dev/null 2>/dev/null; sleep 30 ) &`) or the harness hangs; negative
control via `sed`-out into a temp copy through the `SELF_HEAL_SCRIPT` override
(`lib.sh:18`); reap via trap/pkill; gate behind `command -v flock`.

**[Rank 8] Wire `run-all.sh` into CI** — `.github/workflows/`, `tests/run-all.sh`
15 workflows, **none** reference the ~188-assertion suite (it runs only on manual
invocation — both recent bugs were found live). Add a path-scoped workflow
(`paths: ic-infrastructure-health-check/**`) on push/PR to **staging** (the
integration branch — targeting only `main` would never fire) running
`bash …/tests/run-all.sh`. Verified CI-safe and green on a stock box (188 pass,
mocks shadow systemctl/rc-service/sudo, `GOTIFY_TOKEN=''`).

**[Rank 12] type-corrupt state regression** — `tests/test-self-heal-matrix.sh`
Add Section P — P2 seeds `consecutive_unhealthy:"seven"`, asserts the run completes
+ state persists; pair with the `load_state` coercion. (*Correction:* P4
`restart_history:["abc",123]` does **not** crash — jq tolerates it; the crash class
is broader — `retries`/`next_attempt_at` crash identically, reinforcing the central
`load_state`-coercion fix.)

**[Rank 13] `health-openrc.sh` test suite** — `tests/test-health-openrc.sh` (new)
Grep `health-openrc`/`discover_services` across `tests/` → **none**; the producer
of the report self-heal consumes is entirely untested. New suite with a fake
`/etc/init.d` + PATH-shadowed `rc-service`; assert non-keyword+nonzero → critical,
proxy appears once, discovery picks up pg/pebble/weechat, JSON valid. **Mandatory:**
add an `INITD_DIR=${INITD_DIR:-/etc/init.d}` override (the `SERVICES=` override at
`:38` bypasses `discover_services`).

**[Rank 23] OpenRC chaos for the prod config (`REMEDY_LOGICAL=false`)** — `tests/chaos-harness.sh`
Grep `REMEDY_LOGICAL` in tests → none; the deployed branch (`self-heal:699-717`)
is never exercised, and all 14 `run_chaos` calls use `systemd`. Add **CH16** —
`run_chaos openrc` with `SELF_HEAL_REMEDY_LOGICAL=false`, a critical openrc
sub-unit + a degraded logical gateway; assert the sub-unit is restarted once, base
`lunarwing` 0, MT-mode line present. (*Correction:* drop the proposed CH17/CH18 —
they'd test the wrong file or duplicate CH9.)

---

## 6. Quick wins (do this week)

> **Update (post-merge `2b471720`):** items **1–4** below (the curative trio + the
> O2 test) are now ✅ implemented. Items **5–8 and 11** remain — OpenRC-leg
> (`health-openrc.sh` / tests / CI), unchanged by the merge. **#9 (Rank 11)** is
> *mostly* done (per-tenant linger + `/run/user` checks added to `doctor`) and
> **#10 (Rank 18)** is partially done (weechat rename). The one operational step
> left is **deploying the updated self-heal script** to the live host so #1
> self-recovers.

1. **Rank 4** — `load_state` empty/object guard — *recovers the live 1-byte-state host.*
2. **Rank 1** — `esac >&2 200>&-` (stops restart-stdout state corruption; co-cause of #1).
3. **Rank 3** — invert O2 + add O2b in the same change (locks the fix).
4. **Rank 2** — `send-notification.sh --raw` for escalation + `// {}` defaults.
5. **Rank 5** — `timeout 8` (+`-k`) around per-unit `rc-service status`.
6. **Rank 10** — `rc_exit=0; … || rc_exit=$?`.
7. **Rank 8** — path-scoped CI workflow on `staging`.
8. **Rank 6** — noisy OpenRC restart mock + "Self-Healing complete" assertion.
9. **Rank 11** — doctor per-tenant `podman info` + OpenRC linger check.
10. **Rank 18** — drop redundant `lunarwing-proxy-*` glob; add `weechat-*`.
11. **Rank 27** — delete the inert conf.d dep lines.

**Curative trio = #1 (Rank 4) + #2 (Rank 1) + #4 (Rank 2).** Ship them with their
tests (#3, #8) and add the dead-man heartbeat (Rank 9) so any future wedge pages
instead of failing silently.

---

## 7. What's confirmed solid (don't "fix")

- **The core remediation loop** — detect → restart → verify → recover — works on
  the live host (9/9 restarts succeeded).
- **Atomic `save_state`** (mktemp+mv, `:403-408`).
- **`load_state`'s invalid-JSON corrupt-rename path** (the gap is *only*
  empty/whitespace/wrong-type).
- **The `200>&-` flock fix** (commit `c2c50b6b` — keep it; just test it).
- **The notifier-stdout `>&2` redirect** (commit `bb8bbc57` — the restart path
  needs the same treatment, Rank 1).
- **self-heal's `seen`-map dedup** of duplicated discovery entries.
- **mt-admin units emit canonical `started/stopped` wording** (so the
  "podman-rootless masks status" framing was corrected to false).

**Latent vs live (post-merge `2b471720`):** the curative trio (Ranks 1, 2, 4) is
now **fixed in code**; the only thing still *live* is that the **deployed** host
runs the pre-fix script, so its `state.json` stays empty until redeploy (it then
self-recovers). Everything else is latent — fires on a future incident, reboot,
schema skew, or mass outage — fix before that incident, not after.

---

## 8. Provenance & corrections log

- **Generated by** a 49-agent automated review (Map → Recommend → Verify →
  Synthesize over 6 dimensions; 36 recommendations, 0 dropped in adversarial
  verification), then **recalibrated against read-only inspection of the live
  host** (`/var/lib/lunarwing-health/.../self-heal/`, OpenRC 0.63.1, jq 1.8.1).
- **Corrections applied to the raw draft:**
  - "non-functional / bricked" → **withdrawn**; verified "works; stateful features
    dormant."
  - "proxy-zeus, 8 restarts in ~31s" → **~5** (verified from `actions.log`).
  - Severity of Rank 2 (escalation page) downgraded to **latent** (masked by
    `GOTIFY_TOKEN` gate + dormant state).
  - The review's own adversarial "Correction:" notes (flap-breaker, userns,
    HEALTHCHECK, conf.d, report-dedup, CH17/CH18, P4) are preserved as the accurate
    version.
- **Severity legend:** *LIVE* = observed on the running host today; *latent* =
  real in code, not currently firing; *hardening* = robustness/coverage, no current
  defect.
