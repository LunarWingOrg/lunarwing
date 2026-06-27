# Routine Engine Improvements

## Overview

Systematic review of the routine engine (`ic/src/agent/routine_engine.rs`) identified 8 improvement areas. Two have been implemented (#1, #2); the remaining six are open proposals.

## Completed

### #1 — State Contamination Prevention (DONE)

**Problem:** If the LLM ever outputted a malformed response (text-formatted tool calls like `<function=gotify_send_message>`), that output was persisted to `state.md` and the conversation thread. Subsequent runs loaded the contaminated state as "Previous State", causing the LLM to mimic the broken format — a self-reinforcing loop that persisted until manual intervention (deleting/recreating the routine).

**This caused a real production incident** — a crypto price routine stopped sending Gotify notifications because the LLM began emitting text-formatted tool calls instead of using the proper tool-calling API. The hallucinated output was persisted to state and reinforced on every run.

**Changes made:**
- `HALLUCINATED_TOOL_CALL_MARKERS` constant — patterns indicating the LLM is outputting tool calls as text (`<function=`, `<parameter=`, `</function>`, `</parameter>`, `<function_call>`, `</function_call>`)
- `contains_hallucinated_tool_calls()` — detects if LLM output contains hallucinated tool call patterns
- `strip_hallucinated_tool_calls()` — removes lines containing those patterns
- `sanitize_state_content()` — sanitizes state.md content before prompt injection (strips tool call patterns, control chars, truncates to 4096 chars)
- `handle_text_response()` now strips hallucinated tool calls from output. If the output is entirely hallucinated, returns `EmptyResponse` error instead of passing garbage through as a notification summary
- `execute_lightweight()` now wraps state content through `sanitize_state_content()` before passing to `build_lightweight_prompt()`
- 13 unit tests covering detection, stripping, state sanitization, truncation, and `handle_text_response` integration

### #2 — Retry Policy Actually Fires (DONE)

**Problem:** `RetryPolicy` existed in `RoutineGuardrails` with `compute_delay()`, and `execute_routine` called it — but the "retry" just set `next_fire_at = now + delay` in the DB. This only worked for cron-triggered routines (picked up by the next cron tick). Event-triggered and webhook-triggered routines never retried because there was no cron tick to pick them up.

**Changes made:**
- After a retryable failure, `tokio::spawn` + `tokio::time::sleep(delay)` now re-fires the routine after the backoff period, independent of trigger type
- Three guardrails before re-firing: routine still exists, still enabled, `consecutive_failures` hasn't exceeded `max_retries`
- Retry runs recorded with `trigger_type: "retry"` and `trigger_detail: "attempt N"`
- `execute_routine` changed from `async fn` to `fn -> Pin<Box<dyn Future + Send>>` to break recursive Send bounds
- `EngineContext::clone_ctx()` manual helper added instead of `#[derive(Clone)]`
- 4 unit tests for `RetryPolicy::compute_delay()`: exhaustion, exponential backoff math, max delay cap, zero-retries

## Open Proposals

### #3 — Dedup Window Is Defined But Unused

**Problem:** `RoutineGuardrails.dedup_window` (type `Option<Duration>`) and `content_hash()` function exist in `routine.rs`, but `check_event_triggers` never checks them. If the same message triggers an event routine twice (edited message, cross-post), both fire. The hash function is computed nowhere.

**Fix direction:** Store last content hash + timestamp per routine (in-memory or DB), check against it in `check_event_triggers` before firing. Either implement or remove the dead code.

**Priority:** Medium

### #4 — No Per-Routine Timeout For FullJob

**Problem:** Lightweight routines have a configurable timeout (`lightweight_timeout_secs`, default 300s). FullJob routines rely solely on `FullJobWatcher`'s hardcoded 30-minute ceiling:

```rust
const POLL_INTERVAL: Duration = Duration::from_secs(5);
const MAX_POLLS: u32 = (30 * 60) / Self::POLL_INTERVAL.as_secs() as u32;
```

Every FullJob routine gets the same 30 minutes regardless of what it does. A routine that fetches a quick API response and a routine that does a complex multi-step coding task both get 30 minutes. There is no way to say "this routine should time out after 5 minutes" vs "this one can run up to 30 minutes."

The worker job itself (`ic/src/worker/job.rs`) has its own timeout via `WorkerDeps::timeout`, but that's set at the scheduler/worker level — not per-routine.

**Fix direction:** Add an optional `fulljob_timeout_secs: Option<u64>` to `RoutineGuardrails` or `RoutineAction::FullJob`. If set, pass it through to `FullJobWatcher` as a max poll count instead of the hardcoded `MAX_POLLS`. If not set, fall back to the existing 30-minute default. No DB schema change needed — the timeout would live in the routine's `guardrails` JSON config, which is already stored as a JSON column.

**Priority:** Medium

### #5 — Event Cache Refresh Lag (60s)

**Problem:** When a routine is created/updated/deleted via the tool API, `refresh_event_cache()` is called explicitly — but the periodic safety-net refresh only fires every 60s. If the explicit call fails or the tool path doesn't call it, changes take up to 60s to take effect.

**Fix direction:** Lower priority — could add a notification channel or reduce the interval. Not urgent since the explicit call works in practice.

**Priority:** Low

### #6 — Duplicated EngineContext Construction (3x)

**Problem:** `fire_manual`, `fire_webhook`, and `spawn_fire` each manually construct the same `EngineContext` struct (11 fields). Any change to `EngineContext` requires updating all three. A `clone_ctx()` helper was added for #2, but the three original construction sites still duplicate the field list.

**Fix direction:** Extract a `fn engine_context(&self) -> EngineContext` method on `RoutineEngine` and use it from all three call sites.

**Priority:** Low

### #7 — sanitize_summary / strip_html_tags Are Test-Only

**Problem:** `sanitize_summary()` and `strip_html_tags()` are gated behind `#[cfg(test)]` (line ~2036, ~2064 in routine_engine.rs). They strip control chars and HTML from summaries — exactly what you'd want in production since summaries come from untrusted LLM/job output and get sent to notification channels (XMPP, Gotify, etc.). But they're not called in the production notification path.

**Fix direction:** Remove `#[cfg(test)]`, call `sanitize_summary()` in `send_notification()` and `complete_dispatched_run()` before persisting/displaying summaries.

**Priority:** Medium

### #8 — No Structured Routine Status Query

**Problem:** There is no API or tool to query "what routines are currently running" or "what's the status of routine X's last 5 runs" beyond reading the conversation thread. The `routine_history` tool exists but is basic.

**Fix direction:** Add a `routine_status` tool or gateway endpoint that returns current running routines, their elapsed time, and recent run history with status/summary/tokens.

**Priority:** Low

## Priority Summary

| Priority | Item | Status |
|----------|------|--------|
| High | #1 State contamination | Done |
| High | #2 Retry never fires | Done |
| Medium | #3 Dedup unused | Open |
| Medium | #4 FullJob timeout | Open |
| Medium | #7 Sanitize in production | Open |
| Low | #5 Cache refresh lag | Open |
| Low | #6 EngineContext dedup | Open |
| Low | #8 Status query | Open |

## Test Coverage

- 45 unit tests pass in `routine_engine` module (17 new from this work)
- `cargo check` clean, zero clippy regressions
- All changes scoped to `ic/src/agent/routine_engine.rs` — no DB schema or config changes
