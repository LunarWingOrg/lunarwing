//! End-to-end compilation tests for the LunarWing reflex compiler.
//!
//! These tests exercise the full pipeline:
//!
//!   1. Recurring job patterns accumulate in `agent_jobs` (seeded directly).
//!   2. `ReflexCompiler::compile_patterns()` finds them and calls the builder.
//!   3. The builder mock returns a deterministic successful `BuildResult`.
//!   4. The compiled pattern is persisted to `reflex_patterns`.
//!   5. `ReflexRouter::refresh()` loads the pattern into the in-memory cache.
//!   6. `ReflexRouter::route()` dispatches correctly on an exact and fuzzy input.
//!   7. Evicted patterns are excluded from the router cache after `refresh()`.
//!
//! The mock builder never touches a compiler or LLM; it returns a canned
//! `BuildResult` synchronously so the tests stay fast and hermetic.
//!
//! # Seeding strategy
//!
//! Each test helper keeps a concrete `Arc<LibSqlBackend>` for direct DB
//! operations (seeding jobs, backdating timestamps) and a separate
//! `Arc<dyn Database>` coercion to hand to the compiler/router.  This avoids
//! any need for trait-object downcasting.

#![cfg(feature = "libsql")]

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use chrono::Utc;
use uuid::Uuid;

use lunarwing::agent::reflex::{ReflexCompiler, ReflexRouter};
use lunarwing::db::libsql::LibSqlBackend;
use lunarwing::db::{Database, ReflexStore};
use lunarwing::error::ToolError;
use lunarwing::tools::{Language, SoftwareType};
use lunarwing::tools::builder::{BuildLog, BuildPhase, BuildRequirement, BuildResult, SoftwareBuilder};

// ---------------------------------------------------------------------------
// Mock builders
// ---------------------------------------------------------------------------

/// A deterministic `SoftwareBuilder` that always succeeds instantly — no LLM,
/// no `cargo`, no network.
struct MockSoftwareBuilder;

impl MockSoftwareBuilder {
    fn make_result(req: &BuildRequirement) -> BuildResult {
        let now = Utc::now();
        BuildResult {
            build_id: Uuid::new_v4(),
            requirement: req.clone(),
            artifact_path: PathBuf::from("/dev/null"),
            logs: vec![BuildLog {
                timestamp: now,
                phase: BuildPhase::Complete,
                message: "mock build succeeded".into(),
                details: None,
            }],
            success: true,
            error: None,
            started_at: now,
            completed_at: now,
            iterations: 1,
            validation_warnings: vec![],
            tests_passed: 1,
            tests_failed: 0,
            registered: false,
        }
    }
}

#[async_trait]
impl SoftwareBuilder for MockSoftwareBuilder {
    async fn analyze(&self, description: &str) -> Result<BuildRequirement, ToolError> {
        Ok(BuildRequirement {
            name: format!("mock_{}", description.replace(' ', "_")),
            description: description.to_string(),
            software_type: SoftwareType::WasmTool,
            language: Language::Rust,
            input_spec: None,
            output_spec: None,
            dependencies: vec![],
            capabilities: vec![],
        })
    }

    async fn build(&self, requirement: &BuildRequirement) -> Result<BuildResult, ToolError> {
        Ok(Self::make_result(requirement))
    }

    async fn repair(&self, result: &BuildResult, _error: &str) -> Result<BuildResult, ToolError> {
        Ok(result.clone())
    }
}

/// A `SoftwareBuilder` that always returns a failed `BuildResult`.
struct FailingSoftwareBuilder;

#[async_trait]
impl SoftwareBuilder for FailingSoftwareBuilder {
    async fn analyze(&self, description: &str) -> Result<BuildRequirement, ToolError> {
        Ok(BuildRequirement {
            name: format!("fail_{}", description.replace(' ', "_")),
            description: description.to_string(),
            software_type: SoftwareType::WasmTool,
            language: Language::Rust,
            input_spec: None,
            output_spec: None,
            dependencies: vec![],
            capabilities: vec![],
        })
    }

    async fn build(&self, requirement: &BuildRequirement) -> Result<BuildResult, ToolError> {
        let now = Utc::now();
        Ok(BuildResult {
            build_id: Uuid::new_v4(),
            requirement: requirement.clone(),
            artifact_path: PathBuf::from("/dev/null"),
            logs: vec![BuildLog {
                timestamp: now,
                phase: BuildPhase::Failed,
                message: "intentional mock failure".into(),
                details: None,
            }],
            success: false,
            error: Some("mock build deliberately failed".into()),
            started_at: now,
            completed_at: now,
            iterations: 1,
            validation_warnings: vec![],
            tests_passed: 0,
            tests_failed: 1,
            registered: false,
        })
    }

    async fn repair(&self, result: &BuildResult, _error: &str) -> Result<BuildResult, ToolError> {
        Ok(result.clone())
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Spin up a fresh in-memory backend with migrations applied.
/// Returns `(concrete_backend, dyn_store)` — hold both; the concrete one is
/// for raw SQL ops, the trait-object one is for the compiler/router.
async fn fresh_backend() -> (Arc<LibSqlBackend>, Arc<dyn Database>) {
    let backend = Arc::new(
        LibSqlBackend::new_memory()
            .await
            .expect("LibSqlBackend::new_memory"),
    );
    backend.run_migrations().await.expect("run_migrations");
    let store: Arc<dyn Database> = Arc::clone(&backend) as Arc<dyn Database>;
    (backend, store)
}

/// Insert `count` successfully-completed `agent_jobs` rows with the given description.
async fn seed_completed_jobs(backend: &LibSqlBackend, description: &str, count: usize) {
    let conn = backend.connect().await.expect("connect");
    for _ in 0..count {
        let id = Uuid::new_v4().to_string();
        conn.execute(
            "INSERT INTO agent_jobs \
             (id, title, description, status, source, user_id, success, created_at, updated_at) \
             VALUES (?1, ?2, ?3, 'completed', 'test', 'default', 1, \
                     strftime('%Y-%m-%dT%H:%M:%fZ','now'), \
                     strftime('%Y-%m-%dT%H:%M:%fZ','now'))",
            libsql::params![id.as_str(), description, description],
        )
        .await
        .expect("insert agent_job");
    }
}

/// Wire up a `ReflexCompiler` with the given builder and a 1-hour tick
/// interval so we control sweeps manually via `compile_patterns()`.
fn make_compiler(
    builder: Arc<dyn SoftwareBuilder>,
    store: Arc<dyn Database>,
    min_match: u32,
    max_per_run: usize,
) -> ReflexCompiler {
    ReflexCompiler::new(builder, store, Duration::from_secs(3600), min_match, max_per_run)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// Full happy-path: seed → compile → router refresh → exact route succeeds.
#[tokio::test]
async fn e2e_compile_then_route_exact() {
    let (backend, store) = fresh_backend().await;
    seed_completed_jobs(&backend, "summarize my logs", 5).await;

    let compiler = make_compiler(
        Arc::new(MockSoftwareBuilder),
        Arc::clone(&store),
        3,
        10,
    );
    compiler.compile_patterns().await;

    let (tool_name, status) = store
        .get_reflex_pattern("default", "summarize my logs")
        .await
        .expect("get_reflex_pattern")
        .expect("pattern should exist after compilation");

    assert_eq!(status, "active", "compiled pattern should be active");
    assert!(
        tool_name.starts_with("reflex_"),
        "tool name should have reflex_ prefix, got: {tool_name}"
    );

    let router = ReflexRouter::new();
    router.refresh(Arc::clone(&store), "default").await;

    let routed = router.try_route("summarize my logs").await;
    assert_eq!(
        routed.as_deref(),
        Some(tool_name.as_str()),
        "router should dispatch to the compiled tool"
    );
}

/// Fuzzy routing: a slightly different input should still hit the compiled pattern.
#[tokio::test]
async fn e2e_compile_then_route_fuzzy() {
    let (backend, store) = fresh_backend().await;
    seed_completed_jobs(&backend, "check server health", 4).await;

    let compiler = make_compiler(Arc::new(MockSoftwareBuilder), Arc::clone(&store), 3, 10);
    compiler.compile_patterns().await;

    let router = ReflexRouter::new();
    router.refresh(Arc::clone(&store), "default").await;

    // Slightly paraphrased input — should fuzzy-match.
    let routed = router.try_route("check server health status").await;
    assert!(
        routed.is_some(),
        "'check server health status' should fuzzy-match the compiled pattern"
    );
}

/// Not enough repetitions — compiler should NOT persist a pattern.
#[tokio::test]
async fn e2e_below_threshold_not_compiled() {
    let (backend, store) = fresh_backend().await;
    seed_completed_jobs(&backend, "rare command", 2).await; // below min_match = 3

    let compiler = make_compiler(Arc::new(MockSoftwareBuilder), Arc::clone(&store), 3, 10);
    compiler.compile_patterns().await;

    let pattern = store
        .get_reflex_pattern("default", "rare command")
        .await
        .expect("get_reflex_pattern");

    assert!(pattern.is_none(), "pattern below threshold should not be compiled");
}

/// A failed build should NOT leave an active pattern in the DB.
#[tokio::test]
async fn e2e_failed_build_not_persisted() {
    let (backend, store) = fresh_backend().await;
    seed_completed_jobs(&backend, "exploding operation", 5).await;

    let compiler = make_compiler(Arc::new(FailingSoftwareBuilder), Arc::clone(&store), 3, 10);
    compiler.compile_patterns().await;

    let pattern = store
        .get_reflex_pattern("default", "exploding operation")
        .await
        .expect("get_reflex_pattern");

    assert!(pattern.is_none(), "failed build should not persist an active pattern");
}

/// Compiling the same pattern twice must not produce duplicates or change the
/// already-compiled tool name.
#[tokio::test]
async fn e2e_compile_idempotent() {
    let (backend, store) = fresh_backend().await;
    seed_completed_jobs(&backend, "deploy service", 5).await;

    let compiler = make_compiler(Arc::new(MockSoftwareBuilder), Arc::clone(&store), 3, 10);

    compiler.compile_patterns().await;
    let (first_tool, _) = store
        .get_reflex_pattern("default", "deploy service")
        .await
        .expect("get_reflex_pattern")
        .expect("should exist after first sweep");

    compiler.compile_patterns().await; // second sweep — should be a no-op
    let (second_tool, _) = store
        .get_reflex_pattern("default", "deploy service")
        .await
        .expect("get_reflex_pattern")
        .expect("should still exist after second sweep");

    assert_eq!(
        first_tool, second_tool,
        "second compile sweep must not overwrite the existing pattern"
    );

    let all = store
        .list_reflex_patterns("default")
        .await
        .expect("list_reflex_patterns");
    let dupe_count = all
        .iter()
        .filter(|r| r.normalized_pattern == "deploy service")
        .count();
    assert_eq!(dupe_count, 1, "exactly one record should exist");
}

/// Evicted patterns must be absent from the router cache after `refresh()`.
#[tokio::test]
async fn e2e_evicted_pattern_excluded_from_router() {
    let (backend, store) = fresh_backend().await;
    seed_completed_jobs(&backend, "old routine task", 5).await;

    let compiler = make_compiler(Arc::new(MockSoftwareBuilder), Arc::clone(&store), 3, 10);
    compiler.compile_patterns().await;

    let router = ReflexRouter::new();
    router.refresh(Arc::clone(&store), "default").await;
    assert!(
        router.try_route("old routine task").await.is_some(),
        "pattern should route before eviction"
    );

    // Backdate last_matched_at so the evictor considers it stale (>30 days).
    let old_ts = (Utc::now() - chrono::Duration::days(45))
        .format("%Y-%m-%dT%H:%M:%S%.3fZ")
        .to_string();
    backend
        .connect()
        .await
        .unwrap()
        .execute(
            "UPDATE reflex_patterns \
             SET last_matched_at = ?1, created_at = ?1 \
             WHERE normalized_pattern = 'old routine task'",
            libsql::params![old_ts.as_str()],
        )
        .await
        .unwrap();

    // Run eviction sweep.
    let evicted = backend
        .prune_stale_reflex_patterns(30, false)
        .await
        .expect("prune_stale_reflex_patterns");
    assert_eq!(evicted.len(), 1, "one pattern should be evicted");
    assert_eq!(evicted[0].status, "evicted");

    // Refresh router — evicted pattern must be gone.
    router.refresh(Arc::clone(&store), "default").await;
    assert!(
        router.try_route("old routine task").await.is_none(),
        "evicted pattern should not route after cache refresh"
    );
}

/// Multiple patterns compile in the same sweep and all route correctly.
#[tokio::test]
async fn e2e_multiple_patterns_compile_and_route() {
    let (backend, store) = fresh_backend().await;

    let descs = ["fetch logs", "restart worker", "check disk usage"];
    for desc in &descs {
        seed_completed_jobs(&backend, desc, 4).await;
    }

    let compiler = make_compiler(Arc::new(MockSoftwareBuilder), Arc::clone(&store), 3, 10);
    compiler.compile_patterns().await;

    let router = ReflexRouter::new();
    router.refresh(Arc::clone(&store), "default").await;

    assert_eq!(
        router.pattern_count().await,
        descs.len(),
        "all three patterns should be in the router cache"
    );
    for desc in &descs {
        assert!(
            router.try_route(desc).await.is_some(),
            "pattern '{desc}' should route after bulk compile"
        );
    }
}

/// `max_patterns_per_run` cap: only N patterns compiled per sweep even if more qualify.
#[tokio::test]
async fn e2e_max_patterns_per_run_respected() {
    let (backend, store) = fresh_backend().await;

    let descs = ["alpha job", "beta job", "gamma job", "delta job", "epsilon job"];
    for desc in &descs {
        seed_completed_jobs(&backend, desc, 5).await;
    }

    let compiler = make_compiler(
        Arc::new(MockSoftwareBuilder),
        Arc::clone(&store),
        3,
        2, // cap at 2
    );
    compiler.compile_patterns().await;

    let all = store
        .list_reflex_patterns("default")
        .await
        .expect("list_reflex_patterns");

    assert_eq!(
        all.len(),
        2,
        "only 2 patterns should be compiled when max_patterns_per_run = 2"
    );
}
