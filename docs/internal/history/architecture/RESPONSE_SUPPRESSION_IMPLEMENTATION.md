# R S I

 Here's a summary of the response suppression implementation:

  Flag creation: Arc<AtomicBool> created per-message in the main loop, shared between the spawned task and the timeout handler.

  Flag set: suppressed.store(true, SeqCst) on soft timeout, before sending the "timed out" message.

  Flag checked at these delivery points:
  - agent_loop.rs drain loop — breaks entirely if suppressed (no ghost responses, no new turns started)
  - thread_ops.rs "Thinking" status — skipped
  - thread_ops.rs "Done" status, Suggestions, TurnCost — skipped
  - thread_ops.rs ApprovalNeeded — skipped
  - thread_ops.rs "Interrupted" status — skipped

  Always runs regardless of suppression:
  - complete_turn() / fail_turn() — state machine transitions
  - persist_tool_calls() / persist_assistant_response() — DB persistence
  - The entire agentic loop (LLM calls, tool execution) — work completes naturally
