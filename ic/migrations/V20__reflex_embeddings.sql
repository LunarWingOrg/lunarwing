-- Add embedding columns to reflex_patterns for semantic routing.
-- Uses pgvector without fixed dimension (same approach as memory_chunks after V9).

ALTER TABLE reflex_patterns ADD COLUMN embedding vector;
ALTER TABLE reflex_patterns ADD COLUMN embedding_model TEXT;
