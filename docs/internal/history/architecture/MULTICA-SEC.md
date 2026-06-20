  The workspace is database-backed (PostgreSQL or libSQL), not filesystem. The full chain:

  1. workspace_read("config/multica.json") in WASM
  2. → HostState::workspace_read() checks prefix allowlist
  3. → PreloadedWorkspaceReader (HashMap, pre-loaded before WASM execution)
  4. → loaded from Workspace::read() which queries the database
  5. → memory_documents table, scoped by user_id + agent_id

  There are no plaintext files on disk. The "workspace" is the same database-backed memory system that memory_write / memory_read tools use.

  Addressing each concern:

  "Plaintext Config Files" — Incorrect premise. Workspace data lives in PostgreSQL/libSQL rows, not files. Encryption at rest is handled by the database layer. The PreloadedWorkspaceReader holds data in a HashMap
  only for the duration of a single WASM execution, then it's dropped.

  "Fallback Pattern Doubles Attack Surface" — The 6 paths all read from the same database-backed workspace with the same config/ prefix restriction. An attacker who can call workspace_read inside the WASM sandbox
  already has the capability — the number of key names doesn't change the attack surface. More importantly: none of these values are secrets. A server URL and workspace ID are configuration, not credentials.

  "Secret vs Config Inconsistency" — This is intentional and correct:
  ┌───────────────────┬────────┬────────────────────────────────────────────────────────────────────────────────────────────────────────┐
  │       Value       │  Type  │                                                  Why                                                   │
  ├───────────────────┼────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ multica_api_token │ Secret │ Authentication credential — injected into HTTP Authorization header by the host, never exposed to WASM │
  ├───────────────────┼────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ url, workspace_id │ Config │ Server address and project identifier — the tool needs to read these to know where to send requests    │
  └───────────────────┴────────┴────────────────────────────────────────────────────────────────────────────────────────────────────────┘

  The tool can't make an HTTP request without knowing the URL. That's config, not a secret. Routing it through the secret system would mean the tool literally couldn't function (secrets are never readable by WASM,
  only injectable into headers).

  "Add config validation" — Already done. The fallback validates required fields and fails fast:
  .ok_or("config/multica_workspace_id not found in workspace")?;

