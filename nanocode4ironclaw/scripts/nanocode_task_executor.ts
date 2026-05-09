/**
 * nanocode_task_executor.ts — Executes coding tasks via the nanocode SDK.
 *
 * Uses the local nanocode headless server (HTTP/SSE) to create sessions,
 * send prompts, and stream events back to the caller.
 */

import { createOpencodeClient, type OpencodeClient } from "@nanogpt/sdk/v2"
import {
  type TaskRequest,
  type TaskProgress,
  type TaskResult,
  DEFAULT_TIMEOUT_MS,
} from "./ironclaw_runtime"

const NANOCODE_HOST = process.env.NANOCODE_SERVE_HOST || "127.0.0.1"
const NANOCODE_PORT = process.env.NANOCODE_SERVE_PORT || "4096"
const NANOCODE_BASE_URL = `http://${NANOCODE_HOST}:${NANOCODE_PORT}`
const WORKSPACE_ROOT = process.env.WORKSPACE_ROOT || "/workspace"

function getPassword(): string | undefined {
  return process.env.NANOGPT_SERVER_PASSWORD
}

function createSdk(directory?: string): OpencodeClient {
  const password = getPassword()
  const headers: Record<string, string> = {}
  if (password) {
    const username = process.env.NANOGPT_SERVER_USERNAME ?? "nanocode"
    headers["Authorization"] = `Basic ${Buffer.from(`${username}:${password}`).toString("base64")}`
  }

  return createOpencodeClient({
    baseUrl: NANOCODE_BASE_URL,
    directory: directory || WORKSPACE_ROOT,
    headers: Object.keys(headers).length > 0 ? headers : undefined,
  })
}

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
  const workDir = request.context?.path
    ? resolveWorkDir(request.context.path as string)
    : WORKSPACE_ROOT

  const sdk = createSdk(workDir)
  let sessionID: string | undefined
  let output = ""
  let timedOut = false

  const timeout = setTimeout(() => {
    timedOut = true
  }, timeoutMs)

  try {
    // Create session with full-auto permissions (headless mode)
    const sessionResult = await sdk.session.create({
      title: `ironclaw-${request.task_id}`,
      permission: [
        { permission: "edit", action: "allow", pattern: "*" },
        { permission: "bash", action: "allow", pattern: "*" },
        { permission: "read", action: "allow", pattern: "*" },
        { permission: "write", action: "allow", pattern: "*" },
        { permission: "question", action: "deny", pattern: "*" },
        { permission: "plan_enter", action: "deny", pattern: "*" },
        { permission: "plan_exit", action: "deny", pattern: "*" },
      ],
    })

    sessionID = sessionResult.data?.id
    if (!sessionID) {
      throw new Error("Failed to create nanocode session")
    }

    // Subscribe to SSE events
    const events = await sdk.event.subscribe()

    // Send the prompt
    const promptPromise = sdk.session.prompt({
      sessionID,
      parts: [{ type: "text", text: request.prompt }],
    })

    // Process events
    for await (const event of events.stream) {
      if (abortSignal?.aborted || timedOut) break

      if (event.type === "message.part.updated") {
        const part = event.properties.part
        if (part.sessionID !== sessionID) continue

        if (part.type === "text" && part.time?.end) {
          const text = part.text?.trim()
          if (text) {
            output += text + "\n"
            onProgress({
              task_id: request.task_id,
              delta: text,
              done: false,
            })
          }
        }

        if (part.type === "tool" && part.state?.status === "completed") {
          const toolOutput = part.state.output?.trim()
          const toolName = part.tool || "unknown"
          const delta = `[${toolName}] ${toolOutput || "completed"}`
          output += delta + "\n"
          onProgress({
            task_id: request.task_id,
            delta,
            done: false,
          })
        }
      }

      if (event.type === "session.error") {
        if (event.properties.sessionID !== sessionID) continue
        const err = event.properties.error
        const errMsg = err?.data?.message || err?.name || "Unknown error"
        output += `ERROR: ${errMsg}\n`
      }

      if (event.type === "permission.asked") {
        if (event.properties.sessionID !== sessionID) continue
        // Auto-reject any permission requests in headless mode
        await sdk.permission.reply({
          requestID: event.properties.id,
          reply: "reject",
        })
      }

      if (
        event.type === "session.status" &&
        event.properties.sessionID === sessionID &&
        event.properties.status?.type === "idle"
      ) {
        break
      }
    }

    await promptPromise.catch(() => {})

    const durationMs = Date.now() - startTime

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

    onResult({
      task_id: request.task_id,
      status: "success",
      output: output.trim(),
      error: null,
      duration_ms: durationMs,
    })
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
    clearTimeout(timeout)
  }
}

function resolveWorkDir(path: string): string {
  if (path.startsWith("/")) return path
  return `${WORKSPACE_ROOT}/${path}`
}
