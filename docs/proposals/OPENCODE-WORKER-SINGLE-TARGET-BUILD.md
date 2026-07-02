# Proposal: Build Only the Native Target in the OpenCode Worker Image

**Status:** Proposed
**Date:** 2026-07-02
**Owner:** Christopher (GGMethos)
**Scope:** `opencode4lunarwing/Dockerfile`

## Problem

The opencode worker image build (`build-opencode-worker`) compiles the
opencode binary for **twelve platform targets**, even though the worker only
ever runs as a container on the host that built it.

Observed during a `--no-cache` rebuild on the Fedora dev box:

```
building opencode-linux-arm64-musl
building opencode-linux-x64-musl
building opencode-linux-x64-baseline-musl
building opencode-darwin-arm64
building opencode-darwin-x64
building opencode-darwin-x64-baseline
building opencode-windows-arm64
building opencode-windows-x64
building opencode-windows-x64-baseline
```

Each target is a separate Rust cross-compile. Several also pull a fresh
platform-specific Rust toolchain via rustup (the `linux-arm64-musl`,
`darwin-*`, and `win32-*` targets need `aarch64-unknown-linux-musl`,
`x86_64-apple-darwin`, `aarch64-apple-darwin`, and the
`*-pc-windows-gnu` / `*-pc-windows-msvc` toolchains respectively). This is
where the build spends the overwhelming majority of its wall-clock time.

On a single-tenant rebuild this turned a multi-minute step into a
**5-15+ minute** step, dominated by targets that are never executed and are
discarded the moment the image is done.

## Root Cause

`opencode4lunarwing/Dockerfile` invokes opencode's own build script with no
target filtering:

```dockerfile
WORKDIR /build/opencode/packages/opencode
RUN bun run build 2>/dev/null || true
```

That `bun run build` resolves to
`/app/opencode/packages/opencode/script/build.ts`, which defines a hardcoded
`allTargets` array of twelve entries (linux/darwin/win32 × arm64/x64 ×
musl/baseline variants) and iterates every one when no filter flag is passed.

The build script **already supports** a `--single` flag that restricts the
list to the current host's `os`/`arch` (and skips the baseline + musl
variants for the native platform):

```ts
const targets = singleFlag
  ? allTargets.filter((item) => {
      if (item.os !== process.platform || item.arch !== process.arch) {
        return false
      }
      if (item.avx2 === false) { return baselineFlag }
      if (item.abi !== undefined) { return false }
      return true
    })
  : allTargets
```

There is also a `--skip-install` flag (skips the cross-platform
`bun install --os="*" --cpu="*"` of `@opentui/core`, `@parcel/watcher`, and
`@ff-labs/fff-bun` that otherwise pulls native deps for every target).

We currently pass neither flag, so all twelve targets build.

## Why Only the Native Target Is Needed

The opencode worker is:

- A **runtime container** (`FROM docker.io/oven/bun:debian`), started via
  Quadlet/systemd on the same host that built the image.
- Distributed to tenants via `podman save | podman load` **between stores on
  the same host** (`_ensure_tenant_image` in `lunarwing-mt-admin.sh`). There
  is no cross-host image export.
- Never published to a registry for consumption on a different OS/arch.

So the only binary that is ever loaded is the one matching the build host's
`os`/`arch`. The other eleven are dead weight: compiled, copied into
`/app/opencode/packages/opencode/dist/`, and never executed.

## Proposed Change

Pass `--single` (and optionally `--skip-install`) to the relevant
`bun run build` invocations in `opencode4lunarwing/Dockerfile`:

```dockerfile
WORKDIR /build/opencode/packages/app
RUN bun run build 2>/dev/null || true

WORKDIR /build/opencode/packages/opencode
RUN bun run build -- --single 2>/dev/null || true
```

Notes:

- The `--` separator is required so the flag is forwarded to the underlying
  `script/build.ts` rather than consumed by `bun run` itself.
- `--single` is the load-bearing flag. `--skip-install` is a secondary
  optimization (avoids the multi-arch native-dependency install) and is safe
  to add because the native install already happened in the top-level
  `bun install --frozen-lockfile` at line 20.
- Leave the `packages/app` and `packages/sdk/js` builds unchanged; they
  produce the embedded web UI and the JS SDK respectively (no Rust, no
  cross-compile), so they are not the source of the slowdown.

### Expected impact

| Metric | Before | After |
|--------|--------|-------|
| Rust cross-compiles | 12 | 1 (native) |
| rustup toolchain installs | up to 4 (musl/darwin/win32) | 0 (uses host toolchain) |
| `--no-cache` rebuild wall-clock | 5-15+ min | ~1-3 min (estimated) |
| Image size | larger (12 binaries in `dist/`) | smaller (1 binary) |

### Caveats / risks

1. **`--single` filters on `process.platform`/`process.arch`** inside the
   builder container. The builder is `oven/bun:debian` on the host arch, so
   this resolves correctly for both x86-64 and arm64 hosts — it produces
   `opencode-linux-x64` or `opencode-linux-arm64` respectively. No
   host-arch detection logic is needed in the Dockerfile.
2. **Cross-arch tenant hosts are not supported by this change.** If a tenant
   is ever built on one arch and run on another (e.g. image built on x86,
   loaded on arm64), the native binary would not match. This is not a
   current deployment model (per `_ensure_tenant_image`, images are
   same-host only), but the constraint should be noted in
   `opencode4lunarwing/README.md` when this lands.
3. **The `2>/dev/null || true` soft-fail is preserved.** The build-time SDK
   assertion at Dockerfile line 132 (`import("@opencode-ai/sdk/v2")` →
   `createOpencodeClient`) is the real gate; it already fails the image if
   the build is broken. Soft-failing the `--single` build does not weaken
   that guarantee.
4. **Upstream flag stability.** `--single` is parsed by the pinned opencode
   release (`OPENCODE_REF=v1.17.13`). If a future opencode bump renames or
   removes the flag, the build step will continue to soft-fail (because of
   `|| true`) and the SDK assertion will catch the resulting broken build.
   Worth verifying on each opencode version bump.

## Verification Plan

After the change:

1. `build-opencode-worker --no-cache` and confirm the build log shows
   **only** the native target (e.g. `building opencode-linux-x64`) and no
   `darwin-*` / `win32-*` / `*-musl` lines.
2. Confirm the SDK assertion (Dockerfile:132) still passes.
3. Spin up a tenant worker, run the smoke profile, and confirm the worker
   boots and accepts a task (the live round-trip exercised on `octest`).
4. Confirm image size dropped (`podman images` before/after).

## Open Questions

- Do we want a **build-arg escape hatch** (e.g.
  `ARG OPENCODE_BUILD_TARGETS=single`) so a future cross-arch or
  release-publish workflow can opt back into the full target list without
  editing the Dockerfile? Low cost, useful if we ever publish the image.
- Should we also strip the unused cross-arch toolchain prerequisites from
  the runtime stage (e.g. `musl-tools` at line 76) when `--single` is in
  effect? Out of scope for this proposal but worth tracking.

## Related

- `opencode4lunarwing/Dockerfile` — the file under change.
- `opencode4lunarwing/CLAUDE.md` — build caveats for the worker.
- `docs/proposals/DEFERRED-2026-07-02-OPENCODE-EXTERNAL-WORKER.md` — the
  live round-trip validation that surfaced this build-time cost.
