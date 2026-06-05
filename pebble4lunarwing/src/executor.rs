use std::process::Stdio;
use std::time::Instant;

use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::Command;
use tokio::sync::mpsc;

use crate::protocol::{self, Envelope};

pub struct ExecutorConfig {
    pub pebble_bin: String,
    pub model: String,
    pub permission_mode: String,
    pub workspace_root: String,
}

pub enum ExecutorEvent {
    Progress(Envelope),
    Result(Envelope),
}

pub async fn run_task(
    config: &ExecutorConfig,
    request: &protocol::TaskRequest,
    event_tx: mpsc::UnboundedSender<ExecutorEvent>,
    cancel_rx: tokio::sync::oneshot::Receiver<()>,
) {
    let start = Instant::now();
    let timeout_ms = request.timeout_ms.unwrap_or(protocol::DEFAULT_TIMEOUT_MS);

    let mut child = match spawn_pebble(config, request) {
        Ok(child) => child,
        Err(e) => {
            let _ = event_tx.send(ExecutorEvent::Result(protocol::result_envelope(
                &request.task_id,
                "error",
                "",
                Some(&format!("failed to spawn pebble: {e}")),
                elapsed_ms(start),
            )));
            return;
        }
    };

    let stdout = child.stdout.take().expect("stdout piped");
    let stderr = child.stderr.take().expect("stderr piped");

    let task_id = request.task_id.clone();
    let tx_stderr = event_tx.clone();
    let task_id_stderr = task_id.clone();

    let stderr_handle = tokio::spawn(async move {
        let mut reader = BufReader::new(stderr).lines();
        while let Ok(Some(line)) = reader.next_line().await {
            if !line.trim().is_empty() {
                let _ = tx_stderr.send(ExecutorEvent::Progress(protocol::progress_envelope(
                    &task_id_stderr,
                    &format!("[stderr] {line}"),
                )));
            }
        }
    });

    let (outcome, accumulated_output, final_message) = stream_stdout(
        stdout, &task_id, &event_tx, timeout_ms, cancel_rx, &mut child,
    )
    .await;

    let _ = stderr_handle.await;

    let duration_ms = elapsed_ms(start);
    let output = final_message.as_deref().unwrap_or(&accumulated_output);

    let result = build_result(
        &task_id,
        outcome,
        output,
        &mut child,
        timeout_ms,
        duration_ms,
    )
    .await;
    let _ = event_tx.send(ExecutorEvent::Result(result));
}

fn spawn_pebble(
    config: &ExecutorConfig,
    request: &protocol::TaskRequest,
) -> Result<tokio::process::Child, std::io::Error> {
    Command::new(&config.pebble_bin)
        .args([
            "--output-format",
            "ndjson",
            "--permission-mode",
            &config.permission_mode,
            "--model",
            &config.model,
            "prompt",
        ])
        .arg(&request.prompt)
        .current_dir(&config.workspace_root)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
}

async fn stream_stdout(
    stdout: tokio::process::ChildStdout,
    task_id: &str,
    event_tx: &mpsc::UnboundedSender<ExecutorEvent>,
    timeout_ms: u64,
    mut cancel_rx: tokio::sync::oneshot::Receiver<()>,
    child: &mut tokio::process::Child,
) -> (Outcome, String, Option<String>) {
    let timeout = tokio::time::Duration::from_millis(timeout_ms);
    let mut accumulated_output = String::new();
    let mut final_message: Option<String> = None;
    let mut reader = BufReader::new(stdout).lines();

    let outcome = tokio::select! {
        result = async {
            while let Ok(Some(line)) = reader.next_line().await {
                if line.trim().is_empty() {
                    continue;
                }
                if let Some(early) = process_ndjson_line(
                    &line, task_id, event_tx, &mut accumulated_output, &mut final_message,
                ) {
                    return early;
                }
            }
            Outcome::Completed
        } => result,

        () = tokio::time::sleep(timeout) => {
            let _ = child.kill().await;
            Outcome::Timeout
        },

        _ = &mut cancel_rx => {
            let _ = child.kill().await;
            Outcome::Cancelled
        },
    };

    (outcome, accumulated_output, final_message)
}

fn process_ndjson_line(
    line: &str,
    task_id: &str,
    event_tx: &mpsc::UnboundedSender<ExecutorEvent>,
    accumulated_output: &mut String,
    final_message: &mut Option<String>,
) -> Option<Outcome> {
    let Ok(parsed) = serde_json::from_str::<serde_json::Value>(line) else {
        accumulated_output.push_str(line);
        accumulated_output.push('\n');
        let _ = event_tx.send(ExecutorEvent::Progress(protocol::progress_envelope(
            task_id, line,
        )));
        return None;
    };

    let event_type = parsed
        .get("type")
        .and_then(serde_json::Value::as_str)
        .unwrap_or("");

    match event_type {
        "result" => {
            *final_message = parsed
                .get("message")
                .and_then(serde_json::Value::as_str)
                .map(String::from);
            None
        }
        "error" => {
            let err_msg = parsed
                .get("error")
                .and_then(serde_json::Value::as_str)
                .unwrap_or("unknown error");
            Some(Outcome::Error(err_msg.to_string()))
        }
        "assistant" => {
            let text = parsed
                .get("text")
                .and_then(serde_json::Value::as_str)
                .unwrap_or("");
            if !text.is_empty() {
                accumulated_output.push_str(text);
                let _ = event_tx.send(ExecutorEvent::Progress(protocol::progress_envelope(
                    task_id, text,
                )));
            }
            None
        }
        "tool_start" => {
            let tool = parsed
                .get("tool")
                .and_then(serde_json::Value::as_str)
                .unwrap_or("?");
            let input = parsed
                .get("input")
                .and_then(serde_json::Value::as_str)
                .unwrap_or("");
            let delta = format!("[tool:{tool}] {input}\n");
            let _ = event_tx.send(ExecutorEvent::Progress(protocol::progress_envelope(
                task_id, &delta,
            )));
            None
        }
        "tool_end" => {
            let tool = parsed
                .get("tool")
                .and_then(serde_json::Value::as_str)
                .unwrap_or("?");
            let ok = parsed
                .get("ok")
                .and_then(serde_json::Value::as_bool)
                .unwrap_or(false);
            let label = if ok { "done" } else { "error" };
            let delta = format!("[tool:{tool}] {label}\n");
            let _ = event_tx.send(ExecutorEvent::Progress(protocol::progress_envelope(
                task_id, &delta,
            )));
            None
        }
        "iteration" => {
            let n = parsed
                .get("n")
                .and_then(serde_json::Value::as_u64)
                .unwrap_or(0);
            let delta = format!("[iteration {n}]\n");
            let _ = event_tx.send(ExecutorEvent::Progress(protocol::progress_envelope(
                task_id, &delta,
            )));
            None
        }
        _ => {
            let _ = event_tx.send(ExecutorEvent::Progress(protocol::progress_envelope(
                task_id, line,
            )));
            None
        }
    }
}

async fn build_result(
    task_id: &str,
    outcome: Outcome,
    output: &str,
    child: &mut tokio::process::Child,
    timeout_ms: u64,
    duration_ms: u64,
) -> Envelope {
    match outcome {
        Outcome::Completed => {
            let code = child.wait().await.ok().and_then(|s| s.code()).unwrap_or(-1);
            if code == 0 || !output.is_empty() {
                protocol::result_envelope(task_id, "success", output, None, duration_ms)
            } else {
                protocol::result_envelope(
                    task_id,
                    "error",
                    output,
                    Some(&format!("pebble exited with code {code}")),
                    duration_ms,
                )
            }
        }
        Outcome::Timeout => protocol::result_envelope(
            task_id,
            "error",
            output,
            Some(&format!("task timed out after {timeout_ms}ms")),
            duration_ms,
        ),
        Outcome::Cancelled => {
            protocol::result_envelope(task_id, "cancelled", output, None, duration_ms)
        }
        Outcome::Error(ref msg) => {
            protocol::result_envelope(task_id, "error", output, Some(msg), duration_ms)
        }
    }
}

fn elapsed_ms(start: Instant) -> u64 {
    start.elapsed().as_millis().try_into().unwrap_or(u64::MAX)
}

enum Outcome {
    Completed,
    Timeout,
    Cancelled,
    Error(String),
}
