# LLM Provider Removal Plan

**Branch:** `1.1.8-extension-and-mcp-removal-p-1` (or follow-up branch)
**Target release:** v1.1.9
**Status:** Planning

## Goal

Strip the LLM provider system down to **only `openai_compatible`**. Remove all proprietary SaaS provider implementations (NearAI, Anthropic direct, GitHub Copilot, OpenAI Codex/ChatGPT, Gemini OAuth, Bedrock), their config types, source files, registry entries, and all coupled code paths.

The `openai_compatible` protocol already covers every use case LunarWing cares about: TensorZero proxy, vLLM, LiteLLM, Ollama (OpenAI-compatible mode), local models, and even direct OpenAI API if desired.

## Decisions (Owner-Approved)

| Decision | Choice | Rationale |
|---|---|---|
| NearAI embeddings | **Remove entirely** | Other embedding providers exist (`openai`, `openai_compatible`, `ollama`) |
| Default backend | **`openai_compatible`** | Matches actual deployment (TensorZero proxy) |
| Providers to keep | **`openai_compatible` only** | Covers all OpenAI-compatible endpoints; user confirmed |
| Bedrock feature gate | **Leave gate, remove from docs/wizard** | Lower risk; code stays behind `--features bedrock` but is invisible to users |

## Scope

### IN scope
- Delete 15+ LLM source files
- Strip `providers.json` to single entry
- Simplify `LlmConfig`, `config/llm.rs` resolution
- Remove NearAI from embeddings
- Remove NearAI/Gemini/Codex/Bedrock/Copilot from provider factory
- Update setup wizard, CLI, models command
- Update all affected tests
- Update documentation

### OUT of scope
- Bedrock feature-gated code (`--features bedrock`) — stays compiled but undocumented
- The decorator chain (retry, circuit breaker, failover, smart routing, response cache, recording) — all backend-agnostic, untouched
- The `rig_adapter.rs` — still needed for `openai_compatible`
- The `LlmProvider` trait itself — untouched
- External worker containers (codex, nanocode, pebble) — separate concern

---

## Component Breakdown

### Component 1: `providers.json` cleanup

**File:** `ic/providers.json`

**Current state:** 21 provider entries.
**Target state:** 1 entry (`openai_compatible`).

Remove all entries except `openai_compatible`. The kept entry:
```json
{
  "id": "openai_compatible",
  "aliases": ["openai-compatible", "compatible"],
  "protocol": "open_ai_completions",
  "base_url_env": "LLM_BASE_URL",
  "base_url_required": true,
  "api_key_env": "LLM_API_KEY",
  "api_key_required": false,
  "model_env": "LLM_MODEL",
  "default_model": "default",
  "extra_headers_env": "LLM_EXTRA_HEADERS",
  "description": "Custom OpenAI-compatible endpoint (TensorZero, vLLM, LiteLLM, Ollama, etc.)",
  "setup": {
    "kind": "open_ai_compatible",
    "secret_name": "llm_compatible_api_key",
    "display_name": "OpenAI-compatible",
    "can_list_models": false
  }
}
```

**Tests affected:** `ic/src/llm/registry.rs` — 14 tests reference specific providers (openai, groq, tinfoil, ollama). Must rewrite to only test `openai_compatible`.

---

### Component 2: LLM source file deletion

**Files to DELETE** (15 files in `ic/src/llm/`):

| File | Provider | Notes |
|---|---|---|
| `nearai_chat.rs` | NearAI Chat Completions | Also exports `DEFAULT_MODEL`, `ModelInfo`, `default_models()` — must relocate |
| `session.rs` | NearAI session token management | `create_session_manager()` used by `app.rs` — must stub or remove |
| `anthropic_oauth.rs` | Anthropic OAuth provider | Direct proprietary API |
| `gemini_oauth.rs` | Google Gemini OAuth | Proprietary |
| `github_copilot.rs` | GitHub Copilot Chat API | Proprietary |
| `github_copilot_auth.rs` | Copilot token exchange | Paired with above |
| `codex_chatgpt.rs` | Codex ChatGPT Responses API | Proprietary |
| `openai_codex_provider.rs` | OpenAI Codex provider | Proprietary |
| `openai_codex_session.rs` | Codex OAuth session | Paired with above |
| `codex_auth.rs` | Codex auth.json reader | Paired with above |
| `codex_test_helpers.rs` | Codex test utilities | Paired with above |
| `token_refreshing.rs` | Token refresh decorator | Only wraps Codex provider |
| `oauth_helpers.rs` | Shared OAuth utility | Only used by removed providers |
| `bedrock.rs` | AWS Bedrock provider | **Keep file** (feature-gated), but remove from docs |
| `gemini_oauth.rs` | (already listed) | |

**Relocation needed:**
- `DEFAULT_MODEL` (`"Qwen/Qwen3.5-122B-A10B"`) → move to `mod.rs` as a const. Actually, with `openai_compatible` as default, the default model should come from `LLM_MODEL` env var or `config.toml`. The hardcoded constant is a NearAI relic. **Recommendation:** Remove it entirely; the config template already sets `selected_model`.
- `ModelInfo` struct → only used by NearAI's `list_models()`. Remove.
- `default_models()` → only used by setup wizard NearAI path. Remove.
- `create_session_manager()` → used by `app.rs:init_agent()` to create `SessionManager`. Must remove the call site and the `SessionManager` type. Check what `app.rs` does with the session manager — it passes it to `create_llm_provider()`. With NearAI gone, the session manager is unused.

---

### Component 3: Config types simplification

**File:** `ic/src/llm/config.rs`

**Types to REMOVE:**
- `NearAiConfig` (lines 228-296) — entire struct + `for_model_discovery()` method
- `BedrockConfig` (lines 136-147) — keep behind `#[cfg(feature = "bedrock")]`
- `GeminiOauthConfig` (lines 314-327) — entire struct
- `OpenAiCodexConfig` (lines 107-134) — entire struct + `Default` impl
- `OAUTH_PLACEHOLDER` const (line 21)
- `CacheRetention` enum (lines 30-65) — Anthropic-specific, only used by removed providers

**`LlmConfig` changes** (lines 154-208):

Remove fields:
- `session: SessionConfig` — NearAI-only
- `nearai: NearAiConfig` — NearAI-only
- `bedrock: Option<BedrockConfig>` — keep behind `#[cfg(feature = "bedrock")]`
- `gemini_oauth: Option<GeminiOauthConfig>`
- `openai_codex: Option<OpenAiCodexConfig>`

Keep fields (already generic):
- `backend: String`
- `provider: Option<RegistryProviderConfig>`
- `request_timeout_secs: u64`
- `llm_turn_budget_secs: u64`
- `cheap_model: Option<String>`
- `smart_routing_cascade: bool`
- `max_retries: u32`
- `circuit_breaker_threshold: Option<u32>`
- `circuit_breaker_recovery_secs: u64`
- `response_cache_enabled: bool`
- `response_cache_ttl_secs: u64`
- `response_cache_max_entries: usize`

**`RegistryProviderConfig` changes:**

Remove fields:
- `oauth_token: Option<SecretString>` — only for Anthropic OAuth
- `is_codex_chatgpt: bool` — Codex-specific
- `refresh_token: Option<SecretString>` — Codex-specific
- `auth_path: Option<PathBuf>` — Codex-specific
- `cache_retention: CacheRetention` — Anthropic-specific

Keep fields:
- `protocol: ProviderProtocol`
- `provider_id: String`
- `api_key: Option<SecretString>`
- `base_url: String`
- `model: String`
- `extra_headers: Vec<(String, String)>`
- `unsupported_params: Vec<String>`

**`cheap_model_name()` method:** Remove the NearAI fallback branch. Just return `self.cheap_model.as_deref()`.

---

### Component 4: Config resolution

**File:** `ic/src/config/llm.rs`

**`resolve()` function** (starts at line 67):

Remove:
- NearAI backend detection (`is_nearai`, lines 81-82)
- Bedrock backend detection (`is_bedrock`, lines 83-84) — keep behind `#[cfg(feature = "bedrock")]`
- Gemini OAuth detection (`is_gemini_oauth`, lines 85)
- OpenAI Codex detection (`is_openai_codex`, lines 86-88)
- NearAI session config resolution (lines 102-118)
- NearAI config resolution (lines 120-155) — the entire `nearai` block
- Bedrock config resolution (lines 168-203) — keep behind feature gate
- Gemini OAuth config resolution (lines 245-256)
- OpenAI Codex config resolution (lines 206-235)
- Codex auth.json override in `resolve_registry_provider()` (lines 413-421)
- All `nearai.*` fallback logic in the decorator chain settings (lines 268-320)

Change:
- Default backend from `"nearai"` to `"openai_compatible"` (line 76)
- `LlmConfig` construction at the end (lines 322-352) — remove dropped fields

The decorator chain settings (max_retries, circuit_breaker_*, response_cache_*) currently fall back to `nearai.*` fields. Change them to use hardcoded defaults directly:
- `max_retries`: default 3 (was `nearai.max_retries`)
- `circuit_breaker_threshold`: default None (was `nearai.circuit_breaker_threshold`)
- `circuit_breaker_recovery_secs`: default 30 (was `nearai.circuit_breaker_recovery_secs`)
- `response_cache_enabled`: default false (was `nearai.response_cache_enabled`)
- `response_cache_ttl_secs`: default 3600 (was `nearai.response_cache_ttl_secs`)
- `response_cache_max_entries`: default 1000 (was `nearai.response_cache_max_entries`)

---

### Component 5: Provider factory

**File:** `ic/src/llm/mod.rs`

**Functions to remove:**
- `create_llm_provider_with_config()` (line 144) — NearAI-specific
- `create_bedrock_provider()` (line 233) — keep behind `#[cfg(feature = "bedrock")]`
- `create_anthropic_from_registry()` (line 329)
- `create_ollama_from_registry()` (line 409) — actually, check if ollama is still in providers.json. If not, remove. If openai_compatible covers it via protocol, this is dead code.
- `create_openai_codex_provider()` (line 456)
- `create_codex_chatgpt_from_registry()` (line 202)
- `create_gemini_oauth_provider()` (line 745)
- All NearAI cheap provider functions: `create_cheap_provider_for_backend()` (line 514)

**`create_llm_provider()`** (line 92):
Strip the NearAI branch (lines 98-161). The function becomes:
```rust
pub async fn create_llm_provider(
    config: &LlmConfig,
) -> Result<Arc<dyn LlmProvider>, LlmError> {
    // Bedrock special path (feature-gated)
    #[cfg(feature = "bedrock")]
    if config.backend == "bedrock" {
        return create_bedrock_provider(config);
    }

    // Registry-based provider (openai_compatible)
    let provider_config = config.provider.as_ref()
        .ok_or_else(|| LlmError::Config("No provider config for backend".into()))?;
    create_registry_provider(provider_config, config.request_timeout_secs).await
}
```

**`create_registry_provider()`** (line 173):
Strip Anthropic, Ollama, Codex ChatGPT branches. Becomes:
```rust
pub async fn create_registry_provider(
    config: &RegistryProviderConfig,
    request_timeout_secs: u64,
) -> Result<Arc<dyn LlmProvider>, LlmError> {
    create_openai_compat_from_registry(config, request_timeout_secs).await
}
```

**`build_provider_chain()`** (line 578):
- Remove `session` parameter (no longer needed)
- Remove NearAI cheap model fallback logic
- Keep decorator chain construction (retry, smart routing, failover, circuit breaker, cache, recording)

**`create_cheap_llm_provider()`** (line 497):
Remove NearAI-specific branches. Generic `LLM_CHEAP_MODEL` is the only path.

**Module declarations** (lines 24-34):
Remove `mod` declarations for deleted files. Keep:
- `mod config`, `mod error`, `mod provider`, `mod registry`, `mod rig_adapter`
- `mod circuit_breaker`, `mod retry`, `mod failover`, `mod response_cache`
- `mod smart_routing`, `mod recording`, `mod costs`, `mod reasoning`
- `mod models`, `mod reasoning_models`, `mod vision_models`, `mod image_models`
- `mod timeout`
- `mod bedrock` (behind `#[cfg(feature = "bedrock")]`)

**Re-exports** (lines 57-75):
Remove: `DEFAULT_MODEL`, `ModelInfo`, `NearAiChatProvider`, `default_models`, `SessionConfig`, `SessionManager`, `create_session_manager`.

**Tests in mod.rs** (lines 761-920):
Rewrite `test_nearai_config()`, `test_llm_config()`, and all cheap provider tests to use `openai_compatible` config.

---

### Component 6: Provider protocol enum

**File:** `ic/src/llm/registry.rs`

**`ProviderProtocol` enum** (line 32):
Remove variants:
- `Anthropic` — no longer have Anthropic direct provider
- `GithubCopilot` — removed

Keep:
- `OpenAiCompletions` — the only protocol we need
- `Ollama` — keep for potential future use (harmless)

Update `registry.rs` tests: remove references to `groq`, `tinfoil`, `openai`, `ollama` providers. Test only `openai_compatible`.

---

### Component 7: Embeddings cleanup

**File:** `ic/src/workspace/embeddings.rs`

Remove `NearAiEmbeddings` struct and its `EmbeddingProvider` impl (line 304).

**File:** `ic/src/workspace/mod.rs` (line 61):
Remove `NearAiEmbeddings` from the re-export.

**File:** `ic/src/app.rs`:
Check where embeddings provider is constructed. The NearAI embeddings path likely reads `config.llm.nearai` fields. Must change to use `openai_compatible` config or `openai` config for embeddings.

---

### Component 8: Setup wizard

**File:** `ic/src/setup/wizard.rs`

Remove:
- NearAI provider selection step
- NearAI model listing (`default_models()`, `DEFAULT_MODEL`)
- NearAI session/OAuth login flow
- GitHub Copilot device login flow
- All provider-specific setup paths except `openai_compatible`

The wizard should offer one path: configure an OpenAI-compatible endpoint (base URL + optional API key + model name).

---

### Component 9: CLI commands

**File:** `ic/src/cli/models.rs`
- `build_nearai_model_fetch_config()` (line 334) — remove, replace with openai_compatible config
- `try_fetch_models()` — remove NearAI/Bedrock special cases
- Model listing: only show models from the configured openai_compatible endpoint

**File:** `ic/src/cli/mod.rs`
- Remove NearAI session/login commands
- Remove provider-specific CLI flags

---

### Component 10: AppBuilder wiring

**File:** `ic/src/app.rs`

Remove:
- `create_session_manager()` call — no longer needed
- NearAI session persistence to DB
- NearAI embeddings construction

The `init_agent()` function currently creates a `SessionManager` and passes it to `create_llm_provider()`. Remove the session manager entirely — `create_llm_provider()` no longer takes it.

---

### Component 11: Settings struct

**File:** `ic/src/settings.rs` (and `ic/src/config/mod.rs`)

Remove NearAI-specific settings fields:
- `bedrock_region`, `bedrock_cross_region`, `bedrock_profile` — keep behind `#[cfg(feature = "bedrock")]`
- Any NearAI session-related settings

---

### Component 12: Config template

**File:** `ic/deploy/config.toml`

Update the default config template to reflect `openai_compatible` as the sole backend:
```toml
llm_backend = "openai_compatible"
openai_compatible_base_url = "http://127.0.0.1:3002"
selected_model = "tensorzero::function_name::lunarwing"
```

This is likely already correct — verify and clean up any NearAI references.

---

### Component 13: `.env.example`

**File:** `ic/.env.example`

Remove all NearAI, Anthropic, Gemini, Codex, Copilot, Bedrock env vars. Keep only:
- `LLM_BASE_URL`
- `LLM_API_KEY`
- `LLM_MODEL`
- `LLM_EXTRA_HEADERS`

---

### Component 14: Documentation

**Files to update:**
- `ic/src/llm/CLAUDE.md` — rewrite provider table, file map, remove NearAI/Bedrock/Codex/Copilot sections
- `ic/CLAUDE.md` — update LLM section
- `CLAUDE.md` — update embeddings/providers references
- `AGENTS.md` — update if it references NearAI providers
- `README.md` — update setup examples
- `docs/guides/EMBEDDINGS_SETUP.md` — remove NearAI embedding provider
- `docs/guides/TENSORZERO_PROXY.md` — ensure it reflects sole provider
- `ic/FEATURE_PARITY.md` — update LLM provider parity entries
- `docs/ops/ROADMAP_2026.md` — mark this item as done

---

## Execution Wave Plan

### Wave 1: Data layer (low risk, no code compilation impact)
1. Strip `providers.json` to single `openai_compatible` entry
2. Update `registry.rs` tests
3. Update `config.toml` template
4. Update `.env.example`

### Wave 2: Config types (medium risk, affects compilation)
5. Simplify `LlmConfig` — remove NearAI/Bedrock/Gemini/Codex fields
6. Simplify `RegistryProviderConfig` — remove OAuth/Codex fields
7. Remove `NearAiConfig`, `GeminiOauthConfig`, `OpenAiCodexConfig`, `CacheRetention`, `OAUTH_PLACEHOLDER`
8. Rewrite `config/llm.rs` `resolve()` — default to `openai_compatible`, remove special backends
9. Verify `cargo check`

### Wave 3: Provider factory (high risk, core pipeline)
10. Rewrite `mod.rs` — remove NearAI/Anthropic/Codex/Gemini/Copilot factory functions
11. Simplify `create_llm_provider()` and `build_provider_chain()`
12. Remove `create_session_manager()` usage from `app.rs`
13. Delete LLM source files (15 files)
14. Verify `cargo check`

### Wave 4: Embeddings + wizard + CLI (medium risk)
15. Remove `NearAiEmbeddings` from embeddings module
16. Update embeddings construction in `app.rs`
17. Strip setup wizard to openai_compatible-only path
18. Update CLI models command
19. Verify `cargo check` + `cargo test`

### Wave 5: Tests + docs (low risk)
20. Fix all broken tests across the codebase
21. Run `cargo test` (unit tests)
22. Update all documentation files
23. Final `cargo clippy` clean

---

## Risk Assessment

| Risk | Severity | Mitigation |
|---|---|---|
| `DEFAULT_MODEL` const used by wizard/config | Medium | Move to config template `selected_model` |
| `SessionManager` used by app.rs startup | High | Trace all usages; remove cleanly |
| NearAI embeddings auto-construction in app.rs | High | Verify embedding provider construction path |
| Decorator chain reads `nearai.*` config fields | Medium | Already partially generic; finish migration |
| Tests throughout codebase mock NearAI config | Medium | Rewrite to use openai_compatible config |
| `rig_adapter.rs` references removed protocols | Low | Only uses `OpenAiCompletions` path |
| Breaking change for existing users with NearAI backend | High | Document in CHANGELOG; provide migration note |

## Backward Compatibility

This is a **breaking change**. Existing tenants using `LLM_BACKEND=nearai` or any removed provider will fail to start. Mitigation:
- The config fallback in `resolve()` should detect unknown backends and fall back to `openai_compatible` with a warning (already exists at line 96-100)
- CHANGELOG entry documenting the removal
- Migration note: set `LLM_BACKEND=openai_compatible` and `LLM_BASE_URL` to your endpoint
