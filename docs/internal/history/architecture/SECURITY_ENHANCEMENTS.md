● Changes made this session

  Problem: The branch's commit 1a3ba0c4 added a hidden: Option<bool> field to both RegistryEntry and ExtensionManifest structs (part of P1-H from the 0.28.2
  port analysis), but didn't update all the construction sites — causing 23+ compilation errors.

  Fix: Added hidden: None (or hidden: self.hidden where the source manifest has the field) to every struct literal across 6 files:

  ┌──────────────────────────────┬───────┬────────────────────────────────────────────────────────────────────────┐
  │             File             │ Sites │                                 Notes                                  │
  ├──────────────────────────────┼───────┼────────────────────────────────────────────────────────────────────────┤
  │ src/extensions/discovery.rs  │ 2     │ Discovered MCP server entries — always None (not hidden)               │
  ├──────────────────────────────┼───────┼────────────────────────────────────────────────────────────────────────┤
  │ src/extensions/mod.rs        │ 2     │ Test struct literals for serde roundtrip tests                         │
  ├──────────────────────────────┼───────┼────────────────────────────────────────────────────────────────────────┤
  │ src/extensions/registry.rs   │ 19    │ All test struct literals in the mod tests block                        │
  ├──────────────────────────────┼───────┼────────────────────────────────────────────────────────────────────────┤
  │ src/registry/manifest.rs     │ 2     │ to_registry_entry() conversions — propagates self.hidden from manifest │
  ├──────────────────────────────┼───────┼────────────────────────────────────────────────────────────────────────┤
  │ src/registry/installer.rs    │ 1     │ Test helper ExtensionManifest construction                             │
  ├──────────────────────────────┼───────┼────────────────────────────────────────────────────────────────────────┤
  │ tests/e2e_advanced_traces.rs │ 1     │ E2E test injecting a mock-notion registry entry                        │
  └──────────────────────────────┴───────┴────────────────────────────────────────────────────────────────────────┘

  No behavioral changes — purely completing the P1-H implementation that was started in the previous commit.
