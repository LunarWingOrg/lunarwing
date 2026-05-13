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
    id UUID PRIMARY KEY,
    user_id TEXT NOT NULL,
    normalized_pattern TEXT NOT NULL,
    original_pattern TEXT NOT NULL,
    tool_name TEXT NOT NULL,
    match_count INTEGER DEFAULT 1,
    last_matched_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    status TEXT DEFAULT 'active',
    compilation_attempts INTEGER DEFAULT 0,
    UNIQUE(user_id, normalized_pattern)
);

CREATE INDEX idx_reflex_patterns_user ON reflex_patterns(user_id, status);
CREATE INDEX idx_reflex_patterns_match ON reflex_patterns(user_id, match_count DESC);
```

### Database Trait Additions

- `find_recurring_job_patterns(min_count, limit)` - descriptions appearing >= N times
- `upsert_reflex_pattern(normalized, tool_name)` - insert or update match count
- `get_reflex_pattern(user_id, normalized)` - lookup by normalized pattern
- `list_reflex_patterns(user_id)` - list all patterns for user
- `disable_reflex_pattern(id)` - soft-delete

## Phase 2: Core Reflex Module

**New file: `src/agent/reflex.rs`**

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

**Pattern normalization:** lowercase + whitespace collapse + punctuation strip
**Matching:** exact normalized match (Phase 1), semantic similarity (Phase 2)
**Compilation:** reuse existing `LlmSoftwareBuilder` with `SoftwareType::WasmTool`

## Phase 3: Dispatcher Integration

Modify `src/agent/dispatcher.rs` to add fast-path check before LLM invocation:

```rust
if let Some(tool_name) = reflex_router.try_route(&user_input).await {
    let output = execute_reflex_tool(tool_name, params).await;
    return Response::from_reflex(output);
}
```

Fallback: if reflex execution fails, fall back to normal LLM path.

## Phase 4: Background Compiler Loop

Spawn in `Agent::run()` alongside existing background tasks:

```rust
tokio::spawn(reflex_compiler_loop(
    store.clone(),
    llm.clone(),
    safety.clone(),
    tools.clone(),
    config.reflex_check_interval,
));
```

**Loop behavior:**
1. Every N minutes, query `find_recurring_job_patterns(3, 5)`
2. For each pattern not already compiled:
   - Check if pattern matches existing tool name -> skip
   - Generate `BuildRequirement` with `SoftwareType::WasmTool`
   - Call `builder.build(&req).await`
   - On success: register tool + persist pattern
   - On failure: increment attempts, disable after 3 failures

## Phase 5: Configuration

```toml
[reflex]
enabled = true
check_interval_secs = 1800
min_match_count = 3
max_patterns_per_run = 5
auto_compile = true
```

## Phase 6: CLI Commands

```bash
lunarwing reflex list
lunarwing reflex show <id>
lunarwing reflex delete <id>
lunarwing reflex compile <desc>
lunarwing reflex status
```

## Phase 7: Testing

- Unit tests: pattern normalization, router matching, DB CRUD
- Integration tests: end-to-end 3x prompt -> compilation -> fast-path execution
- Backend parity: libSQL + PostgreSQL

## Files to Modify

| File | Change |
|------|--------|
| `src/db/mod.rs` | Add reflex pattern trait methods |
| `src/db/postgres.rs` | Implement PostgreSQL CRUD |
| `src/db/libsql/*.rs` | Implement libSQL CRUD |
| `migrations/V19__reflex_patterns.sql` | PostgreSQL migration |
| `src/db/libsql_migrations.rs` | libSQL migration |
| `src/agent/reflex.rs` | **New** - core compiler + router |
| `src/agent/mod.rs` | Export reflex types |
| `src/agent/agent_loop.rs` | Spawn compiler loop |
| `src/agent/dispatcher.rs` | Add fast-path routing |
| `src/config/mod.rs` | Add reflex config |
| `src/cli/mod.rs` | Add reflex subcommands |
| `FEATURE_PARITY.md` | Mark reflex as implemented |

## Risk Mitigation

1. **Compilation failures:** Limit to 3 attempts, then disable
2. **Memory bloat:** Cap patterns at 50 per user, prune oldest
3. **Security:** Compiled tools run in existing WASM sandbox
4. **Performance:** Compiler loop is fully async, doesn't block main agent
