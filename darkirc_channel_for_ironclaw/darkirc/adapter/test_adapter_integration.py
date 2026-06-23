#!/usr/bin/env python3
"""
Integration test for darkirc_adapter.py (T4).

Stands up a mock IRC server + the real adapter (subprocess), then drives the
adapter's HTTP API to verify the DarkIRC security/robustness cluster:
  - /health responds
  - /poll serves inbound DMs; /ack clears them (no duplicate on next poll)
  - /poll WITHOUT /ack re-serves the batch (M4 at-least-once redelivery)
  - /send forwards a PRIVMSG to the IRC server
  - wrong bearer token -> 401 (M6 auth enforced)
  - oversized body -> 413 (M5 body cap)
  - malformed Content-Length -> 400

Standalone (no pytest): run directly. Exits 0 on pass, 1 on fail.
"""

import asyncio
import json
import os
import socket
import subprocess
import sys
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ADAPTER = os.path.join(HERE, "darkirc_adapter.py")


def _free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


class MockIRC:
    """Minimal async IRC server: registers the adapter, echoes PONG, records
    PRIVMSGs sent through it, and can inject an inbound DM (PRIVMSG to the
    adapter's nick)."""

    def __init__(self, port, adapter_nick):
        self.port = port
        self.adapter_nick = adapter_nick
        self.sent_privmsgs = []  # PRIVMSGs the adapter sent (outbound)
        self._writer = None
        self._inject_q: asyncio.Queue = asyncio.Queue()
        self._server = None

    async def start(self):
        self._server = await asyncio.start_server(self._handle, "127.0.0.1", self.port)
        asyncio.create_task(self._pump_injections())

    async def _pump_injections(self):
        # Proactively push queued DMs to the adapter's IRC stream (independent of
        # the adapter sending anything), so /poll tests get reliable delivery.
        while True:
            dm = await self._inject_q.get()
            if self._writer is not None:
                payload = f":sender!u@h PRIVMSG {self.adapter_nick} :{dm}\r\n"
                try:
                    self._writer.write(payload.encode())
                    await self._writer.drain()
                except (ConnectionError, OSError):
                    pass

    async def _handle(self, reader, writer):
        self._writer = writer
        # Allow the registration (NICK/USER) to arrive, then send 001 (registered).
        await reader.readline()  # NICK
        await reader.readline()  # USER
        writer.write(b":server 001 ")
        writer.write(self.adapter_nick.encode())
        writer.write(b" :Welcome\r\n")
        await writer.drain()
        # Answer PINGs + record PRIVMSGs the adapter forwards.
        try:
            while True:
                line = await reader.readline()
                if not line:
                    break
                s = line.decode(errors="replace").strip()
                if s.startswith("PING"):
                    writer.write(b"PONG :pong\r\n")
                    await writer.drain()
                elif s.startswith("PRIVMSG"):
                    self.sent_privmsgs.append(s)
        except (ConnectionError, OSError):
            pass

    def inject_dm(self, text):
        self._inject_q.put_nowait(text)

    async def stop(self):
        if self._writer:
            self._writer.close()
        if self._server:
            self._server.close()
            await self._server.wait_closed()


async def _http(method, host, port, path, token=None, body=None, raw_content_length=None):
    """Tiny async HTTP/1.1 client. Returns (status, json_or_text)."""
    reader, writer = await asyncio.open_connection(host, port)
    headers = f"{method} {path} HTTP/1.1\r\nHost: {host}:{port}\r\nConnection: close\r\n"
    if token:
        headers += f"Authorization: Bearer {token}\r\n"
    if body is not None:
        if raw_content_length is not None:
            headers += f"Content-Length: {raw_content_length}\r\n"
        else:
            headers += f"Content-Length: {len(body)}\r\n"
    writer.write((headers + "\r\n").encode())
    if body is not None:
        writer.write(body if isinstance(body, bytes) else body.encode())
    await writer.drain()
    data = b""
    while True:
        chunk = await reader.read(4096)
        if not chunk:
            break
        data += chunk
    writer.close()
    try:
        await writer.wait_closed()
    except Exception:
        pass
    head, _, payload = data.partition(b"\r\n\r\n")
    status = int(head.split()[1])
    try:
        return status, json.loads(payload)
    except Exception:
        return status, payload.decode(errors="replace")


async def _wait_for_adapter(port, token):
    for _ in range(50):
        try:
            s, _ = await _http("GET", "127.0.0.1", port, "/health", token=token)
            if s == 200:
                return True
        except (ConnectionError, OSError):
            pass
        await asyncio.sleep(0.2)
    return False


class AdapterIntegrationTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.irc_port = _free_port()
        self.http_port = _free_port()
        self.secret = "test-secret-xyz"
        self.irc = MockIRC(self.irc_port, "kageho-bridge")
        await self.irc.start()
        env = dict(os.environ)
        env.update(
            DARKIRC_PORT=str(self.irc_port),
            ADAPTER_PORT=str(self.http_port),
            ADAPTER_SECRET=self.secret,
            ADAPTER_LOG_LEVEL="WARNING",
        )
        self.proc = subprocess.Popen(
            [sys.executable, ADAPTER],
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        if not await _wait_for_adapter(self.http_port, self.secret):
            self.proc.kill()
            await self.irc.stop()
            self.fail("adapter did not become ready")

    async def asyncTearDown(self):
        self.proc.terminate()
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()
        await self.irc.stop()

    def H(self, method, path, **kw):
        return _http(method, "127.0.0.1", self.http_port, path, **kw)

    async def test_health(self):
        s, body = await self.H("GET", "/health", token=self.secret)
        self.assertEqual(s, 200)
        self.assertEqual(body["status"], "ok")

    async def test_auth_rejected_without_token(self):
        s, _ = await self.H("GET", "/poll")
        self.assertEqual(s, 401)

    async def test_auth_rejected_wrong_token(self):
        s, _ = await self.H("GET", "/poll", token="wrong")
        self.assertEqual(s, 401)

    async def test_oversize_body_rejected(self):
        s, body = await self.H(
            "POST", "/send", token=self.secret,
            body=b"x", raw_content_length=str(10 * 1024 * 1024),
        )
        self.assertEqual(s, 413)

    async def test_malformed_content_length(self):
        s, _ = await self.H(
            "POST", "/send", token=self.secret,
            body=b"x", raw_content_length="not-a-number",
        )
        self.assertEqual(s, 400)

    async def test_poll_ack_no_duplicate(self):
        # Inject a DM, poll it, ack it -> next poll is empty (no duplicate).
        self.irc.inject_dm("hello from irc")
        await asyncio.sleep(0.6)  # let the adapter receive + queue it
        s, body = await self.H("GET", "/poll", token=self.secret)
        self.assertEqual(s, 200)
        self.assertTrue(any(m["text"] == "hello from irc" for m in body["messages"]))
        # Ack the batch.
        s_ack, _ = await self.H("POST", "/ack", token=self.secret)
        self.assertEqual(s_ack, 200)
        # Next poll should NOT re-serve the acked message.
        s2, body2 = await self.H("GET", "/poll", token=self.secret)
        self.assertFalse(any(m["text"] == "hello from irc" for m in body2["messages"]))

    async def test_poll_without_ack_redelivers(self):
        # M4: a batch polled but NOT acked must be re-served on the next poll.
        self.irc.inject_dm("redeliver me")
        await asyncio.sleep(0.6)
        _, body = await self.H("GET", "/poll", token=self.secret)
        self.assertTrue(any(m["text"] == "redeliver me" for m in body["messages"]))
        # Do NOT ack. Poll again -> same message re-served (at-least-once).
        _, body2 = await self.H("GET", "/poll", token=self.secret)
        self.assertTrue(any(m["text"] == "redeliver me" for m in body2["messages"]))

    async def test_send_forwards_privmsg(self):
        s, _ = await self.H(
            "POST", "/send", token=self.secret,
            body=json.dumps({"to": "someone", "text": "hi there"}).encode(),
        )
        self.assertEqual(s, 200)
        # The mock IRC recorded the PRIVMSG the adapter forwarded.
        for _ in range(30):
            if any("hi there" in p for p in self.irc.sent_privmsgs):
                break
            await asyncio.sleep(0.2)
        else:
            self.fail("adapter did not forward PRIVMSG to IRC server")


if __name__ == "__main__":
    unittest.main(verbosity=2)
