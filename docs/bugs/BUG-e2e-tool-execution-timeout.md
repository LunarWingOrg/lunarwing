# BUG: E2E Tool Execution Tests Timeout

**Status:** Open
**Severity:** Medium — tests only, no production impact
**Affected tests:**
- `test_tool_execution.py::test_builtin_echo_tool`
- `test_tool_execution.py::test_builtin_time_tool`

## Symptoms

Both tests timeout at 30 seconds waiting for the assistant response to appear in the chat UI after sending a message that should trigger a tool call via the mock LLM.

```
playwright._impl._errors.TimeoutError: Page.wait_for_function: Timeout 30000ms exceeded.
```

The `test_non_tool_message_still_works` test in the same file passes, confirming that basic chat messaging works.

## Root Cause (Suspected)

The mock LLM (`mock_llm.py`) has `TOOL_CALL_PATTERNS` that match `"echo (.+)"` and `"what time|current time"` and return OpenAI-compatible `tool_calls` responses. The tool executes successfully on the daemon side, but the agent loop's second LLM call (to summarize the tool result) may not produce a response that contains the `expected_fragment` the test waits for. Alternatively, the streaming SSE response may not reach the browser UI within the timeout window.

The `_send_and_get_response` helper waits for a new `.message.assistant` DOM element whose `innerText` contains the `expected_fragment` (e.g., `"hello world"` for echo, `"time"` for time). If the mock LLM's follow-up response after the tool result doesn't contain those fragments, the test hangs.

## Possible Fixes

1. **Check mock LLM follow-up responses** — After tool execution, the daemon sends a second LLM request with the tool result. Verify that `CANNED_RESPONSES` in `mock_llm.py` has a pattern that matches this follow-up and returns text containing the expected fragments.
2. **Increase timeout** — The 30s timeout may be insufficient if the agent loop takes longer with tool calls (two LLM round-trips instead of one).
3. **Check SSE streaming** — Verify that tool result messages are emitted as SSE events and rendered in the chat UI. A change to the SSE event format or the frontend JS rendering could cause the assistant message to never appear.

## Files

- `ic/tests/e2e/scenarios/test_tool_execution.py` (lines 55-80)
- `ic/tests/e2e/mock_llm.py` — `TOOL_CALL_PATTERNS` (line 26), `CANNED_RESPONSES`
- `ic/src/agent/dispatcher.rs` — agent loop tool call handling
