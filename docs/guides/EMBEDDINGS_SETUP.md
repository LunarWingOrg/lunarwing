# Embedded Memory Update

## Configurable Embedding URL and OpenAI-Compatible Provider

Added support for the `openai_compatible` embedding provider, allowing LunarWing to use any OpenAI-compatible embedding endpoint (e.g., TensorZero, local models, third-party providers).

### Changes

- **`ic/src/config/embeddings.rs`** — Added `openai_compatible` provider branch that creates an `OpenAiEmbeddings` instance with a configurable base URL. Falls back to `EMBEDDING_BASE_URL` env var or the settings-level `base_url` field.
- **`ic/src/settings.rs`** — Added `base_url: Option<String>` to `EmbeddingsSettings` for persisting the custom endpoint URL in `settings.json`.
- **`ic/src/setup/wizard.rs`** — Added "OpenAI-compatible (custom URL)" as a provider choice in the onboarding wizard. Instructs the user to set the URL via the web UI or `EMBEDDING_BASE_URL` env var.

### Configuration

Via environment:
```bash
EMBEDDING_ENABLED=true
EMBEDDING_PROVIDER=openai_compatible
EMBEDDING_MODEL=text-embedding-3-small
EMBEDDING_BASE_URL=http://192.168.1.157:3002/openai/v1
OPENAI_API_KEY=your-key
```

Via settings.json:
```json
{
  "embeddings": {
    "enabled": true,
    "provider": "openai_compatible",
    "model": "text-embedding-3-small",
    "base_url": "http://192.168.1.157:3002/openai/v1"
  }
}
```

### Supported Providers

| Provider | Key | Base URL | Notes |
|----------|-----|----------|-------|
| `openai` | `OPENAI_API_KEY` | Default OpenAI API | Standard OpenAI embeddings |
| `lunarwing_cloud` | LunarWing Cloud auth | — | Uses LunarWing Cloud infrastructure |
| `ollama` | — | `OLLAMA_BASE_URL` | Local Ollama instance |
| `openai_compatible` | `OPENAI_API_KEY` | `EMBEDDING_BASE_URL` or settings `base_url` | Any OpenAI-compatible endpoint |
