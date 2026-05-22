-- Reflex compiler pattern tracking table.
-- Stores recurring user prompts that have been compiled into WASM micro-skills.

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
