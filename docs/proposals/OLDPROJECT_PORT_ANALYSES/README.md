# IronClaw Port-Analysis Backlog — Status Index

Consolidated status across the four upstream port analyses, **reconciled 2026-06-07** against the
LunarWing tree. Each analysis file carries its own per-item detail; this is the at-a-glance view.
Per the v1.1.1 release decision, **all remaining code-level ports are deferred** — see the
"Features and changes deferred to future releases" table in `RELEASE-v1.1.1.md`.

## Implemented (landed in v1.1.0 / v1.1.1)

| Item | What | Where |
|------|------|-------|
| 0.28.x/0.29.0 **P0-A** | Ghost-seeded tool-permission cleanup | `cleanup_ghost_seeded_tool_permissions()` (`ic/src/app.rs`) |
| **P1-H** | Registry `hidden` field | `ic/src/registry/manifest.rs`, extensions/registry |
| **P2-A** | Logs download endpoint (backend) | `/api/logs/download` (`ic/src/channels/web/server.rs`) — UI button still pending |
| **P2-B** | Approval-gate clamping refactor | `clamp_always_to_resume_kind()` (`ic/src/bridge/router.rs`) |
| 0.29.1 **P0** | Cross-conversation history leakage (non-UUID scopes) | `scoped_conversation_id()` UUID-v5 (`ic/src/bridge/router.rs`) |
| (MULTICA) | Bare-`*` host allowlist | `ic/src/tools/wasm/capabilities.rs:238` |

## Open / deferred (NOT in v1.1.1)

| Item | Priority | Note |
|------|---------|------|
| 0.29.0 **P0-B** Wasmtime 28→44 sandbox upgrade | P0 | XL, multi-PR; ~12 of 19 advisories live in the wasmtime stack. Own release track. |
| 0.29.0 **P0-A** Dependency advisory bumps | P0 | Run `cargo deny check advisories`; real blockers are libsql/tokio-xmpp/libsignal upgrades. |
| 0.28.1 **P1-A** WASM selective channel activation (headless) | P1 | Don't load all channels unconditionally. |
| 0.28.1 **P1-B** `scoped_to_user` workspace isolation | P1 | Per-request workspace clone for multi-tenant. |
| 0.28.1 **P1-C** Mission auto-resume after gate | P1 | Partial (`fire_on_system_event` only). |
| 0.28.1 **P1-D / P1-E** LLM-crate extraction + `lunarwing_common` expansion | P1 | XL refactor. |
| 0.29.0 **P1-A** CodeAct kill-switch (`LUNARWING_DISABLE_CODEACT`) | P1 | Operator safety toggle; standalone. |
| 0.28.2 **P1-I** `fetch_models_for` facade | P1 | LLM API surface cleanup. |
| 0.28.1 **P2-A** Pre-commit checks 7–9 | P2 | Needs P1-E identity types for check 8. |
| 0.29.0 **P2-B** Embeddings SSRF hardening | P2 | Verify embedding HTTP flows through `NetworkPolicyDecider`; always block cloud-metadata IP. |
| 0.28.2 **P2-C** / 0.29.0 **P2-C/P2-D** Snapshot harness, embeddings crate, WIT `websocket-send-text` | P2 | Nice-to-have; evaluate before adopting. |
