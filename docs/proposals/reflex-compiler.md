# Reflex Compiler Implementation Plan

## Overview

The Reflex Compiler detects recurring user prompts and compiles them into optimized WASM micro-skills, bypassing the LLM entirely for known patterns. This provides sub-100ms responses for recurring tasks versus multi-second LLM latency.

## Architecture

```
User Input
    |
    v
[ReflexRouter] --(fast path)--> [Compiled WASM Tool] --> Response
    | (miss)
    v
[Normal LLM Path]
    |
    v
[Background ReflexCompiler] --(periodic scan)--> [New WASM Tools]
```

## Phase 1: Database Schema

### New Table: `reflex_patterns`

```sql
CREATE TABLE reflex_patterns (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id TEXT NOT NULL,
    normalized_pattern TEXT NOT NULL,
    original_pattern TEXT NOT NULL,
    tool_name TEXT NOT NULL,
    match_count INTEGER NOT NULL DEFAULT 1,
    last_matched_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    status TEXT NOT NULL DEFAULT 'active',
    compilation_attempts INTEGER NOT NULL DEFAULT 0,
    UNIQUE(user_id, normalized_pattern)
);

CREATE INDEX idx_reflex_patterns_user ON reflex_patterns(user_id, status);
CREATE INDEX idx_reflex_patterns_match ON reflex_patterns(user_id, match_count DESC);
CREATE INDEX idx_reflex_patterns_tool ON reflex_patterns(tool_name);
```

### Database Trait Additions

- `find_recurring_job_patterns(min_count, limit)` - descriptions appearing >= N times
- `upsert_reflex_pattern(user_id, normalized, original, tool_name)` - insert or update match count
- `get_reflex_pattern(user_id, normalized)` - lookup by normalized pattern
- `list_reflex_patterns(user_id)` - list all patterns for user
- `disable_reflex_pattern(id)` - soft-delete
- `bump_reflex_pattern_match(user_id, normalized)` - increment match count

### Migrations

- PostgreSQL: `migrations/V19__reflex_patterns.sql`
- libSQL: `src/db/libsql_migrations.rs` (version 19)

## Phase 2: Core Reflex Module

**New file: `src/agent/reflex.rs`**

### Components

```rust
pub struct ReflexCompiler {
    builder: Arc<dyn SoftwareBuilder>,
    store: Arc<dyn Database>,
    check_interval: Duration,
    min_match_count: u32,
    max_patterns_per_run: usize,
}

pub struct ReflexRouter {
    patterns: Arc<RwLock<HashMap<String, String>>>, // normalized -> tool_name
}
```

### Pattern Normalization

- lowercase + whitespace collapse + punctuation strip
- Example: `"Hello, World!!!"` -> `"hello world"`

### Matching Strategy

- Phase 1: Exact normalized match
- Phase 2 (future): Semantic similarity via embeddings

### Compilation

- Reuse existing `LlmSoftwareBuilder` with `SoftwareType::WasmTool`
- Generate deterministic tool names: `reflex_{uuid}`

## Phase 3: Dispatcher Integration

Modify `src/agent/dispatcher.rs` to add fast-path check before LLM invocation:

```rust
if let Some(tool_name) = self.reflex_router.try_route(&message.content).await {
    tracing::info!("Reflex fast-path: routing to compiled tool '{}'", tool_name);
    let params = serde_json::json!({"input": message.content});
    match self.execute_chat_tool(&tool_name, &params, &job_ctx).await {
        Ok(output) => return Ok(AgenticLoopResult::Response(output)),
        Err(e) => tracing::warn!("Reflex tool failed, falling back to LLM: {}", e),
    }
}
```

**Fallback:** If reflex execution fails, fall back to normal LLM path.

## Phase 4: Background Compiler Loop

Spawn in `Agent::run()` alongside existing background tasks (heartbeat, routine engine):

```rust
let _reflex_handle = if self.config.reflex.enabled {
    if let (Some(store), Some(builder)) = (self.store(), self.deps.builder.clone()) {
        Some(crate::agent::reflex::spawn_reflex_compiler(
            builder,
            Arc::clone(store),
            self.config.reflex.check_interval,
            self.config.reflex.min_match_count,
            self.config.reflex.max_patterns_per_run,
        ))
    } else {
        tracing::warn!("Reflex compiler enabled but store or builder not available");
        None
    }
} else {
    None
};
```

**Loop behavior:**
1. Every N minutes, query `find_recurring_job_patterns(min_count, max_patterns)`
2. For each pattern not already compiled:
   - Check if pattern matches existing tool name -> skip
   - Generate `BuildRequirement` with `SoftwareType::WasmTool`
   - Call `builder.build(&req).await`
   - On success: register tool + persist pattern mapping
   - On failure: increment `compilation_attempts`, disable after 3 failures

## Phase 5: Configuration

**New struct: `ReflexConfig`**

```rust
pub struct ReflexConfig {
    pub enabled: bool,
    pub check_interval: Duration,
    pub min_match_count: u32,
    pub max_patterns_per_run: usize,
}
```

**Environment variables:**
- `REFLEX_COMPILER_ENABLED` - Enable/disable (default: false)
- `REFLEX_COMPILER_INTERVAL_SECS` - Check interval (default: 1800)
- `REFLEX_MIN_MATCH_COUNT` - Minimum matches before compilation (default: 3)
- `REFLEX_MAX_PATTERNS_PER_RUN` - Max patterns per check cycle (default: 5)

**Added to `AgentConfig`:**
```rust
pub reflex: ReflexConfig,
```

## Phase 6: Agent Loop Integration

**Modified `Agent` struct:**
```rust
pub(super) reflex_router: Arc<crate::agent::reflex::ReflexRouter>,
```

**Initialization in `Agent::new()`:**
```rust
reflex_router: Arc::new(crate::agent::reflex::ReflexRouter::new()),
```

## Phase 7: CLI Commands (Future)

```bash
lunarwing reflex list              # Show all patterns
lunarwing reflex show <id>         # Pattern details
lunarwing reflex delete <id>       # Remove pattern + compiled tool
lunarwing reflex compile <desc>    # Manually trigger compilation
lunarwing reflex status            # Compiler loop status
```

## Phase 8: Pattern Cache Refresh (Future)

- Periodic refresh of in-memory pattern cache from database
- Trigger refresh after successful compilation
- Configurable cache TTL

## Phase 9: Testing

### Unit Tests (Implemented)

- Pattern normalization edge cases
- ReflexRouter exact matching
- Database CRUD operations

### Integration Tests (Future)

- End-to-end: submit same prompt 3x -> verify reflex compilation -> verify fast-path execution
- Fallback: reflex failure -> normal LLM path
- libSQL + PostgreSQL backend parity

## Phase 10: Documentation Updates

- `FEATURE_PARITY.md` - Mark reflex as implemented
- `docs/proposals/reflex-compiler.md` - This document
- Inline code documentation for public APIs

## Files Modified/Created

| File | Change |
|------|--------|
| `src/db/mod.rs` | Add `ReflexStore` trait + `ReflexPatternRecord` struct |
| `src/db/postgres.rs` | Implement `ReflexStore` for PostgreSQL |
| `src/db/libsql/reflex.rs` | **New** - Implement `ReflexStore` for libSQL |
| `src/db/libsql/mod.rs` | Add `reflex` module |
| `migrations/V19__reflex_patterns.sql` | **New** - PostgreSQL migration |
| `src/db/libsql_migrations.rs` | Add V19 migration |
| `src/agent/reflex.rs` | **New** - Core compiler + router + normalization |
| `src/agent/mod.rs` | Export reflex types, add module |
| `src/agent/agent_loop.rs` | Spawn compiler loop, add `reflex_router` field |
| `src/agent/dispatcher.rs` | Add fast-path routing before LLM |
| `src/config/agent.rs` | Add `ReflexConfig` + env var parsing |
| `src/config/mod.rs` | Re-export `ReflexConfig` |
| `docs/proposals/reflex-compiler.md` | **New** - This implementation plan |

## Risk Mitigation

1. **Compilation failures:** Limit to 3 attempts, then disable
2. **Memory bloat:** Cap patterns at 50 per user, prune oldest
3. **Security:** Compiled tools run in existing WASM sandbox with same capability restrictions
4. **Performance:** Compiler loop is fully async, runs on cheap LLM, doesn't block main agent
5. **Fallback:** Fast-path failures automatically fall back to normal LLM path

## Implementation Status

- [x] Phase 1: Database Schema
- [x] Phase 2: Core Reflex Module
- [x] Phase 3: Dispatcher Integration
- [x] Phase 4: Background Compiler Loop
- [x] Phase 5: Configuration
- [x] Phase 6: Agent Loop Integration
- [x] Phase 7: CLI Commands
- [x] Phase 8: Pattern Cache Refresh
- [x] Phase 9: Unit Tests
- [ ] Phase 9: Integration Tests
- [x] Phase 10: Documentation Updates (FEATURE_PARITY.md)
