#!/usr/bin/env python3
"""
Worker Test Harness Runner
Matrix-driven test suite for all 4 LunarWing worker types.

Usage:
    python runner.py                # smoke (happy paths)
    python runner.py --mode full    # all scenarios + chaos
    python runner.py --worker codex # single worker
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import time
import traceback
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import requests
import websocket
import yaml

ROOT = Path(__file__).resolve().parent
COMPOSE = ROOT / "docker-compose.test.yml"


@dataclass
class Case:
    name: str
    passed: bool
    detail: str = ""


@dataclass
class Suite:
    cases: list[Case] = field(default_factory=list)

    def add(self, n: str, ok: bool, d: str = "") -> None:
        self.cases.append(Case(n, ok, d))

    @property
    def total(self) -> int: return len(self.cases)
    @property
    def passed(self) -> int: return sum(1 for c in self.cases if c.passed)
    @property
    def failed(self) -> int: return sum(1 for c in self.cases if not c.passed)


def compose(*args: str) -> subprocess.CompletedProcess:
    cmd = ["docker", "compose", "-f", str(COMPOSE)] + list(args)
    return subprocess.run(cmd, capture_output=True, text=True, timeout=120)


def wait_url(url: str, timeout: float = 45, poll: float = 1) -> None:
    dl = time.monotonic() + timeout
    while time.monotonic() < dl:
        try:
            r = requests.get(url, timeout=2)
            if r.status_code < 500:
                return
        except Exception:
            pass
        time.sleep(poll)
    raise TimeoutError(f"unreachable after {timeout}s: {url}")


# ── test primitives ──────────────────────

def http_case(base: str, sc: dict, suite: Suite, prefix: str):
    m = sc.get("method", "GET").upper()
    u = base.rstrip("/") + sc["path"]
    body = sc.get("body")
    exp = sc.get("expect", {})
    try:
        r = requests.request(m, u, json=body, timeout=10)
        ok = True
        dets = []
        if ec := exp.get("status_code"):
            if r.status_code != ec:
                ok = False
                dets.append(f"status {r.status_code} ≠ {ec}")
        if ec := exp.get("body_contains"):
            if ec not in r.text:
                ok = False
                dets.append(f"missing '{ec}'")
        suite.add(f"{prefix}/{sc['name']}", ok, " | ".join(dets) or "ok")
    except Exception as e:
        suite.add(f"{prefix}/{sc['name']}", False, str(e))


def ws_case(uri: str, auth: str, sc: dict, suite: Suite, prefix: str):
    name = sc["name"]
    try:
        token = sc.get("auth_token", auth)
        headers = [f"Authorization: Bearer {token}"] if token else []
        ws = websocket.create_connection(uri, header=headers, timeout=10)

        if sc["type"] == "ws_handshake":
            msg = ws.recv()
            p = json.loads(msg)
            ok = True
            dets = []
            exp = sc.get("expect", {})
            if exp.get("first_message") and p.get("type") != exp["first_message"]:
                ok = False
                dets.append(f"type={p.get('type')}")
            if miss := set(exp.get("payload_has", [])) - set(p.get("payload", {})):
                ok = False
                dets.append(f"missing keys: {miss}")
            ws.close()
            suite.add(f"{prefix}/{name}", ok, " | ".join(dets) or "ok")

        elif sc["type"] == "ws_connect":
            ws.close()
            # If we got here with bad auth, the server let us in — that's wrong
            suite.add(f"{prefix}/{name}", False, "connected despite bad auth")

        else:
            ws.close()
            suite.add(f"{prefix}/{name}", False, f"unknown type {sc['type']}")

    except websocket.WebSocketBadStatusException as e:
        if sc.get("expect", {}).get("error_code"):
            suite.add(f"{prefix}/{name}", True, "auth rejected ✓")
        else:
            suite.add(f"{prefix}/{name}", False, str(e))
    except Exception as e:
        suite.add(f"{prefix}/{name}", False, str(e))


# ── runner ───────────────────────

def run_one(name: str, cfg: dict, mode: str, suite: Suite):
    svc = cfg["deploy"]
    prefix = name
    print(f"\n{'─'*50}\n  {name}  ({mode})\n{'─'*50}")

    try:
        r = compose("up", "-d", svc)
        if r.returncode != 0:
            suite.add(f"{prefix}/startup", False, r.stderr[:200])
            return

        hp = cfg.get("health_port")
        health_url = f"http://localhost:{hp}/health"
        ready_url = f"http://localhost:{hp}/ready"

        if hp:
            wait_url(health_url)
            print(f"  ✓ {svc} healthy")
            wait_url(ready_url)
            print(f"  ✓ {svc} ready")

        scenarios = [s for s in cfg.get("scenarios", [])
                     if mode == "full" or not s.get("chaos")]

        for sc in scenarios:
            t = sc["type"]
            if t in ("http",):
                http_case(f"http://localhost:{hp}", sc, suite, prefix)
            elif t in ("ws_handshake", "ws_connect"):
                ws_port = cfg.get("ws_port", hp)
                ws_uri = f"ws://localhost:{ws_port}"
                auth = cfg.get("auth_token", "")
                ws_case(ws_uri, auth, sc, suite, prefix)
            else:
                suite.add(f"{prefix}/{sc['name']}", False, f"unknown type {t}")

    except Exception:
        traceback.print_exc()
        suite.add(f"{prefix}/fatal", False, traceback.format_exc(limit=2))
    finally:
        compose("down", "-v")
        print(f"  ✓ teardown")


def main() -> int:
    p = argparse.ArgumentParser("Worker Test Harness")
    p.add_argument("--mode", choices=["smoke", "full"], default="smoke")
    p.add_argument("--worker")
    args = p.parse_args()

    with open(ROOT / "tests.yaml") as f:
        matrix = yaml.safe_load(f)

    workers = matrix["workers"]
    if args.worker:
        if args.worker not in workers:
            print(f"Unknown worker '{args.worker}'. Options: {list(workers)}")
            return 1
        workers = {args.worker: workers[args.worker]}

    suite = Suite()
    for wname, wcfg in workers.items():
        run_one(wname, wcfg, args.mode, suite)

    print(f"\n{'='*50}")
    print(f"  {suite.passed}/{suite.total} passed   {suite.failed} failed")
    print(f"{'='*50}")
    for c in suite.cases:
        icon = "✅" if c.passed else "❌"
        line = f"  {icon} {c.name}"
        if not c.passed and c.detail:
            line += f"  ⚠ {c.detail}"
        print(line)

    return 0 if suite.failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
