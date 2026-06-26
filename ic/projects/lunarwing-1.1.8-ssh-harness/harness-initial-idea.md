## SSH Harness — Initial Design Draft (2026-06-XX)

**Status:** Draft — Awaiting review and refinement

### Overview
Centralized SSH bridge for secure remote host access, auto-injected into workers/routines, no disk writes for secrets.

### Key Components
- `SSHBridge` struct
- Config storage (non-sensitive in `config.toml`)
- Secret storage (sensitive keys in secrets store)
- Auto-injection into routine context
- Remote worker integration

### Architecture
See `harness-architecture.md` for full diagram.

### Implementation Plan
See `harness-implementation.md` for step-by-step breakdown.

---

*Note: This is the initial design draft. Refine as we go.*
