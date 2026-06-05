# Human Delay Mode - Documentation Index

A quick overview of the Human Delay Mode feature and how to work with it.

## What is Human Delay Mode?

Human Delay Mode (HDM) adds human-in-the-loop approval to LunarWing tool execution. Tools can be configured to pause and require explicit human approval before executing — useful for safety-critical operations, sensitive commands, or simply adding a checkpoint before any action runs.

## Quick Links

| Document | Purpose |
|----------|---------|
| [human-delay-mode-phase1-test-checklist.md](human-delay-mode-phase1-test-checklist.md) | Step-by-step instructions to test Phase 1 implementation |
| [human-delay-mode-phase2-plan.md](human-delay-mode-phase2-plan.md) | Future work: timeouts, UI, gate pipeline integration |
| [human-delay-mode-testing-guide.md](human-delay-mode-testing-guide.md) | How to run tests and verify the feature works |

## Current Status (Phase 1)

- ✅ `supervised_mode` flag in ThreadConfig
- ✅ CLI flag (`--supervised`) and env var (`AGENT_SUPERVISED_MODE`)
- ✅ Inline approval gating in effect adapter
- ✅ Overrides auto-approve settings
- ⏳ Timeout expiration (Phase 2)
- ⏳ Gate pipeline integration (Phase 2)
- ⏳ Modify UI option (Phase 2)

## Usage

```bash
# Start with supervised mode via env var
AGENT_SUPERVISED_MODE=true lunarwing

# Start with supervised mode via CLI flag
lunarwing --supervised
```

## Next Steps

1. **Test Phase 1** — Use the [test checklist](human-delay-mode-phase1-test-checklist.md) to verify everything works
2. **Run `cargo test`** — Follow the [testing guide](human-delay-mode-testing-guide.md)
3. **Plan Phase 2** — Review the [phase 2 plan](human-delay-mode-phase2-plan.md) for what's next

---

*Part of LunarWing's safety and control features. See also: `docs/guides/security.md` for general security practices.*