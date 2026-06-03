-- Fix the unique constraint on memory_documents to handle NULL agent_id.
--
-- PostgreSQL treats NULLs as distinct in unique constraints, so
-- UNIQUE (user_id, agent_id, path) allowed duplicate rows when
-- agent_id was NULL. This caused "query returned an unexpected
-- number of rows" errors under concurrent writes.
--
-- Step 1: Remove duplicates, keeping the oldest row per (user_id, agent_id, path).
DELETE FROM memory_chunks
WHERE document_id IN (
    SELECT id FROM memory_documents
    WHERE id NOT IN (
        SELECT DISTINCT ON (user_id, COALESCE(agent_id::text, ''), path) id
        FROM memory_documents
        ORDER BY user_id, COALESCE(agent_id::text, ''), path, created_at ASC
    )
);

DELETE FROM memory_documents
WHERE id NOT IN (
    SELECT DISTINCT ON (user_id, COALESCE(agent_id::text, ''), path) id
    FROM memory_documents
    ORDER BY user_id, COALESCE(agent_id::text, ''), path, created_at ASC
);

-- Step 2: Replace the constraint with one that treats NULLs as equal.
ALTER TABLE memory_documents
    DROP CONSTRAINT unique_path_per_user;

ALTER TABLE memory_documents
    ADD CONSTRAINT unique_path_per_user
    UNIQUE NULLS NOT DISTINCT (user_id, agent_id, path);
