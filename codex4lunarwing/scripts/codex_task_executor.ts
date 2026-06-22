/**
 * codex_task_executor.ts — Executes coding tasks via the @openai/codex CLI.
 *
 * Spawns `codex` as a subprocess in full-auto mode and streams stdout/stderr
 * back as task_progress events.
 */

import { spawn, type Subprocess } from "bun"
import {
  type TaskRequest,
  type TaskProgress,
  type TaskResult,
  DEFAULT_TIMEOUT_MS,
} from "./lunarwing_runtime"

const WORKSPACE_ROOT = process.env.WORKSPACE_ROOT || "/workspace"
const CODEX_MODEL = process.env.CODEX_MODEL || "codex-mini-latest"

export type ProgressCallback = (progress: TaskProgress) => void
export type ResultCallback = (result: TaskResult) => void

export async function executeTask(
  request: TaskRequest,
  onProgress: ProgressCallback,
  onResult: ResultCallback,
  abortSignal?: AbortSignal,
): Promise<void> {
  const startTime = Date.now()
  const timeoutMs = request.timeout_ms ?? DEFAULT_TIMEOUT_MS
  const workDir = request.context?.project_dir
    ? resolveWorkDir(request.context.project_dir)
    : WORKSPACE_ROOT
  const extraEnv = request.context?.environment ?? {}

  let output = ""
  let proc: Subprocess | null = null
  let timedOut = false

  const timer = setTimeout(() => {
    timedOut = true
    if (proc) {
      proc.kill("SIGTERM")
      setTimeout(() => {
        if (proc && !proc.killed) proc.kill("SIGKILL")
      }, 5000)
    }
  }, timeoutMs)

  const onAbort = () => {
    if (proc && !proc.killed) {
      proc.kill("SIGTERM")
    }
  }

  if (abortSignal) {
    abortSignal.addEventListener("abort", onAbort, { once: true })
  }

  try {
    const args = [
      "--approval-mode", "full-auto",
      "--quiet",
      "--model", CODEX_MODEL,
      request.prompt,
    ]

    proc = spawn(["codex", ...args], {
      cwd: workDir,
      stdout: "pipe",
      stderr: "pipe",
      env: {
        ...process.env,
        ...extraEnv,
        CODEX_QUIET_MODE: "1",
      },
    })

    const readStream = async (
      stream: ReadableStream<Uint8Array> | null,
      prefix?: string,
    ) => {
      if (!stream) return
      const reader = stream.getReader()
      const decoder = new TextDecoder()

      try {
        while (true) {
          const { done, value } = await reader.read()
          if (done) break

          const text = decoder.decode(value, { stream: true })
          if (text) {
            const delta = prefix ? `[${prefix}] ${text}` : text
            output += delta
            onProgress({
              task_id: request.task_id,
              delta,
              done: false,
            })
          }
        }
      } catch {
        // stream closed
      } finally {
        reader.releaseLock()
      }
    }

    await Promise.all([
      readStream(proc.stdout as ReadableStream<Uint8Array>),
      readStream(proc.stderr as ReadableStream<Uint8Array>, "stderr"),
    ])

    const exitCode = await proc.exited
    const durationMs = Date.now() - startTime

    if (abortSignal?.aborted) {
      onResult({
        task_id: request.task_id,
        status: "cancelled",
        output: output.trim(),
        error: null,
        duration_ms: durationMs,
      })
      return
    }

    if (timedOut) {
      onResult({
        task_id: request.task_id,
        status: "error",
        output: output.trim(),
        error: `Task timed out after ${timeoutMs}ms`,
        duration_ms: durationMs,
      })
      return
    }

    if (exitCode === 0) {
      onResult({
        task_id: request.task_id,
        status: "success",
        output: output.trim(),
        error: null,
        duration_ms: durationMs,
      })
    } else {
      onResult({
        task_id: request.task_id,
        status: "error",
        output: output.trim(),
        error: `codex exited with code ${exitCode}`,
        duration_ms: durationMs,
      })
    }
  } catch (err) {
    const durationMs = Date.now() - startTime
    const errorMsg = err instanceof Error ? err.message : String(err)
    onResult({
      task_id: request.task_id,
      status: "error",
      output: output.trim(),
      error: errorMsg,
      duration_ms: durationMs,
    })
  } finally {
    clearTimeout(timer)
    if (abortSignal) {
      abortSignal.removeEventListener("abort", onAbort)
    }
  }
}

function resolveWorkDir(path: string): string {
  if (path.startsWith("/")) return path
  return `${WORKSPACE_ROOT}/${path}`
}
