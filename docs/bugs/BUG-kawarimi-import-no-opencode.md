# BUG: Kawarimi import script does not support --with-opencode

**Severity:** Low
**Found:** 2026-07-03 during v1.1.8 migration testing (tenant `starforce`)
**Status:** FIXED (2026-07-09) — `--with-opencode` is now accepted by `import-tenant.sh` (line 60, wired into `build_args` at line 251). Original report retained below.
**Affects:** `ic/scripts/import-tenant.sh` — cross-machine migration import path

## Symptoms

1. Operator runs `import-tenant.sh <bundle> --with-opencode`
2. Script rejects the flag: `unknown arg: --with-opencode`
3. Opencode worker image must be built separately after import completes

## Reproduction

```bash
sudo ic/scripts/import-tenant.sh /path/to/bundle.tar --with-opencode
# error: unknown arg: --with-opencode
```

## Root Cause

The import script (lines 36-48) only defines `--with-nanocode` and `--with-pebble` in its arg parser. The `build_args` array (line 140-143) hardcodes `--with-wasm` (always on) and conditionally appends `--with-nanocode` / `--with-pebble`. The `--with-opencode` flag was not added when the opencode worker was introduced in v1.1.8.

Additionally, `--with-wasm` is not accepted as a user-facing flag because the script hardcodes it internally. An operator who passes `--with-wasm` explicitly gets `unknown arg: --with-wasm`, which is confusing since `build-tenant` accepts it.

## Impact

- Opencode worker cannot be built as part of the migration flow — requires a separate `build-opencode-worker` + `start-tenant` after import
- Flag surface mismatch with `build-tenant` may confuse operators

## Fix

Add `--with-opencode` to the arg parser and `build_args`:

```bash
# Line ~38
WITH_OPENCODE=false

# Line ~48 (add after --with-pebble)
--with-opencode) WITH_OPENCODE=true; shift ;;

# Line ~142 (add after WITH_PEBBLE)
$WITH_OPENCODE && build_args+=(--with-opencode)
```

## Workaround

Build the opencode worker separately after import:

```bash
sudo ic/scripts/lunarwing-mt-admin.sh build-opencode-worker
sudo ic/scripts/lunarwing-mt-admin.sh start-tenant <name>
```
