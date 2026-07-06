Done. Here's what changed in AGENTS.md:

  1. Doc list: Added crates/lunarwing_engine/CLAUDE.md to the specs list
  2. Where to Work: Added 11 missing modules — sandbox, orchestrator, secrets, hooks, tunnel, skills, bridge, gate, pairing, webhooks, observability, registry
  3. Clippy command: Added missing --benches flag to match root CLAUDE.md
  4. WASM build script: Expanded to show all three flag variants (--tools, --channels, no flag)
  5. Service install path: Added macOS render-launchd + launchctl alongside systemd/OpenRC
  6. Watchdog assets: Added lunarwing-watchdog-launchd.sh script and com.lunarwing.watchdog.plist; noted launchd in auto-detection
