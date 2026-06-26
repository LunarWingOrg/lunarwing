# BUG: Workspace/Memory Concurrency Failures

**Severity:** High (4 bugs), Medium (2 bugs)
**Found:** 2026-06-03 during v1.1.0 pre-release stress testing
**Status:** Fixed
**Affects:** `ic/src/workspace/`, `ic/src/db/` (both PostgreSQL and libSQL backends)
**Found by:** Sunburst (test tenant, multi-tenant systemd deployment)
**Testing environment:** PostgreSQL 16 (pgvector/pgvector:pg16)

## Summary

Pre-release stress testing uncovered 6 concurrency bugs in the workspace/memory
write path. Under concurrent write loads (8+ simultaneous operations), agents
experienced data loss, silent failures, timeouts, and stale search results.
All 6 bugs are now fixed, with regression tests covering the critical paths.

Normal agent operation (sequential tool calls, occasional concurrent routines)
was never affected. The bugs surfaced only under sustained parallel write loads.

---

## Bug 1: Ghost Writes Under Concurrent Unique-Path Writes (HIGH)

**Symptom:** 8+ parallel writes to distinct paths all returned success, but
data was permanently lost on subsequent reads.

**Root cause:** The `UNIQUE (user_id, agent_id, path)` constraint on
`memory_documents` does not prevent duplicates when `agent_id IS NULL`.
PostgreSQL treats NULLs as distinct in unique constraints, so every concurrent
`INSERT` with `NULL` `agent_id` created a new row rather than conflicting.
Reads using `IS NOT DISTINCT FROM` then found multiple rows, causing
`query_opt` to error or return the wrong row.

The `get_or_create_document_by_path` method compounded the problem: it used
three separate connections (SELECT to check existence, INSERT with
`ON CONFLICT DO NOTHING`, then SELECT again) without a transaction. Under
concurrency, multiple callers would all see "not found" on the first SELECT,
all INSERT successfully (because NULLs don't conflict), and then each get
a different row ID back.

**Fix:** See [Fix: NULL-Safe Unique Constraint](#fix-null-safe-unique-constraint)
and [Fix: Atomic get_or_create_document_by_path](#fix-atomic-get_or_create_document_by_path).

---

## Bug 2: Ghost Writes Under Rapid Sequential Writes (HIGH)

**Symptom:** 9 sequential writes sent in quick succession all returned success,
but files were missing when read immediately afterward.

**Root cause:** Persistence lag from connection pool contention. Writes queued
behind each other in the pool, and read-back happened before all writes
committed. Not permanent data loss -- data appeared after a short delay.

**Fix:** Resolved as a side effect of the connection usage reduction in other
fixes. Writes now use fewer connections per operation, reducing pool pressure.

---

## Bug 3: Write Contention Race on Same-Path Appends (HIGH)

**Symptom:** 6+ concurrent writes to the same path caused
`"query returned unexpected number of rows"` failures and ghost writes. The
`append()` method's own doc comment stated it was "not concurrency-safe."

**Root cause:** `append()` used a read-modify-write pattern across separate
connections: read content on connection A, concatenate in Rust, write the
result back on connection B. Last writer won; all other appends were silently
lost.

**Fix:** See [Fix: Atomic SQL Append](#fix-atomic-sql-append).

---

## Bug 4: Total Timeout at 10+ Concurrent Writes (HIGH)

**Symptom:** 10+ concurrent writes ALL timed out at 60 seconds. The threshold
was exact: 9 concurrent writes succeeded, 10 caused every write to hang until
timeout. This also crashed the web gateway, affecting all users on that
instance.

**Root cause:** `reindex_document()` held database connections while making
sequential network calls to the embedding provider. Each call to
`reindex_document()` consumed 4-6+ connections from a pool of 10:

1. One connection to fetch the document
2. One connection to delete old chunks
3. One connection per chunk to insert, with a **blocking** `provider.embed()`
   network call inside the loop

With 10 concurrent writes, that meant 40-60 connection requests competing for
10 pool slots. The pool starved completely and every pending request hit the
60-second timeout.

**Fix:** See [Fix: Connection-Efficient Reindex](#fix-connection-efficient-reindex).

---

## Bug 5: Search Index Lag Under Load (MEDIUM)

**Symptom:** Freshly written content was not immediately searchable under load.
Search queries returned stale results or no results for content that had been
successfully written.

**Root cause:** `update_document()` committed the new content immediately in
one transaction. Then `reindex_document()` deleted old chunks and re-inserted
new chunks in separate operations. Between the content commit and the chunk
replacement, search queries hit either stale chunks (matching old content) or
zero chunks (after delete, before insert).

**Fix:** See [Fix: Atomic Document + Chunk Update](#fix-atomic-document-and-chunk-update).

---

## Bug 6: Persistence Lag at 16+ Concurrent Writes (MEDIUM, EXPECTED)

**Symptom:** At 16+ concurrent writes, write acknowledgment returned before
all data was queryable by other connections.

**Root cause:** Normal connection pool queueing behavior. With 16 transactions
competing for 10 pool slots, some writes commit later than others. This is
not data loss -- all writes persist successfully, and reads succeed after a
brief delay (typically <1 second).

**Mitigation:** Increase `DATABASE_POOL_SIZE` from the default 10 to 20-25 if
your workload regularly performs many concurrent writes. Set via environment
variable in the tenant's `lunarwing.env`.

This only affects burst workloads with 16+ simultaneous memory writes. Normal
agent operation (sequential tool calls, occasional concurrent routines) is
well within the safe threshold.

---

## Fixes Applied

### Fix: NULL-Safe Unique Constraint

**Migration:** `ic/migrations/V21__fix_null_agent_id_unique_constraint.sql`

The V21 migration:

1. Cleans up duplicate rows created by the old constraint, keeping the oldest
   per `(user_id, agent_id, path)` group
2. Drops the old `unique_path_per_user` constraint
3. Adds a new constraint using `NULLS NOT DISTINCT` (PostgreSQL 15+):

```sql
ALTER TABLE memory_documents
    ADD CONSTRAINT unique_path_per_user
    UNIQUE NULLS NOT DISTINCT (user_id, agent_id, path);
```

For libSQL, an expression unique index achieves the same effect:

```sql
CREATE UNIQUE INDEX ON memory_documents(user_id, COALESCE(agent_id, ''), path)
```

Added in `ic/src/db/libsql_migrations.rs`.

### Fix: Atomic get_or_create_document_by_path

**File:** `ic/src/workspace/repository.rs`, `ic/src/db/libsql/workspace.rs`

Replaced the 3-connection check/insert/fetch sequence with a single atomic
statement.

PostgreSQL uses `INSERT ... ON CONFLICT ON CONSTRAINT` with the named
constraint:

```sql
INSERT INTO memory_documents (id, user_id, agent_id, path, content, ...)
VALUES ($1, $2, $3, $4, '', ...)
ON CONFLICT ON CONSTRAINT unique_path_per_user
DO UPDATE SET id = memory_documents.id
RETURNING *
```

One statement, one connection, fully atomic. The `DO UPDATE SET id = id` trick
makes the `RETURNING *` clause work for both the insert and conflict cases.

libSQL wraps the insert and select in a single transaction on one connection.
The `ON CONFLICT` clause references the expression index columns:

```sql
ON CONFLICT (user_id, COALESCE(agent_id, ''), path) DO NOTHING
```

The subsequent `SELECT` within the same transaction retrieves whichever row
exists (the one just inserted, or the pre-existing one).

Connection usage per `get_or_create`: 2-3 connections reduced to 1.

### Fix: Atomic SQL Append

**Files:** `ic/src/db/mod.rs` (trait), `ic/src/workspace/repository.rs`
(PostgreSQL), `ic/src/db/libsql/workspace.rs` (libSQL),
`ic/src/workspace/mod.rs` (callers)

Added `append_document()` to the `WorkspaceStore` trait. Concatenation now
happens atomically in SQL rather than in Rust across separate connections:

```sql
UPDATE memory_documents
SET content = CASE
    WHEN content = '' THEN $2
    ELSE content || $3 || $2
END,
    updated_at = NOW()
WHERE id = $1
RETURNING content
```

The `$3` parameter is the separator (`\n` for `append()`, `\n\n` for
`append_to_layer()`).

PostgreSQL uses a single `UPDATE ... RETURNING content` statement. libSQL uses
a transaction with `UPDATE` followed by `SELECT` read-back (libSQL does not
support `RETURNING` on all statement types).

The old read-modify-write pattern and its "not concurrency-safe" documentation
comment have been removed.

Trait signature:

```rust
async fn append_document(
    &self,
    id: Uuid,
    content: &str,
    separator: &str,
) -> Result<String, WorkspaceError>;
```

### Fix: Connection-Efficient Reindex

**File:** `ic/src/workspace/mod.rs`

Added a `prepare_chunks()` helper that splits content into chunks and generates
all embeddings concurrently via `futures::future::join_all` **without holding
any database connections**:

```
prepare_chunks(content) -> Vec<(chunk_index, chunk_text, Option<embedding>)>
```

Added `replace_chunks()` to the `WorkspaceStore` trait, which atomically
deletes old chunks and inserts new ones in a single transaction. Both
PostgreSQL and libSQL backends implement this.

The reindex pipeline is now:

1. Fetch document (1 connection, released immediately)
2. Compute all embeddings in parallel (0 connections held)
3. Replace chunks atomically (1 connection/transaction)

Connection usage per write: reduced from ~6+N to ~3. The embedding network
calls no longer block database connections.

Trait signature:

```rust
async fn replace_chunks(
    &self,
    document_id: Uuid,
    chunks: &[(i32, String, Option<Vec<f32>>)],
) -> Result<Vec<Uuid>, WorkspaceError>;
```

### Fix: Atomic Document and Chunk Update

**Files:** `ic/src/db/mod.rs` (trait), `ic/src/workspace/repository.rs`
(PostgreSQL), `ic/src/db/libsql/workspace.rs` (libSQL),
`ic/src/workspace/mod.rs` (callers)

Added `update_document_and_replace_chunks()` to the `WorkspaceStore` trait.
This wraps the content `UPDATE`, chunk `DELETE`, and chunk `INSERT`s in a
single transaction. Search queries never see a content/chunk mismatch --
either old content with old chunks, or new content with new chunks.

`write()` and `write_to_layer()` now call this method instead of separate
`update_document()` + `reindex_document()`.

Trait signature:

```rust
async fn update_document_and_replace_chunks(
    &self,
    id: Uuid,
    content: &str,
    chunks: &[(i32, String, Option<Vec<f32>>)],
) -> Result<(), WorkspaceError>;
```

---

## Regression Tests

Three libSQL-backed concurrency tests in `ic/src/workspace/mod.rs` under
`workspace::tests::concurrency`:

| Test | What it verifies |
|------|------------------|
| `test_concurrent_writes_unique_paths_no_ghost` | 10 concurrent writes to unique paths; all readable immediately |
| `test_concurrent_appends_same_path_no_lost_writes` | 10 concurrent appends to one path; all lines present in final content |
| `test_get_or_create_concurrent_same_path_returns_same_id` | 10 concurrent creates for the same path; all return the same document ID |

Tests use `LibSqlBackend::new_local()` with `tempfile::tempdir()` to get real
cross-connection concurrency (in-memory databases do not share state between
connections).

---

## Stress Test Results

| Test scenario | Before fix | After fix |
|---------------|-----------|-----------|
| 8 concurrent writes, unique paths | All ghost writes | All persisted, immediately readable |
| 6 concurrent appends, same path | 4 failures, 1 ghost write | All succeed, all lines present |
| 10 concurrent writes | All timeout at 60s | All succeed |
| 12 concurrent writes | All timeout at 60s | All succeed, immediately readable |
| 16 concurrent writes | N/A | All succeed, brief persistence lag |
| Concurrent reads | Worked | Still works |
| Concurrent searches | Worked | Still works |
| Sequential operations | Worked | Still works |

---

## Files Changed

| File | Change |
|------|--------|
| `ic/src/db/mod.rs` | Added `replace_chunks`, `append_document`, `update_document_and_replace_chunks` to `WorkspaceStore` trait |
| `ic/src/workspace/repository.rs` | PostgreSQL implementations of new methods; fixed `get_or_create_document_by_path` |
| `ic/src/db/libsql/workspace.rs` | libSQL implementations of new methods; fixed `get_or_create_document_by_path` |
| `ic/src/db/postgres.rs` | Delegation for new `WorkspaceStore` methods |
| `ic/src/workspace/mod.rs` | Refactored `write()`, `append()`, `write_to_layer()`, `append_to_layer()`, `reindex_document()`; added `prepare_chunks()` helper; added regression tests |
| `ic/migrations/V21__fix_null_agent_id_unique_constraint.sql` | PostgreSQL migration: deduplicate rows, add `NULLS NOT DISTINCT` constraint |
| `ic/src/db/libsql_migrations.rs` | libSQL expression unique index for NULL-safe uniqueness |

---

## Key Takeaways

1. **PostgreSQL `UNIQUE` constraints do not prevent NULL duplicates** by
   default. Use `NULLS NOT DISTINCT` (PostgreSQL 15+) or a `COALESCE`
   expression index when nullable columns participate in uniqueness.

2. **Never hold database connections during network I/O.** The embedding
   provider calls were the root cause of pool exhaustion. Compute embeddings
   first, then write results to the database.

3. **Read-modify-write across connections is always a race condition.** If
   concatenation can be done in SQL (`content || separator || new_content`),
   do it there. The database serializes concurrent updates correctly.

4. **Atomic document + chunk replacement eliminates search inconsistency.**
   Wrapping content and chunk updates in a single transaction prevents the
   window where search sees stale or missing chunks.

5. **Connection pool size is a concurrency ceiling.** With N connections and
   M connections per operation, the maximum safe concurrency is roughly N/M.
   Reducing M (connections per operation) is more effective than increasing N.
