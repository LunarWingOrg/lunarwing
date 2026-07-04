# Test Plan: Upgraded Tenant Across the 1.1.9 Renames (OpenRC/Gentoo)

**Goal:** validate `docs/ops/TENANT-RENAME-MIGRATION-1.1.9.md` end-to-end on a
tenant that was **provisioned on v1.1.8** and upgraded to 1.1.9 — the case the
fresh-tenant test (tenant `lion`, provisioned 2026-07-04 from the 1.1.9 tree)
cannot cover, because a fresh tenant never has old-path units or carried state.

**Machine assumptions (verified 2026-07-04):** Gentoo + OpenRC + rootless
podman; single production tenant `lion` (must remain untouched); port registry
`/etc/lunarwing/ports.json` at version 11; git tag `v1.1.8` present; ≥ 20 GB
free disk; tmux available. Tenant checkouts are full git clones with
`origin = /home/eris/lunarwing`.

**Verified go/no-go preconditions (already checked, re-verify on the day):**

- v1.1.8 mt-admin's registry migrations are monotonic (`if version -lt N`),
  so it reads a v11 registry without touching it. ✔
- The current script's v11 migration is *content-gated* (fires for any tenant
  entry that has `reserved_7` but no `opencode_wss`), so a v1.1.8-shaped
  tenant entry gets its missing port fields backfilled by the first
  current-mt-admin invocation. ✔
- No DB migrations changed between v1.1.8 and the 1.1.9 head (schema-neutral
  upgrade). ✔
- Compat symlinks are git-tracked mode-120000 blobs — they arrive atomically
  with any `git checkout/pull`. ✔

**Known-expected behaviors (do not treat as test failures):**

- **WeeChat health-glob / render-units flap**: the fix is scheduled for
  v1.2.3 (`ROADMAP_2026.md`; writeup in
  `docs/proposals/RENDER_UNITS_SMALL_BUG.md`) and is NOT in 1.1.9. Watch for
  adapter/weechat flap after `render-units` + restart, record what happens,
  tolerate it. (`supervise-daemon` respawn limit: 5 per 60 s.)
- A bridge without valid XMPP credentials crash-loops to `crashed` and
  generates health noise — decide credentials up front (Decision D1).
- The health pipeline pages via Gotify. A crash-looping throwaway tenant
  produces real operator pages and self-heal restart churn. Keep the test
  window short and expect noise, or schedule accordingly.

## Decisions to make before starting

- **D1 — XMPP creds:** give the throwaway tenant real XMPP credentials
  (clean bridge, no noise) or accept a parked/crash-looping bridge for a
  short window. Recommended: real creds if cheap, else `--no-xmpp`-equivalent
  parking (check flag availability in v1.1.8 script).
- **D2 — DarkIRC coverage:** `lion` models weechat only. Enabling darkirc on
  the throwaway exercises the second compat symlink
  (`darkirc_channel_for_ironclaw`) and its adapter unit. Recommended: enable
  if darkirc infra (ircd endpoint) is available; otherwise the symlink is
  still asserted at filesystem level (Assert 3) and unit level via grep.
- **D3 — Mixed-version worker depth:** opencode did not exist in v1.1.8, so
  the "old worker + new daemon" cell needs a **pebble** worker built from the
  v1.1.8 tree (heavy: container image build). Code-level compat is already
  verified (v1.1.8 bridges accept any offer list containing
  `ironclaw-agent-v1` and echo it; tungstenite accepts any echoed value it
  offered). Recommended: skip the image build unless releasing hinges on it;
  run Phase 4 only if D3=yes.
- **D4 — Upgrade target ref:** the branch being validated for release
  (`1.1.9-renames` at time of writing). The tenant's origin
  (`/home/eris/lunarwing`) must contain it.

## Phase 0 — Preflight (read-only + backups)

```bash
df -h /                                   # need ~12 GB for the throwaway tenant
sudo cp -a /etc/lunarwing/ports.json /etc/lunarwing/ports.json.pre-tiger-test
ls -la /usr/local/lib/lunarwing-health/ /usr/local/sbin/lunarwing-mt-health   # record mtimes (lion-protection baseline)
sudo /home/eris/lunarwing/ic/scripts/lunarwing-mt-admin.sh status lion        # lion healthy baseline
for u in /etc/init.d/*-lion; do stat -c '%y %n' "$u"; done                     # record unit mtimes
```

All long-running mt-admin commands below run **inside tmux** (machine rule).
Throwaway tenant name used here: `tiger` (any name ≠ lion works; double-check
every command's tenant argument — `remove-tenant` is registry-keyed).

## Phase 1 — Synthesize a genuine v1.1.8 tenant

`add-tenant` has **no ref-pin flag**: it clones the *current named branch* of
the source repo the invoked script lives in (detached HEAD silently falls
back to `origin/staging` — a plain tag checkout does NOT pin). So provision
from a pinned clone using **the v1.1.8 copy of mt-admin**:

```bash
git clone /home/eris/lunarwing /home/eris/lunarwing-v118
git -C /home/eris/lunarwing-v118 checkout -b pin-1.1.8 v1.1.8
sudo LUNARWING_MT_SOURCE_REPO=/home/eris/lunarwing-v118 \
  /home/eris/lunarwing-v118/ic/scripts/lunarwing-mt-admin.sh \
  add-tenant tiger --no-health [--with-pebble per D3] [xmpp flags per D1]
```

**`--no-health` is mandatory**: without it, the v1.1.8 `add-tenant`
*downgrades* the host-global health pipeline
(`/usr/local/lib/lunarwing-health/`, `/usr/local/sbin/lunarwing-mt-health`,
cron entry) to v1.1.8 copies — silently changing behavior for `lion`. This is
the single most likely way this test damages production.

```bash
sudo /home/eris/lunarwing-v118/ic/scripts/lunarwing-mt-admin.sh build-tenant tiger --with-wasm   # tmux; flock-serialized
sudo /home/eris/lunarwing-v118/ic/scripts/lunarwing-mt-admin.sh start-tenant tiger
```

**Baseline assertions (must all pass before proceeding):**

```bash
# A1: tenant is genuinely on v1.1.8
sudo -u tiger git -C /home/tiger/lunarwing log -1 --oneline          # = v1.1.8 tag commit
# A2: units embed OLD adapter path (adapter_args default + directory=)
grep -c 'ironclaw_weechat_wss' /etc/init.d/lunarwing-weechat-adapter-tiger   # expect 2
# A3: old dirs are REAL directories, no symlinks yet
test -d /home/tiger/lunarwing/ironclaw_weechat_wss -a ! -L /home/tiger/lunarwing/ironclaw_weechat_wss && echo real-dir-ok
# A4: services healthy
sudo /home/eris/lunarwing/ic/scripts/lunarwing-mt-admin.sh status tiger
rc-service lunarwing-weechat-adapter-tiger status
# A5 (if D3): record OLD worker banner — no "legacy alias" suffix on v1.1.8
sudo -u tiger env HOME=/home/tiger XDG_RUNTIME_DIR=/run/user/$(id -u tiger) \
  podman logs lunarwing-pebble-tiger 2>&1 | grep '\[bridge\]\|subprotocol'
```

Note: running any *current* mt-admin command (as above for `status`) will
backfill tiger's v9–v11 port fields via the content-gated migration — that is
expected and part of what we're testing.

## Phase 2 — Upgrade the checkout (validates the no-breakage-window claim)

```bash
sudo /home/eris/lunarwing/ic/scripts/lunarwing-mt-admin.sh backup-tenant tiger
sudo /home/eris/lunarwing/ic/scripts/lunarwing-mt-admin.sh stop-tenant tiger
# retarget origin to the live repo and move to the release ref (D4)
sudo -u tiger git -c safe.directory=/home/tiger/lunarwing -C /home/tiger/lunarwing remote set-url origin /home/eris/lunarwing
sudo -u tiger git -c safe.directory=/home/tiger/lunarwing -C /home/tiger/lunarwing fetch --tags --prune origin
sudo -u tiger git -c safe.directory=/home/tiger/lunarwing -C /home/tiger/lunarwing checkout -b upgrade-test origin/1.1.9-renames
```

**Assertions — symlinks arrive with the checkout:**

```bash
readlink /home/tiger/lunarwing/ironclaw_weechat_wss              # -> lunarwing_weechat_wss
readlink /home/tiger/lunarwing/darkirc_channel_for_ironclaw     # -> darkirc_channel_for_lunarwing
test -f /home/tiger/lunarwing/ironclaw_weechat_wss/weechat_relay/ws_adapter.py && echo resolves-ok
sudo -u tiger git -C /home/tiger/lunarwing config core.symlinks  # must NOT be false
```

Rebuild and start **without re-rendering units** — old-path units must work
through the symlinks:

```bash
sudo /home/eris/lunarwing/ic/scripts/lunarwing-mt-admin.sh build-tenant tiger --with-wasm   # tmux
sudo /home/eris/lunarwing/ic/scripts/lunarwing-mt-admin.sh start-tenant tiger
```

**Assertions — the bridging claim:**

```bash
# A6: adapter runs FROM the old path in argv, resolving to the new real dir
rc-service lunarwing-weechat-adapter-tiger status                 # started
pgrep -af 'ironclaw_weechat_wss/weechat_relay/ws_adapter.py'      # old path in argv
readlink /proc/$(pgrep -f 'ws_adapter.py' | head -1)/cwd          # .../lunarwing_weechat_wss/weechat_relay
tail -20 /home/tiger/lunarwing/logs/weechat-adapter.err           # no ENOENT/traceback
# A7: WASM artifacts keep loading (names are rename-neutral; DB stores BYTEA, no paths)
sudo ls -la /home/tiger/lunarwing/state/channels/                 # weechat.wasm etc. present
grep -iE 'wasm channel|weechat' /home/tiger/lunarwing/logs/lunarwing.err | tail -5
# A8: env legacy aliases quiet (both LUNARWING_* and IRONCLAW_* set identically since 1.1.8)
grep 'differ; using' /home/tiger/lunarwing/logs/lunarwing.err     # expect empty
# A9 (if D3): mixed cell — NEW daemon offers both, OLD pebble echoes legacy, still connects
grep "External worker" /home/tiger/lunarwing/logs/lunarwing.err | tail -5   # 'ready', no 'connection failed'/'protocol error'
```

**Optional A10 — v1.2.0 rehearsal (destructive-ish, tiger only, pre-render):**
move `ironclaw_weechat_wss` symlink aside → adapter restart must FAIL →
restore symlink → restart recovers. Validates the migration doc's deadline
claim. Never run against lion.

## Phase 3 — render-units + restart

```bash
for u in /etc/init.d/*-tiger /etc/conf.d/*tiger*; do sudo cp -a "$u" /root/tiger-units-pre-render/; done
sudo /home/eris/lunarwing/ic/scripts/lunarwing-mt-admin.sh render-units tiger
diff -r /root/tiger-units-pre-render/ /etc/init.d/   # review FULL diff: render also updates units to current generator shape, not just adapter paths
grep -rl 'ironclaw_weechat_wss\|darkirc_channel_for_ironclaw' /etc/init.d/ /etc/conf.d/   # expect EMPTY
sudo /home/eris/lunarwing/ic/scripts/lunarwing-mt-admin.sh patch-env tiger
rc-service lunarwing-weechat-adapter-tiger restart
sleep 120; rc-service lunarwing-weechat-adapter-tiger status; rc-service lunarwing-weechat-tiger status
tail -5 /home/tiger/lunarwing/logs/weechat-adapter.err            # observe (known footgun: possible flap — record, don't fail)
pgrep -af 'lunarwing_weechat_wss/weechat_relay/ws_adapter.py'     # NEW path in argv now
```

## Phase 4 (only if D3=yes) — worker image rebuild, second mixed cell

Rebuild the pebble image from the upgraded checkout, recreate the container,
assert the new banner (`subprotocol: lunarwing-agent-v1 (legacy alias
accepted: ironclaw-agent-v1)`) and a clean `External worker ... ready` in the
daemon log — proving the primary name now negotiates end-to-end.

## Phase 5 — Teardown + lion integrity check

```bash
sudo /home/eris/lunarwing/ic/scripts/lunarwing-mt-admin.sh remove-tenant tiger --purge   # TRIPLE-CHECK the name
rm -rf /home/eris/lunarwing-v118 /root/tiger-units-pre-render
ls /etc/init.d/ /etc/conf.d/ | grep tiger                          # expect empty
python3 -c "import json; print(list(json.load(open('/etc/lunarwing/ports.json'))['tenants']))"   # ['lion']
# lion untouched:
sudo /home/eris/lunarwing/ic/scripts/lunarwing-mt-admin.sh status lion
for u in /etc/init.d/*-lion; do stat -c '%y %n' "$u"; done          # mtimes unchanged from Phase 0
ls -la /usr/local/lib/lunarwing-health/ /usr/local/sbin/lunarwing-mt-health   # mtimes unchanged
```

**Success criteria:** every numbered assertion passes; the only tolerated
anomaly is the documented render-units flap (recorded, not fixed here);
lion's units, health pipeline, and registry entry are bit-identical to the
Phase 0 baseline.

## Incidental findings from planning (operator FYI, not part of this test)

- `/etc/conf.d/` holds `*ninejane*` remnants (comment-only) with no matching
  init scripts — leftovers from a prior test tenant; harmless, delete at will.
- `/home/lion/lunarwing` contains a ~74 MB regular file whose name is
  whitespace (mtime Jul 4 20:25) — likely a stray binary copy; worth a look.
- `TENANT-RENAME-MIGRATION-1.1.9.md`'s footgun caveat originally pointed at
  "GOALS item #7", which has since been renumbered; the fix is actually
  scheduled for v1.2.3 (see that doc's corrected caveat).
