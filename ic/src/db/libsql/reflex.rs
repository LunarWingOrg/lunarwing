//! Reflex pattern-related ReflexStore implementation for LibSqlBackend.

use async_trait::async_trait;
use libsql::params;
use uuid::Uuid;

use super::{LibSqlBackend, fmt_ts, get_i64, get_opt_ts, get_text, get_ts};
use crate::db::{ReflexPatternRecord, ReflexStore};
use crate::error::DatabaseError;

use chrono::Utc;

#[async_trait]
impl ReflexStore for LibSqlBackend {
    async fn find_recurring_job_patterns(
        &self,
        min_count: i32,
        limit: i32,
    ) -> Result<Vec<String>, DatabaseError> {
        let conn = self.connect().await?;
        let mut rows = conn
            .query(
                r#"
                SELECT description FROM agent_jobs
                WHERE status = 'completed' AND success = 1
                GROUP BY description
                HAVING COUNT(*) >= ?1
                ORDER BY COUNT(*) DESC
                LIMIT ?2
                "#,
                params![min_count as i64, limit as i64],
            )
            .await
            .map_err(|e| DatabaseError::Query(e.to_string()))?;

        let mut patterns = Vec::new();
        while let Some(row) = rows
            .next()
            .await
            .map_err(|e| DatabaseError::Query(e.to_string()))?
        {
            patterns.push(get_text(&row, 0));
        }
        Ok(patterns)
    }

    async fn upsert_reflex_pattern(
        &self,
        user_id: &str,
        normalized_pattern: &str,
        original_pattern: &str,
        tool_name: &str,
    ) -> Result<(), DatabaseError> {
        let conn = self.connect().await?;
        let now = fmt_ts(&Utc::now());
        conn.execute(
            r#"
                INSERT INTO reflex_patterns
                (id, user_id, normalized_pattern, original_pattern, tool_name, match_count, last_matched_at, created_at, updated_at, status, compilation_attempts)
                VALUES (?1, ?2, ?3, ?4, ?5, 1, ?6, ?6, ?6, 'active', 0)
                ON CONFLICT (user_id, normalized_pattern) DO UPDATE SET
                    match_count = reflex_patterns.match_count + 1,
                    last_matched_at = ?6,
                    updated_at = ?6
                "#,
            params![
                Uuid::new_v4().to_string(),
                user_id,
                normalized_pattern,
                original_pattern,
                tool_name,
                now
            ],
        )
        .await
        .map_err(|e| DatabaseError::Query(e.to_string()))?;
        Ok(())
    }

    async fn get_reflex_pattern(
        &self,
        user_id: &str,
        normalized_pattern: &str,
    ) -> Result<Option<(String, String)>, DatabaseError> {
        let conn = self.connect().await?;
        let mut rows = conn
            .query(
                "SELECT tool_name, status FROM reflex_patterns WHERE user_id = ?1 AND normalized_pattern = ?2",
                params![user_id, normalized_pattern],
            )
            .await
            .map_err(|e| DatabaseError::Query(e.to_string()))?;

        match rows
            .next()
            .await
            .map_err(|e| DatabaseError::Query(e.to_string()))?
        {
            Some(row) => Ok(Some((get_text(&row, 0), get_text(&row, 1)))),
            None => Ok(None),
        }
    }

    async fn list_reflex_patterns(
        &self,
        user_id: &str,
    ) -> Result<Vec<ReflexPatternRecord>, DatabaseError> {
        let conn = self.connect().await?;
        let mut rows = conn
            .query(
                r#"
                SELECT id, user_id, normalized_pattern, original_pattern, tool_name,
                       match_count, last_matched_at, created_at, updated_at, status, compilation_attempts
                FROM reflex_patterns WHERE user_id = ?1 ORDER BY match_count DESC
                "#,
                params![user_id],
            )
            .await
            .map_err(|e| DatabaseError::Query(e.to_string()))?;

        let mut patterns = Vec::new();
        while let Some(row) = rows
            .next()
            .await
            .map_err(|e| DatabaseError::Query(e.to_string()))?
        {
            patterns.push(ReflexPatternRecord {
                id: get_text(&row, 0).parse().unwrap_or_default(),
                user_id: get_text(&row, 1),
                normalized_pattern: get_text(&row, 2),
                original_pattern: get_text(&row, 3),
                tool_name: get_text(&row, 4),
                match_count: get_i64(&row, 5) as i32,
                last_matched_at: get_opt_ts(&row, 6),
                created_at: get_ts(&row, 7),
                updated_at: get_ts(&row, 8),
                status: get_text(&row, 9),
                compilation_attempts: get_i64(&row, 10) as i32,
            });
        }
        Ok(patterns)
    }

    async fn disable_reflex_pattern(&self, id: Uuid) -> Result<bool, DatabaseError> {
        let conn = self.connect().await?;
        let count = conn
            .execute(
                "UPDATE reflex_patterns SET status = 'disabled', updated_at = ?2 WHERE id = ?1",
                params![id.to_string(), fmt_ts(&Utc::now())],
            )
            .await
            .map_err(|e| DatabaseError::Query(e.to_string()))?;
        Ok(count > 0)
    }

    async fn bump_reflex_pattern_match(
        &self,
        user_id: &str,
        normalized_pattern: &str,
    ) -> Result<(), DatabaseError> {
        let conn = self.connect().await?;
        let now = fmt_ts(&Utc::now());
        conn.execute(
            r#"
                UPDATE reflex_patterns
                SET match_count = match_count + 1, last_matched_at = ?3, updated_at = ?3
                WHERE user_id = ?1 AND normalized_pattern = ?2
                "#,
            params![user_id, normalized_pattern, now],
        )
        .await
        .map_err(|e| DatabaseError::Query(e.to_string()))?;
        Ok(())
    }
}
