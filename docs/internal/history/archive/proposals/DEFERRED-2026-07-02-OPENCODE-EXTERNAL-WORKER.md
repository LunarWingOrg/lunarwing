## Status (2026-07-02)

Polish + repo-doc pass addressed:
- `build-tenant --with-opencode` now threads through `build_tenant` (banner + consistency) instead of building separately.
- `build_opencode_worker` carries the `--network=host`/`--format docker` rationale comments (F8/O4) matching nanocode/pebble.
- opencode upstream pinned to release tag via `OPENCODE_REF` build arg (default `v1.17.13`); overridable.
- `opencode4lunarwing/README.md` CLI invocation corrected (uses `TASK_PROMPT` env).
- `migrate-ports-v10-to-v11.sh` brought to parity with v8/v9/v10 standalone migrators: strict `version < 10` gate, timestamped backup, collision-uniqueness validation, rollback hint.
- Repo-level docs updated: `README.md` (Opencode Worker bullet, v11 schema ref, worker-type count), `docs/README.md` (index parenthetical + worker-dir list), `docs/ops/WORKER-CONTAINERS.md` (Opencode + Pebble sections), `docs/ops/MULTITENANCY-PRODUCTION.md` (build flags, configure-opencode, extended port block, v11 schema, dir layout, OpenRC brace list, command reference), `docs/guides/MT-ADMIN-QUICKSTART.md` (prereq + extended port map), `docs/ops/TENANT-CONFIGURATION.md` (systemd/OpenRC unit lists + extended port table), `docs/ops/ROADMAP_2026.md` (opencode row marked shipped-early v1.1.8), `docs/ops/GOALS_1.1.8.md` (item #8 marked done).

## Live end-to-end validation: COMPLETE (2026-07-02)

The never-done round-trip listed under "Remaining follow-ups" is **done.**
Validated on tenant `octest` (Fedora dev host, rootless podman, systemd):

- `build-opencode-worker --no-cache` → image built, SDK assertion passed.
- `add-tenant`→`build-tenant --with-opencode`→`start-tenant` lifecycle ran clean:
  image synced into the tenant's rootless store via `podman save|load`
  (`_ensure_tenant_image`), stale container force-recreated
  (`_container_config_changed`), quadlet unit active, `/health` + `/ready` 200
  with `websocket.listening:true`.
- Daemon registered the worker: `External workers configured: opencode, pebble, nanocode`.
- Dispatched a task via the gateway (`POST /api/chat/send` → `create_job` with
  `mode:"opencode"`). The orchestrator dialed the worker WS, handshake completed
  (`ironclaw-agent-v1`), opencode session created, the LLM backend responded, and
  the result returned to the agent. SSE `tool_completed` with `success:true`,
  `status:"completed"`, `output:"opencode round-trip OK"`, 21s round-trip
  including LLM latency.

### Bug found + fixed during validation: model reference format

The first dispatch failed with
`Model not found: tensorzero::function_name::<fn>/.` (note the trailing slash).
Root cause: opencode's `Model.parse` (`packages/core/src/model.ts:30`) splits
the model string on the first `/`, so a reference must be `<provider>/<model-id>`.
The baked `config/opencode.json` had the bare function name
(`tensorzero::function_name::lunarwing`) with no slash, so opencode parsed the
whole string as the provider and the model id as empty → the mangled
`<fn>/` request that TensorZero rejected.

Fixed in commit `4a42af17` (two parts):

1. `opencode4lunarwing/config/opencode.json` — default model now
   `tensorzero/tensorzero::function_name::lunarwing` (correct provider/model
   format, matching opencode's resolution convention).
2. `opencode4lunarwing/entrypoint.sh` — the `OPENCODE_MODEL` override now
   detects a bare function name (no `/`), constructs `<provider>/<fn>` against
   the first provider in the config, AND registers the model in that provider's
   `models` map so opencode can resolve it. Previously the override set
   `cfg["model"]` to the bare name verbatim, reproducing the bug for every
   override. `OPENCODE_MODEL` keeps the bare-function-name convention (matching
   the daemon's `LLM_MODEL`), so `configure-opencode --model` is unaffected.

Confirmed against the working reference config at
`github.com/chrismcfee/oc-paseo-setup-installer/opencode.jsonc`, which uses the
same `provider/model` reference shape.

### Minor follow-up (non-blocking)

- opencode's PostHog telemetry emits `ConnectionRefused` /
  `PostHogFetchNetworkError` lines in the worker log under rootless network
  isolation. Purely cosmetic — the worker continues after them and tasks
  complete normally. Can be silenced with a `DISABLE_TELEMETRY`-style env var
  if the log noise is unwanted; tracked separately, not a functional issue.

## Build-time optimization applied (2026-07-02)

`opencode4lunarwing/Dockerfile` now passes `-- --single` to
`bun run build`, filtering opencode's 12-target cross-compile to the native
platform only (~5-15+ min → ~1-3 min). See
`docs/proposals/OPENCODE-WORKER-SINGLE-TARGET-BUILD.md` for rationale and
caveats (cross-arch tenant hosts are not supported by this change, which
matches the current same-host `podman save|load` distribution model).

## Remaining follow-ups

- Update `docs/ops/NANOCODE-MULTITENANT.md` version drift ("current is v5" → v11) if that doc is refreshed.
- `opencode_task_executor.ts:119-128` — `part.tool`/`part.state.output` access should be smoke-verified post-build against the v2 SDK types.

## OpenRC / Gentoo compatibility (2026-07-02)

The opencode integration in `lunarwing-mt-admin.sh` itself was complete across every OpenRC path (worker loops, start/stop/render/register, doctor, status). Three opencode-specific regressions were found and fixed in the self-heal infrastructure that the admin script provisions units for:

- `ic-infrastructure-health-check/health-openrc.sh` — `unit_tenant()` now strips the `opencode-` prefix (was falling through, misclassifying stopped opencode workers as `skipped` instead of `critical`, so self-heal never restarted them).
- `ic-infrastructure-health-check/lunarwing-self-heal.sh` — `unit_tenant()` now handles `lunarwing-opencode-*` before the generic catch-all (was resolving to a bogus tenant, routing systemd restarts to system-scope where they fail for user-Quadlet units).
- `ic-infrastructure-health-check/health-systemd.sh` — deep container-health probe now includes `lunarwing-opencode-*` (was only triggering for pg/nanocode/pebble, so a Running-but-wedged opencode container reported healthy).
- `docs/ops/MT-GENTOO-SETUP-AND-CHANGES-MADE.md` — worker image line now mentions opencode.

## Rootless Podman compatibility (2026-07-02)

Audited fleet-wide (nanocode/pebble/opencode share identical launch patterns). Findings:

- **SSH agent socket SELinux label (FIXED, fleet-wide):** all worker launch sites (imperative `_ctr run` for nanocode/pebble/opencode + the Quadlet `render_worker_quadlet`) mounted the SSH agent socket without a `:z` SELinux label. On SELinux-Enforcing Fedora hosts, `container_t` is denied access to the tenant-home-labeled socket, breaking SSH/git-push from workers despite the 0666 socket mode. Added `:z` to all four socket mount sites.
- **Workspace file ownership (DEFERRED, by design):** the workers run as non-root `USER` (system accounts via `useradd -r`, unpredictable UIDs). Under rootless userns, files written to `/workspace` appear owned by a host subuid. `--userns=keep-id` does NOT fix this for non-root `USER` directives (it maps the host user to a *different* container UID than the process runs as); only `keep-id:uid=<fixed-container-uid>` would, which requires pinning the container UID in all three Dockerfiles. The current `chmod 777` on the workspace dir is the working workaround (DAC permits access regardless of owner). Deferring the UID-pinning + `keep-id:uid=` change as a larger, separate hardening pass since it touches all three worker images.

References: [Red Hat — rootless userns modes](https://www.redhat.com/en/blog/rootless-podman-user-namespace-modes), [Podman — `--userns` docs](https://docs.podman.io/en/v4.6.1/markdown/options/userns.container.html), [Podman #25919 — rootless bind-mount SELinux](https://github.com/containers/podman/issues/25919).
