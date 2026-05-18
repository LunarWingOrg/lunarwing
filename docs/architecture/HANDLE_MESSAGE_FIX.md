# handle_message fix proposal and attempt

 Summary

  Root cause: agent_loop.rs:871 wraps handle_message() in tokio::time::timeout(). When the timeout fires, the future is dropped mid-execution. If thread.start_turn() was already called (setting
  ThreadState::Processing), neither complete_turn() nor fail_turn() ever runs. The thread stays Processing forever — all subsequent messages get "Message queued — will be processed after the
  current turn."

  Fix (Option A): Instead of cancelling handle_message on timeout, spawn it as a tokio::spawn task that runs to completion. The main loop waits on the JoinHandle with a soft timeout:

  - Normal completion: Result is delivered to user as before
  - Soft timeout: User gets "timed out" immediately. The task continues running in background — it calls complete_turn()/fail_turn() naturally, keeping the state machine clean
  - Hard-kill timer: A second background task waits one more timeout period. If the thread is still Processing, it force-resets via fail_turn() (safety net for truly hung tasks)
  - Panic handling: If the spawned task panics, the JoinHandle returns Err(JoinError), and thread state is reset

  Changes:
  - ic/src/agent/agent_loop.rs: run(self) → run(self: Arc<Self>) to enable cloning for spawned tasks. Replaced tokio::time::timeout(handle_message) with tokio::spawn + soft/hard timeout pattern.
  Added panic recovery.
  - ic/src/main.rs: agent.run() → Arc::new(agent).run()
  - ic/src/agent/session.rs: Added regression test test_timeout_resets_stuck_processing_thread

