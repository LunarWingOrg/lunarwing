# GitHub Issue Status Report
**Generated**: 2026-07-09 (item #5 from AGENT_GOALS_1.1.9.md)
**Source**: https://github.com/LunarWingOrg/lunarwing/issues

---

## Summary

| State | Count |
|-------|-------|
| Open  | 7     |
| Closed| 13    |
| Total | 20    |

---

## Open Issues

### #241 — verify telegram removal
**Status**: 🟡 Partially Done — Telegram references remain

The main Telegram source files have been removed (issue #210 closed "rm tg"). However, `grep -r telegram` in the codebase still finds:
- `ic/src/import/openclaw/history.rs` — 2 occurrences (import history test data referencing `"telegram"` as a channel name). These are in the OpenClaw import compatibility layer and are *expected* since OpenClaw imports may have Telegram-sourced conversations.
- `docs/` — multiple release notes and historical docs reference Telegram. These are historical records and do not represent live code.

**Verdict**: Code-level removal is done. The remaining references in `openclaw/history.rs` are intentional (import compatibility). Historical doc references are expected. **This issue can be closed** unless the intent was also to purge doc references.

---

### #240 — crate updates k 2
**Status**: 🟡 Open — Deferred crates noted

This issue documents a crate audit. Current state:
- `tower-http` 0.6.10 → 0.7.0: Still on 0.6 in `ic/Cargo.toml`. Deferred per issue notes.
- `rand` 0.8.6 → 0.10.2: Still on 0.8 in `ic/Cargo.toml`. Breaking change, deferred.
- `base64` 0.21.7 → 0.22: Still on 0.21 in `ic/Cargo.toml`. Minor breaking, deferred.
- The `cargo update` (patch/minor bumps) recommendation may or may not have been run.

**Verdict**: The deferred crates (`rand`, `base64`, `tower-http`) are intentionally held back for 2.0.0+. The patch-level `cargo update` should be verified. **Genuinely open** — deferred to 2.0.0+.

---

### #232 — Integration Test Improvements needed
**Status**: 🟡 Open

The issue mentions improving integration tests on the Gentoo VM and writing a health check update script + checklist. The test suite has grown (50+ test files in `ic/tests/`), but no specific checklist or Gentoo-targeted improvement has been documented.

**Verdict**: **Genuinely open.** No evidence of a dedicated health-check integration test improvement or Gentoo-specific checklist.

---

### #223 — Create DarkIRC key exchange
**Status**: 🟡 Open

Request for an automated DarkIRC key exchange script. DarkIRC is still opt-in (`--enable-darkirc`), and no key exchange automation script was found in `ic/scripts/` or `docs/`.

**Verdict**: **Genuinely open.** No key exchange automation exists.

---

### #201 — implement third party memory cleaning, de-duping, correction routines
**Status**: 🟡 Open (Stub)

The issue is a stub for integrating external memory de-duplication routines. No implementation or proposal doc exists.

**Verdict**: **Genuinely open.** Stub issue, no work started.

---

### #196 — Versioning Schema Change
**Status**: 🟢 Done (in practice)

The issue tracks the version schema change to `1.1.9.0`, `1.1.9.1`, etc. `ic/Cargo.toml` currently shows `version = "1.1.9"`. The 4-part schema (`1.1.9.0`) may not be reflected in `Cargo.toml` yet, but the release notes and goals document use the `1.1.9.0` format.

**Verdict**: **Effectively done** — the Cargo.toml version is `1.1.9` (Rust semver doesn't support 4-part natively). The 4-part notation is used in docs/release naming. **Can be closed.**

---

### #5 — Staging Test: Reflex Compiler Integration
**Status**: 🟡 Open — Extensive test checklist

A comprehensive 8-phase validation checklist for the reflex compiler. The reflex compiler is implemented (`ic/src/agent/reflex.rs`, `ic/src/cli/reflex.rs`, and DB support). An E2E test exists (`ic/tests/e2e_reflex_compiler.rs`). However, the checklist shows most phases unchecked.

**Verdict**: **Genuinely open.** The reflex compiler is implemented and has basic tests, but the full 8-phase validation checklist is largely uncompleted. This is a testing/verification tracking issue.

---

## Closed Issues

### #236 — Crate Upgrade Deep Dive and Code Rewrite Needed
**Closed**: 2026-07-08
**Status**: ✅ Resolved

Superseded by #240 which contains the detailed audit. The "deep dive" was completed and the findings moved to #240.

---

### #220 — rm windows tests
**Closed**: 2026-07-08
**Status**: ✅ Resolved

Windows-specific test code and clippy items were removed. `grep cfg(windows)` in the source still shows some `cfg(windows)` blocks in `src/testing/mod.rs`, `src/sandbox/`, and `src/channels/wasm/` — these are **platform-detection logic** (not Windows tests), which is expected cross-platform code.

---

### #219 — cargo-deny always fails
**Closed**: 2026-07-08
**Status**: ✅ Resolved

The CI workflow `.github/workflows/code_style.yml` now has a proper `deny-check` job using `EmbarkStudios/cargo-deny-action@v2` with `manifest-path: ic/Cargo.toml` and `--config ic/deny.toml`. The original issue was that the action ran from the wrong directory. Fixed.

---

### #212 — NR and LLM plans
**Closed**: 2026-07-08
**Status**: ✅ Resolved (meta/tracking)

Internal planning issue. Closed as completed.

---

### #211 — refactor nanocode container to be like opencode's
**Closed**: 2026-07-08
**Status**: ✅ Resolved

`lunarcode4lunarwing/` exists with a Dockerfile (187 lines). The source was refactored. `docs/internal/vendored/nanocode-config/` no longer exists (removed per #180).

---

### #210 — rm tg
**Closed**: 2026-07-08
**Status**: ✅ Resolved

Telegram source code removed. Only references remain in OpenClaw import history (intentional) and historical docs.

---

### #209 — tests needs updating
**Closed**: 2026-07-08
**Status**: ✅ Resolved

Tests were updated across the files listed in the issue body (safety, validator, sanitizer, policy, web app.js, migrations, tool schema validation, builtin memory, support assertions, clippy.toml).

---

### #208 — fix submodule path error
**Closed**: 2026-07-08
**Status**: ✅ Resolved

`.gitmodules` now has a valid `[submodule "pebble"]` entry pointing to `https://github.com/nanogpt-community/pebble.git`. The path error was fixed.

---

### #195 — WITRENAME
**Closed**: 2026-07-07
**Status**: ✅ Resolved

Crate rename completed (`crates-ex` reference in body).

---

### #180 — Cleanup 1.1.9 essential items
**Closed**: 2026-07-07
**Status**: ✅ Resolved

Three sub-items:
1. **Dead test removal**: Tests for removed features were cleaned up.
2. **Stale remote branch pruning**: This is a GitHub-side operation, not code-verified here.
3. **Vendored content review**: `docs/internal/vendored/nanocode-config/` no longer exists in the tree — removed.

---

### #161 — Multiple Kawarimi Gaps
**Closed**: 2026-07-08
**Status**: 🟡 Partially Resolved

The issue was extensively edited (2026-07-07) with updated findings. Key gaps and current state:
- **Owner-scope detection/rekey**: `import-tenant.sh` now has `--owner-scope` flag, `owner-scopes` command, and `migrate-owner-scope` logic. ✅
- **Health pipeline re-enable**: Still manual after import — `enable-health-fleet.sh` exists but is not auto-called. 🟡
- **WeeChat/Vision sidecar**: No explicit import-time WeeChat validation or `--with-vision` flag. 🟡
- **`--with-opencode`**: Not verified in current import-tenant.sh build args. 🟡

**Verdict**: The most critical gap (owner-scope) was addressed. Some secondary gaps (auto health re-enable, WeeChat validation, vision sidecar) remain. The issue was closed, likely because the owner-scope fix landed.

---

### #140 — 1.1.9 Codename
**Closed**: 2026-07-07
**Status**: ✅ Resolved

Codename "Kiyome (清め/きよめ)" established and used throughout docs/ops/AGENT_GOALS_1.1.9.md and release planning.

---

### #50 — OMEMO Degradation with Self-Repair fires gotify notification when service is degraded
**Closed**: 2026-07-07
**Status**: ✅ Resolved

OMEMO health check behavior was fixed or made toggleable.

---

## Issues That Could Be Closed

Based on codebase verification:

| # | Title | Recommendation |
|---|-------|---------------|
| #241 | verify telegram removal | **Close** — code-level removal done; remaining refs are intentional import compat |
| #196 | Versioning Schema Change | **Close** — Cargo.toml uses `1.1.9`; 4-part is doc-level only (Rust semver limitation) |

## Issues Needing Attention

| # | Title | Priority | Notes |
|---|-------|----------|-------|
| #240 | crate updates k 2 | Low (deferred to 2.0.0) | `rand`, `base64`, `tower-http` intentionally deferred |
| #232 | Integration Test Improvements | Medium | Gentoo VM test improvements + health check checklist |
| #223 | DarkIRC key exchange | Low | DarkIRC is opt-in; key exchange automation missing |
| #201 | memory de-duping routines | Low | Stub issue, no work started |
| #5 | Reflex Compiler Integration | Medium | Full 8-phase validation largely uncompleted |
