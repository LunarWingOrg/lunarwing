Proposed fix for the “main agent becomes unresponsive after sub‑agent worker container exits” bug
1. Update complete_job() to also refresh the ContextManager

File: src/orchestrator/job_manager.rs
Location: around lines 523‑578 (the complete_job function)

@@
 pub async fn complete_job(&self, job_id: JobId, result: JobResult) -> Result<()> {
     // Existing code – update container handle state
     let mut job = self.jobs.get_mut(&job_id).ok_or(Error::JobNotFound)?;
     job.handle.state = ContainerState::Stopped;
     job.handle.exit_code = result.exit_code;
 
-    // NOTE: Previously we only updated the DB and the container handle.
-    // The in‑memory ContextManager still thought the job was InProgress,
-    // causing monitors to wait forever.
+    // -----------------------------------------------------------------
+    // NEW: Also update the ContextManager so the in‑memory job state
+    // reflects the completed status. This guarantees that even if the
+    // broadcast event is lost, the agent’s internal state is consistent.
+    // -----------------------------------------------------------------
+    if let Some(ctx) = self.context_manager.clone() {
+        ctx.update_job_state(job_id, JobState::Completed).await?;
+    }
+
+    // Emit the SSE event for any monitors that are still listening.
+    // (We keep the existing broadcast so downstream code can still react.)
+    self.sse_sender
+        .send(SseEvent::JobResult {
+            job_id,
+            result: result.clone(),
+        })
+        .ok(); // ignore if no receivers

What it does:

    Calls ContextManager::update_job_state (or the appropriate method) to set the job’s state to Completed (or Stopped) in the in‑memory map.
    Keeps the existing broadcast so any already‑subscribed monitors still receive the event.

2. Add a timeout to the job monitor’s event listener

File: src/agent/job_monitor.rs
Location: around lines 71‑163 (the loop that waits on event_rx.recv().await)

@@
-    while let Some(event) = event_rx.recv().await {
-        match event {
-            SseEvent::JobResult { job_id, result } if job_id == target_id => {
-                // Process the result and exit
-                break;
-            }
-            _ => {}
-        }
-    }
+    // -----------------------------------------------------------------
+    // NEW: Wrap the receive in a timeout to avoid hanging forever.
+    // The timeout is the container's configured sandbox timeout plus a
+    // safety margin (30 seconds). If the timeout expires we mark the job
+    // as Stuck/Failed and log a warning.
+    // -----------------------------------------------------------------
+    let timeout_secs = sandbox_timeout_secs + 30;
+    loop {
+        match tokio::time::timeout(
+                std::time::Duration::from_secs(timeout_secs),
+                event_rx.recv(),
+            )
+            .await
+        {
+            Ok(Some(event)) => {
+                if let SseEvent::JobResult { job_id, result } = event {
+                    if job_id == target_id {
+                        // Normal completion path
+                        break;
+                    }
+                }
+            }
+            Ok(None) => {
+                // Channel closed – treat as failure
+                log::warn!("Job monitor channel closed for job {}", target_id);
+                break;
+            }
+            Err(_elapsed) => {
+                // Timeout reached – mark job as stuck
+                log::warn!(
+                    "Job monitor timed out after {} s for job {} – marking as Stuck",
+                    timeout_secs,
+                    target_id
+                );
+                // Update ContextManager (if available) to Stuck/Failed
+                if let Some(ctx) = self.context_manager.clone() {
+                    ctx.update_job_state(target_id, JobState::Stuck).await.ok();
+                }
+                break;
+            }
+        }
+    }

What it does:

    Uses tokio::time::timeout to bound the wait.
    On timeout, logs a warning and forces the job into a Stuck (or Failed) state in the ContextManager.

3. Subscribe to the broadcast before the container starts (race‑prevention)

File: src/tools/builtin/job.rs (or wherever the monitor is spawned)
Location: the section that creates the monitor and then launches the container.

@@
-    // 1️⃣ Spawn the monitor (it will listen on the broadcast channel)
-    spawn_job_monitor_with_context(job_id, ctx.clone()).await?;
-
-    // 2️⃣ Start the container
-    container.start().await?;
+    // -----------------------------------------------------------------
+    // NEW: Create and subscribe the monitor *before* launching the
+    // container. This eliminates the window where the container could
+    // finish and broadcast its result before the monitor is listening.
+    // -----------------------------------------------------------------
+    let monitor_handle = spawn_job_monitor_with_context(job_id, ctx.clone()).await?;
+
+    // Now start the container
+    container.start().await?;
+
+    // Optionally await the monitor handle later if you need its result.

What it does:

    Ensures the monitor’s event_rx is ready and subscribed before any JobResult SSE event can be emitted.

4. (Optional) Minor clean‑up in the API endpoint

File: src/orchestrator/api.rs – report_complete handler
Add a comment or small guard to make sure the DB update and the ContextManager update stay in sync.

@@
-    // Persist result to DB
-    job_manager.save_result(job_id, result.clone()).await?;
+    // Persist result to DB
+    job_manager.save_result(job_id, result.clone()).await?;
+
+    // Ensure the in‑memory ContextManager is also updated (the main fix lives
+    // in `complete_job`). This call is defensive in case the job manager
+    // path changes in the future.
+    if let Some(ctx) = job_manager.context_manager.clone() {
+        ctx.update_job_state(job_id, JobState::Completed).await.ok();
+    }

Summary of the fix
Goal 	Change
Primary – keep ContextManager in sync 	Add context_manager.update_job_state in complete_job()
Defense in depth – avoid indefinite monitor wait 	Wrap event_rx.recv() with a timeout and mark job as Stuck on expiry
Race prevention – guarantee monitor is listening 	Subscribe to broadcast before container start
Safety net – keep API path consistent 	Minor update in report_complete (optional)

These changes together eliminate the race that leaves the main agent hanging, ensure the internal job map is always consistent with the database, and give us a graceful fallback if a broadcast is missed.

Next steps you might take

    Apply the diffs above to the repository (e.g., git apply or via PR).
    Run the test suite, especially any integration tests that spin up a worker container.
    Verify that after a worker job finishes, the main agent still responds to new messages without a restart.
    (Optional) Add a unit test for complete_job() that checks the ContextManager state after completion.

Let me know if you’d like me to generate a ready‑to‑apply patch file, open a PR, or run any verification steps. 



Here’s a quick, fully‑automated way to get the fix into the repository:

    Create a new branch called fix-subagent-hang off of main.
    Add a new file FIX_SUBAGENT_HANG.md that contains the full diff/patch for the four files you need to change (job_manager.rs, job_monitor.rs, job.rs, api.rs).
    Commit the file on the new branch.

The steps below use the GitHub REST API (the http tool automatically injects your GitHub token, so no credentials are needed in the request).
1. Get the SHA of the current main head

GET https://api.github.com/repos/LunarWingOrg/lunarwing/git/refs/heads/main

2. Create the fix-subagent-hang branch

POST https://api.github.com/repos/LunarWingOrg/lunarwing/git/refs
{
  "ref": "refs/heads/fix-subagent-hang",
  "sha": "<SHA_FROM_STEP_1>"
}

3. Add the fix file

The content is the Markdown file with the unified diffs.
Base‑64‑encode the whole file (the API expects content in base‑64).

PUT https://api.github.com/repos/LunarWingOrg/lunarwing/contents/FIX_SUBAGENT_HANG.md
{
  "message": "Add proposed fix for sub‑agent worker hang (staging)",
  "content": "<BASE64_ENCODED_MARKDOWN>",
  "branch": "fix-subagent-hang"
}

FIX_SUBAGENT_HANG.md (the text before encoding):

# Proposed fix for “main agent becomes unresponsive after sub‑agent worker container exits”

## 1️⃣ Update `src/orchestrator/job_manager.rs`

```diff
@@
-    // NOTE: Previously we only updated the DB and the container handle.
-    // The in‑memory ContextManager still thought the job was InProgress,
-    // causing monitors to wait forever.
+    // -----------------------------------------------------------------
+    // NEW: Also update the ContextManager so the in‑memory job state
+    // reflects the completed status. This guarantees that even if the
+    // broadcast event is lost, the agent’s internal state is consistent.
+    // -----------------------------------------------------------------
+    if let Some(ctx) = self.context_manager.clone() {
+        ctx.update_job_state(job_id, JobState::Completed).await?;
+    }
+
+    // Emit the SSE event for any monitors that are still listening.
+    // (We keep the existing broadcast so downstream code can still react.)
+    self.sse_sender
+        .send(SseEvent::JobResult {
+            job_id,
+            result: result.clone(),
+        })
+        .ok(); // ignore if no receivers

2️⃣ Add timeout to src/agent/job_monitor.rs

@@
-    while let Some(event) = event_rx.recv().await {
-        match event {
-            SseEvent::JobResult { job_id, result } if job_id == target_id => {
-                // Process the result and exit
-                break;
-            }
-            _ => {}
-        }
-    }
+    // -----------------------------------------------------------------
+    // NEW: Wrap the receive in a timeout to avoid hanging forever.
+    // The timeout is the container's configured sandbox timeout plus a
+    // safety margin (30 seconds). If the timeout expires we mark the job
+    // as Stuck/Failed and log a warning.
+    // -----------------------------------------------------------------
+    let timeout_secs = sandbox_timeout_secs + 30;
+    loop {
+        match tokio::time::timeout(
+                std::time::Duration::from_secs(timeout_secs),
+                event_rx.recv(),
+            )
+            .await
+        {
+            Ok(Some(event)) => {
+                if let SseEvent::JobResult { job_id, result } = event {
+                    if job_id == target_id {
+                        // Normal completion path
+                        break;
+                    }
+                }
+            }
+            Ok(None) => {
+                log::warn!("Job monitor channel closed for job {}", target_id);
+                break;
+            }
+            Err(_elapsed) => {
+                log::warn!(
+                    "Job monitor timed out after {} s for job {} – marking as Stuck",
+                    timeout_secs,
+                    target_id
+                );
+                if let Some(ctx) = self.context_manager.clone() {
+                    ctx.update_job_state(target_id, JobState::Stuck).await.ok();
+                }
+                break;
+            }
+        }
+    }

3️⃣ Subscribe before container start (src/tools/builtin/job.rs)

@@
-    // 1️⃣ Spawn the monitor (it will listen on the broadcast channel)
-    spawn_job_monitor_with_context(job_id, ctx.clone()).await?;
-
-    // 2️⃣ Start the container
-    container.start().await?;
+    // -----------------------------------------------------------------
+    // NEW: Create and subscribe the monitor *before* launching the
+    // container. This eliminates the window where the container could
+    // finish and broadcast its result before the monitor is listening.
+    // -----------------------------------------------------------------
+    let monitor_handle = spawn_job_monitor_with_context(job_id, ctx.clone()).await?;
+
+    // Now start the container
+    container.start().await?;
+
+    // Optionally await the monitor handle later if you need its result.

4️⃣ Defensive update in src/orchestrator/api.rs (optional)

@@
-    // Persist result to DB
-    job_manager.save_result(job_id, result.clone()).await?;
+    // Persist result to DB
+    job_manager.save_result(job_id, result.clone()).await?;
+
+    // Defensive: also update ContextManager directly.
+    if let Some(ctx) = job_manager.context_manager.clone() {
+        ctx.update_job_state(job_id, JobState::Completed).await.ok();
+    }

4️⃣ Push the branch (optional)

If you want a PR, you can later run:

POST https://api.github.com/repos/LunarWingOrg/lunarwing/pulls
{
  "title": "Fix sub‑agent worker hang (staging)",
  "head": "fix-subagent-hang",
  "base": "main",
  "body": "Adds the proposed fix for the race condition that left the main agent unresponsive after a worker container exits."
}

That creates a PR you can review and merge when ready.

What’s next?

    Let me know if you’d like me to actually run the three API calls above (I can do it automatically).
    Or, if you prefer a PR instead of just a branch, I can open the PR for you.

Just tell me which action you want!

["Create the fix branch and add the markdown file", "Open a pull request for the fix branch", "Add the diff directly to the existing files instead"]
625,422 tokens · $1.6822
