#!/usr/bin/env python3
"""Mock WebSocket Hub — plays the agent side of agent_comm_protocol.json.

Receives ready → sends task_request → collects task_progress/task_result.
"""

import argparse
import asyncio
import json
import os
import time
import uuid

import websockets

AUTH_TOKEN = os.environ.get("HARNESS_AUTH_TOKEN", "test-token")
TASK_PROMPT = os.environ.get("TASK_PROMPT", "print('worker test')")
TASK_TIMEOUT = int(os.environ.get("TASK_TIMEOUT_MS", "30000"))


class Hub:
    results: list[dict]

    def __init__(self):
        self.results = []

    async def handle(self, ws: websockets.WebSocketServerProtocol):
        auth = ws.request.headers.get("Authorization", "")
        if not auth or not auth.endswith(AUTH_TOKEN):
            await ws.close(1008, "unauthorized")
            return

        try:
            # 1) wait for ready
            ready = await asyncio.wait_for(ws.recv(), timeout=15)
            r = json.loads(ready)
            assert r["type"] == "ready", f"expected ready, got {r['type']}"
            print(f"  [hub] ready: {r['payload'].get('worker_id', '?')}")

            # 2) send task
            task_id = str(uuid.uuid4())
            task = {
                "id": str(uuid.uuid4()),
                "type": "task_request",
                "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ"),
                "payload": {
                    "task_id": task_id,
                    "prompt": TASK_PROMPT,
                    "timeout_ms": TASK_TIMEOUT,
                },
            }
            await ws.send(json.dumps(task))
            print(f"  [hub] sent task {task_id}")

            # 3) collect
            while True:
                msg = await asyncio.wait_for(ws.recv(), timeout=30)
                p = json.loads(msg)
                self.results.append(p)
                t = p["type"]
                if t == "task_progress":
                    delta = p["payload"].get("delta", "")[:60]
                    done = "✓" if p["payload"].get("done") else ""
                    print(f"  [hub] progress: {delta} {done}")
                elif t == "task_result":
                    print(f"  [hub] result: {p['payload'].get('status')}")
                    break

        except asyncio.TimeoutError:
            print("  [hub] timeout")
        except Exception as e:
            print(f"  [hub] error: {e}")

    async def run(self, host="0.0.0.0", port=9000):
        async with websockets.serve(self.handle, host, port):
            print(f"[hub] WS on ws://{host}:{port}")
            await asyncio.Future()


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--port", type=int, default=9000)
    args = p.parse_args()
    asyncio.run(Hub().run(port=args.port))


if __name__ == "__main__":
    main()