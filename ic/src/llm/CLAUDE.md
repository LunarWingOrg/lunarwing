# LLM Module

Multi-provider LLM integration with circuit breaker, retry, failover, and response caching.

## File Map

| File | Role |
|------|------|
| `mod.rs` | Provider construction (`create_llm_provider`, `build_provider_chain`) and module exports |
| `config.rs` | LLM config types (`LlmConfig`, `RegistryProviderConfig`, `LunarWingCloudConfig`, `BedrockConfig`) |
| `error.rs` | `LlmError` enum used by all providers |
| `provider.rs` | `LlmProvider` trait, `ChatMessage`, `ToolCall`, `CompletionRequest`, `sanitize_tool_messages` |
| `lunarwing_cloud_chat.rs` | LunarWing Cloud Chat Completions provider (dual auth: session token or API key) |
| `reasoning.rs` | `Reasoning` struct, `ReasoningContext`, `RespondResult`, `ActionPlan`, `ToolSelection`; thinking-tag stripping; `SILENT_REPLY_TOKEN` |
| `session.rs` | LunarWing Cloud session token management with disk + DB persistence, OAuth login flow |
| `circuit_breaker.rs` | Circuit breaker: Closed → Open → HalfOpen state machine |
| `retry.rs` | Exponential backoff retry wrapper; `is_retryable()` classification |
| `failover.rs` | `FailoverProvider` — tries providers in order with per-provider cooldown |
| `response_cache.rs` | In-memory LLM response cache with TTL and LRU eviction (keyed by SHA-256) |
| `costs.rs` | Static per-model cost table (OpenAI, Anthropic, local/Ollama heuristics) |
| `rig_adapter.rs` | Adapter bridging rig-core `CompletionModel` → `LlmProvider`; used by OpenAI, Anthropic, Ollama, Tinfoil |
| `smart_routing.rs` | `SmartRoutingProvider` — 13-dimension complexity scorer routes cheap vs primary model |
| `recording.rs` | `RecordingLlm` — trace capture for E2E replay testing (`IRONCLAW_RECORD_TRACE`) |
| `bedrock.rs` | AWS Bedrock provider via native Converse API (feature-gated: `--features bedrock`) |

## Provider Selection

Set via `LLM_BACKEND` env var:

| Value | Provider | Key env vars |
|-------|----------|-------------|
| `lunarwing_cloud` (default) | LunarWing Cloud Chat Completions | `LUNARWING_CLOUD_SESSION_TOKEN` or `LUNARWING_CLOUD_API_KEY` |
| `anthropic` | Anthropic | `ANTHROPIC_API_KEY` |
| `ollama` | Ollama local | `OLLAMA_BASE_URL` |
| `openai_compatible` | Any OpenAI-compatible endpoint | `LLM_BASE_URL`, `LLM_API_KEY`, `LLM_MODEL` |
| `tinfoil` | Tinfoil TEE inference | `TINFOIL_API_KEY`, `TINFOIL_MODEL` |
| `bedrock` | AWS Bedrock (requires `--features bedrock`) | `BEDROCK_REGION`, `BEDROCK_MODEL`, `AWS_PROFILE` |

## AWS Bedrock Provider

Uses the native Converse API via `aws-sdk-bedrockruntime` (`bedrock.rs`). Requires `--features bedrock` at build time — not in default features due to heavy AWS SDK dependencies.

**Auth:** Standard AWS credential chain — IAM credentials (`AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`), SSO profiles (`AWS_PROFILE`), or instance roles. The SDK resolves auth automatically from the environment.

**Config:**
- `BEDROCK_REGION` — AWS region (default: `us-east-1`)
- `BEDROCK_MODEL` — Required model ID (e.g., `anthropic.claude-opus-4-6-v1`)
- `BEDROCK_CROSS_REGION` — Optional cross-region inference prefix (`us`, `eu`, `apac`, `global`)

## LunarWing Cloud Provider Gotchas

**Dual auth modes:**
- **Session token** (default): `LUNARWING_CLOUD_SESSION_TOKEN=sess_...`, base URL = `https://private.lunarwing.org`. Tokens are persisted to `~/.lunarwing/session.json` (mode 0600) and optionally to the DB `settings` table (`lunarwing_cloud.session_token`). On 401 responses where the body contains "session" + "expired"/"invalid", `LunarWingCloudChatProvider` calls `session.handle_auth_failure()` which triggers the interactive OAuth login flow and retries once. Plain `AuthFailed` 401s are not retried.
- **API key**: Set `LUNARWING_CLOUD_API_KEY` (from `lunarwing.org`), base URL defaults to `https://lunarwing.org`. 401s with API key auth are immediately returned as `LlmError::AuthFailed` — no renewal.

**Session renewal is interactive:** When `SessionExpired` triggers renewal, it blocks and prompts the user in the terminal (GitHub/Google OAuth or manual API key entry). This is unsuitable for headless/hosted deployments — set `LUNARWING_CLOUD_SESSION_TOKEN` env var instead.

**Tool message flattening:** LunarWing Cloud's API doesn't support `role: "tool"` messages in the standard format. `lunarwing_cloud_chat.rs` defaults `flatten_tool_messages = true`, converting tool results to user messages with `[Tool result from <name>]: <content>` format. Use `LunarWingCloudChatProvider::new_with_flatten(..., false)` to disable for compliant endpoints.

**Pricing auto-fetch:** On startup, `LunarWingCloudChatProvider` fires a background task to fetch per-model pricing from `/v1/model/list`. If the fetch fails, it silently falls back to `costs::model_cost()` / `costs::default_cost()`. Pricing is stored in-memory only.

**HTTP request timeout:** The LunarWing Cloud HTTP client has a 120-second timeout per request. Rate limit `Retry-After` headers are parsed (both delay-seconds and HTTP-date formats) and forwarded as `LlmError::RateLimited { retry_after }` for the `RetryProvider` to honor.

## Circuit Breaker

State machine in `circuit_breaker.rs`:
```
Closed (normal)
  → Open (after failure_threshold consecutive transient failures; default: 5)
    → HalfOpen (after recovery_timeout; default: 30s)
      → Closed (after half_open_successes_needed probe successes; default: 2)
      → Open (if any probe fails)
```

**Transient vs non-transient errors:** Only `RequestFailed`, `RateLimited`, `InvalidResponse`, `SessionExpired`, `SessionRenewalFailed`, `Http`, and `Io` count toward the threshold. `AuthFailed`, `ContextLengthExceeded`, `ModelNotAvailable`, and `Json` errors never trip the breaker — they indicate caller problems, not backend degradation.

Configure via `LunarWingCloudConfig` fields: `circuit_breaker_threshold` (None = disabled), `circuit_breaker_recovery_secs` (default: 30).

The circuit breaker wraps the entire provider chain. When open, it immediately returns `LlmError::RequestFailed` with a message including remaining cooldown seconds. The `FailoverProvider` sitting outside can then try a fallback model.

## Failover Chain

`FailoverProvider` in `failover.rs` wraps a list of `LlmProvider` instances. On a retryable error, it tries the next provider in the list. Providers that fail repeatedly enter a cooldown period and are skipped (unless all providers are in cooldown, in which case the least-recently-cooled one is tried).

**Cooldown defaults:** `failure_threshold = 3` consecutive retryable failures → cooldown for `cooldown_duration = 300s`. Configure via `LunarWingCloudConfig` fields: `failover_cooldown_secs`, `failover_cooldown_threshold`.

**Current wiring:** The failover is set up between primary model and `LUNARWING_CLOUD_FALLBACK_MODEL` (a different model name on the same LunarWing Cloud backend), not across different LLM provider types. Cross-provider failover (e.g., LunarWing Cloud → Anthropic) requires manual construction.

## Retry

`RetryProvider` in `retry.rs` wraps any `LlmProvider` with exponential backoff. Retries on: `RequestFailed`, `RateLimited`, `InvalidResponse`, `SessionRenewalFailed`, `Http`, `Io`. Does **not** retry: `AuthFailed`, `SessionExpired`, `ContextLengthExceeded`, `ModelNotAvailable`, `Json`.

**Backoff schedule:** base 1s doubled per attempt with ±25% jitter, minimum floor 100ms. Attempt 0: ~1s, attempt 1: ~2s, attempt 2: ~4s. For `RateLimited`, uses the `retry_after` duration from the error (provider-supplied) instead of backoff.

Configure via `LunarWingCloudConfig.max_retries` (env: `LUNARWING_CLOUD_MAX_RETRIES`; default: 3). Set to 0 to disable.

**Empty-response retry (reasoning.rs):** A separate retry mechanism in `Reasoning::respond_with_tools()` handles the case where the LLM returns a valid HTTP response but the content cleans to empty (e.g. reasoning models returning only `<think>` tags). This retries up to `MAX_EMPTY_RESPONSE_RETRIES` (default 1) before returning the "I'm not sure how to respond to that." fallback. It is independent of `RetryProvider` — `RetryProvider` handles transport-level errors, while this handles content-level cleaning artifacts.

**Tool-call recovery (`recover_tool_calls_from_content`):** Before the empty-response path gives up, `respond_with_tools()` tries to rescue tool calls that the model emitted as text instead of in the structured `tool_calls` field. Recognized dialects: JSON inside `<tool_call>`/`<function_call>` (incl. pipe-delimited), bare tool name inside `<tool_call>`, the `[Called tool \`name\` with arguments: {...}]` bracket form, and the `<function=NAME><parameter=KEY>value</parameter></function>` XML form (GLM/Qwen-style, with or without a `<tool_call>` wrapper; parameter values are JSON-parsed when valid, else kept as strings). The `<function=...>` form was the root cause of the v1.1.2 "lapse" recurrence — those calls were being stripped to empty and misreported as empty responses. `clean_response()` also strips any leftover `<function=...>` blocks so unrecovered ones never leak to users.

## LlmProvider Trait

The full trait (all methods must be implemented or rely on defaults):

```rust
#[async_trait]
pub trait LlmProvider: Send + Sync {
    // Required
    fn model_name(&self) -> &str;
    fn cost_per_token(&self) -> (Decimal, Decimal);  // (input, output) per token
    async fn complete(&self, request: CompletionRequest) -> Result<CompletionResponse, LlmError>;
    async fn complete_with_tools(&self, request: ToolCompletionRequest) -> Result<ToolCompletionResponse, LlmError>;

    // Optional (have defaults)
    async fn list_models(&self) -> Result<Vec<String>, LlmError> { Ok(vec![]) }
    async fn model_metadata(&self) -> Result<ModelMetadata, LlmError> { /* name only */ }
    fn effective_model_name(&self, requested_model: Option<&str>) -> String { /* uses active */ }
    fn active_model_name(&self) -> String { self.model_name().to_string() }
    fn set_model(&self, _model: &str) -> Result<(), LlmError> { /* Err: not supported */ }
    fn calculate_cost(&self, input_tokens: u32, output_tokens: u32) -> Decimal { /* uses cost_per_token */ }
}
```

Key notes:
- `model_name()` returns the configured model name; `active_model_name()` returns the currently active model (may differ if `set_model()` was called — only `LunarWingCloudChatProvider` supports this).
- `cost_per_token()` returns `(Decimal, Decimal)` using `rust_decimal`. Look up via `costs::model_cost()` in your constructor; fall back to `costs::default_cost()` for unknowns.
- `RigAdapter` ignores per-request model overrides (logs a warning). Only `LunarWingCloudChatProvider` supports per-request model overrides via `CompletionRequest::model`.
- `complete_with_tools()` is never cached (tool calls can have side effects) — `CachedProvider` always passes them through.

To add a new provider:
1. Create `src/llm/myprovider.rs` implementing `LlmProvider`
2. Add variant to `LlmBackend` in `mod.rs`
3. Wire into the factory match in `mod.rs`
4. Add env vars to `config/llm.rs` and `.env.example`

## Response Cache

`CachedProvider` in `response_cache.rs` caches `complete()` responses. `complete_with_tools()` is never cached (side effects). Cache key is SHA-256 of `(model_name, messages_json, max_tokens, temperature, stop_sequences)`. LRU eviction when `max_entries` is reached; TTL-based expiry on access.

**Defaults:** TTL = 1 hour, max entries = 1000. Configure via `LunarWingCloudConfig` fields: `response_cache_enabled` (env: `LUNARWING_CLOUD_RESPONSE_CACHE_ENABLED`), `response_cache_ttl_secs`, `response_cache_max_entries`. Cache is in-memory only — evicted on restart.

## OpenAI-Compatible Custom Headers

Set `LLM_EXTRA_HEADERS=Key:Value,Key2:Value2` to inject headers into every request. Useful for OpenRouter attribution (`HTTP-Referer`, `X-Title`). Invalid header names/values are skipped with a warning (not a fatal error).

## Provider Chain Construction

`build_provider_chain()` in `mod.rs` is the single source of truth for assembling decorators. It always creates the base provider through `create_llm_provider()`, then applies all decorators inline:

```
Raw provider
  → RetryProvider           (per-provider backoff; wraps both primary and fallback)
  → SmartRoutingProvider    (cheap/primary split when LUNARWING_CLOUD_CHEAP_MODEL is set)
  → FailoverProvider        (fallback model; only when LUNARWING_CLOUD_FALLBACK_MODEL is set)
  → CircuitBreakerProvider  (fast-fail; only when LUNARWING_CLOUD_CIRCUIT_BREAKER_THRESHOLD is set)
  → CachedProvider          (response cache; only when LUNARWING_CLOUD_RESPONSE_CACHE_ENABLED=true)
  → RecordingLlm            (trace capture; only when IRONCLAW_RECORD_TRACE is set)
```

`build_provider_chain()` also returns a separate standalone cheap LLM provider (for heartbeat/evaluation tasks — not part of the decorator chain).

## reasoning.rs Contents

`reasoning.rs` does **not** contain an `IntentClassifier`. It contains:
- `Reasoning` struct — the main reasoning engine used by the agent worker; calls `complete_with_tools()` and handles tool dispatch
- `ReasoningContext` — carries messages, available tools, job description, and metadata into a reasoning call
- `RespondResult`, `ActionPlan`, `ToolSelection` — output types from the reasoning engine
- `TokenUsage` — input/output token counts
- `SILENT_REPLY_TOKEN` (`"NO_REPLY"`) and `is_silent_reply()` — used by the dispatcher to suppress empty responses in group chats
- Thinking-tag stripping — regex-based removal of `<thinking>`, `<reflection>`, `<scratchpad>`, `<|think|>`, `<final>`, etc. from model responses before returning to the user
- Empty-response retry — when `clean_response` strips all content (e.g. reasoning models returning only `<think>` tags), `respond_with_tools` retries the LLM call up to `MAX_EMPTY_RESPONSE_RETRIES` times (default 1) before falling back to a generic message. Original content is logged at `warn` level for diagnosis. This is separate from `RetryProvider` (which handles transport/rate-limit errors).

## costs.rs Details

`costs.rs` provides a static lookup table (`model_cost(model_id)`) returning `(input_cost, output_cost)` per token as `rust_decimal::Decimal`. Provider prefixes like `"openai/gpt-4o"` are stripped before lookup. Returns `None` for unknown models — callers should fall back to `default_cost()` (roughly GPT-4o pricing). Local model heuristic (`is_local_model()`) returns zero cost for Ollama-style identifiers (llama*, mistral*, `:latest`, `:instruct`, etc.).

## rig_adapter.rs Details

`RigAdapter<M>` bridges any rig-core `CompletionModel` to `LlmProvider`. It is actively used in production for all non-LunarWing Cloud providers (OpenAI, Anthropic, Ollama, Tinfoil, OpenAI-compatible). Key behaviors:
- **Per-request model overrides are silently ignored** (warning logged); the model is baked at construction time.
- **OpenAI strict-mode schema normalization** is applied to all tool definitions: `additionalProperties: false`, all properties added to `required`, optional fields made nullable via `"type": ["T", "null"]`. This happens transparently at the provider boundary.
- **System messages** are extracted into the rig-core `preamble` field (concatenated with newlines if multiple).
- **Tool call IDs** are generated (`generated_tool_call_{seed}`) if the provider returns empty/whitespace IDs.
- **Tool name normalization**: strips `proxy_` prefix if it matches a known tool (handles some proxy implementations).
- **OpenAI uses Chat Completions API** (`completions_api()`), not the newer Responses API — the Responses API path panics when tool results are sent back (rig-core doesn't thread `call_id` through `ToolCall`).

## Streaming Support

No streaming support. All providers use non-streaming (blocking) Chat Completions requests. The `complete()` and `complete_with_tools()` methods return only after the full response is available.

## Trace Recording

Set `IRONCLAW_RECORD_TRACE=1` to enable live trace recording via `RecordingLlm`. Traces are JSON files containing: memory snapshot, HTTP exchanges from tools, and LLM steps (user inputs, text responses, tool call responses). Replay these in E2E tests via `TraceLlm`. Configure output path with `IRONCLAW_TRACE_OUTPUT` (default: `trace_{timestamp}.json`).
