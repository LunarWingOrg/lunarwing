# BUG: E2E OAuth URL Parameter Tests Fail During Fixture Setup

**Status:** Open
**Severity:** Low — environment-dependent, no production impact
**Affected tests:**
- `test_oauth_url_parameters.py::test_oauth_url_has_client_id_not_clientid`
- `test_oauth_url_parameters.py::test_oauth_url_has_required_parameters`
- `test_oauth_url_parameters.py::test_oauth_url_has_extra_params`
- `test_oauth_url_parameters.py::test_oauth_url_is_valid_google_oauth`
- `test_oauth_url_parameters.py::test_oauth_url_state_is_unique`
- `test_oauth_url_parameters.py::test_oauth_url_escaping`

## Symptoms

All 6 tests error during the `installed_gmail` fixture setup. The fixture attempts to install the `gmail` WASM extension via the `/api/extensions/install` endpoint, which tries to download the WASM artifact. The download fails because the test environment cannot reach the internet without a proxy.

```
AssertionError: Install failed: Primary install failed: Download failed: error sending request
for url (WASM artifact download URL);
fallback install also failed: Installation failed: 'gmail' requires building from source.
```

The tests themselves validate OAuth URL parameter formatting (client_id format, required parameters, state uniqueness) and are not related to the download failure — they simply cannot run because the prerequisite gmail extension cannot be installed.

## Root Cause

Same as the `test_wasm_lifecycle.py` failures: the lunarwing daemon started by conftest.py does not have proxy access (`ext_proxy`) configured, so all WASM artifact downloads fail. The fallback build-from-source path also fails because `wasm-tools` / `cargo-component` are not installed.

## Possible Fixes

1. **Configure HTTP proxy for the test daemon** — Pass `HTTP_PROXY`/`HTTPS_PROXY` environment variables to the lunarwing process in `conftest.py` so it can reach GitHub through the corporate proxy.
2. **Pre-build WASM artifacts** — Run `scripts/build-wasm-extensions.sh` before the E2E suite and point `WASM_TOOLS_DIR` at the built artifacts directory so the daemon uses local files instead of downloading.
3. **Mock the install endpoint** — For tests that only need gmail installed as a prerequisite (not testing the install flow itself), mock the `/api/extensions/install` response and pre-populate the WASM tools directory with a dummy `.wasm` file.

## Notes

This is the same root cause as the `test_wasm_lifecycle.py` errors (all 20 of them) and the `test_extension_oauth.py::test_oauth_install_gmail` failure. All stem from inability to download WASM artifacts in the test environment.

## Files

- `ic/tests/e2e/scenarios/test_oauth_url_parameters.py` (lines 53-76, `installed_gmail` fixture)
- `ic/tests/e2e/conftest.py` — `lunarwing_server` fixture environment setup
- `ic/src/registry/installer.rs` — WASM artifact download and fallback logic
