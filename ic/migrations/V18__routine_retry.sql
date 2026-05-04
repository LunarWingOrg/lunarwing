-- Add retry policy columns to routines table.
-- Defaults match RetryPolicy::default(): 3 retries, 60s initial delay, 2x backoff, 1h max.

ALTER TABLE routines ADD COLUMN retry_max_retries INTEGER NOT NULL DEFAULT 3;
ALTER TABLE routines ADD COLUMN retry_initial_delay_secs INTEGER NOT NULL DEFAULT 60;
ALTER TABLE routines ADD COLUMN retry_backoff_multiplier DOUBLE PRECISION NOT NULL DEFAULT 2.0;
ALTER TABLE routines ADD COLUMN retry_max_delay_secs INTEGER NOT NULL DEFAULT 3600;
