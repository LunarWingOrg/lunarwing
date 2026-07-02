# mt-admin Container-Runtime Persistence — Design

**Date:** 2026-07-02
**Status:** Approved design, pending implementation
**Target:** `ic/scripts/lunarwing-mt-admin.sh` (+ small doc updates)
**Origin:** Follow-up item 2 of the SSH-arc backlog. `detect_container_runtime()` prefers docker whenever the docker CLI exists, so on a dual-runtime box the operator must prefix **every** command with `LUNARWING_CONTAINER_RUNTIME=podman` (and remember `sudo env`); forgetting it silently targets the wrong runtime — podman and docker are separate container universes, so the failure modes are confusing (e.g. "postgres failed to connect to docker API").

## Goal

Set the runtime **once** — the next command run with `LUNARWING_CONTAINER_RUNTIME=<rt>` persists the choice machine-wide; every later command uses it with no env var.

## Decisions (from brainstorm)

| Decision | Choice |
|---|---|
| Persist trigger | **Auto-persist on explicit env-var use.** No new subcommand. Auto-*detected* values are never persisted (a dual-runtime box must not cement "docker" by accident). |
| Storage | **Dedicated file `/etc/lunarwing/container-runtime`** containing exactly `podman` or `docker` (one line, mode `0644`, dir auto-created). Chosen over a `ports.json` field (jq dependency + chicken-and-egg before the registry exists) and over a sourced env file (needlessly wide mechanism). |
| Scope | System-global (per box), shared by all admins — mt-admin always runs as root, and the tenant fleet the choice governs is machine-global. Per-user scope would reintroduce split-brain. |
| Failure philosophy | Warn-and-continue: unreadable/garbage file → warn + fall through to auto-detect; unwritable file → warn + continue with the resolved value. No new `die` paths beyond the existing invalid-env-value one. |

## Behavior

**Resolution order in `detect_container_runtime()`:**
1. `LUNARWING_CONTAINER_RUNTIME` env var — validated (`docker|podman`, else `die`, unchanged).
2. `/etc/lunarwing/container-runtime` file — trimmed, lowercased, validated; a value other than `docker`/`podman` warns (`WARNING: ignoring invalid /etc/lunarwing/container-runtime: '<val>'`) and falls through.
3. Existing auto-detect (unchanged, docker-preferred when both CLIs exist).

**Persistence rule:** only when resolution came from step 1 AND the file is absent or holds a different value: write the value to the file and `say` one line, e.g. `container runtime 'podman' saved to /etc/lunarwing/container-runtime (env var no longer needed)`. When env conflicts with the file, **env wins and overwrites** (latest explicit choice is the truth), with the message making the switch visible. Same-value env use writes nothing (idempotent, no chatter).

**Doctor:** one informational line reporting the resolved runtime and its source: `env` / `saved (/etc/lunarwing/container-runtime)` / `auto-detected`.

**Non-root reads:** `doctor` may run unprivileged; the `0644` file is still readable. Any write failure (read-only `/etc`, non-root) warns and continues.

## Implementation shape

- New helper `_load_saved_container_runtime()` (read+validate the file; prints value or nothing) and `_save_container_runtime <rt>` (mkdir -p `/etc/lunarwing`, write via temp-file+`mv` in the same directory, chmod 0644, warn-and-continue). No `sed -i`.
- `detect_container_runtime()` gains the file branch between env and auto-detect, plus the persist call on the env branch. The function currently only `printf`s the value; persistence output must go to **stderr** (`say ... >&2`) so command-substitution callers (`CONTAINER_RT="$(detect_container_runtime)"`) don't capture the message into the runtime value.
- Doctor's line uses the same helpers to report the source without duplicating logic.

## Testing

- `bash -n`; extracted-function harness under `set -euo pipefail` covering: env + no file (persists, stdout is exactly the runtime name); file only (used, no rewrite — check mtime/content unchanged); env vs file conflict (env wins, file updated); garbage file (warning on stderr, auto-detect fallback); no env + no file (auto-detect, nothing written); unwritable dir (warning, still resolves).
- Live on the deployment box: one command with the prefix (observe the "saved" line), next command **without** the prefix (observe podman used — e.g. `status sshtest` hits the podman-backed tenant cleanly), and `doctor` showing `saved` as the source.

## Docs to update

- mt-admin usage text: the `LUNARWING_CONTAINER_RUNTIME` line gains "(persisted to /etc/lunarwing/container-runtime on first explicit use; later runs need no env var)".
- `docs/ops/MULTITENANCY-PRODUCTION.md`: prerequisites/quick-start note about set-once behavior.

## Out of scope

- No `set-runtime` subcommand (persist-on-env-use chosen instead).
- No change to `LUNARWING_MT_ROOTLESS` handling or the auto-detect preference order.
- Multi-box propagation (each host keeps its own choice by design).
