# BUG: Agent "lapse" — recurring "I'm not sure how to respond to that."

> **STATUS: FIXED (v1.1.2, 2026-06-07)** — tool calls emitted in the
> `<function=NAME>…</function>` XML dialect are now recovered into structured calls before
> response cleaning, so they no longer clean to empty and trip the empty-response fallback.
> Fix in `ic/src/llm/reasoning.rs` (commit `7a9aca2c`). Report retained for history.

**Severity:** High — user-visible; the agent appears to "lapse" and stop doing work.
**Found:** v1.1.2 cycle, on models that speak the GLM/Qwen tool-call dialect.
**Affects:** any LLM whose tool calls arrive as `<function=NAME>…</function>` XML rather than
the provider's native structured `tool_calls` field (seen via the TensorZero/`openai_compatible`
path with GLM/Qwen-family models).

## Symptoms

- The agent repeatedly replies with the fallback **"I'm not sure how to respond to that."**
  instead of calling the tool it clearly intended to call.
- The behavior **recurs** ("lapses") because the model keeps emitting the same dialect every
  turn, so every turn cleans to empty and falls back again.
- More likely on tool-heavy turns (e.g. `tool_search`, discovery) where the model's entire
  visible response *is* the tool call.

## Root cause

Some models (GLM/Qwen-style) emit tool calls as an XML dialect, optionally wrapped in
`<tool_call>`:

```text
<tool_call>
<function=tool_search>
<parameter=discover>true</parameter>
<parameter=query>nanocode</parameter>
</function>
</tool_call>
```

This is a *well-formed* tool call, but it does not arrive in the provider's native
structured `tool_calls` field. Response post-processing in `reasoning.rs` **stripped** the
`<function=…>` / `<tool_call>` tags as non-standard markup, which left the visible content
**empty**. The empty content then hit the empty-response path:

- `Reasoning::respond_with_tools()` retries empty completions up to
  `MAX_EMPTY_RESPONSE_RETRIES` (default `1`, `reasoning.rs:37`), then returns the
  `"I'm not sure how to respond to that."` fallback (`reasoning.rs:776`, `:823`).

So a valid tool call was discarded, misreported as an empty response, and surfaced to the
user as the fallback — every turn the model used the dialect.

## Fix

`ic/src/llm/reasoning.rs` (commit `7a9aca2c`, +8 regression tests):

1. **`recover_function_xml_calls()`** — before cleaning, scan the raw content for
   `<function=NAME>…</function>` blocks (with or without the `<tool_call>` wrapper) and turn
   them into structured `ToolCall`s. Only known tool names are recovered; each
   `<parameter=KEY>VALUE</parameter>` becomes an argument, with `VALUE` parsed as JSON when
   valid (so `true`/numbers keep their type) and kept as a trimmed string otherwise. IDs
   continue the caller's numbering so recovered calls stay unique across recovery formats.
2. **`strip_function_xml_tags()`** — strip any `<function=…>` blocks that were *not* recovered
   (e.g. an unknown tool name) so leftover XML never leaks to the user. An unclosed
   `<function=` drops the trailing partial XML, mirroring the strict handling of unclosed
   thinking tags.

With recovery in place, the dialect produces real tool calls, the loop executes the tool, and
the empty-response fallback is no longer triggered.

## Affected code

| File | Relevance |
|------|-----------|
| `ic/src/llm/reasoning.rs` | `recover_function_xml_calls()` (recovery), `strip_function_xml_tags()` (cleanup), empty-response retry + fallback (`MAX_EMPTY_RESPONSE_RETRIES`, `:776`/`:823`) |
| `ic/src/llm/CLAUDE.md` | Documents the empty-response retry mechanism |

## Regression tests (`ic/src/llm/reasoning.rs`)

`test_recover_function_xml_with_parameters`, `_no_parameters`, `_unwrapped`,
`_unknown_tool_ignored`, `_string_value_not_coerced`, `_unique_ids`,
`test_clean_response_strips_function_xml_tags`, and
`test_respond_with_tools_recovers_function_xml_dialect`.

## Notes

- Independent of `RetryProvider` (which handles transport-level errors); this was a
  content-level cleaning artifact.
- If the lapse recurs with a *different* dialect, the same pattern applies: recover the call
  before cleaning, then strip any unrecovered remnant.
