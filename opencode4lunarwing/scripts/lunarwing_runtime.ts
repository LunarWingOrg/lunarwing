/**
 * lunarwing_runtime.ts — Shared types, envelope helpers, and state file management
 * for the LunarWing WebSocket protocol (lunarwing-agent-v1, with the legacy
 * ironclaw-agent-v1 alias still accepted for one deprecation cycle).
 *
 * Adapted for the opencode worker (upstream sst/opencode).
 */

import { randomUUID } from "crypto"
import { writeFileSync, readFileSync } from "fs"

// ── Protocol Envelope ─────────────────────────────────────────────────────────

export interface Envelope {
  id: string
  type: string
  timestamp: string
  payload: Record<string, unknown>
}

export function createEnvelope(type: string, payload: Record<string, unknown>): Envelope {
  return {
    id: randomUUID(),
    type,
    timestamp: new Date().toISOString(),
    payload,
  }
}

export function parseEnvelope(data: string): Envelope | null {
  try {
    const msg = JSON.parse(data)
    if (msg && typeof msg.type === "string" && msg.payload !== null && typeof msg.payload === "object") {
      return msg as Envelope
    }
    return null
  } catch {
    return null
  }
}

// ── Message Types ─────────────────────────────────────────────────────────────

export interface TaskContext {
  project_dir?: string
  conversation_history?: Array<{ role: string; content: string }>
  environment?: Record<string, string>
  user_id?: string
  metadata?: Record<string, string>
}

export interface TaskRequest {
  task_id: string
  prompt: string
  context?: TaskContext
  timeout_ms?: number
}

export interface TaskProgress {
  task_id: string
  delta: string
  done: boolean
}

export interface TaskResult {
  task_id: string
  status: "success" | "error" | "cancelled"
  output: string
  error: string | null
  duration_ms: number
}

export interface ReadyPayload {
  worker_id: string
  version: string
  mode: string
}

// ── State File (IPC with health_server.py) ────────────────────────────────────

export interface WsState {
  timestamp: string
  ready: boolean
  role: string
  listening?: boolean
  bind_host?: string
  port?: number
  path?: string
  connections: number
  connected_to?: string
}

const WS_STATE_FILE = process.env.WS_STATE_FILE || "/tmp/lunarwing_ws_state.json"

export function writeWsState(state: WsState): void {
  try {
    writeFileSync(WS_STATE_FILE, JSON.stringify(state, null, 2))
  } catch (err) {
    console.error("[lunarwing_runtime] failed to write state file:", err)
  }
}

export function readWsState(): WsState | null {
  try {
    const data = readFileSync(WS_STATE_FILE, "utf-8")
    return JSON.parse(data)
  } catch {
    return null
  }
}

// ── Constants ─────────────────────────────────────────────────────────────────

export const SUBPROTOCOL = "lunarwing-agent-v1"
// Legacy alias still accepted for one deprecation cycle: old daemons offer
// only this value in their Sec-WebSocket-Protocol header.
export const LEGACY_SUBPROTOCOL = "ironclaw-agent-v1"
export const DEFAULT_TIMEOUT_MS = 300_000
export const WORKER_ID = process.env.LUNARWING_WORKER_ID || "worker-opencode-01"
export const WORKER_VERSION = "opencode-worker-1.0.0"
