/**
 * smoke_test.ts — Quick connectivity check for the opencode worker.
 * Verifies health endpoint and WebSocket handshake.
 */

const WS_HOST = process.env.SMOKE_WS_HOST || "127.0.0.1"
const WS_PORT = process.env.SMOKE_WS_PORT || "9090"
const HEALTH_PORT = process.env.SMOKE_HEALTH_PORT || "8443"
const AUTH_TOKEN = process.env.AGENT_AUTH_TOKEN || ""
const WS_PATH = process.env.WS_PATH || "/ws/agent"

async function checkHealth(): Promise<boolean> {
  try {
    const res = await fetch(`http://${WS_HOST}:${HEALTH_PORT}/health`)
    const data = await res.json()
    if (data.status === "ok") {
      console.log(`[smoke] health: OK (uptime=${data.uptime_seconds}s)`)
      return true
    }
    console.error(`[smoke] health: unexpected response:`, data)
    return false
  } catch (err) {
    console.error(`[smoke] health: failed:`, err)
    return false
  }
}

async function checkReady(): Promise<boolean> {
  try {
    const res = await fetch(`http://${WS_HOST}:${HEALTH_PORT}/ready`)
    const data = await res.json()
    if (data.ready) {
      console.log(`[smoke] ready: OK`)
      return true
    }
    console.error(`[smoke] ready: not ready:`, data)
    return false
  } catch (err) {
    console.error(`[smoke] ready: failed:`, err)
    return false
  }
}

async function checkWebSocket(): Promise<boolean> {
  return new Promise((resolve) => {
    const uri = `ws://${WS_HOST}:${WS_PORT}${WS_PATH}`
    const headers: Record<string, string> = {
      "Sec-WebSocket-Protocol": "lunarwing-agent-v1, ironclaw-agent-v1",
    }
    if (AUTH_TOKEN) {
      headers["Authorization"] = `Bearer ${AUTH_TOKEN}`
    }

    const ws = new WebSocket(uri, { headers })
    const timeout = setTimeout(() => {
      console.error(`[smoke] websocket: timeout`)
      ws.close()
      resolve(false)
    }, 10_000)

    ws.addEventListener("message", (event) => {
      try {
        const msg = JSON.parse(typeof event.data === "string" ? event.data : "")
        if (msg.type === "ready") {
          console.log(`[smoke] websocket: received ready from ${msg.payload?.worker_id}`)
          clearTimeout(timeout)
          ws.close()
          resolve(true)
        }
      } catch {
        // ignore parse errors
      }
    })

    ws.addEventListener("error", (event) => {
      console.error(`[smoke] websocket: error:`, event)
      clearTimeout(timeout)
      resolve(false)
    })

    ws.addEventListener("close", (event) => {
      if (event.code !== 1000 && event.code !== 1001) {
        console.error(`[smoke] websocket: closed unexpectedly: ${event.code} ${event.reason}`)
        clearTimeout(timeout)
        resolve(false)
      }
    })
  })
}

async function main() {
  console.log(`[smoke] testing worker at ${WS_HOST}`)
  console.log(`[smoke] health port: ${HEALTH_PORT}, ws port: ${WS_PORT}`)
  console.log()

  const results = {
    health: await checkHealth(),
    ready: await checkReady(),
    websocket: await checkWebSocket(),
  }

  console.log()
  console.log("[smoke] results:")
  for (const [name, passed] of Object.entries(results)) {
    console.log(`  ${passed ? "✓" : "✗"} ${name}`)
  }

  const allPassed = Object.values(results).every(Boolean)
  console.log()
  console.log(allPassed ? "[smoke] ALL CHECKS PASSED" : "[smoke] SOME CHECKS FAILED")
  process.exit(allPassed ? 0 : 1)
}

main()
