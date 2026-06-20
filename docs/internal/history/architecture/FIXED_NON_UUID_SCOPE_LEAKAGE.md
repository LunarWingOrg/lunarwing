# Done

* P0-A in 0.29.1 md
  
  - Pattern sweep (per review-discipline.md): All Uuid::parse_str + conversation-scope sites in the router are fixed (Sites A and B). The remaining
  parse_scope_uuid/parse_engine_thread_id helpers serve engine thread resolution, not v1 conversation persistence. The other
  get_or_create_assistant_conversation callers (gateway, tenant, agent_loop) use hardcoded "gateway" channels with no non-UUID scopes — correct as-is.
  - Dual-backend: No migration needed; scoped_conversation_id() is pure, and the trait default method delegates to existing ensure_conversation(). Both
  --features postgres and --features libsql compile clean.
  - Tests: 5 regression tests pass (including DB-backed isolation proof).
  - Docs: Port analysis and release notes updated.
