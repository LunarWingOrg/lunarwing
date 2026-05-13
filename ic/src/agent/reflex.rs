//! Reflex compiler and router for fast-path execution of recurring patterns.
//!
//! The reflex system detects recurring user prompts and compiles them into
//! optimized WASM micro-skills, bypassing the LLM entirely for known patterns.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use tokio::sync::RwLock;

use crate::db::Database;
use crate::tools::builder::{
    BuildRequirement, Language, SoftwareBuilder, SoftwareType,
};
use uuid::Uuid;

/// Normalize a user input pattern for matching.
///
/// Converts to lowercase, strips punctuation, and collapses whitespace.
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

/// In-memory router for reflex patterns.
///
/// Maintains a cache of normalized patterns -> compiled tool names.
/// The cache is refreshed periodically from the database.
pub struct ReflexRouter {
    patterns: Arc<RwLock<HashMap<String, String>>>,
}

impl ReflexRouter {
    /// Create a new empty reflex router.
    pub fn new() -> Self {
        Self {
            patterns: Arc::new(RwLock::new(HashMap::new())),
        }
    }

    /// Try to route a user input to a compiled reflex tool.
    ///
    /// Returns the tool name if a matching active pattern is found.
    pub async fn try_route(&self, input: &str) -> Option<String> {
        let normalized = normalize_pattern(input);
        let patterns = self.patterns.read().await;
        patterns.get(&normalized).cloned()
    }

    /// Refresh the pattern cache from the database.
    pub async fn refresh(&self, store: Arc<dyn Database>, user_id: &str) {
        match store.list_reflex_patterns(user_id).await {
            Ok(records) => {
                let mut patterns = self.patterns.write().await;
                patterns.clear();
                for record in records {
                    if record.status == "active" {
                        patterns.insert(record.normalized_pattern, record.tool_name);
                    }
                }
            }
            Err(e) => {
                tracing::warn!("Failed to refresh reflex patterns: {}", e);
            }
        }
    }

    /// Register a new pattern in the in-memory cache.
    pub async fn register(&self, normalized_pattern: &str, tool_name: &str) {
        let mut patterns = self.patterns.write().await;
        patterns.insert(normalized_pattern.to_string(), tool_name.to_string());
    }
}

impl Default for ReflexRouter {
    fn default() -> Self {
        Self::new()
    }
}

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
    async fn compile_patterns(&self) {
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

#[cfg(test)]
mod tests {
    use super::*;

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
}
