# Semantic Memory Search

LunarWing provides persistent memory for agents with hybrid search combining full-text search (BM25-style keyword matching) and vector search (cosine similarity on embeddings). Results are fused using Reciprocal Rank Fusion (RRF) to produce a single ranked list.

The system lives in `ic/src/workspace/` and is exposed to agents via the `memory_search`, `memory_write`, `memory_read`, and `memory_tree` tools in `ic/src/tools/builtin/memory.rs`.

## Architecture Overview

```
Agent calls memory_search("dark mode preference", limit=5)
  |
  v
Workspace::search()
  |
  +-- embed query via EmbeddingProvider (if enabled)
  |     |
  |     +-- check LRU cache (10,000 entries default)
  |     +-- on miss: call provider API (OpenAI / Ollama / LunarWing Cloud)
  |
  +-- parallel search
  |     |
  |     +-- FTS: PostgreSQL ts_rank_cd / libSQL FTS5
  |     +-- Vector: pgvector cosine distance / libsql_vector_idx
  |
  +-- fuse results (RRF or WeightedScore)
  |
  +-- filter by min_score, sort descending, limit
  |
  v
SearchResult[] { content, score, path, document_id, is_hybrid_match }
```

## Full Pipeline

### Step 1: Content Ingestion

When an agent writes to the workspace, the document is stored and indexed:

```
workspace.write(path, content)
  |
  v
Document stored in memory_documents table
  |
  v
reindex_document():
  1. Chunk document (800-word chunks, 15% overlap)
  2. For each chunk:
     - Generate tsvector (auto-indexed by PostgreSQL / FTS5 trigger for libSQL)
     - Generate embedding via EmbeddingProvider (or None if disabled)
     - Insert into memory_chunks with FTS vector + embedding vector
```

### Step 2: Document Chunking

Documents are split into overlapping chunks for better search recall. Overlap ensures context is preserved across chunk boundaries.

```rust
ChunkConfig {
    chunk_size: 800,          // words per chunk (~800 tokens for English)
    overlap_percent: 0.15,    // 15% overlap between adjacent chunks
    min_chunk_size: 50,       // tiny trailing chunks merge with previous
}
```

Example: a 2,000-word document produces 3 chunks of ~800 words each, with ~120 words of overlap between adjacent chunks.

Source: `ic/src/workspace/chunker.rs`

### Step 3: Embedding Generation

Embeddings convert text into dense vectors that capture semantic meaning. Similar concepts have similar vectors, enabling semantic search beyond keyword matching.

```rust
trait EmbeddingProvider: Send + Sync {
    fn dimension(&self) -> usize;
    fn model_name(&self) -> &str;
    fn max_input_length(&self) -> usize;
    async fn embed(&self, text: &str) -> Result<Vec<f32>, EmbeddingError>;
    async fn embed_batch(&self, texts: &[String]) -> Result<Vec<Vec<f32>>, EmbeddingError>;
}
```

#### Supported Providers

| Provider | Models | Default Dimension | Config |
|----------|--------|-------------------|--------|
| **OpenAI** | `text-embedding-3-small`, `text-embedding-3-large`, `text-embedding-ada-002` | 1536 / 3072 / 1536 | `OPENAI_API_KEY` |
| **Ollama** | `nomic-embed-text`, `mxbai-embed-large`, `all-minilm` | 768 / 1024 / 384 | `OLLAMA_BASE_URL` (default `http://localhost:11434`) |
| **LunarWing Cloud** | Configurable | Configurable | LunarWing Cloud session auth |
| **Mock** | Deterministic | Configurable | Test harness only |

Source: `ic/src/workspace/embeddings.rs`

#### Embedding Cache

An LRU cache wraps the embedding provider to avoid duplicate API calls:

- Default capacity: 10,000 entries
- Approximate memory: `cache_size x dimension x 4 bytes` (payload only)
  - 10,000 x 1,536 floats = ~58 MB for OpenAI small
  - 10,000 x 768 floats = ~29 MB for Ollama nomic
- Configurable via `EMBEDDING_CACHE_SIZE`

Source: `ic/src/workspace/embedding_cache.rs`

### Step 4: Hybrid Search

Search combines two retrieval methods and fuses them into a single ranked list.

#### Full-Text Search (FTS)

**PostgreSQL**: Uses `tsvector` columns with GIN indexes and `ts_rank_cd` for relevance scoring.

```sql
SELECT c.id, c.document_id, d.path, c.content,
       ts_rank_cd(c.content_tsv, plainto_tsquery('english', $query)) as rank
FROM memory_chunks c
JOIN memory_documents d ON d.id = c.document_id
WHERE d.user_id = $user_id
  AND c.content_tsv @@ plainto_tsquery('english', $query)
ORDER BY rank DESC
LIMIT $pre_fusion_limit
```

**libSQL**: Uses FTS5 virtual tables with sync triggers that keep the FTS index updated.

#### Vector Search

**PostgreSQL**: Uses pgvector cosine distance (`<=>` operator).

```sql
SELECT c.id, c.document_id, d.path, c.content,
       1 - (c.embedding <=> $embedding) as similarity
FROM memory_chunks c
JOIN memory_documents d ON d.id = c.document_id
WHERE d.user_id = $user_id
  AND c.embedding IS NOT NULL
ORDER BY c.embedding <=> $embedding
LIMIT $pre_fusion_limit
```

**libSQL**: Uses `libsql_vector_idx` with `F32_BLOB(N)` storage, dimension set dynamically by `ensure_vector_index()` during startup.

After migration V9, PostgreSQL uses brute-force cosine distance (the HNSW index was dropped to support flexible embedding dimensions). This is O(N x D) where D is the embedding dimension.

#### Fusion Strategies

Two strategies for combining FTS and vector results into a unified ranking:

**RRF (Reciprocal Rank Fusion)** -- default:

```
score(d) = SUM( 1 / (k + rank(d)) ) for each method where d appears
```

- k=60 (configurable via `rrf_k`)
- Normalized to [0, 1]
- Documents appearing in both FTS and vector results get boosted scores (the `is_hybrid_match` flag marks these)

**WeightedScore** -- alternative:

```
score(d) = (fts_weight * fts_score) + (vector_weight * vector_score)
```

- Converts ranks to scores via `1/rank`
- Combines with configurable weights (default 0.5/0.5)
- Normalizes by max score

Source: `ic/src/workspace/search.rs`

### Step 5: Agent Access via Memory Tools

Four tools in `ic/src/tools/builtin/memory.rs`:

| Tool | Purpose |
|------|---------|
| `memory_search` | Hybrid FTS + vector search, returns scored results (limit 1-20) |
| `memory_write` | Write to workspace (memory, daily_log, heartbeat, or custom path) |
| `memory_read` | Read any file by path |
| `memory_tree` | View workspace structure as a directory tree |

Search results include:
```json
{
  "content": "User prefers dark mode...",
  "score": 0.95,
  "path": "context/preferences.md",
  "document_id": "uuid",
  "is_hybrid_match": true
}
```

## Database Schema

### PostgreSQL

**`memory_documents`** table:
- `id` (UUID), `user_id` (TEXT), `agent_id` (UUID, nullable)
- `path` (TEXT), `content` (TEXT)
- `created_at`, `updated_at` (TIMESTAMPTZ), `metadata` (JSONB)
- Unique constraint: `(user_id, agent_id, path)`

**`memory_chunks`** table:
- `id` (UUID), `document_id` (UUID FK)
- `chunk_index` (INT), `content` (TEXT)
- `content_tsv` (TSVECTOR, GENERATED, GIN-indexed)
- `embedding` (VECTOR, flexible dimension after V9)

Key migrations:
- `V1__initial.sql`: base schema with documents, chunks, tsvector, pgvector
- `V9__flexible_embedding_dimension.sql`: dropped HNSW index, changed to unbounded `vector` type

### libSQL

Schema mirrors PostgreSQL with SQL dialect translation:
- `UUID` -> `TEXT`
- `TIMESTAMPTZ` -> `TEXT` (ISO-8601)
- `JSONB` -> `TEXT` (JSON string)
- `VECTOR` -> `F32_BLOB(N)` (dynamic dimension via `libsql_vector_idx`)
- `tsvector` + `ts_rank_cd` -> FTS5 virtual table + sync triggers

Source: `ic/src/db/libsql_migrations.rs`

## Multi-Scope Reads

When a workspace has additional read scopes (via `with_additional_read_scopes()`), read operations can span multiple user scopes. A user with scopes `["alice", "shared"]` can read documents from both.

**Identity files are exempt.** System prompt reads identity and configuration files from the primary scope only (`read_primary()`), never from secondary scopes:

| File | Read method | Rationale |
|------|-------------|-----------|
| AGENTS.md, SOUL.md, USER.md, IDENTITY.md, TOOLS.md, BOOTSTRAP.md | `read_primary()` | Per-user identity, prevents silent inheritance |
| MEMORY.md, daily/*.md | `read()` | Shared memory is a feature |

PostgreSQL optimization: single query with `WHERE user_id = ANY($1::text[])`.

## Privacy Layer

Sensitive content can auto-redirect from shared to private scope via an optional `PrivacyClassifier` trait:

```rust
workspace.with_privacy_classifier(Arc::new(PatternPrivacyClassifier::new()))
```

Writes to "shared" with sensitive keywords get redirected to "private". The classifier uses regex patterns; must be explicitly configured.

## Search Configuration

```rust
SearchConfig {
    limit: 10,                          // max results returned
    rrf_k: 60,                          // RRF constant (higher = favor top results more)
    use_fts: true,                      // enable full-text search
    use_vector: true,                   // enable vector search
    min_score: 0.0,                     // threshold [0, 1]
    pre_fusion_limit: 50,               // top-N per method before fusion
    fusion_strategy: FusionStrategy::Rrf,  // Rrf or WeightedScore
    fts_weight: 0.5,                    // WeightedScore only
    vector_weight: 0.5,                 // WeightedScore only
}
```

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `EMBEDDING_ENABLED` | `false` | Enable semantic embeddings |
| `EMBEDDING_PROVIDER` | `openai` | Provider: `openai`, `lunarwing_cloud`, or `ollama` |
| `EMBEDDING_MODEL` | `text-embedding-3-small` | Embedding model name |
| `EMBEDDING_DIMENSION` | Auto-inferred | Override embedding dimension |
| `EMBEDDING_CACHE_SIZE` | `10000` | LRU cache capacity (min 1) |
| `EMBEDDING_BASE_URL` | None | Custom OpenAI-compatible endpoint |
| `OPENAI_API_KEY` | None | API key for OpenAI provider |
| `OLLAMA_BASE_URL` | `http://localhost:11434` | Ollama server URL |

Source: `ic/src/config/embeddings.rs`

## Graceful Degradation

The system is designed to work at multiple capability levels:

1. **Full hybrid search** (embeddings enabled): FTS + vector search + RRF fusion
2. **FTS only** (embeddings disabled): keyword search still works, `use_vector` automatically false
3. **No search** (no database): workspace operates as a read/write filesystem only

When `EMBEDDING_ENABLED=false` (the default), documents are still chunked and FTS-indexed. Only vector embeddings are skipped. Enabling embeddings later will require re-indexing existing documents.

## V2 Engine Integration

The v2 engine (`ic/crates/lunarwing_engine/`) has its own memory layer (`memory/retrieval.rs`) that provides keyword-based context retrieval from project-scoped `MemoryDoc` objects. This is separate from the workspace semantic search:

| System | Scope | Search method | Used by |
|--------|-------|---------------|---------|
| Workspace (`src/workspace/`) | User-scoped, cross-tenant capable | Hybrid FTS + vector with RRF fusion | v1 agent, memory tools, system prompt |
| Engine memory (`crates/lunarwing_engine/src/memory/`) | Project-scoped | Keyword-based retrieval from MemoryDocs | v2 engine execution context |

The v2 engine's `RetrievalEngine` is a lighter-weight system that retrieves relevant MemoryDocs (summaries, lessons, skills) to inject into the execution context. The workspace's full hybrid search remains the primary memory tool for agent-facing search.

## Performance Characteristics

- **Embedding cache hit**: ~0ms (in-memory LRU lookup)
- **Embedding cache miss**: ~50-100ms (OpenAI API round-trip)
- **Chunking**: ~1ms per 10KB document
- **FTS search**: sub-second for <100K chunks (GIN/FTS5 index scan)
- **Vector search**: O(N x D) brute-force cosine after V9, typically <1s for 10K chunks
- **RRF fusion**: O(N log N) sort after combining two ranked lists
- **Cache memory**: ~58 MB for 10,000 x 1,536-dim embeddings (payload only)

## File Reference

| File | Purpose |
|------|---------|
| `ic/src/workspace/mod.rs` | Workspace API, document/chunk CRUD, search orchestration |
| `ic/src/workspace/repository.rs` | PostgreSQL FTS + vector search implementation |
| `ic/src/workspace/embeddings.rs` | EmbeddingProvider trait, 4 implementations |
| `ic/src/workspace/embedding_cache.rs` | LRU caching wrapper |
| `ic/src/workspace/search.rs` | RRF + WeightedScore fusion algorithms |
| `ic/src/workspace/chunker.rs` | Document chunking with overlap |
| `ic/src/workspace/document.rs` | Core types (MemoryDocument, MemoryChunk, well-known paths) |
| `ic/src/workspace/layer.rs` | Memory layers (scoped access, sensitivity classification) |
| `ic/src/workspace/privacy.rs` | Privacy classifier trait for sensitive content detection |
| `ic/src/tools/builtin/memory.rs` | Agent-facing tools (search, read, write, tree) |
| `ic/src/config/embeddings.rs` | Configuration resolver |
| `ic/src/db/libsql/workspace.rs` | libSQL FTS5 + vector search |
| `ic/migrations/V1__initial.sql` | PostgreSQL base schema |
| `ic/migrations/V9__flexible_embedding_dimension.sql` | Flexible vector dimensions |
