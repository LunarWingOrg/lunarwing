1. tests/support/gateway_workflow_harness.rs:295
2. tests/support/test_rig.rs:818

* Both call agent.run() on a plain Agent, but Agent::run() now takes self: Arc<Self>. The fix is wrapping with Arc::new(agent).run() as the compiler suggests. This is the same class of issue as the engine tests — the test support code wasn't updated after a production refactor. Not related to the version bump.
