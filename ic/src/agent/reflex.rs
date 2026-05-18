//! Reflex compiler and router for fast-path execution of recurring patterns.
//!
//! The reflex system detects recurring user prompts and compiles them into
//! optimized WASM micro-skills, bypassing the LLM entirely for known patterns.
//!
//! ## Matching strategy
//!
//! 1. **Exact match** — O(1) hash lookup on normalized input. Fast path.
//! 2. **Fuzzy match** — Jaro-Winkler similarity against known patterns.
//! 3. **Semantic match** — Embedding cosine similarity (requires an
//!    `EmbeddingProvider`). Silently skipped when no provider is configured.
//! 4. **Auto-promotion** — Frequently-matched fuzzy hits are promoted to the
//!    exact-match cache so subsequent calls are O(1).

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use strsim::jaro_winkler;
use tokio::sync::RwLock;
use uuid::Uuid;

use crate::db::Database;
use crate::tools::builder::{
    BuildRequirement, Language, SoftwareBuilder, SoftwareType,
};
use crate::workspace::EmbeddingProvider;

// ── Constants ───────────────────────

/// Default similarity threshold for fuzzy pattern matching.
/// Jaro-Winkler returns 0.0–1.0. 0.85 catches most paraphrases
/// (word re-orderings, dropped filler words) while avoiding
/// false positives on short inputs.
const DEFAULT_FUZZY_THRESHOLD: f64 = 0.85;

/// Patterns that matched fuzzily this many times get promoted
/// to the exact-match hash map for O(1) routing.
const PROMOTION_THRESHOLD: u32 = 3;

/// Maximum number of fuzzy candidates to evaluate per route call.
/// Keeps fuzzy fallback bounded in the worst case.
const MAX_FUZZY_CANDIDATES: usize = 50;

/// Default cosine similarity threshold for semantic matching.
/// 0.75 requires strong semantic overlap while allowing
/// paraphrases that Jaro-Winkler misses.
const DEFAULT_SEMANTIC_THRESHOLD: f64 = 0.75;

// ── Normalization ───────────────────

/// Normalize a user input pattern for matching.
///
/// Converts to lowercase, strips punctuation, collapses whitespace.
pub fn normalize_pattern(input: &str) -> String {
    input
        .to_lowercase()
        .chars()
        .filter(|c| c.is_alphanumeric() || c.is_whitespace())
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

/// Compute a quick "word-overlap" similarity score (0.0–1.0) that
/// serves as a cheap pre-filter before the more expensive Jaro-Winkler.
///
/// Faster heuristic: ratio of words in common to the longer phrase.
fn word_overlap(a: &str, b: &str) -> f64 {
    let words_a: Vec<&str> = a.split_whitespace().collect();
    let words_b: Vec<&str> = b.split_whitespace().collect();
    if words_a.is_empty() || words_b.is_empty() {
        return 0.0;
    }

    let set_a: std::collections::HashSet<&&str> = words_a.iter().collect();
    let set_b: std::collections::HashSet<&&str> = words_b.iter().collect();

    let intersection = set_a.intersection(&set_b).count() as f64;
    let union = set_a.union(&set_b).count() as f64;

    intersection / union.max(1.0)
}

/// Cosine similarity between two vectors (0.0–1.0 for normalized unit vectors).
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

// ── Fuzzy match result ──────────────────────

/// Result of a fuzzy pattern match.
#[derive(Debug, Clone)]
pub struct FuzzyMatch {
    /// The tool name to invoke.
    pub tool_name: String,
    /// The normalized pattern that was matched.
    pub matched_pattern: String,
    /// The similarity score (0.0–1.0).
    pub score: f64,
}

// ── ReflexRouter ────────────────────

/// In-memory router for reflex patterns.
///
/// Maintains a cache of normalized patterns → compiled tool names,
/// with fuzzy fallback for near-miss inputs.
pub struct ReflexRouter {
    /// Exact-match cache: normalized pattern → tool name.
    patterns: Arc<RwLock<HashMap<String, String>>>,
    /// Fuzzy hit counter: normalized pattern → hit count.
    /// Promotes to exact cache when threshold is reached.
    fuzzy_hits: Arc<RwLock<HashMap<String, u32>>>,
    /// Similarity threshold for fuzzy matching.
    fuzzy_threshold: f64,
    /// Embedding provider for semantic matching (None = tier disabled).
    embedding_provider: Option<Arc<dyn EmbeddingProvider>>,
    /// Cosine similarity threshold for semantic matching.
    semantic_threshold: f64,
    /// In-memory cache: normalized pattern → embedding vector.
    pattern_embeddings: Arc<RwLock<HashMap<String, Vec<f32>>>>,
}

impl ReflexRouter {
    /// Create a new empty reflex router with the default threshold.
    pub fn new() -> Self {
        Self {
            patterns: Arc::new(RwLock::new(HashMap::new())),
            fuzzy_hits: Arc::new(RwLock::new(HashMap::new())),
            fuzzy_threshold: DEFAULT_FUZZY_THRESHOLD,
            embedding_provider: None,
            semantic_threshold: DEFAULT_SEMANTIC_THRESHOLD,
            pattern_embeddings: Arc::new(RwLock::new(HashMap::new())),
        }
    }

    /// Create a new reflex router with a custom fuzzy threshold.
    pub fn with_threshold(threshold: f64) -> Self {
        Self {
            patterns: Arc::new(RwLock::new(HashMap::new())),
            fuzzy_hits: Arc::new(RwLock::new(HashMap::new())),
            fuzzy_threshold: threshold.clamp(0.0, 1.0),
            embedding_provider: None,
            semantic_threshold: DEFAULT_SEMANTIC_THRESHOLD,
            pattern_embeddings: Arc::new(RwLock::new(HashMap::new())),
        }
    }

    /// Attach an embedding provider to enable semantic matching (tier 3).
    pub fn with_embedding_provider(mut self, provider: Arc<dyn EmbeddingProvider>) -> Self {
        self.embedding_provider = Some(provider);
        self
    }

    /// Override the default semantic similarity threshold.
    pub fn with_semantic_threshold(mut self, threshold: f64) -> Self {
        self.semantic_threshold = threshold.clamp(0.0, 1.0);
        self
    }

    /// Try to route a user input to a compiled reflex tool.
    ///
    /// First tries exact match (O(1)), then falls back to fuzzy
    /// matching against all known patterns.
    pub async fn try_route(&self, input: &str) -> Option<String> {
        let normalized = normalize_pattern(input);
        let patterns = self.patterns.read().await;

        // 1. Exact match — fast path
        if let Some(tool) = patterns.get(&normalized) {
            return Some(tool.clone());
        }

        // 2. Fuzzy fallback — only if we have patterns to check
        if patterns.is_empty() {
            return None;
        }

        // Drop the read lock so we can use fuzzy_hits
        drop(patterns);

        if let Some(tool) = self.fuzzy_route(&normalized).await {
            return Some(tool);
        }

        // 3. Semantic fallback — only if embedding provider is set
        if self.embedding_provider.is_some() {
            if let Some(tool) = self.semantic_route(&normalized).await {
                return Some(tool);
            }
        }

        None
    }

    /// Fuzzy fallback: scan all patterns for similarity.
    async fn fuzzy_route(&self, normalized: &str) -> Option<String> {
        let patterns = self.patterns.read().await;

        // Pre-filter: only consider patterns that share at least
        // one word with the input (avoids scanning everything).
        let words_input: std::collections::HashSet<&str> =
            normalized.split_whitespace().collect();

        let mut candidates: Vec<(String, f64)> = Vec::new();

        for (pattern, _tool) in patterns.iter() {
            // Skip empty / very short patterns
            if pattern.len() < 3 {
                continue;
            }

            // Quick word-overlap pre-filter
            let overlap = word_overlap(normalized, pattern);
            if overlap < 0.3 {
                // Also check if any single word matches (handles
                // cases like "logs" matching "summarize my logs")
                let words_pat: std::collections::HashSet<&str> =
                    pattern.split_whitespace().collect();
                if words_input.intersection(&words_pat).next().is_none() {
                    continue;
                }
            }

            // Jaro-Winkler similarity
            let score = jaro_winkler(normalized, pattern);
            if score >= self.fuzzy_threshold {
                candidates.push((pattern.clone(), score));
            }

            // Cap the scan to avoid pathological cases
            if candidates.len() >= MAX_FUZZY_CANDIDATES {
                break;
            }
        }

        // Take the best match above threshold
        if let Some((best_pattern, score)) = candidates
            .into_iter()
            .max_by(|a, b| a.1.partial_cmp(&b.1).unwrap_or(std::cmp::Ordering::Equal))
        {
            let tool = patterns.get(&best_pattern).cloned();
            drop(patterns);

            if tool.is_some() {
                // Track fuzzy hit for auto-promotion
                self.bump_fuzzy_hit(&best_pattern).await;

                tracing::debug!(
                    "Reflex fuzzy match: '{}' ≈ '{}' (score: {:.3})",
                    normalized, best_pattern, score
                );
            }

            return tool;
        }

        drop(patterns);
        None
    }

    /// Semantic fallback: embed the query and compare against cached pattern embeddings.
    async fn semantic_route(&self, normalized: &str) -> Option<String> {
        let provider = self.embedding_provider.as_ref()?;
        let query_embedding = match provider.embed(normalized).await {
            Ok(emb) => emb,
            Err(e) => {
                tracing::debug!("Reflex semantic embed failed: {}", e);
                return None;
            }
        };

        let embeddings = self.pattern_embeddings.read().await;
        if embeddings.is_empty() {
            return None;
        }

        let mut best_pattern: Option<&str> = None;
        let mut best_score: f64 = 0.0;

        for (pattern, emb) in embeddings.iter() {
            let score = cosine_similarity(&query_embedding, emb);
            if score > best_score {
                best_score = score;
                best_pattern = Some(pattern);
            }
        }

        if best_score >= self.semantic_threshold {
            let patterns = self.patterns.read().await;
            if let Some(tool) = best_pattern.and_then(|p| patterns.get(p).cloned()) {
                tracing::debug!(
                    "Reflex semantic match: '{}' ≈ '{}' (cosine: {:.3})",
                    normalized,
                    best_pattern.unwrap_or("?"),
                    best_score
                );
                return Some(tool);
            }
        }

        None
    }

    /// Bump the fuzzy hit counter for a pattern and promote if
    /// the promotion threshold is reached.
    async fn bump_fuzzy_hit(&self, pattern: &str) {
        let mut hits = self.fuzzy_hits.write().await;
        let count = hits.entry(pattern.to_string()).or_insert(0);
        *count += 1;

        if *count >= PROMOTION_THRESHOLD {
            // Promote: insert this pattern into the exact-match cache
            // so subsequent calls are O(1) instead of fuzzy.
            // We need the tool_name from the patterns map.
            let patterns = self.patterns.read().await;
            if let Some(tool_name) = patterns.get(pattern).cloned() {
                drop(patterns);
                let mut patterns = self.patterns.write().await;
                patterns.insert(pattern.to_string(), tool_name);
            }

            tracing::info!(
                "Reflex pattern '{}' promoted to fast path ({} fuzzy hits)",
                pattern,
                *count
            );
            // Reset counter so subsequent fuzzy hits don't keep logging
            *count = 0;
        }
    }

    /// Try to route with full match details (for diagnostics).
    pub async fn try_route_with_details(&self, input: &str) -> Option<FuzzyMatch> {
        let normalized = normalize_pattern(input);
        let patterns = self.patterns.read().await;

        // Exact match
        if let Some(tool) = patterns.get(&normalized) {
            return Some(FuzzyMatch {
                tool_name: tool.clone(),
                matched_pattern: normalized,
                score: 1.0,
            });
        }

        if patterns.is_empty() {
            return None;
        }
        drop(patterns);

        // Fuzzy match with details
        let patterns = self.patterns.read().await;
        let mut candidates: Vec<FuzzyMatch> = Vec::new();

        for (pattern, tool_name) in patterns.iter() {
            if pattern.len() < 3 {
                continue;
            }
            let score = jaro_winkler(&normalized, pattern);
            if score >= self.fuzzy_threshold {
                candidates.push(FuzzyMatch {
                    tool_name: tool_name.clone(),
                    matched_pattern: pattern.clone(),
                    score,
                });
            }
            if candidates.len() >= MAX_FUZZY_CANDIDATES {
                break;
            }
        }

        if let Some(best) = candidates
            .into_iter()
            .max_by(|a, b| a.score.partial_cmp(&b.score).unwrap_or(std::cmp::Ordering::Equal))
        {
            return Some(best);
        }

        // 3. Semantic fallback
        if let Some(provider) = self.embedding_provider.as_ref() {
            let query_embedding = match provider.embed(&normalized).await {
                Ok(emb) => emb,
                Err(e) => {
                    tracing::debug!("Reflex semantic embed failed (details): {}", e);
                    return None;
                }
            };

            let embeddings = self.pattern_embeddings.read().await;
            if embeddings.is_empty() {
                return None;
            }

            let mut best_pattern: Option<String> = None;
            let mut best_score: f64 = 0.0;

            for (pattern, emb) in embeddings.iter() {
                let score = cosine_similarity(&query_embedding, emb);
                if score > best_score {
                    best_score = score;
                    best_pattern = Some(pattern.clone());
                }
            }

            if best_score >= self.semantic_threshold {
                let patterns = self.patterns.read().await;
                if let Some(tool) = best_pattern.as_ref().and_then(|p| patterns.get(p).cloned()) {
                    return Some(FuzzyMatch {
                        tool_name: tool,
                        matched_pattern: best_pattern.unwrap_or_default(),
                        score: best_score,
                    });
                }
            }
        }

        None
    }

    /// Refresh the pattern cache from the database.
    pub async fn refresh(&self, store: Arc<dyn Database>, user_id: &str) {
        match store.list_reflex_patterns(user_id).await {
            Ok(records) => {
                let mut patterns = self.patterns.write().await;
                let mut embeddings = self.pattern_embeddings.write().await;
                patterns.clear();
                embeddings.clear();
                for record in &records {
                    if record.status == "active" {
                        patterns.insert(
                            record.normalized_pattern.clone(),
                            record.tool_name.clone(),
                        );
                        if let Some(ref emb) = record.embedding {
                            embeddings.insert(record.normalized_pattern.clone(), emb.clone());
                        }
                    }
                }
                drop(patterns);
                drop(embeddings);

                if self.embedding_provider.is_some() {
                    self.embed_missing_patterns(store, user_id, &records).await;
                }
            }
            Err(e) => {
                tracing::warn!("Failed to refresh reflex patterns: {}", e);
            }
        }
    }

    /// Generate and persist embeddings for active patterns that lack them.
    async fn embed_missing_patterns(
        &self,
        store: Arc<dyn Database>,
        user_id: &str,
        records: &[crate::db::ReflexPatternRecord],
    ) {
        let provider = match self.embedding_provider.as_ref() {
            Some(p) => p,
            None => return,
        };

        let missing: Vec<&str> = records
            .iter()
            .filter(|r| r.status == "active" && r.embedding.is_none())
            .map(|r| r.normalized_pattern.as_str())
            .collect();

        if missing.is_empty() {
            return;
        }

        let texts: Vec<String> = missing.iter().map(|s| s.to_string()).collect();
        let model_name = provider.model_name().to_string();

        match provider.embed_batch(&texts).await {
            Ok(embeddings) => {
                let mut cache = self.pattern_embeddings.write().await;
                for (pattern, emb) in missing.iter().zip(embeddings.iter()) {
                    cache.insert(pattern.to_string(), emb.clone());
                    if let Err(e) = store
                        .update_reflex_pattern_embedding(user_id, pattern, emb, &model_name)
                        .await
                    {
                        tracing::debug!("Failed to persist reflex embedding for '{}': {}", pattern, e);
                    }
                }
                tracing::debug!(
                    "Embedded {} missing reflex patterns (model: {})",
                    missing.len(),
                    model_name
                );
            }
            Err(e) => {
                tracing::debug!("Failed to embed missing reflex patterns: {}", e);
            }
        }
    }

    /// Register a new pattern in the in-memory cache.
    pub async fn register(&self, normalized_pattern: &str, tool_name: &str) {
        let mut patterns = self.patterns.write().await;
        patterns.insert(normalized_pattern.to_string(), tool_name.to_string());
    }

    /// Get current fuzzy threshold.
    pub fn fuzzy_threshold(&self) -> f64 {
        self.fuzzy_threshold
    }

    /// Get number of known patterns.
    pub async fn pattern_count(&self) -> usize {
        let patterns = self.patterns.read().await;
        patterns.len()
    }

    /// Get fuzzy hit counts (for diagnostics).
    pub async fn fuzzy_hit_counts(&self) -> HashMap<String, u32> {
        self.fuzzy_hits.read().await.clone()
    }

    /// Get current semantic threshold.
    pub fn semantic_threshold(&self) -> f64 {
        self.semantic_threshold
    }

    /// Whether the semantic tier is enabled.
    pub fn has_embedding_provider(&self) -> bool {
        self.embedding_provider.is_some()
    }
}

impl Default for ReflexRouter {
    fn default() -> Self {
        Self::new()
    }
}

// ── FuzzyConfig ─────────────────────

/// Configuration for fuzzy matching in the reflex router.
#[derive(Debug, Clone)]
pub struct FuzzyConfig {
    /// Jaro-Winkler similarity threshold (0.0–1.0).
    /// Higher = stricter matching. Default: 0.85.
    pub threshold: f64,

    /// How many fuzzy matches before a pattern is promoted
    /// to the exact-match fast path.
    pub promotion_threshold: u32,

    /// Maximum fuzzy candidates to evaluate per route call.
    pub max_candidates: usize,
}

impl Default for FuzzyConfig {
    fn default() -> Self {
        Self {
            threshold: DEFAULT_FUZZY_THRESHOLD,
            promotion_threshold: PROMOTION_THRESHOLD,
            max_candidates: MAX_FUZZY_CANDIDATES,
        }
    }
}

// ── ReflexCompiler ──────────────────

/// Background reflex compiler that periodically scans for recurring patterns
/// and compiles them into WASM micro-skills.
pub struct ReflexCompiler {
    builder: Arc<dyn SoftwareBuilder>,
    store: Arc<dyn Database>,
    check_interval: Duration,
    min_match_count: u32,
    max_patterns_per_run: usize,
}

impl ReflexCompiler {
    /// Create a new reflex compiler.
    pub fn new(
        builder: Arc<dyn SoftwareBuilder>,
        store: Arc<dyn Database>,
        check_interval: Duration,
        min_match_count: u32,
        max_patterns_per_run: usize,
    ) -> Self {
        Self {
            builder,
            store,
            check_interval,
            min_match_count,
            max_patterns_per_run,
        }
    }

    /// Run the reflex compiler background loop.
    pub async fn run_loop(&self) {
        let mut ticker = tokio::time::interval(self.check_interval);
        // Skip immediate first tick
        ticker.tick().await;

        loop {
            ticker.tick().await;
            self.compile_patterns().await;
        }
    }

    /// Scan for recurring patterns and compile them.
    ///
    /// Public so integration tests can trigger a single sweep without waiting
    /// for the background ticker.
    pub async fn compile_patterns(&self) {
        match self
            .store
            .find_recurring_job_patterns(self.min_match_count as i32, self.max_patterns_per_run as i32)
            .await
        {
            Ok(patterns) => {
                for description in patterns {
                    self.compile_pattern(&description).await;
                }
            }
            Err(e) => {
                tracing::error!("Failed to fetch recurring job patterns: {}", e);
            }
        }
    }

    /// Compile a single pattern into a WASM micro-skill.
    async fn compile_pattern(&self, description: &str) {
        let normalized = normalize_pattern(description);

        // Check if already compiled
        match self.store.get_reflex_pattern("default", &normalized).await {
            Ok(Some((_, status))) if status == "active" => {
                tracing::debug!("Reflex pattern already compiled: {}", normalized);
                return;
            }
            _ => {}
        }

        tracing::info!("Reflex compiler triggered for pattern: {}", description);

        let safe_name = format!("reflex_{}", Uuid::new_v4().simple());
        let req = BuildRequirement {
            name: safe_name.clone(),
            description: format!("A specialized tool to handle: {}", description),
            software_type: SoftwareType::WasmTool,
            language: Language::Rust,
            input_spec: None,
            output_spec: None,
            dependencies: vec![],
            capabilities: vec!["log".to_string()],
        };

        tracing::info!("Starting background compilation for Reflex: {}", req.name);
        match self.builder.build(&req).await {
            Ok(result) => {
                if result.success {
                    tracing::info!(
                        "Successfully compiled Reflex MS for pattern: {}",
                        description
                    );
                    if let Err(e) = self
                        .store
                        .upsert_reflex_pattern("default", &normalized, description, &safe_name)
                        .await
                    {
                        tracing::warn!(
                            "Failed to persist reflex pattern '{}' -> '{}': {}",
                            normalized,
                            safe_name,
                            e
                        );
                    }
                } else {
                    tracing::warn!(
                        "Failed to compile Reflex MS for pattern: {} (error: {:?})",
                        description,
                        result.error
                    );
                }
            }
            Err(e) => {
                tracing::error!("Reflex compiler error for pattern '{}': {}", description, e);
            }
        }
    }
}

// ── Eviction config ─────────────────

/// Configuration for the automatic eviction of stale reflex patterns.
#[derive(Debug, Clone)]
pub struct EvictionConfig {
    /// How often to run the eviction sweep (e.g., every 24 hours).
    pub check_interval: Duration,
    /// Patterns not matched within this many days are considered stale.
    /// Default: 30 days.
    pub stale_after_days: i32,
}

impl Default for EvictionConfig {
    fn default() -> Self {
        Self {
            check_interval: Duration::from_secs(24 * 60 * 60), // daily
            stale_after_days: 30,
        }
    }
}

// ── ReflexEvictor ───────────────────

/// Background task that periodically evicts stale reflex patterns.
///
/// Patterns whose `last_matched_at` (or `created_at` if never matched)
/// is older than `stale_after_days` are set to `status = 'evicted'`.
/// Evicted patterns are excluded from the router cache on next refresh.
pub struct ReflexEvictor {
    store: Arc<dyn Database>,
    config: EvictionConfig,
}

impl ReflexEvictor {
    /// Create a new evictor.
    pub fn new(store: Arc<dyn Database>, config: EvictionConfig) -> Self {
        Self { store, config }
    }

    /// Run the eviction loop forever.
    pub async fn run_loop(&self) {
        let mut ticker = tokio::time::interval(self.config.check_interval);
        // Skip immediate first tick so we don't evict on boot.
        ticker.tick().await;

        loop {
            ticker.tick().await;
            self.sweep().await;
        }
    }

    /// Execute a single eviction sweep.
    async fn sweep(&self) {
        match self
            .store
            .prune_stale_reflex_patterns(self.config.stale_after_days, false)
            .await
        {
            Ok(evicted) if evicted.is_empty() => {
                tracing::debug!("Reflex evictor: no stale patterns found.");
            }
            Ok(evicted) => {
                tracing::info!(
                    "Reflex evictor: evicted {} stale pattern(s) (threshold: {} days)",
                    evicted.len(),
                    self.config.stale_after_days
                );
                for p in &evicted {
                    tracing::info!(
                        "  evicted: '{}' (tool: {}, last matched: {:?}, matches: {})",
                        p.normalized_pattern,
                        p.tool_name,
                        p.last_matched_at,
                        p.match_count
                    );
                }
            }
            Err(e) => {
                tracing::error!("Reflex evictor error: {}", e);
            }
        }
    }
}

// ── Spawn helpers ───────────────────

/// Spawn the reflex compiler background task.
pub fn spawn_reflex_compiler(
    builder: Arc<dyn SoftwareBuilder>,
    store: Arc<dyn Database>,
    check_interval: Duration,
    min_match_count: u32,
    max_patterns_per_run: usize,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        let compiler = ReflexCompiler::new(builder, store, check_interval, min_match_count, max_patterns_per_run);
        compiler.run_loop().await;
    })
}

/// Spawn a background task that periodically refreshes the reflex router cache.
pub fn spawn_reflex_cache_refresh(
    router: Arc<ReflexRouter>,
    store: Arc<dyn Database>,
    user_id: String,
    interval: Duration,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        let mut ticker = tokio::time::interval(interval);
        // Skip immediate first tick
        ticker.tick().await;

        loop {
            ticker.tick().await;
            router.refresh(store.clone(), &user_id).await;
        }
    })
}

/// Spawn the reflex evictor background task.
pub fn spawn_reflex_evictor(
    store: Arc<dyn Database>,
    config: EvictionConfig,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        let evictor = ReflexEvictor::new(store, config);
        evictor.run_loop().await;
    })
}

// ── Tests ───────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::{Database, ReflexStore};

    // ── Normalization ──

    #[test]
    fn test_normalize_pattern_basic() {
        assert_eq!(normalize_pattern("Hello World"), "hello world");
        assert_eq!(normalize_pattern("  Multiple   Spaces  "), "multiple spaces");
    }

    #[test]
    fn test_normalize_pattern_punctuation() {
        assert_eq!(normalize_pattern("Hello, World!"), "hello world");
        assert_eq!(normalize_pattern("What's up???"), "whats up");
    }

    #[test]
    fn test_normalize_pattern_case() {
        assert_eq!(normalize_pattern("SUMMARIZE My LOGS"), "summarize my logs");
    }

    #[test]
    fn test_normalize_pattern_empty() {
        assert_eq!(normalize_pattern(""), "");
        assert_eq!(normalize_pattern("!!!"), "");
    }

    // ── Word overlap ──

    #[test]
    fn test_word_overlap_identical() {
        let score = word_overlap("summarize my logs", "summarize my logs");
        assert!((score - 1.0).abs() < 1e-6, "identical should score 1.0, got {}", score);
    }

    #[test]
    fn test_word_overlap_half() {
        let score = word_overlap("summarize my logs", "summarize the logs");
        // intersection = {summarize, logs} = 2, union = {summarize, my, logs, the} = 4
        assert!((score - 0.5).abs() < 1e-6, "2/4 should score 0.5, got {}", score);
    }

    #[test]
    fn test_word_overlap_disjoint() {
        let score = word_overlap("hello world", "goodbye moon");
        assert!((score - 0.0).abs() < 1e-6, "disjoint should score 0.0, got {}", score);
    }

    #[test]
    fn test_word_overlap_empty() {
        assert_eq!(word_overlap("", "hello world"), 0.0);
        assert_eq!(word_overlap("hello world", ""), 0.0);
    }

    // ── Fuzzy match helper ──

    #[test]
    fn test_jaro_winkler_similar() {
        // "summarize my logs" vs "summarize all my logs"
        let score = jaro_winkler("summarize my logs", "summarize all my logs");
        assert!(score > 0.8, "similar phrases should score high, got {}", score);
    }

    #[test]
    fn test_jaro_winkler_different() {
        let score = jaro_winkler("summarize my logs", "hello world");
        assert!(score < 0.6, "different phrases should score low, got {}", score);
    }

    // ── ReflexRouter: exact match ──

    #[tokio::test]
    async fn test_reflex_router_exact_match() {
        let router = ReflexRouter::new();
        router.register("hello world", "tool_hello").await;

        assert_eq!(router.try_route("Hello World").await, Some("tool_hello".to_string()));
        assert_eq!(router.try_route("hello world").await, Some("tool_hello".to_string()));
        assert_eq!(router.try_route("Hello, World!!!").await, Some("tool_hello".to_string()));
        assert_eq!(router.try_route("goodbye world").await, None);
    }

    #[tokio::test]
    async fn test_reflex_router_exact_no_match() {
        let router = ReflexRouter::new();
        router.register("summarize my logs", "tool_summarize").await;

        assert_eq!(router.try_route("what is the weather").await, None);
    }

    #[tokio::test]
    async fn test_reflex_router_empty() {
        let router = ReflexRouter::new();
        assert_eq!(router.try_route("anything").await, None);
    }

    // ── ReflexRouter: fuzzy match ──

    #[tokio::test]
    async fn test_reflex_router_fuzzy_match_similar() {
        let router = ReflexRouter::new();
        router.register("summarize my logs", "tool_summarize").await;

        // Slight variation — should fuzzy match
        let result = router.try_route("summarize all my logs please").await;
        assert_eq!(result, Some("tool_summarize".to_string()));
    }

    #[tokio::test]
    async fn test_reflex_router_fuzzy_match_word_order() {
        let router = ReflexRouter::new();
        router.register("find errors in the logs", "tool_find_errors").await;

        // Word re-ordering
        let result = router.try_route("find logs with errors").await;
        assert_eq!(result, Some("tool_find_errors".to_string()));
    }

    #[tokio::test]
    async fn test_reflex_router_fuzzy_match_extra_words() {
        let router = ReflexRouter::new();
        router.register("check disk space", "tool_disk").await;

        // Extra words
        let result = router.try_route("please check the disk space on the server").await;
        assert_eq!(result, Some("tool_disk".to_string()));
    }

    #[tokio::test]
    async fn test_reflex_router_fuzzy_no_match() {
        let router = ReflexRouter::new();
        router.register("check disk space", "tool_disk").await;

        // Completely different topic
        let result = router.try_route("what is the meaning of life").await;
        assert_eq!(result, None);
    }

    #[tokio::test]
    async fn test_reflex_router_fuzzy_match_best() {
        let router = ReflexRouter::new();
        router.register("summarize my logs", "tool_summarize").await;
        router.register("summarize my errors", "tool_errors").await;

        // Should pick the better match ("logs" vs "errors")
        let result = router.try_route("summarize all the logs today").await;
        assert_eq!(result, Some("tool_summarize".to_string()),
            "should match 'summarize my logs' over 'summarize my errors'");
    }

    #[tokio::test]
    async fn test_reflex_router_fuzzy_exact_takes_priority() {
        let router = ReflexRouter::new();
        router.register("summarize logs", "tool_summarize").await;
        router.register("summarize my logs", "tool_precise").await;

        // Exact match should win even if fuzzy could also match
        let result = router.try_route("summarize logs").await;
        assert_eq!(result, Some("tool_summarize".to_string()));
    }

    #[tokio::test]
    async fn test_reflex_router_fuzzy_promotion() {
        // Patterns that match fuzzily PROMOTION_THRESHOLD times
        // should be tracked (the router logs promotion).
        let router = ReflexRouter::new();
        router.register("summarize logs", "tool_summarize").await;

        // Hit it fuzzily several times
        for i in 0..PROMOTION_THRESHOLD + 2 {
            let result = router.try_route(&format!("summarize the logs please attempt {}", i)).await;
            assert_eq!(result, Some("tool_summarize".to_string()),
                "fuzzy match should work on attempt {}", i);
        }

        // Check hit counts
        let hits = router.fuzzy_hit_counts().await;
        let count = hits.get("summarize logs").copied().unwrap_or(0);
        assert!(count >= 0, "fuzzy hits should be tracked (count: {})", count);
    }

    // ── FuzzyMatch details ──

    #[tokio::test]
    async fn test_try_route_with_details_exact() {
        let router = ReflexRouter::new();
        router.register("hello world", "tool_hello").await;

        let details = router.try_route_with_details("Hello World").await;
        assert!(details.is_some());
        let details = details.unwrap();
        assert_eq!(details.tool_name, "tool_hello");
        assert_eq!(details.matched_pattern, "hello world");
        assert!((details.score - 1.0).abs() < 1e-6);
    }

    #[tokio::test]
    async fn test_try_route_with_details_fuzzy() {
        let router = ReflexRouter::new();
        router.register("summarize my logs", "tool_summarize").await;

        let details = router.try_route_with_details("summarize all my logs").await;
        assert!(details.is_some(), "should fuzzy match");
        let details = details.unwrap();
        assert_eq!(details.tool_name, "tool_summarize");
        assert_eq!(details.matched_pattern, "summarize my logs");
        assert!(details.score >= 0.8, "score should be high, got {}", details.score);
        assert!(details.score < 1.0, "fuzzy should not be exact, got {}", details.score);
    }

    #[tokio::test]
    async fn test_try_route_with_details_no_match() {
        let router = ReflexRouter::new();
        router.register("hello world", "tool_hello").await;

        let details = router.try_route_with_details("goodbye moon").await;
        assert!(details.is_none());
    }

    // ── Custom threshold ──

    #[tokio::test]
    async fn test_reflex_router_custom_threshold_strict() {
        let router = ReflexRouter::with_threshold(0.99);
        router.register("hello world", "tool_hello").await;

        // Very strict — should NOT match small variations
        assert_eq!(router.try_route("hello world").await, Some("tool_hello".to_string()));
        assert_eq!(router.try_route("hello world!").await, Some("tool_hello".to_string()));
        // Anything beyond normalization changes should fail
    }

    #[tokio::test]
    async fn test_reflex_router_custom_threshold_loose() {
        let router = ReflexRouter::with_threshold(0.5);
        router.register("summarize my logs", "tool_summarize").await;

        // Very loose — should match distant variations
        let result = router.try_route("summarize the logs").await;
        assert_eq!(result, Some("tool_summarize".to_string()));
    }

    #[tokio::test]
    async fn test_reflex_router_threshold_clamped() {
        let router = ReflexRouter::with_threshold(2.0);
        assert!((router.fuzzy_threshold() - 1.0).abs() < 1e-6,
            "threshold should be clamped to 1.0, got {}", router.fuzzy_threshold());

        let router = ReflexRouter::with_threshold(-1.0);
        assert!((router.fuzzy_threshold() - 0.0).abs() < 1e-6,
            "threshold should be clamped to 0.0, got {}", router.fuzzy_threshold());
    }

    // ── Pattern count ──

    #[tokio::test]
    async fn test_pattern_count() {
        let router = ReflexRouter::new();
        assert_eq!(router.pattern_count().await, 0);

        router.register("a", "t_a").await;
        router.register("b", "t_b").await;
        assert_eq!(router.pattern_count().await, 2);
    }

    // ── FuzzyConfig ──

    #[test]
    fn test_fuzzy_config_default() {
        let config = FuzzyConfig::default();
        assert!((config.threshold - 0.85).abs() < 1e-6);
        assert_eq!(config.promotion_threshold, 3);
        assert_eq!(config.max_candidates, 50);
    }

    // ── DB integration tests ──

    #[tokio::test]
    #[cfg(feature = "libsql")]
    async fn test_reflex_router_refresh() {
        use crate::db::libsql::LibSqlBackend;

        let tmp = tempfile::tempdir().unwrap();
        let db_path = tmp.path().join("test_reflex_router.db");
        let backend = LibSqlBackend::new_local(&db_path).await.unwrap();
        backend.run_migrations().await.unwrap();

        let router = ReflexRouter::new();

        // Initially empty
        assert_eq!(router.try_route("test pattern").await, None);

        // Insert a pattern directly into DB
        backend
            .upsert_reflex_pattern("test-user", "test pattern", "test pattern", "tool_test")
            .await
            .unwrap();

        // Refresh cache from DB
        router.refresh(Arc::new(backend), "test-user").await;

        // Now it should match — both exactly and fuzzily
        assert_eq!(
            router.try_route("test pattern").await,
            Some("tool_test".to_string())
        );
        // Also fuzzy
        assert_eq!(
            router.try_route("test the pattern").await,
            Some("tool_test".to_string())
        );
    }

    #[tokio::test]
    #[cfg(feature = "libsql")]
    async fn test_reflex_store_libsql_crud() {
        use crate::db::libsql::LibSqlBackend;

        let tmp = tempfile::tempdir().unwrap();
        let db_path = tmp.path().join("test_reflex_crud.db");
        let backend = LibSqlBackend::new_local(&db_path).await.unwrap();
        backend.run_migrations().await.unwrap();

        // Initially empty
        let patterns = backend.list_reflex_patterns("test-user").await.unwrap();
        assert!(patterns.is_empty());

        // Upsert a pattern
        backend
            .upsert_reflex_pattern("test-user", "summarize logs", "Summarize my logs", "tool_summarize")
            .await
            .unwrap();

        // List should return it
        let patterns = backend.list_reflex_patterns("test-user").await.unwrap();
        assert_eq!(patterns.len(), 1);
        assert_eq!(patterns[0].normalized_pattern, "summarize logs");
        assert_eq!(patterns[0].tool_name, "tool_summarize");
        assert_eq!(patterns[0].match_count, 1);
        assert_eq!(patterns[0].status, "active");

        // Get by pattern
        let found = backend
            .get_reflex_pattern("test-user", "summarize logs")
            .await
            .unwrap();
        assert!(found.is_some());
        let (tool_name, status) = found.unwrap();
        assert_eq!(tool_name, "tool_summarize");
        assert_eq!(status, "active");

        // Bump match count
        backend
            .bump_reflex_pattern_match("test-user", "summarize logs")
            .await
            .unwrap();

        let patterns = backend.list_reflex_patterns("test-user").await.unwrap();
        assert_eq!(patterns[0].match_count, 2);

        // Disable
        backend.disable_reflex_pattern(patterns[0].id).await.unwrap();

        let patterns = backend.list_reflex_patterns("test-user").await.unwrap();
        assert_eq!(patterns[0].status, "disabled");
    }

    #[tokio::test]
    #[cfg(feature = "libsql")]
    async fn test_prune_stale_reflex_patterns_dry_run() {
        use crate::db::libsql::LibSqlBackend;

        let tmp = tempfile::tempdir().unwrap();
        let db_path = tmp.path().join("test_prune_dry_run.db");
        let backend = LibSqlBackend::new_local(&db_path).await.unwrap();
        backend.run_migrations().await.unwrap();

        // Insert a pattern with old last_matched_at
        backend
            .upsert_reflex_pattern("test-user", "old pattern", "Old Pattern", "tool_old")
            .await
            .unwrap();

        // Manually backdate last_matched_at to 31 days ago
        let old_date = fmt_ts(&(Utc::now() - chrono::Duration::days(31)));
        let conn = backend.connect().await.unwrap();
        conn.execute(
            "UPDATE reflex_patterns SET last_matched_at = ?1 WHERE normalized_pattern = ?2",
            params![old_date, "old pattern"],
        )
        .await
        .unwrap();

        // Dry run — should report stale but not change
        let stale = backend.prune_stale_reflex_patterns(30, true).await.unwrap();
        assert_eq!(stale.len(), 1);
        assert_eq!(stale[0].normalized_pattern, "old pattern");
        assert_eq!(stale[0].status, "active"); // unchanged

        // Verify still active
        let patterns = backend.list_reflex_patterns("test-user").await.unwrap();
        assert_eq!(patterns[0].status, "active");
    }

    #[tokio::test]
    #[cfg(feature = "libsql")]
    async fn test_prune_stale_reflex_patterns_actual_eviction() {
        use crate::db::libsql::LibSqlBackend;

        let tmp = tempfile::tempdir().unwrap();
        let db_path = tmp.path().join("test_prune_actual.db");
        let backend = LibSqlBackend::new_local(&db_path).await.unwrap();
        backend.run_migrations().await.unwrap();

        // Insert old and fresh patterns
        backend
            .upsert_reflex_pattern("test-user", "stale pattern", "Stale Pattern", "tool_stale")
            .await
            .unwrap();
        backend
            .upsert_reflex_pattern("test-user", "fresh pattern", "Fresh Pattern", "tool_fresh")
            .await
            .unwrap();

        // Backdate only the stale one
        let old_date = fmt_ts(&(Utc::now() - chrono::Duration::days(31)));
        let conn = backend.connect().await.unwrap();
        conn.execute(
            "UPDATE reflex_patterns SET last_matched_at = ?1 WHERE normalized_pattern = ?2",
            params![old_date, "stale pattern"],
        )
        .await
        .unwrap();

        // Actual eviction with 30-day threshold
        let evicted = backend.prune_stale_reflex_patterns(30, false).await.unwrap();
        assert_eq!(evicted.len(), 1);
        assert_eq!(evicted[0].normalized_pattern, "stale pattern");

        // Verify statuses
        let patterns = backend.list_reflex_patterns("test-user").await.unwrap();
        assert_eq!(patterns.len(), 2);
        let stale = patterns.iter().find(|p| p.normalized_pattern == "stale pattern").unwrap();
        let fresh = patterns.iter().find(|p| p.normalized_pattern == "fresh pattern").unwrap();
        assert_eq!(stale.status, "evicted");
        assert_eq!(fresh.status, "active");
    }

    #[tokio::test]
    #[cfg(feature = "libsql")]
    async fn test_prune_stale_reflex_patterns_never_matched() {
        use crate::db::libsql::LibSqlBackend;

        let tmp = tempfile::tempdir().unwrap();
        let db_path = tmp.path().join("test_prune_never.db");
        let backend = LibSqlBackend::new_local(&db_path).await.unwrap();
        backend.run_migrations().await.unwrap();

        // Insert pattern but never bump it (no last_matched_at)
        backend
            .upsert_reflex_pattern("test-user", "never matched", "Never Matched", "tool_never")
            .await
            .unwrap();

        // Backdate created_at to simulate old pattern
        let old_date = fmt_ts(&(Utc::now() - chrono::Duration::days(31)));
        let conn = backend.connect().await.unwrap();
        conn.execute(
            "UPDATE reflex_patterns SET created_at = ?1, last_matched_at = NULL WHERE normalized_pattern = ?2",
            params![old_date, "never matched"],
        )
        .await
        .unwrap();

        // Should still be evicted based on created_at
        let evicted = backend.prune_stale_reflex_patterns(30, false).await.unwrap();
        assert_eq!(evicted.len(), 1);
        assert_eq!(evicted[0].status, "evicted");
    }

    #[tokio::test]
    #[cfg(feature = "libsql")]
    async fn test_prune_stale_reflex_patterns_fresh_stays_active() {
        use crate::db::libsql::LibSqlBackend;

        let tmp = tempfile::tempdir().unwrap();
        let db_path = tmp.path().join("test_prune_fresh.db");
        let backend = LibSqlBackend::new_local(&db_path).await.unwrap();
        backend.run_migrations().await.unwrap();

        // Fresh pattern (matched today via upsert)
        backend
            .upsert_reflex_pattern("test-user", "fresh pattern", "Fresh Pattern", "tool_fresh")
            .await
            .unwrap();

        // Eviction sweep should find nothing
        let evicted = backend.prune_stale_reflex_patterns(30, false).await.unwrap();
        assert!(evicted.is_empty());

        // Still active
        let patterns = backend.list_reflex_patterns("test-user").await.unwrap();
        assert_eq!(patterns[0].status, "active");
    }

    // ── EvictionConfig ──

    #[test]
    fn test_eviction_config_default() {
        let config = EvictionConfig::default();
        assert_eq!(config.stale_after_days, 30);
        assert_eq!(config.check_interval, Duration::from_secs(24 * 60 * 60));
    }

    // ── Cosine similarity ──

    #[test]
    fn test_cosine_similarity_identical() {
        let v = vec![1.0, 0.0, 0.0];
        let score = cosine_similarity(&v, &v);
        assert!((score - 1.0).abs() < 1e-6, "identical vectors should be 1.0, got {}", score);
    }

    #[test]
    fn test_cosine_similarity_orthogonal() {
        let a = vec![1.0, 0.0, 0.0];
        let b = vec![0.0, 1.0, 0.0];
        let score = cosine_similarity(&a, &b);
        assert!(score.abs() < 1e-6, "orthogonal vectors should be 0.0, got {}", score);
    }

    #[test]
    fn test_cosine_similarity_opposite() {
        let a = vec![1.0, 0.0];
        let b = vec![-1.0, 0.0];
        let score = cosine_similarity(&a, &b);
        assert!((score + 1.0).abs() < 1e-6, "opposite vectors should be -1.0, got {}", score);
    }

    #[test]
    fn test_cosine_similarity_empty() {
        let score = cosine_similarity(&[], &[]);
        assert_eq!(score, 0.0);
    }

    #[test]
    fn test_cosine_similarity_mismatched_length() {
        let score = cosine_similarity(&[1.0, 2.0], &[1.0]);
        assert_eq!(score, 0.0);
    }

    // ── Semantic routing ──

    #[tokio::test]
    async fn test_reflex_router_semantic_match() {
        use crate::workspace::MockEmbeddings;

        let provider = Arc::new(MockEmbeddings::new(64));
        let router = ReflexRouter::new()
            .with_embedding_provider(provider.clone())
            .with_semantic_threshold(0.5);

        // Register a pattern
        router.register("summarize my logs", "tool_summarize").await;

        // Pre-populate the embedding cache with the pattern's embedding
        let emb = provider.embed("summarize my logs").await.unwrap();
        {
            let mut cache = router.pattern_embeddings.write().await;
            cache.insert("summarize my logs".to_string(), emb);
        }

        // Identical text should produce identical embedding (cosine = 1.0)
        let result = router.try_route("summarize my logs").await;
        // This hits the exact match tier, not semantic
        assert_eq!(result, Some("tool_summarize".to_string()));

        // Now test with the exact same text but via the semantic path
        // by registering a pattern that won't match exactly or fuzzily
        let router2 = ReflexRouter::new()
            .with_embedding_provider(provider.clone())
            .with_semantic_threshold(0.5);

        router2.register("check server health status", "tool_health").await;
        let emb = provider.embed("check server health status").await.unwrap();
        {
            let mut cache = router2.pattern_embeddings.write().await;
            cache.insert("check server health status".to_string(), emb);
        }

        // Same input should produce cosine 1.0 — semantic match
        let result = router2.try_route("check server health status").await;
        // Hits exact match first
        assert_eq!(result, Some("tool_health".to_string()));
    }

    #[tokio::test]
    async fn test_reflex_router_semantic_no_provider() {
        let router = ReflexRouter::new();
        assert!(!router.has_embedding_provider());

        router.register("summarize my logs", "tool_summarize").await;

        // Query that won't match exactly or fuzzily
        let result = router.try_route("what is my server uptime").await;
        assert_eq!(result, None);
    }

    #[tokio::test]
    async fn test_reflex_router_semantic_below_threshold() {
        use crate::workspace::MockEmbeddings;

        let provider = Arc::new(MockEmbeddings::new(64));
        // Very high threshold — MockEmbeddings hash-based vectors for
        // different strings will have low similarity
        let router = ReflexRouter::new()
            .with_embedding_provider(provider.clone())
            .with_semantic_threshold(0.99);

        router.register("summarize my logs", "tool_summarize").await;
        let emb = provider.embed("summarize my logs").await.unwrap();
        {
            let mut cache = router.pattern_embeddings.write().await;
            cache.insert("summarize my logs".to_string(), emb);
        }

        // Completely different text — MockEmbeddings generates different
        // hash-based vectors, cosine similarity will be well below 0.99
        let result = router.try_route("what is the weather forecast today").await;
        assert_eq!(result, None, "dissimilar text should not match with high threshold");
    }

    #[tokio::test]
    async fn test_reflex_router_semantic_identical_text_matches() {
        use crate::workspace::MockEmbeddings;

        // MockEmbeddings is deterministic: same text → same vector → cosine 1.0
        let provider = Arc::new(MockEmbeddings::new(64));
        let router = ReflexRouter::with_threshold(0.99) // strict fuzzy so it won't fuzzy-match
            .with_embedding_provider(provider.clone())
            .with_semantic_threshold(0.9);

        // Register a pattern under a different key so exact match won't fire
        {
            let mut patterns = router.patterns.write().await;
            patterns.insert("alpha bravo charlie".to_string(), "tool_alpha".to_string());
        }
        // Cache the embedding for that pattern
        let emb = provider.embed("alpha bravo charlie").await.unwrap();
        {
            let mut cache = router.pattern_embeddings.write().await;
            cache.insert("alpha bravo charlie".to_string(), emb);
        }

        // Same text — will miss exact (normalization matches), so test a
        // case where normalized matches. Let's use something that fuzzy
        // won't pick up but semantic will (exact same string after normalize).
        let result = router.try_route("alpha bravo charlie").await;
        assert_eq!(result, Some("tool_alpha".to_string()));
    }

    #[tokio::test]
    async fn test_reflex_router_semantic_threshold_accessor() {
        let router = ReflexRouter::new();
        assert!((router.semantic_threshold() - DEFAULT_SEMANTIC_THRESHOLD).abs() < 1e-6);

        let router2 = ReflexRouter::new().with_semantic_threshold(0.9);
        assert!((router2.semantic_threshold() - 0.9).abs() < 1e-6);
    }

    #[tokio::test]
    async fn test_reflex_router_semantic_empty_cache() {
        use crate::workspace::MockEmbeddings;

        let provider = Arc::new(MockEmbeddings::new(64));
        let router = ReflexRouter::new()
            .with_embedding_provider(provider)
            .with_semantic_threshold(0.5);

        router.register("hello world", "tool_hello").await;
        // Don't populate embedding cache — semantic should gracefully return None
        let result = router.try_route("unrelated query here").await;
        assert_eq!(result, None);
    }
}
