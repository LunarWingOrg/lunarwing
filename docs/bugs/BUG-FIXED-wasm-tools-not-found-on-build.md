# Fixed: wasm-tools not found on build (Known Issue → Bug Fix)

* Root cause (more than cosmetic, it turned out): build-tenant --with-wasm calls install_wasm_tenant, which runs as the admin/root user and probed wasm-tools
via root's PATH. But add-tenant installs wasm-tools into the tenant's ~/.cargo/bin — not on root's PATH — so the warning fired even when wasm-tools was correctly installed, and the strip/componentize step was needlessly skipped on every MT build.

* Changes:

1. ic/scripts/lunarwing-mt-admin.sh — install_wasm_tenant now resolves wasm-tools from the tenant's ~/.cargo/bin first, falling back to the admin PATH. Both componentize/strip blocks use the resolved binary. So in the normal MT flow the warning disappears and stripping actually runs (smaller artifacts). Output is still chowned to the tenant at the end, so running root→tenant-binary is safe.
2. Residual genuinely-missing case — softened from the alarming wasm-tools not found; copying raw WASM files without componentize/strip to a benign note: 

* wasm-tools not installed — installing raw WASM components (works fine; skipping optional debug-info strip). Same wording aligned in ic/scripts/lunarwing-xmpp-test-env.sh.

3. ic/build.rs — fixed a mislabeled warning: the old code printed wasm-tools not found but only on a fallback-copy I/O failure (never on a missing tool). It now stays quiet when the tool is simply absent (the raw wasip2 artifact is already a valid component) and reports the real error if the copy fails.
4. RELEASE-v1.1.3.md — moved the item from Known Issues to Bug Fixes with the root-cause explanation.

### Verified:
- bash -n clean on both scripts; shellcheck adds no new warnings (the 2 it reports are pre-existing, outside my edits)
- cargo check --bin lunarwing passes (build.rs compiles; freshness guard short-circuits)
- rustfmt --edition 2024 --check build.rs clean
