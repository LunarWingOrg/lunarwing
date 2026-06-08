# BUG: WASM tools can't resolve secrets when triggered over WeeChat (IRC)

> **STATUS: FIXED (verified 2026-06-07)** — channel-originated messages now execute under the
> owner credential scope (`resolve_message_scope`, `ic/src/channels/wasm/wrapper.rs:768`), so
> tools like `web_search` resolve secrets over WeeChat. Analysis retained for history.

**Severity:** Medium — secret-backed WASM tools (e.g. `web_search` → `brave_api_key`) failed
only when the conversation originated from the WeeChat/IRC channel; the same tools worked from
the REPL/CLI on the same daemon.

## Architecture context

It is **one process**. A single LunarWing daemon runs all channels at once (`ChannelsConfig`,
`ic/src/config/channels.rs`): CLI, HTTP, gateway, XMPP, and WASM channels. WASM channels (like
WeeChat) are loaded from `~/.lunarwing/channels/` (or `WASM_CHANNELS_DIR`) and `ChannelManager`
merges their streams. The WeeChat WASM channel is **not** a separate agent — `ws_adapter.py` is
only a WebSocket↔HTTP proxy to WeeChat; the agent loop, tools, and secrets store all live in the
same daemon.

Secrets are scoped by `owner_id` (and `LUNARWING_BASE_DIR`). For WASM tools, the host injects
credentials at the HTTP-request level (`ic/src/tools/wasm/credential_injector.rs`): when
`web_search` calls `api.search.brave.com`, the host injects `brave_api_key` as the
`X-Subscription-Token` header. So if REPL and WeeChat run in the same daemon (same base dir),
they share the same secrets store — the credential *should* be available regardless of channel.

A separate instance (different `LUNARWING_BASE_DIR`/DB) would have its own secrets store and is
the trivial explanation for "works on the REPL but not on IRC." The interesting bug is when it
fails **on the same daemon** — meaning the execution path loses the credential scope.

## Root cause (confirmed bug chain)

Credential resolution keys off `ctx.user_id`, which comes from the channel:

1. The REPL/CLI creates messages with `user_id = "default"`.
2. The WeeChat channel emits `user_id = "id:nick!user@host"` (the raw IRC hostmask).
3. `resolve_message_scope` checked whether the sender equals the owner actor id. For WeeChat
   there is typically no entry in `wasm_channel_owner_ids`, so it fell through and used the raw
   hostmask as the resolved workspace `user_id`.
4. That `user_id` flowed into `IncomingMessage.user_id` → `JobContext.user_id` → tool execution
   (`credential_user_id = ctx.user_id`).
5. Credential lookup did `store.get_decrypted("id:nick!user@host", "brave_api_key")`, which
   found nothing — secrets are stored under the owner scope (typically `"default"`).
6. There is **no fallback to `"default"`**: a code comment described one, but it was never
   implemented, and a test explicitly asserts it must not happen
   (`must not fallback to default`) to prevent cross-user credential leakage.

So channel-originated tool calls executed under the IRC sender's scope, where no secrets exist,
and the tool failed with "credentials not configured."

## Fix

Chosen approach (**Option A** — the cleaner of two): in `resolve_message_scope`
(`ic/src/channels/wasm/wrapper.rs:768`), when no owner actor id is set, resolve to the instance
**owner scope** rather than the raw sender id. Channel-originated messages now execute tools
under the instance owner's credential scope; the raw `sender_id` is still preserved separately
for audit/routing. The strict "no fallback to default" guard for per-user credential isolation
is left intact — this fixes the *scope resolution*, not the credential lookup.

(The rejected Option B — adding a `"default"` fallback inside credential resolution — would have
weakened the per-user isolation the test enforces.)
