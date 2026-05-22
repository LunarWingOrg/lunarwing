/**
 * lunarwing_bridge.ts — WebSocket bridge between LunarWing agents and the
 * OpenAI Codex CLI worker. Implements the ironclaw-agent-v1 subprotocol.
 *
 * Supports two roles:
 *   server — listens for inbound agent connections (default)
 *   client — connects outbound to a hub
 */

import {
  createEnvelope,
  parseEnvelope,
  writeWsState,
  SUBPROTOCOL,
  WORKER_ID,
  WORKER_VERSION,
  type Envelope,
  type TaskRequest,
  type WsState,
} from "./lunarwing_runtime"
import { executeTask } from "./codex_task_executor"

// ── Configuration ─────────────────────────────────────────────────────────────

const WS_ROLE = process.env.WS_ROLE || "server"
const WS_BIND_HOST = process.env.WS_BIND_HOST || "0.0.0.0"
const WS_PORT = parseInt(process.env.WS_PORT || "9090", 10)
const WS_PATH = process.env.WS_PATH || "/ws/agent"
const WS_URL = process.env.WS_URL || ""
const AGENT_AUTH_TOKEN = process.env.AGENT_AUTH_TOKEN || ""
const RECONNECT_MS = parseInt(process.env.RECONNECT_MS || "3000", 10)
const PING_INTERVAL_MS = parseInt(process.env.PING_INTERVAL_MS || "20000", 10)

// ── Active Tasks ──────────────────────────────────────────────────────────────

const activeTasks = new Map<string, AbortController>()

// ── Message Handling ──────────────────────────────────────────────────────────

function sendReady(ws: { send(data: string): void }): void {
  const msg = createEnvelope("ready", {
    worker_id: WORKER_ID,
    version: WORKER_VERSION,
    mode: "websocket",
  })
  ws.send(JSON.stringify(msg))
}

async function handleMessage(data: string, ws: { send(data: string): void }): Promise<void> {
  const envelope = parseEnvelope(data)
  if (!envelope) {
    console.error("[bridge] failed to parse message:", data.slice(0, 200))
    return
  }

  switch (envelope.type) {
    case "task_request":
      await handleTaskRequest(envelope.payload as unknown as TaskRequest, ws)
      break

    case "cancel":
      handleCancel(envelope.payload as { task_id: string })
      break

    case "ping":
      ws.send(JSON.stringify(createEnvelope("pong", {})))
      break

    default:
      console.warn("[bridge] unknown message type:", envelope.type)
  }
}

async function handleTaskRequest(
  request: TaskRequest,
  ws: { send(data: string): void },
): Promise<void> {
  if (!request.task_id || !request.prompt) {
    const errMsg = createEnvelope("task_result", {
      task_id: request.task_id || "unknown",
      status: "error",
      output: "",
      error: "Missing task_id or prompt",
      duration_ms: 0,
    })
    ws.send(JSON.stringify(errMsg))
    return
  }

  console.log(`[bridge] task ${request.task_id}: starting`)

  const controller = new AbortController()
  activeTasks.set(request.task_id, controller)

  try {
    await executeTask(
      request,
      (progress) => {
        const msg = createEnvelope("task_progress", progress as unknown as Record<string, unknown>)
        ws.send(JSON.stringify(msg))
      },
      (result) => {
        const msg = createEnvelope("task_result", result as unknown as Record<string, unknown>)
        ws.send(JSON.stringify(msg))
        console.log(`[bridge] task ${request.task_id}: ${result.status} (${result.duration_ms}ms)`)
      },
      controller.signal,
    )
  } finally {
    activeTasks.delete(request.task_id)
  }
}

function handleCancel(payload: { task_id: string }): void {
  const controller = activeTasks.get(payload.task_id)
  if (controller) {
    console.log(`[bridge] task ${payload.task_id}: cancelled`)
    controller.abort()
  } else {
    console.warn(`[bridge] cancel: task ${payload.task_id} not found`)
  }
}

// ── Server Role ───────────────────────────────────────────────────────────────

function startServer(): void {
  let connectionCount = 0

  function updateState(ready: boolean): void {
    writeWsState({
      timestamp: new Date().toISOString(),
      ready,
      role: "server",
      listening: true,
      bind_host: WS_BIND_HOST,
      port: WS_PORT,
      path: WS_PATH,
      connections: connectionCount,
    })
  }

  const server = Bun.serve({
    hostname: WS_BIND_HOST,
    port: WS_PORT,
    fetch(req, server) {
      const url = new URL(req.url)

      if (url.pathname !== WS_PATH) {
        return new Response("Not Found", { status: 404 })
      }

      // Validate bearer token
      if (AGENT_AUTH_TOKEN) {
        const authHeader = req.headers.get("authorization") || ""
        const token = authHeader.replace(/^Bearer\s+/i, "")
        if (token !== AGENT_AUTH_TOKEN) {
          return new Response("Unauthorized", { status: 401 })
        }
      }

      // Validate subprotocol
      const protocols = req.headers.get("sec-websocket-protocol") || ""
      if (!protocols.split(",").map((p) => p.trim()).includes(SUBPROTOCOL)) {
        return new Response(`Subprotocol ${SUBPROTOCOL} required`, { status: 400 })
      }

      const upgraded = server.upgrade(req, {
        headers: { "sec-websocket-protocol": SUBPROTOCOL },
      })
      if (!upgraded) {
        return new Response("WebSocket upgrade failed", { status: 500 })
      }
      return undefined
    },
    websocket: {
      open(ws) {
        connectionCount++
        updateState(true)
        console.log(`[bridge] agent connected (${connectionCount} active)`)
        sendReady(ws)
      },
      async message(ws, message) {
        const data = typeof message === "string" ? message : new TextDecoder().decode(message)
        await handleMessage(data, ws)
      },
      close(ws, code, reason) {
        connectionCount--
        updateState(connectionCount > 0)
        console.log(`[bridge] agent disconnected: ${code} ${reason} (${connectionCount} active)`)
      },
    },
  })

  updateState(true)
  console.log(`[bridge] server listening on ws://${WS_BIND_HOST}:${WS_PORT}${WS_PATH}`)
  console.log(`[bridge] subprotocol: ${SUBPROTOCOL}`)
  console.log(`[bridge] auth: ${AGENT_AUTH_TOKEN ? "enabled" : "disabled (dev mode)"}`)
}

// ── Client Role ───────────────────────────────────────────────────────────────

async function startClient(): Promise<void> {
  const uri = WS_URL || "ws://agent-hub:9000/codex"

  function updateState(ready: boolean): void {
    writeWsState({
      timestamp: new Date().toISOString(),
      ready,
      role: "client",
      connections: ready ? 1 : 0,
      connected_to: uri,
    })
  }

  async function connect(): Promise<void> {
    console.log(`[bridge] connecting to ${uri}...`)

    const headers: Record<string, string> = {}
    if (AGENT_AUTH_TOKEN) {
      headers["Authorization"] = `Bearer ${AGENT_AUTH_TOKEN}`
    }
    headers["Sec-WebSocket-Protocol"] = SUBPROTOCOL

    try {
      const ws = new WebSocket(uri, {
        headers,
      })

      ws.addEventListener("open", () => {
        console.log(`[bridge] connected to hub`)
        updateState(true)
        sendReady({ send: (data: string) => ws.send(data) })
      })

      ws.addEventListener("message", async (event) => {
        const data = typeof event.data === "string" ? event.data : ""
        await handleMessage(data, { send: (d: string) => ws.send(d) })
      })

      ws.addEventListener("close", (event) => {
        console.log(`[bridge] disconnected from hub: ${event.code} ${event.reason}`)
        updateState(false)
        scheduleReconnect()
      })

      ws.addEventListener("error", (event) => {
        console.error("[bridge] WebSocket error:", event)
        updateState(false)
      })
    } catch (err) {
      console.error("[bridge] connection failed:", err)
      updateState(false)
      scheduleReconnect()
    }
  }

  function scheduleReconnect(): void {
    console.log(`[bridge] reconnecting in ${RECONNECT_MS}ms...`)
    setTimeout(connect, RECONNECT_MS)
  }

  updateState(false)
  await connect()

  // Keep alive
  await new Promise(() => {})
}

// ── Main ──────────────────────────────────────────────────────────────────────

if (WS_ROLE === "server") {
  startServer()
} else if (WS_ROLE === "client") {
  startClient()
} else {
  console.error(`[bridge] unknown WS_ROLE: ${WS_ROLE}`)
  process.exit(1)
}
