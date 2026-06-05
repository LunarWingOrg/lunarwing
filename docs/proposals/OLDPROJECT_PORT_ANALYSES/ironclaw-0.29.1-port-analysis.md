# Port IronClaw 0.29.1 Changes to LunarWing

**Date:** 2026-06-05
**Status:** Analysis complete

## Context

IronClaw v0.29.1 (commit `556dfd077`, 7 commits after the 0.29.0 release) shipped on 2026-06-04. This is a small patch release: one feature (temperature plumbing for the Responses API, which also fixes an off-by-one bug in the agentic loop), one correctness/isolation fix for non-UUID channel conversation scopes, three CI workflow fixes, a WeCom registry artifact, and a version bump.

The release is smaller than 0.29.0 but contains a **high-severity conversation isolation fix** that directly affects LunarWing's XMPP bridge and any future non-UUID-scoped channel. The temperature/Responses API changes do not apply — LunarWing's Responses API is a stub and the dispatcher has no iteration-gated settings overrides.

**Commits analyzed:**

| Commit | Description |
|--------|-------------|
| `0a6c2126e` | plumb temperature through Responses API (#3641) |
| `d588abff3` | fix(engine): scope v1 history for channel conversations (#4320) |
| `27994a162` | ci(nearai-bench): track nearai/benchmarks @main instead of pinning (#4217) |
| `f314390ca` | ci(nearai-bench): grant id-token: write to unblock reusable workflow (#4220) |
| `749f58441` | ci(nearai-bench): scope id-token: write to the bench job (#4221) |
| `9df5e8dba` | chore: add WeCom release artifact (#4107) |
| `556dfd077` | chore(release): bump ironclaw to 0.29.1 (#4405) |

---

## Changes NOT Applicable to LunarWing (Skip)

| Commit | Description | Why Skip |
|--------|-------------|----------|
| `0a6c2126e` (partial) | Off-by-one iteration gate fix (`iteration == 0` → `iteration == 1`) in `ChatDelegate::call_llm` | LunarWing's `ChatDelegate::call_llm` (`src/agent/dispatcher.rs:351`) has no iteration-gated settings overrides. There is no `resolve_settings_temperature`, no `selected_model` override, and no `get_setting_with_admin_fallback` call. The bug is not reachable. |
| `0a6c2126e` (partial) | `resolve_temperature_overrides()` precedence function (context → metadata → settings) | LunarWing doesn't read temperature from a settings store or per-request metadata in the agentic loop. Temperature is set directly via `.with_temperature()` in specific callers (heartbeat, compaction, routines). No precedence resolution is needed. |
| `0a6c2126e` (partial) | Responses API `temperature` validation + metadata plumbing in `create_response_handler` | LunarWing's `src/channels/web/responses_api.rs` is a 4-line stub — the endpoint is not registered and routes are not served. No code to fix. |
| `0a6c2126e` (partial) | `tests/responses_api_temperature.rs` (215 lines, new file) | Tests an endpoint LunarWing doesn't have. |
| `0a6c2126e` (partial) | `agentic_loop.rs` regression test `first_call_llm_iteration_is_one` | Tests a gate LunarWing doesn't have. |
| `0a6c2126e` (partial) | Fixture `llm_traces/tools/job_list_cancel.json` | Test fixture for the temperature E2E tests; not needed. |
| `27994a162` | ci: track nearai/benchmarks @main instead of pinning (#4217) | IronClaw-specific CI infrastructure (nearai-bench workflow). LunarWing has its own CI. |
| `f314390ca` | ci: grant id-token: write to unblock reusable workflow (#4220) | IronClaw-specific CI. |
| `749f58441` | ci: scope id-token: write to the bench job (#4221) | IronClaw-specific CI. |
| `9df5e8dba` | chore: add WeCom release artifact (#4107) | WeCom is a proprietary channel (WeChat for Work). LunarWing rejects proprietary channels per the manifesto. |
| `556dfd077` | chore(release): bump ironclaw to 0.29.1 (#4405) | Version bump, CHANGELOG entry, Cargo.lock update — IronClaw-specific. |

---

## P0 — Security / Correctness (Port Immediately)

### P0-A: Scope V1 History for Non-UUID Channel Conversations — Cross-Conversation Leakage
**Commit:** `d588abff3` (#4320) | **Complexity:** S-M | **Dependencies:** None | **Status:** Not implemented — LunarWing's `src/bridge/router.rs` still uses the UUID-only `Uuid::parse_str()` pattern at lines ~2198 and ~2297; no `scoped_conversation_id` or `resolve_v1_conversation_for_message` in `src/db/mod.rs` or `src/bridge/router.rs`.

**Why:** LunarWing's v1 history persistence in `src/bridge/router.rs` only handles UUID-formatted conversation scopes correctly. When a channel produces a non-UUID scope — as XMPP does for room JIDs (`xmpp:room:dev@conference.example.org`), DM JIDs (`xmpp:dm:alice@example.org`), WeeChat buffer names, or DarkIRC channel identifiers — the `Uuid::parse_str()` call fails silently and all messages fall back to a single shared "assistant conversation" per user+channel. This means:

1. **History leakage across conversations**: messages from distinct XMPP rooms or DMs appear interleaved in a single v1 history thread, visible through the gateway history API.
2. **Multi-tenant privacy violation**: in a multi-tenant deployment, different conversation contexts collapse into one, potentially exposing private exchanges through the shared history view.
3. **Broken history correlation**: when a user opens the gateway UI to review a specific conversation, messages from unrelated scopes pollute the view.

This is directly relevant to LunarWing's XMPP/OMEMO channels, which are the primary interaction path. IronClaw discovered the bug via their WeCom channel (which uses scopes like `wecom:dm:ZhangSan` and `wecom:group:wr-t-7ZAAAM7...`), but the pattern is channel-agnostic.

**What IronClaw changed:**

1. **`src/db/mod.rs`** — Added `scoped_conversation_id(channel, user_id, scope) -> Uuid`: when the scope is already a valid UUID, returns it directly; otherwise, generates a stable UUID v5 from a length-prefixed seed of `(channel, user_id, scope)`. The length-prefix encoding prevents collision between scopes that share a delimiter (e.g. `("a", "b\x1fc", "d")` vs `("a\x1fb", "c", "d")`). Added `get_or_create_scoped_conversation()` as a default method on `ConversationStore` that uses `scoped_conversation_id` + `ensure_conversation`, preserving the original scope string in `conversations.thread_id`.

2. **`src/bridge/router.rs`** — Added `resolve_v1_conversation_for_message(db, message) -> Result<Uuid>`: checks `message.conversation_scope()`; if present, delegates to `get_or_create_scoped_conversation`; otherwise falls back to `get_or_create_assistant_conversation`. Replaced 4 call sites (user message persist, post-park assistant persist, outcome assistant persist, tool_calls persist) with calls to this unified function. Added proper `tracing::warn!` on resolution failures instead of silently dropping messages.

3. **Tests** — E2E test `handle_with_engine_persists_non_uuid_channel_scopes_to_separate_v1_conversations` verifying that two WeCom messages with different non-UUID scopes create separate conversation histories. Unit tests for `scoped_conversation_id`: UUID passthrough and length-prefix collision avoidance.

**LunarWing files to modify:**

1. `ic/src/db/mod.rs` — Add `scoped_conversation_id()` function and `get_or_create_scoped_conversation()` default method on `ConversationStore`. Add unit tests for UUID passthrough and length-prefix collision safety.

2. `ic/src/bridge/router.rs` — Add `resolve_v1_conversation_for_message()`. Replace 2 call sites:
   - Line ~2197: `handle_with_engine_inner` — user message persist (currently UUID-only parse with fallback to assistant conversation)
   - Line ~2290: `write_v1_response` closure in `await_thread_outcome` — assistant response persist (same UUID-only pattern)

**IronClaw reference:**
- `git show d588abff3:src/db/mod.rs` (search for `scoped_conversation_id` and `get_or_create_scoped_conversation`)
- `git show d588abff3:src/bridge/router.rs` (search for `resolve_v1_conversation_for_message`)

**Adaptation notes:**

- LunarWing has 2 v1 persist sites in the router (user message at `handle_with_engine_inner` and assistant response at `await_thread_outcome`). IronClaw 0.29.1 has 4 because it also has `spawn_post_park_continuation` and `persist_v2_tool_calls` — functions that don't exist in LunarWing's router. Per review-discipline.md ("fix the pattern, not just the instance"), grep for any additional `get_or_create_assistant_conversation` or `Uuid::parse_str` + conversation scope patterns in the router before committing.
- The E2E test references `IronclawBot` in its group message — adapt to `LunarWingBot` or a generic name. The test also uses `ironclaw_engine::` imports and `CompletedTextLlm` — adjust to `lunarwing_engine::` and LunarWing's test helpers.
- The notification persist site at line ~2645 (`get_or_create_assistant_conversation` for notification messages) should be evaluated: if notifications carry a conversation scope, the same fix applies.

---

## Recommended Implementation Order

```
1. P0-A  Scope v1 history for non-UUID channel conversations   [S-M]   prevents cross-conversation history leakage via XMPP/WeeChat/DarkIRC
```

Single item. Can be done in one PR.

## Verification

After implementation:
- `cargo fmt && cargo clippy --all --benches --tests --examples --all-features` (zero warnings)
- `cargo test`
- `cargo check --no-default-features --features libsql` (dual-backend)
- `scripts/pre-commit-safety.sh`

For P0-A specifically:
- Verify `scoped_conversation_id("xmpp", "user1", "room@conference.example.org")` returns a stable, non-nil UUID v5 (not a parse error fallback)
- Verify `scoped_conversation_id("xmpp", "user1", "<valid-uuid-string>")` returns the UUID directly (passthrough)
- Verify length-prefix collision avoidance: `scoped_conversation_id("a", "b\x1fc", "d") != scoped_conversation_id("a\x1fb", "c", "d")`
- Verify that the new unit tests pass under both `--features postgres` and `--features libsql`
- If the integration harness is available: send two XMPP messages with different room JIDs as conversation scopes and confirm they create separate v1 conversations visible in the gateway history API
