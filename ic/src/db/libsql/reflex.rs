//! Reflex pattern-related ReflexStore implementation for LibSqlBackend.

use async_trait::async_trait;
use libsql::params;
use uuid::Uuid;

use super::{LibSqlBackend, fmt_ts, get_i64, get_opt_text, get_opt_ts, get_text, get_ts};
use crate::db::{ReflexPatternRecord, ReflexStore};
use crate::error::DatabaseError;

use chrono::Utc;

fn embedding_from_blob(row: &libsql::Row, idx: i32) -> Option<Vec<f32>> {
    let bytes: Vec<u8> = row.get(idx).ok()?;
    if !bytes.len().is_multiple_of(4) {
        return None;
    }
    Some(
        bytes
            .chunks_exact(4)
            .map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]]))
            .collect(),
    )
}

fn embedding_to_blob(embedding: &[f32]) -> Vec<u8> {
    embedding.iter().flat_map(|f| f.to_le_bytes()).collect()
}

fn cosine_similarity(a: &[f32], b: &[f32]) -> f64 {
    if a.len() != b.len() || a.is_empty() {
        return 0.0;
    }
    let mut dot = 0.0f64;
    let mut mag_a = 0.0f64;
    let mut mag_b = 0.0f64;
    for (x, y) in a.iter().zip(b.iter()) {
        let x = *x as f64;
        let y = *y as f64;
        dot += x * y;
        mag_a += x * x;
        mag_b += y * y;
    }
    let denom = mag_a.sqrt() * mag_b.sqrt();
    if denom == 0.0 {
        return 0.0;
    }
    dot / denom
}

fn parse_row(row: &libsql::Row) -> ReflexPatternRecord {
    ReflexPatternRecord {
        id: get_text(row, 0).parse().unwrap_or_default(),
        user_id: get_text(row, 1),
        normalized_pattern: get_text(row, 2),
        original_pattern: get_text(row, 3),
        tool_name: get_text(row, 4),
        match_count: get_i64(row, 5) as i32,
        last_matched_at: get_opt_ts(row, 6),
        created_at: get_ts(row, 7),
        updated_at: get_ts(row, 8),
        status: get_text(row, 9),
        compilation_attempts: get_i64(row, 10) as i32,
        embedding: embedding_from_blob(row, 11),
        embedding_model: get_opt_text(row, 12),
    }
}

const SELECT_COLS: &str = "id, user_id, normalized_pattern, original_pattern, tool_name, \
    match_count, last_matched_at, created_at, updated_at, status, compilation_attempts, \
    embedding, embedding_model";

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
        let sql = format!(
            "SELECT {} FROM reflex_patterns WHERE user_id = ?1 ORDER BY match_count DESC",
            SELECT_COLS
        );
        let mut rows = conn
            .query(&sql, params![user_id])
            .await
            .map_err(|e| DatabaseError::Query(e.to_string()))?;

        let mut patterns = Vec::new();
        while let Some(row) = rows
            .next()
            .await
            .map_err(|e| DatabaseError::Query(e.to_string()))?
        {
            patterns.push(parse_row(&row));
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

    async fn prune_stale_reflex_patterns(
        &self,
        stale_after_days: i32,
        dry_run: bool,
    ) -> Result<Vec<ReflexPatternRecord>, DatabaseError> {
        let conn = self.connect().await?;
        let now = Utc::now();
        let cutoff = fmt_ts(&(now - chrono::Duration::days(stale_after_days as i64)));

        let sql = format!(
            "SELECT {} FROM reflex_patterns \
             WHERE status = 'active' \
               AND COALESCE(last_matched_at, created_at) < ?1 \
             ORDER BY COALESCE(last_matched_at, created_at) ASC",
            SELECT_COLS
        );
        let mut rows = conn
            .query(&sql, params![cutoff])
            .await
            .map_err(|e| DatabaseError::Query(e.to_string()))?;

        let mut stale = Vec::new();
        while let Some(row) = rows
            .next()
            .await
            .map_err(|e| DatabaseError::Query(e.to_string()))?
        {
            stale.push(parse_row(&row));
        }

        if !dry_run && !stale.is_empty() {
            let updated_at = fmt_ts(&now);
            for record in &mut stale {
                conn.execute(
                    "UPDATE reflex_patterns SET status = 'evicted', updated_at = ?2 WHERE id = ?1",
                    params![record.id.to_string(), updated_at.clone()],
                )
                .await
                .map_err(|e| DatabaseError::Query(e.to_string()))?;
                // Reflect the eviction in the returned records so callers see the
                // post-update status (matches the PostgreSQL backend, which re-queries).
                record.status = "evicted".to_string();
                record.updated_at = now;
            }
        }

        Ok(stale)
    }

    async fn update_reflex_pattern_embedding(
        &self,
        user_id: &str,
        normalized_pattern: &str,
        embedding: &[f32],
        model: &str,
    ) -> Result<(), DatabaseError> {
        let conn = self.connect().await?;
        let blob = embedding_to_blob(embedding);
        let now = fmt_ts(&Utc::now());
        conn.execute(
            "UPDATE reflex_patterns SET embedding = ?3, embedding_model = ?4, updated_at = ?5 \
             WHERE user_id = ?1 AND normalized_pattern = ?2",
            params![
                user_id,
                normalized_pattern,
                libsql::Value::Blob(blob),
                model,
                now
            ],
        )
        .await
        .map_err(|e| DatabaseError::Query(e.to_string()))?;
        Ok(())
    }

    async fn semantic_search_reflex_patterns(
        &self,
        user_id: &str,
        query_embedding: &[f32],
        limit: i32,
    ) -> Result<Vec<(ReflexPatternRecord, f64)>, DatabaseError> {
        // libSQL has no pgvector -- load active patterns with embeddings and
        // compute cosine similarity in Rust. The reflex_patterns table is small
        // (hundreds of rows at most), so this is acceptable.
        let conn = self.connect().await?;
        let sql = format!(
            "SELECT {} FROM reflex_patterns \
             WHERE user_id = ?1 AND status = 'active' AND embedding IS NOT NULL \
             ORDER BY match_count DESC",
            SELECT_COLS
        );
        let mut rows = conn
            .query(&sql, params![user_id])
            .await
            .map_err(|e| DatabaseError::Query(e.to_string()))?;

        let mut scored: Vec<(ReflexPatternRecord, f64)> = Vec::new();
        while let Some(row) = rows
            .next()
            .await
            .map_err(|e| DatabaseError::Query(e.to_string()))?
        {
            let record = parse_row(&row);
            if let Some(ref emb) = record.embedding {
                let sim = cosine_similarity(query_embedding, emb);
                scored.push((record, sim));
            }
        }

        scored.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
        scored.truncate(limit as usize);
        Ok(scored)
    }
}
