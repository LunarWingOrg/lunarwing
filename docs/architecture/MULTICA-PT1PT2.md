Part 1 — WASM tool workspace reader (the wiring gap fix):
  - wrapper.rs: Added PreloadedWorkspaceReader struct and preload_workspace_reader() async function. Before entering spawn_blocking, workspace data matching the tool's allowed prefixes is loaded into a HashMap and
  injected as the reader. Added workspace field and with_workspace() builder.
  - registry.rs: Added workspace field to WasmToolRegistration, wired through in register_wasm().
  - loader.rs: Added workspace field and with_workspace() builder to WasmToolLoader.
  - app.rs: Thread workspace from init_tools() into init_extensions() and down to the loader.

  Part 2 — Multica-bridge config fallback:
  - lib.rs: load_config() now tries config/multica.json first, then falls back to individual workspace keys (config/multica_url, config/multica_workspace_id, etc.). The error message tells the agent exactly what
  to write. 
  
  Tests: Two regression tests confirming the PreloadedWorkspaceReader works standalone and through HostState with prefix restrictions. All 6 workspace_read tests pass.

  Now sunburst can configure multica with either:
  memory_write(target: "config/multica.json", content: '{"url":"...","workspace_id":"..."}')
  Or individual keys:
  memory_write(target: "config/multica_url", content: "https://multica.ai")
  memory_write(target: "config/multica_workspace_id", content: "ws-123")
