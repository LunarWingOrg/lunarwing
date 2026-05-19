# debug and info

  debug! (only visible with RUST_LOG=lunarwing=debug)                                                                                                                                               
                                                                                                                                                                                                    
  ┌─────────────────────────┬───────────────────────────────────────────────────────────────────────┐                                                                                               
  │          File           │                                 What                                  │                                                                                               
  ├─────────────────────────┼───────────────────────────────────────────────────────────────────────┤                                                                                               
  │ session.rs:341          │ start_turn: state transition (prev_state, turn_number, pending count) │                                                                                               
  ├─────────────────────────┼───────────────────────────────────────────────────────────────────────┤                                                                                               
  │ thread_ops.rs:167       │ Hydrated thread from DB                                               │                                                                                               
  ├─────────────────────────┼───────────────────────────────────────────────────────────────────────┤                                                                                               
  │ thread_ops.rs:184       │ Processing user input (message_id, thread_id, content_len)            │                                                                                               
  ├─────────────────────────┼───────────────────────────────────────────────────────────────────────┤                                                                                               
  │ thread_ops.rs:203       │ process_user_input: initial thread state                              │                                                                                               
  ├─────────────────────────┼───────────────────────────────────────────────────────────────────────┤                                                                                               
  │ thread_ops.rs:212       │ Checked thread state                                                  │                                                                                               
  ├─────────────────────────┼───────────────────────────────────────────────────────────────────────┤                                                                                               
  │ thread_ops.rs:449,462   │ Drain loop / agentic loop dispatch details                            │                                                                                               
  ├─────────────────────────┼───────────────────────────────────────────────────────────────────────┤                                                                                               
  │ thread_ops.rs:997       │ Ignoring stale approval (wrong state)                                 │                                                                                               
  ├─────────────────────────┼───────────────────────────────────────────────────────────────────────┤                                                                                               
  │ thread_ops.rs:1005      │ process_approval: entering with AwaitingApproval                      │                                                                                               
  ├─────────────────────────┼───────────────────────────────────────────────────────────────────────┤                                                                                               
  │ thread_ops.rs:1019      │ Ignoring stale approval (no pending found)                            │                                                                                               
  ├─────────────────────────┼───────────────────────────────────────────────────────────────────────┤                                                                                               
  │ thread_ops.rs:1580      │ process_approval: rejection branch entered                            │                                                                                               
  ├─────────────────────────┼───────────────────────────────────────────────────────────────────────┤                                                                                               
  │ thread_ops.rs:1598      │ process_approval: rejection state transitions                         │                                                                                               
  ├─────────────────────────┼───────────────────────────────────────────────────────────────────────┤                                                                                               
  │ thread_ops.rs:1626      │ process_approval: rejection final state before respond                │                                                                                               
  ├─────────────────────────┼───────────────────────────────────────────────────────────────────────┤                                                                                               
  │ agent_loop.rs:951       │ HARD TIMEOUT: thread not in Processing, no action taken               │                                                                                               
  ├─────────────────────────┼───────────────────────────────────────────────────────────────────────┤                                                                                               
  │ agent_loop.rs:364,389   │ Self-repair cycle timing                                              │                                                                                               
  ├─────────────────────────┼───────────────────────────────────────────────────────────────────────┤                                                                                               
  │ agent_loop.rs:771       │ Routine cron tick                                                     │                                                                                               
  ├─────────────────────────┼───────────────────────────────────────────────────────────────────────┤                                                                                               
  │ agent_loop.rs:1048      │ Empty response suppressed                                             │                                                                                               
  ├─────────────────────────┼───────────────────────────────────────────────────────────────────────┤                                                                                               
  │ agent_loop.rs:1165,1179 │ handle_message entry / drain loop                                     │                                                                                               
  ├─────────────────────────┼───────────────────────────────────────────────────────────────────────┤                                                                                               
  │ agent_loop.rs:1296+     │ Agentic loop internals                                                │                                                                                               
  ├─────────────────────────┼───────────────────────────────────────────────────────────────────────┤                                                                                               
  │ agent_loop.rs:1539      │ Suppressing silent reply token                                        │                                                                                               
  └─────────────────────────┴───────────────────────────────────────────────────────────────────────┘

   info! (visible with RUST_LOG=lunarwing=info)                                                                                                                                                      

  ┌───────────────────────┬────────────────────────────────────────────────┐
  │         File          │                      What                      │
  ├───────────────────────┼────────────────────────────────────────────────┤
  │ agent_loop.rs:814     │ Agent ready and listening                      │
  ├───────────────────────┼────────────────────────────────────────────────┤
  │ agent_loop.rs:832     │ Ctrl+C received                                │
  ├───────────────────────┼────────────────────────────────────────────────┤
  │ agent_loop.rs:1056    │ Shutdown command received                      │
  ├───────────────────────┼────────────────────────────────────────────────┤
  │ agent_loop.rs:1077    │ Agent shutting down                            │
  ├───────────────────────┼────────────────────────────────────────────────┤
  │ agent_loop.rs:444     │ Attempting to repair stuck job                 │
  ├───────────────────────┼────────────────────────────────────────────────┤
  │ agent_loop.rs:459     │ Repair succeeded                               │
  ├───────────────────────┼────────────────────────────────────────────────┤
  │ agent_loop.rs:513,535 │ Tool repair attempts/results                   │
  ├───────────────────────┼────────────────────────────────────────────────┤
  │ agent_loop.rs:1142    │ Routine notification                           │
  ├───────────────────────┼────────────────────────────────────────────────┤
  │ thread_ops.rs:386     │ Auto-compaction triggered (context % capacity) │
  ├───────────────────────┼────────────────────────────────────────────────┤
  │ thread_ops.rs:1046    │ Approval matched / resumed                     │
  ├───────────────────────┼────────────────────────────────────────────────┤
  │ thread_ops.rs:1726    │ (other info-level event)                       │
  └───────────────────────┴────────────────────────────────────────────────┘


 warn! (always visible — the sentinel logs)

  Key ones from the baud-fix instrumentation:
  - thread_ops.rs:275 — MESSAGE QUEUED: thread still in Processing state
  - agent_loop.rs:903 — SOFT TIMEOUT: thread state snapshot
  - agent_loop.rs:944 — HARD TIMEOUT: reset stuck thread from Processing to Idle

  Plus all the pre-existing warns (persistence failures, hook blocks, routine errors, etc.).

  error! (always visible)

  - thread_ops.rs:1614 — process_approval: rejection branch — thread missing when applying state!
  - agent_loop.rs:890 — handle_message error
  - agent_loop.rs:965 — JoinHandle panic recovery
  - Plus pre-existing errors (repair failures, deferred task panics, etc.)

