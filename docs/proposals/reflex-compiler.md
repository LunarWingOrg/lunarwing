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

## Phase 7: CLI Commands

Implemented in `src/cli/reflex.rs`:

```bash
lunarwing reflex list              # Show all patterns (with --disabled, --json)
lunarwing reflex show <id>         # Pattern details
lunarwing reflex delete <id>       # Remove pattern (with --yes for no-confirm)
lunarwing reflex status            # Compiler statistics
```

Also wired into `src/cli/mod.rs` (Command enum) and `src/main.rs` (command dispatch).

## Phase 8: Pattern Cache Refresh

Implemented `spawn_reflex_cache_refresh()` in `src/agent/reflex.rs`:

- Periodic refresh of in-memory pattern cache from database
- Runs on same interval as compiler loop
- Clears and rebuilds cache from active patterns only

## Phase 9: Testing

### Unit Tests (8 tests, all passing)

- `test_normalize_pattern_basic` - whitespace collapse
- `test_normalize_pattern_punctuation` - punctuation stripping
- `test_normalize_pattern_case` - lowercase conversion
- `test_normalize_pattern_empty` - empty input handling
- `test_reflex_router_exact_match` - in-memory routing
- `test_reflex_router_refresh` - DB cache sync (libSQL)
- `test_reflex_store_libsql_crud` - full CRUD cycle (libSQL)
- `test_reflex_store_find_recurring` - pattern detection from job history (libSQL)

### Integration Test Coverage

- End-to-end: create jobs -> detect recurring pattern -> verify DB query returns it
- libSQL backend parity verified (PostgreSQL uses same trait)

### Running Tests

```bash
# Run all reflex tests (unit + integration)
cd ic
cargo test --lib --features libsql reflex -- --nocapture

# Run only unit tests
cargo test --lib reflex -- --nocapture

# Run a specific test
cargo test test_reflex_router_exact_match -- --exact --nocapture

# Full build check
cargo check --all-features
```

## Phase 10: Documentation Updates

- `FEATURE_PARITY.md` - Marked reflex compiler as 🚧 implemented
- `docs/proposals/reflex-compiler.md` - This document (updated)
- Inline code documentation for all public APIs

## Files Modified/Created

| File | Change |
|------|--------|
| `src/db/mod.rs` | Add `ReflexStore` trait + `ReflexPatternRecord` struct |
| `src/db/postgres.rs` | Implement `ReflexStore` for PostgreSQL |
| `src/db/libsql/reflex.rs` | **New** - Implement `ReflexStore` for libSQL |
| `src/db/libsql/mod.rs` | Add `reflex` module |
| `migrations/V19__reflex_patterns.sql` | **New** - PostgreSQL migration |
| `src/db/libsql_migrations.rs` | Add V19 migration |
| `src/agent/reflex.rs` | **New** - Core compiler + router + normalization + tests |
| `src/agent/mod.rs` | Export reflex types, add module |
| `src/agent/agent_loop.rs` | Spawn compiler + cache refresh, add `reflex_router` field |
| `src/agent/dispatcher.rs` | Add fast-path routing before LLM |
| `src/config/agent.rs` | Add `ReflexConfig` + env var parsing |
| `src/config/mod.rs` | Re-export `ReflexConfig` |
| `src/cli/reflex.rs` | **New** - CLI subcommands (list/show/delete/status) |
| `src/cli/mod.rs` | Add `Reflex` Command variant + exports |
| `src/main.rs` | Dispatch `Command::Reflex` to `run_reflex_command` |
| `FEATURE_PARITY.md` | Mark reflex compiler as 🚧 |
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
- [x] Phase 9: Integration Tests
- [x] Phase 10: Documentation Updates (FEATURE_PARITY.md)

**All phases complete. Build passes. 8/8 tests passing.**
