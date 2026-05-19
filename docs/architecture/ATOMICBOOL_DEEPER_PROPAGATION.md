# AtomicBool Deeper Propagation - Future Work

**Date:** 2026-05-19  
**Status:** Design Note - Not Implemented  
**Related:** RESPONSE_SUPPRESSION_IMPLEMENTATION.md, HANDLE_MESSAGE_FIX.md

## Current State (as of 2026-05-18)

The `Arc<AtomicBool>` suppression flag is threaded from `agent_loop.rs::run()` down through:

- `handle_message()` — top-level entry
- `process_user_input()` — turn processing
- Status delivery points in `thread_ops.rs`:
  - `Thinking` status
  - `Done` status
  - `Suggestions`
  - `TurnCost`
  - `ApprovalNeeded`
  - `Interrupted` status
- Drain loop in `agent_loop.rs` — breaks early if suppressed

**The flag boundary stops at `process_user_input()`**. It does NOT propagate into:

- `run_agentic_loop()`
- `ChatDelegate`
- Tool execution layer
- SSE event emission from tools

## The Problem

When a soft timeout fires, the user is notified and the suppression flag is set. The background task continues to run, including:

1. The full agentic loop (LLM calls, tool dispatch)
2. Individual tool executions
3. Any SSE events those tools emit (progress, status, intermediate results)
4. Sub-delegate calls and their associated channel emissions

**Concrete scenarios where ghost output can leak:**

- Tool emits `"🔧 Running web_search..."` SSE event mid-execution
- ChatDelegate emits intermediate "thinking" tokens to the streaming endpoint
- A long-running tool (e.g. browser automation) sends progress updates
- Sub-agent dispatch fires `"Spawning sub-agent..."` notifications
- Any custom tool that calls `channels.send_status()` directly

After the user has already received the timeout message, these stray notifications can be confusing.

## Proposed Solution: Deep AtomicBool Propagation

### Option A: Thread the flag all the way through

Pass `&AtomicBool` (or `Arc<AtomicBool>`) through every function in the call chain that touches channels or emits status updates:

```
process_user_input(&AtomicBool)
  └─ run_agentic_loop(&AtomicBool)
       ├─ ChatDelegate::stream(&AtomicBool)
       │    └─ checks before each token/event emission
       └─ Tool::execute(&AtomicBool)
            └─ checks before each progress event
```

**Pros:**
- Direct, explicit, no magic
- Every emission point can be guarded
- Easy to reason about ordering

**Cons:**
- Invasive refactor — touches potentially dozens of files
- Every tool implementation needs to be aware of the flag
- Trait signatures change for `Tool`, `ChatDelegate`, etc.

### Option B: Context-Based Suppression

Store the suppression flag in a turn-scoped context (e.g. `TurnContext` struct that's already passed around), and have channel emission helpers check it automatically:

```rust
impl ChannelManager {
    pub async fn send_status_ctx(&self, ctx: &TurnContext, ...) {
        if ctx.is_suppressed() { return; }
        self.send_status(...).await
    }
}
```

**Pros:**
- Single check point per emission, no need to remember
- Less invasive than threading raw flags
- Easy to add new "suppressible" channels/events

**Cons:**
- Requires existing `TurnContext` or creation of one
- Indirect — harder to grep for "where is suppression checked?"

### Option C: Channel-Layer Token

Issue a unique "turn token" at the start of each message, and channels track which tokens are still valid. When the soft timeout fires, the token is invalidated, and any future channel emissions tagged with that token are dropped at the channel layer.

```rust
// On message arrival
let turn_token = channels.begin_turn();

// On soft timeout
channels.invalidate_turn(turn_token);

// In any tool/delegate/anywhere
channels.send_status_tagged(turn_token, status); // silently drops if invalidated
```

**Pros:**
- Suppression is enforced at the channel boundary, not at every call site
- Tools don't need to know anything about it
- Works for SSE/WebSocket too (just check token on emission)
- Naturally extends to other "turn cancelled" scenarios

**Cons:**
- New abstraction layer (turn tokens)
- Channels need to track valid tokens (memory cost, but bounded)
- Requires plumbing tokens through tool call interfaces anyway

## Recommendation

**Defer until there's empirical evidence of confusion from ghost notifications.**

The current implementation suppresses the user-visible response and status updates from `handle_message`/`process_user_input` paths. The remaining unsuppressed paths emit lower-priority events (tool progress, intermediate thinking) that are diagnostic rather than conversational.

When you start seeing real user feedback like "I got 'timed out' but then 5 minutes later I saw 'Running search tool...'" — that's the signal to revisit.

If/when you do revisit, **Option C (Channel-Layer Token)** is probably the cleanest path forward:

- Centralizes suppression logic in one place
- Doesn't require invasive trait changes
- Scales to future "turn cancelled" scenarios (user hit interrupt, panic recovery, etc.)
- Tool implementations stay clean

## Open Questions

1. **Ghost task side effects beyond channels:** What about DB writes, workspace file changes, sub-agent spawns? Do we want to abort those, or let them complete?

   *Christopher's note (2026-05-19): Not enough info to answer yet.*

2. **Should the flag also propagate to non-channel emissions?** E.g. metrics counters, log spans, etc. Or are those fine to emit regardless?

3. **What about the heartbeat/routine system?** They use their own emission paths via `notify_tx`. Do those need similar suppression?

## Files Likely Affected (if Option C is chosen)

- `ic/src/channels/mod.rs` — turn token management
- `ic/src/channels/web/sse.rs` — SSE event filtering
- `ic/src/agent/dispatcher.rs` — pass turn token through agentic loop
- `ic/src/tools/mod.rs` — tool execution context
- `ic/src/llm/delegate.rs` — ChatDelegate emission

## Decision Log

- **2026-05-18:** Initial AtomicBool implementation, boundary at `process_user_input`
- **2026-05-19:** Decision to defer deeper propagation, document for future revisit
- **TBD:** When user feedback or telemetry indicates ghost notifications are a real problem

---

*Documented during Lunarwing review session between Christopher and Baud.*
