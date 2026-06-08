//! Regression tests for the lightweight stuck-run sweeper.
//!
//! The routine engine's `sweep_stuck_lightweight_runs()` (src/agent/routine_engine.rs)
//! is the self-healing path that recovers lightweight routine runs which were left in
//! the `running` state past their timeout (e.g. the daemon crashed mid-run). It relies on
//! `Database::list_stuck_lightweight_runs(cutoff)`, whose query is:
//!
//! ```sql
//! SELECT ... FROM routine_runs
//! WHERE status = 'running' AND job_id IS NULL AND started_at < ?cutoff
//! ```
//!
//! The `job_id IS NULL` clause is what scopes the sweep to *lightweight* runs —
//! dispatched FullJob runs carry a `job_id` and are recovered separately by
//! `sync_dispatched_runs()`. Prior to these tests this query (and the finalization
//! path the sweeper drives via `complete_routine_run`) had no coverage in either
//! backend. See docs/ops/GOALS_1.1.2.md item 4 ("Test ... Self-Healing Enhancements").

#[cfg(feature = "libsql")]
mod tests {
    use std::sync::Arc;

    use chrono::{DateTime, Duration, Utc};
    use uuid::Uuid;

    use lunarwing::agent::routine::{
        Routine, RoutineAction, RoutineGuardrails, RoutineRun, RunStatus, Trigger,
    };
    use lunarwing::context::JobContext;
    use lunarwing::db::Database;

    async fn create_test_db() -> (Arc<dyn Database>, tempfile::TempDir) {
        use lunarwing::db::libsql::LibSqlBackend;

        // A file-backed temp DB (not :memory:) so the per-operation connections
        // opened by LibSqlBackend::connect() share state — matches the documented
        // pattern in src/db/CLAUDE.md and tests/dispatched_routine_run_tests.rs.
        let temp_dir = tempfile::tempdir().expect("tempdir");
        let db_path = temp_dir.path().join("test.db");
        let backend = LibSqlBackend::new_local(&db_path)
            .await
            .expect("LibSqlBackend");
        backend.run_migrations().await.expect("migrations");
        let db: Arc<dyn Database> = Arc::new(backend);
        (db, temp_dir)
    }

    fn make_routine(id: Uuid) -> Routine {
        Routine {
            id,
            name: format!("test-routine-{}", id),
            description: "Test routine".to_string(),
            user_id: "default".to_string(),
            enabled: true,
            trigger: Trigger::Manual,
            // The routine's action type is irrelevant to the sweep query (which
            // only inspects routine_runs columns); FullJob keeps the fixture simple.
            action: RoutineAction::FullJob {
                title: "Test job".to_string(),
                description: "Test description".to_string(),
                max_iterations: 5,
            },
            guardrails: RoutineGuardrails {
                cooldown: std::time::Duration::from_secs(0),
                max_concurrent: 1,
                dedup_window: None,
                retry: Default::default(),
            },
            notify: Default::default(),
            last_run_at: None,
            next_fire_at: None,
            run_count: 0,
            consecutive_failures: 0,
            state: serde_json::json!({}),
            created_at: Utc::now(),
            updated_at: Utc::now(),
        }
    }

    fn make_run_at(
        routine_id: Uuid,
        job_id: Option<Uuid>,
        status: RunStatus,
        started_at: DateTime<Utc>,
    ) -> RoutineRun {
        RoutineRun {
            id: Uuid::new_v4(),
            routine_id,
            trigger_type: "manual".to_string(),
            trigger_detail: None,
            started_at,
            completed_at: None,
            status,
            result_summary: None,
            tokens_used: None,
            job_id,
            created_at: Utc::now(),
        }
    }

    /// The sweep must return *only* the run that is simultaneously running,
    /// job-less (lightweight), and older than the cutoff — exercising every
    /// clause of the `list_stuck_lightweight_runs` WHERE filter.
    #[tokio::test]
    async fn list_stuck_lightweight_returns_only_old_running_jobless_runs() {
        let (db, _tmp) = create_test_db().await;
        let routine_id = Uuid::new_v4();
        db.create_routine(&make_routine(routine_id))
            .await
            .expect("create routine");

        let now = Utc::now();
        let old = now - Duration::hours(1); // before cutoff -> stuck
        let recent = now - Duration::seconds(10); // after cutoff -> legitimately running
        let cutoff = now - Duration::minutes(5);

        // (1) STUCK: old, running, no job_id -> the only run that should be swept.
        let stuck = make_run_at(routine_id, None, RunStatus::Running, old);
        db.create_routine_run(&stuck).await.expect("create stuck");

        // (2) Fresh lightweight running run -> still within timeout, must be left alone.
        let fresh = make_run_at(routine_id, None, RunStatus::Running, recent);
        db.create_routine_run(&fresh).await.expect("create fresh");

        // (3) Old *dispatched* run (carries job_id) -> recovered by the FullJob path,
        //     not the lightweight sweeper, so it must be excluded.
        let job = JobContext::new("dispatched", "full job");
        db.save_job(&job).await.expect("save job");
        let dispatched = make_run_at(routine_id, Some(job.job_id), RunStatus::Running, old);
        db.create_routine_run(&dispatched)
            .await
            .expect("create dispatched");

        // (4) Old but already-finalized lightweight run -> not running, excluded.
        let mut done = make_run_at(routine_id, None, RunStatus::Ok, old);
        done.completed_at = Some(old);
        db.create_routine_run(&done).await.expect("create done");

        let stuck_runs = db
            .list_stuck_lightweight_runs(cutoff)
            .await
            .expect("list stuck");

        assert_eq!(
            stuck_runs.len(),
            1,
            "only the old, running, job-less run should be swept; got {:?}",
            stuck_runs.iter().map(|r| r.id).collect::<Vec<_>>()
        );
        assert_eq!(stuck_runs[0].id, stuck.id);
        assert_eq!(stuck_runs[0].status, RunStatus::Running);
        assert!(stuck_runs[0].job_id.is_none());
    }

    /// After the sweeper finalizes a stuck run via `complete_routine_run`, a second
    /// sweep must not see it again — recovery is idempotent and won't loop.
    #[tokio::test]
    async fn finalizing_stuck_run_removes_it_from_subsequent_sweeps() {
        let (db, _tmp) = create_test_db().await;
        let routine_id = Uuid::new_v4();
        db.create_routine(&make_routine(routine_id))
            .await
            .expect("create routine");

        let now = Utc::now();
        let old = now - Duration::hours(1);
        let cutoff = now - Duration::minutes(5);

        let stuck = make_run_at(routine_id, None, RunStatus::Running, old);
        db.create_routine_run(&stuck).await.expect("create stuck");

        let before = db
            .list_stuck_lightweight_runs(cutoff)
            .await
            .expect("list before");
        assert_eq!(before.len(), 1, "stuck run should be detected first");

        // Mirror exactly what sweep_stuck_lightweight_runs() does on each stuck run.
        db.complete_routine_run(
            stuck.id,
            RunStatus::Failed,
            Some("Timed out (stuck run recovery)"),
            None,
        )
        .await
        .expect("finalize stuck run");

        let after = db
            .list_stuck_lightweight_runs(cutoff)
            .await
            .expect("list after");
        assert!(
            after.is_empty(),
            "a finalized run must not be swept again (idempotent recovery)"
        );
    }

    /// An empty table must sweep cleanly to an empty result (no false positives,
    /// no error) — the common steady-state path on every cron tick.
    #[tokio::test]
    async fn no_stuck_runs_when_table_empty() {
        let (db, _tmp) = create_test_db().await;
        let cutoff = Utc::now();
        let runs = db
            .list_stuck_lightweight_runs(cutoff)
            .await
            .expect("list stuck on empty table");
        assert!(runs.is_empty());
    }
}
