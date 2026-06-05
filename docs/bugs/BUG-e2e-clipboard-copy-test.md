# BUG: E2E Clipboard Copy Test Error

**Status:** Open
**Severity:** Low — test infrastructure issue, no production impact
**Affected test:**
- `test_chat.py::test_copy_from_chat_forces_plain_text`

## Symptoms

The test errors during setup with a Playwright browser permissions issue when attempting to use the clipboard API in headless Chromium.

## Root Cause

The test uses `page.evaluate()` to simulate a copy event by dispatching a synthetic `Event('copy')` on a chat message element. In headless Chromium, clipboard permissions may not be granted by default. The test constructs a mock `clipboardData` object on the event, but the browser's copy event handling may differ between headed and headless modes.

## Possible Fixes

1. **Grant clipboard permissions** — Add `permissions: ['clipboard-read', 'clipboard-write']` to the browser context creation in `conftest.py`.
2. **Use Playwright's clipboard API** — Replace the manual `dispatchEvent` approach with `page.evaluate("navigator.clipboard.writeText(...)")` after granting permissions.
3. **Skip in headless mode** — Mark the test with `pytest.mark.skip` when `HEADED` is not set, since clipboard behavior differs between modes.

## Files

- `ic/tests/e2e/scenarios/test_chat.py` (lines 79-117)
- `ic/tests/e2e/conftest.py` — browser and page fixture setup
