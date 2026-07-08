#!/usr/bin/env python3
"""Mock Orchestrator — serves the Worker HTTP API for built-in worker tests.

Endpoints:
  GET  /health                    → 200 ok
  GET  /worker/config             → bootstrap config for worker
  GET  /worker/{id}/llm/complete  → mock LLM response
  POST /worker/{id}/status        → accept worker status report
  POST /jobs/create               → mock job creation
"""

import argparse
import json
import os
import uuid
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse

DEFAULT_RESPONSE = os.environ.get("MOCK_LLM_RESPONSE", "mock llm response")


class Orchestrator(BaseHTTPRequestHandler):

    def log_message(self, fmt, *args):
        pass  # suppress default logging

    def _json(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _body(self):
        cl = int(self.headers.get("Content-Length", 0))
        return json.loads(self.rfile.read(cl)) if cl else {}

    def do_GET(self):
        path = urlparse(self.path).path

        if path == "/health":
            return self._json(200, {"status": "ok", "mock": True})

        if path == "/worker/config":
            job = {
                "job_id": os.environ.get("MOCK_JOB_ID", str(uuid.uuid4())),
                "orchestrator_url": "http://orchestrator:8080",
                "max_iterations": 5,
            }
            return self._json(200, job)

        if "/llm/complete" in path:
            return self._json(200, {
                "choices": [{"message": {"content": DEFAULT_RESPONSE}}]
            })

        self._json(404, {"error": f"unknown path: {path}"})

    def do_POST(self):
        path = urlparse(self.path).path
        body = self._body()

        if "/status" in path:
            return self._json(202, {"accepted": True, "status": "running"})

        if path == "/jobs/create":
            job_id = str(uuid.uuid4())
            return self._json(201, {"job_id": job_id, **body})

        self._json(404, {"error": f"unknown path: {path}"})


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--port", type=int, default=8080)
    p.add_argument("--host", default="0.0.0.0")
    args = p.parse_args()

    srv = HTTPServer((args.host, args.port), Orchestrator)
    print(f"[mock-orch] listening on {args.host}:{args.port}")
    srv.serve_forever()


if __name__ == "__main__":
    main()