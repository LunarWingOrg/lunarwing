# Review Pass: podman wait babysitter implementation

**Date**: 2026-06-16
**Branch**: `prerelease-1.1.4-wrench` (uncommitted)
**Reviewer**: Kumogakure
**Scope**: Correctness audit of all changes from the implementation session.

## TL;DR

**One critical bug found.** Single-quote/heredoc quoting in `command_args` will produce a unit that **fails to start** because OpenRC splits `command_args` on whitespace, not via shell parsing. Single quotes become literal argv characters, so `/bin/sh -c` receives a malformed command string.

Everything else (lifecycle wiring, env threading, `supervise_daemon_args` syntax, `-ctr` filtering, tests) is correct.

Tests pass (216/0) only because **no test actually exercises the generated unit file under supervise-daemon** — the tests are fixture-driven mocks of `rc-service status` output. The bug is invisible to the existing test suite.

## CRITICAL BUG: command_args shell-quoting

### Current code (broken)

In `render_pg_ctr_unit()` (lines 487-488) and `render_worker_ctr_unit()` (similar):

```sh
command="/bin/sh"
command_args="-c '${pg_runtime} start ${pg_container} >/dev/null 2>&1 || true; exec ${pg_runtime} wait ${pg_container}'"
```

### Why it fails

OpenRC's openrc-run reads `command_args` and splits on whitespace to build the argv array passed to `command`. There is no shell parsing of quotes.

For PG container `lunarwing-pg-zeus` with runtime `/usr/bin/podman`, the splitting produces:

```
argv[0]=/bin/sh
argv[1]=-c
argv[2]='/usr/bin/podman          <-- literal single-quote at start
argv[3]=start
argv[4]=lunarwing-pg-zeus
argv[5]=>/dev/null
argv[6]=2>&1
...
argv[N]=lunarwing-pg-zeus'        <-- literal single-quote at end
```

`/bin/sh -c` then tries to execute argv[2] as its command string, which is `'/usr/bin/podman` — starting with a literal quote — and fails immediately.

Even if quoting were perfect, the redirections (`>/dev/null`, `2>&1`) become argv elements rather than shell metacharacters, since they pass through OpenRC's tokenizer before reaching any shell.

### Verification

I ran a simulation (`/tmp/test-quoting.sh`):

```
argv[1] = '${pg_runtime}
The single quotes are LITERAL characters — /bin/sh -c will try to execute
a command starting with a quote!
```

### Fix: wrapper script

The clean, idiomatic OpenRC pattern is a small wrapper script invoked as `command`, with positional args as `command_args`:

**Create** `/opt/data/lunarwing/ic/scripts/lunarwing-ctr-babysit`:

```sh
#!/bin/sh
# LunarWing container babysitter wrapper.
# Args: <runtime> <container>
# Idempotently starts the container, then blocks on `podman wait`.
# When the container exits, this wrapper exits, supervise-daemon respawns it,
# and the cycle starts the container again.
set -u
RT="${1:?usage: $0 <runtime> <container>}"
CT="${2:?usage: $0 <runtime> <container>}"
"$RT" start "$CT" >/dev/null 2>&1 || true
exec "$RT" wait "$CT"
```

Install it to `/usr/local/lib/lunarwing/lunarwing-ctr-babysit` (or `/usr/libexec/...`).

**Then change the unit template to**:

```sh
command="/usr/local/lib/lunarwing/lunarwing-ctr-babysit"
command_args="${pg_runtime} ${pg_container}"
```

Now argv is clean:
- argv[0] = lunarwing-ctr-babysit
- argv[1] = /usr/bin/podman
- argv[2] = lunarwing-pg-zeus

The redirections and `|| true` live inside the wrapper script where the shell can actually parse them.

### Bonus: avoids `command_user` + `/bin/sh` interaction

When `command_user=zeus:zeus` is set, supervise-daemon does `setuid(zeus)` before `execve("/bin/sh", argv)`. With the broken approach, the failing `/bin/sh -c '<garbage>'` would fail as user `zeus`. With the wrapper, the same setuid happens, and the wrapper runs as zeus correctly.

## Things that are correct (verified)

### 1. `supervise_daemon_args="--env HOME=..."` syntax

Verified against upstream OpenRC source (`src/supervise-daemon/supervise-daemon.c`):

```c
{ "env",          1, NULL, 'e'},
```

So `--env KEY=VALUE` (long form) is valid; equivalent to `-e KEY=VALUE`. Whitespace-split argv works:
- `--env`
- `HOME=/home/zeus`
- `--env`
- `XDG_RUNTIME_DIR=/run/user/1001`

This is the exact pattern used by the Alpine Docker Rootless OpenRC service.

### 2. `command_user="user:group"` works with supervise-daemon

Confirmed by upstream supervise-daemon source: it calls PAM/setuid before exec, then applies env from `--env`.

### 3. Lifecycle wiring

- `_register_worker_unit` adds the `-ctr` unit, rc-update default, rc-service start — correct.
- `_deregister_worker_unit` stops, rc-update del, removes both `/etc/init.d/X-ctr` and `/etc/conf.d/X-ctr` — correct.
- `start_tenant_openrc` starts the `-ctr` babysitter after the imperative PG unit — correct ordering.
- `stop_tenant_openrc` stops the `-ctr` babysitter after the imperative PG unit — correct (so the babysitter doesn't respawn while we're trying to stop).
- `uninstall_tenant_openrc` cleans up all 3 `-ctr` units — correct.

### 4. `depend()` chains

- PG-ctr: `need net localmount; after firewall; before lunarwing-${name}` — correct (PG must be up before main daemon).
- Worker-ctr: `need net localmount; after firewall lunarwing-${name}` — correct (workers come up after the daemon).

### 5. `-ctr` filtering

- `health-openrc.sh:discover_services()` case branch matches `*-ctr` and skips — verified in S7 tests.
- `lunarwing-self-heal.sh:unit_tenant()` strips `-ctr` suffix before extracting tenant name — verified in D-ctr tests.

### 6. Test coverage

- S7 (health-openrc): 3 -ctr units present, none in JSON report, real units still discovered. PASS.
- D-ctr (self-heal-matrix): `lunarwing-{pg,nanocode,pebble}-acme-ctr` all map to "acme". PASS.
- All 216 existing tests still green.

## Concerns / Open Questions

### Q1: stop ordering creates a respawn race

Current `stop_tenant_openrc` sequence:
1. Stop `lunarwing-${name}` (daemon)
2. Stop `lunarwing-pg-${name}` (imperative; does `podman stop`)
3. Stop `lunarwing-pg-${name}-ctr` (babysitter)

Between step 2 (container exits via `podman stop`) and step 3 (babysitter stopped), supervise-daemon will see the container exit and attempt to respawn it. It will call `podman start lunarwing-pg-zeus` again — which may succeed before step 3 kills the babysitter.

**Result**: A "stopped" tenant may have a running PG container until the next start cycle. Minor but real.

**Fix options**:
- Reorder: stop babysitter FIRST, then imperative unit:
  ```
  rc-service lunarwing-pg-${name}-ctr stop
  rc-service lunarwing-pg-${name} stop
  ```
  This is safer — babysitter is killed before container is touched.
- The babysitter's respawn_delay=2s gives a small window even if reordered, but `rc-service ... stop` is synchronous and supervise-daemon SIGTERMs cleanly.

**Recommendation**: Reorder stops — babysitter first.

### Q2: Worker babysitter unused?

`render_worker_ctr_unit` is defined and wired into `_register_worker_unit` / `_deregister_worker_unit`, but I should verify that `_register_worker_unit` is actually called somewhere in the worker provisioning path. Grep for callers.

### Q3: `health_port` arg unused in worker babysitter

The worker babysitter template accepts `health_port` but never uses it (the babysitter just runs `podman wait`, no health check). It's an unused parameter — should be dropped from the function signature, or repurposed if we ever add `healthcheck()`.

### Q4: `pg_uid` empty when tenant user does not exist yet

`pg_uid="$(id -u "$name" 2>/dev/null || echo "")"` — if user not created yet, `pg_uid` is empty. Generated unit becomes:

```
: "${pg_uid:=}"
...
supervise_daemon_args="--env HOME=/home/zeus --env XDG_RUNTIME_DIR=/run/user/"
```

Empty `XDG_RUNTIME_DIR` will break rootless podman. The existing `lunarwing-pg-${name}` unit has the same risk but it gates on `[ -n "${pg_runtime}" ]`; the babysitter has no equivalent guard.

**Recommendation**: Add a `start_pre()` guard:
```
if [ -z "${pg_uid}" ] || [ ! -x "${pg_runtime}" ]; then
    ewarn "container runtime or tenant uid unavailable; skipping"
    return 1
fi
```

But this matters less in practice because `render_tenant_openrc_units` is called AFTER tenant user creation. Worth a comment though.

## Recommended action

1. **Don't commit current state.** The `command_args` bug means the babysitter would fail to start on a real Gentoo/Alpine host.
2. **Add wrapper script** at `ic/scripts/lunarwing-ctr-babysit`, install during `mt-admin install`.
3. **Rewrite both `render_*_ctr_unit` templates** to use the wrapper.
4. **Reorder `stop_tenant_openrc`** to stop babysitter before the imperative PG unit.
5. **Add `start_pre()` guard** in babysitter for empty runtime / uid.
6. **Add integration test** that actually generates a unit file, parses argv, and confirms `/bin/sh -c` would receive a sensible command. (Catches future regressions of this bug class.)
7. **Re-run tests** and commit.

## What didn't get audited

- **Real-host deployment**: We can't test supervise-daemon behaviour without an OpenRC host (containers in this env don't have it). All correctness above is from source-reading + simulation.
- **Container runtime races**: When `podman wait` exits because of `podman stop` from another process, does the exit code distinguish "stopped externally" vs "crashed"? Currently we don't care (we respawn unconditionally), but it could matter for crash-loop containment with `respawn_max`.
- **PAM interaction**: `command_user` triggers a PAM session via supervise-daemon. The `--env` flags MAY be overridden by PAM session env (limits.conf, pam_env). Test on real Gentoo to confirm.

---

## Fixes applied (post-review, same session)

All 7 recommended actions are now done. Tests: 247/0 (was 216/0; added 31 new).

### Files changed
| File | Change |
|---|---|
| `ic/scripts/lunarwing-ctr-babysit` | NEW — 60-line POSIX sh wrapper |
| `ic/scripts/lunarwing-mt-admin.sh` | BABYSIT_* constants, ensure_babysit_wrapper(), rewrote both render_*_ctr_unit, reordered stop_tenant_openrc + _deregister_worker_unit |
| `ic-infrastructure-health-check/tests/test-babysit-renderers.sh` | NEW — 31 tests |
| `ic-infrastructure-health-check/tests/run-all.sh` | Added `babysit` suite to ORDER |

### Fix #1: Wrapper script replaces broken command_args
- `lunarwing-ctr-babysit` does `start` then `exec wait`. Returns exit 2 on bad args, exit 1 when runtime not executable, exit 0 on clean container exit. Manually verified all three paths.
- Added `BABYSIT_SRC` (source path next to admin script), `BABYSIT_LIB_DIR=/usr/local/lib/lunarwing`, `BABYSIT_BIN`.
- `ensure_babysit_wrapper()`: idempotent `install -m 0755`. Called from both render functions.
- Both renderers now emit:
  ```
  command="${babysit_bin}"
  command_args="${runtime} ${container}"
  ```
  Argv after OpenRC whitespace-split: `[wrapper, /usr/bin/podman, lunarwing-pg-zeus]` — clean.

### Fix #2: Stop ordering
- `stop_tenant_openrc`: PG babysitter stopped BEFORE imperative PG unit (was reversed).
- `_deregister_worker_unit`: worker babysitter stopped before imperative worker unit.

### Fix #3: start_pre() guards
- Both babysitter units check (a) runtime exists & executable, (b) uid non-empty in rootless mode, (c) wrapper binary installed. Return 1 if any fail → supervise-daemon respawns then crash-loop-caps the unit.

### Fix #4: Unused `health_port` arg dropped from `render_worker_ctr_unit`.

### Fix #5: Integration test catches the bug class
- `test-babysit-renderers.sh` sources a sed-patched copy of the admin script (writes redirected to a sandbox), generates 3 unit files, parses each.
- **4 regression grep guards** that specifically catch the old broken patterns:
  - `^command="/bin/sh"` (the old command)
  - `^command_args=.*'` (literal single quote)
  - `^command_args=.*>/dev/null` (shell redirection)
  - `^command_args="-c ` (the -c flag)
- Each guard was verified to FIRE on a synthetic broken unit before the test was finalized.
- **Argv simulation**: parses `command_args`, splits on whitespace, asserts argv[1]=runtime, argv[2]=container — exactly what supervise-daemon would see.
- **Wrapper behavior**: invokes the wrapper with no args / bad runtime / fake-good runtime, asserts exit codes 2/1/0.
- **bash -n syntax check** on every generated unit file.

### Final test suite: 247/0
```
suite            pass     fail     exit
regression         28        0        0
matrix            128        0        0
chaos              36        0        0
openrc             24        0        0
babysit            31        0        0   ← NEW
TOTAL             247        0
```

### Verification

Generated PG unit (rendered for tenant `zeus`, container `lunarwing-pg-zeus`):
```
command="${babysit_bin}"
command_args="${pg_runtime} ${pg_container}"
command_user="${pg_user}:${pg_user}"
supervise_daemon_args="--env HOME=${pg_home} --env XDG_RUNTIME_DIR=/run/user/${pg_uid}"
```
After variable expansion at runtime:
- `command` → `/usr/local/lib/lunarwing/lunarwing-ctr-babysit`
- `command_args` → `/usr/bin/podman lunarwing-pg-zeus` (2 argv tokens)
- `command_user` → `zeus:zeus`
- `supervise_daemon_args` → `--env HOME=/home/zeus --env XDG_RUNTIME_DIR=/run/user/1001` (4 argv tokens)

## Remaining action

**Do not commit yet.** Showing diff to sun for approval first.
