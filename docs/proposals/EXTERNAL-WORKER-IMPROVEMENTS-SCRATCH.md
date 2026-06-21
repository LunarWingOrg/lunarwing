Agent had a stroke apparently

[SYSTEM DIRECTIVE: OH-MY-OPENCODE - TODO CONTINUATION]

Incomplete tasks remain in your todo list. Continue working on the next pending task.

- Proceed without asking for permission
- Mark each task complete when finished
- Do not stop until all tasks are done
- If you believe all work is already complete, the system is questioning your completion claim. Critically re-examine each todo item from a skeptical perspective, verify the work was actually done correctly, and update the todo list accordingly.

[Status: 0/21 completed, 21 remaining]

Remaining tasks:
- [in_progress] Task 1.1: Add TaskContext struct to external_worker.rs with project_dir, conversation_history, environment, user_id, metadata fields
- [pending] Task 1.2: Add ConversationMessage struct with role and content fields
- [pending] Task 1.3: Add #[serde(default)] to all TaskContext fields for backward compatibility
- [pending] Task 1.4: Update task_request serialization in run_external_task() to use TaskContext
- [pending] Task 1.5: Add unit test: task_context_full_roundtrip
- [pending] Task 1.6: Add unit test: task_context_backward_compat
- [pending] Task 2.1: Add ExternalTaskStatus enum with Success, Failed, Cancelled, TimedOut, Partial(String) variants
- [pending] Task 2.2: Implement Serialize/Deserialize for ExternalTaskStatus with lowercase variant names
- [pending] Task 2.3: Change ExternalTaskResult.status from String to ExternalTaskStatus
- [pending] Task 2.4: Update all match arms in run_external_task() to use enum matching
- [pending] Task 2.5: Update execute_external() in job.rs to use enum matching
- [pending] Task 2.6: Add impl Display for ExternalTaskStatus
- [pending] Task 2.7: Add unit test: task_status_enum_serde
- [pending] Task 2.8: Add unit test: task_status_enum_matching
- [pending] Task 3.1: Add WorkerEndpoint struct with url, auth_token, weight fields
- [pending] Task 3.2: Add endpoints field to ExternalWorkerConfig with #[serde(default)]
- [pending] Task 3.3: Add LoadBalanceStrategy enum with RoundRobin, LeastConnections variants
- [pending] Task 3.4: Update resolve_from_settings() to parse endpoints from TOML
- [pending] Task 3.5: Add endpoints() helper method returning canonical endpoint list
- [pending] Task 3.6: Add unit test: external_worker_config_multi_endpoint
- [pending] Task 3.7: Add unit test: external_worker_config_legacy_fallback
<!-- OMO_INTERNAL_INITIATOR -->
