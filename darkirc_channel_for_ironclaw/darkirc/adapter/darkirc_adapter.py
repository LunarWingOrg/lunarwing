#!/usr/bin/env python3
"""
darkirc-http-adapter: Bridges DarkIRC's IRC interface to HTTP.

Connects to DarkIRC's local IRC server (localhost:6667) and exposes
a simple HTTP API that the IronClaw WASM channel can poll.

Endpoints:
  GET  /poll          → Returns queued inbound DMs as JSON array
  POST /send          → Sends a DM via IRC: {"to":"nick","text":"..."}
  GET  /health        → Health check

This is intentionally minimal — all security, rate limiting, and
session management happens in the WASM channel / IronClaw host.
"""

import asyncio
import hmac
import json
import logging
import os
import re
import signal
import sys
import time
from collections import deque
from http import HTTPStatus

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

IRC_HOST = os.getenv("DARKIRC_HOST", "127.0.0.1")
IRC_PORT = int(os.getenv("DARKIRC_PORT", "6667"))
IRC_NICK = os.getenv("DARKIRC_NICK", "kageho-bridge")
IRC_USER = os.getenv("DARKIRC_USER", "kageho")
IRC_REALNAME = os.getenv("DARKIRC_REALNAME", "DarkIRC-IronClaw Bridge")

HTTP_HOST = os.getenv("ADAPTER_HOST", "127.0.0.1")
HTTP_PORT = int(os.getenv("ADAPTER_PORT", "6680"))

# Max messages to buffer before dropping oldest
MAX_QUEUE = int(os.getenv("ADAPTER_MAX_QUEUE", "500"))

# Max UTF-8 bytes per IRC message chunk (conservative under 512-byte IRC limit)
MAX_IRC_MESSAGE_BYTES = int(os.getenv("DARKIRC_MAX_MESSAGE_BYTES", "400"))

# Minimum seconds between PRIVMSG sends (DarkFi metering requires spacing)
PRIVMSG_MIN_INTERVAL = float(os.getenv("DARKIRC_PRIVMSG_INTERVAL", "7.0"))
_last_privmsg_time: float = 0.0
_privmsg_lock = asyncio.Lock()

# Cap on inbound HTTP request bodies (M5: the hand-rolled reader trusts
# Content-Length via readexactly — without a cap a caller can force unbounded
# allocation → OOM). 64 KiB is far above any legitimate /send payload.
MAX_BODY_BYTES = int(os.getenv("ADAPTER_MAX_BODY_BYTES", str(64 * 1024)))

# Shared secret for basic auth between WASM channel and adapter
# The WASM channel sends this as Bearer token
ADAPTER_SECRET = os.getenv("ADAPTER_SECRET", "")

LOG_LEVEL = os.getenv("ADAPTER_LOG_LEVEL", "INFO")

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

log = logging.getLogger("darkirc-adapter")


def setup_logging():
    level = getattr(logging, LOG_LEVEL.upper(), logging.INFO)
    fmt = logging.Formatter(
        "%(asctime)s [%(levelname)s] %(name)s: %(message)s",
        datefmt="%Y-%m-%dT%H:%M:%S",
    )
    sh = logging.StreamHandler(sys.stderr)
    sh.setFormatter(fmt)
    log.addHandler(sh)
    log.setLevel(level)


# ---------------------------------------------------------------------------
# IRC Client (async, minimal, no deps)
# ---------------------------------------------------------------------------

_CTRL_RE = re.compile(r"[\x00-\x1f\x7f]")


class IRCClient:
    def __init__(self):
        self._reader = None
        self._writer = None
        self._connected = False
        self._registered = False
        self.nick = IRC_NICK

    @property
    def connected(self):
        return self._connected and self._registered

    async def connect(self):
        self._reader, self._writer = await asyncio.open_connection(
            IRC_HOST, IRC_PORT
        )
        self._connected = True
        self._registered = False
        await self._send(f"NICK {IRC_NICK}")
        await self._send(f"USER {IRC_USER} 0 * :{IRC_REALNAME}")
        log.info("IRC: connecting to %s:%d as %s", IRC_HOST, IRC_PORT, IRC_NICK)

    async def _send(self, line: str):
        if not self._writer:
            raise ConnectionError("not connected")
        log.debug("IRC >>> %s", line)
        try:
            self._writer.write((line + "\r\n").encode("utf-8", errors="replace"))
            await self._writer.drain()
        except (ConnectionError, OSError) as e:
            log.error("IRC send failed: %s", e)
            self._connected = False
            self._registered = False
            raise

    async def readline(self):
        if not self._reader:
            raise ConnectionError("not connected")
        data = await self._reader.readline()
        if not data:
            return None
        line = data.decode("utf-8", errors="replace").rstrip("\r\n")
        log.debug("IRC <<< %s", line)
        return line

    async def pong(self, token: str):
        await self._send(f"PONG :{token}")

    async def privmsg(self, target: str, text: str):
        global _last_privmsg_time
        chunks = _split_message_bytes(text, MAX_IRC_MESSAGE_BYTES)
        successful_chunks = 0

        for chunk in chunks:
            async with _privmsg_lock:
                now = asyncio.get_event_loop().time()
                elapsed = now - _last_privmsg_time
                if elapsed < PRIVMSG_MIN_INTERVAL:
                    await asyncio.sleep(PRIVMSG_MIN_INTERVAL - elapsed)
                try:
                    await self._send(f"PRIVMSG {target} :{chunk}")
                    _last_privmsg_time = asyncio.get_event_loop().time()
                    successful_chunks += 1
                except Exception as e:
                    log.error("Failed to send chunk %d to %s: %s", successful_chunks + 1, target, e)

        log.info("Sent %d of %d chunk(s) to %s", successful_chunks, len(chunks), target)

    async def close(self):
        self._connected = False
        self._registered = False
        if self._writer:
            try:
                self._writer.close()
                await self._writer.wait_closed()
            except Exception:
                pass

    def parse_line(self, raw: str):
        prefix = None
        if raw.startswith(":"):
            prefix, raw = raw[1:].split(" ", 1)
        if " :" in raw:
            params_part, trailing = raw.split(" :", 1)
        else:
            params_part, trailing = raw, None
        parts = params_part.split()
        command = parts[0].upper() if parts else ""
        params = parts[1:] if len(parts) > 1 else []
        return {
            "prefix": prefix,
            "command": command,
            "params": params,
            "trailing": trailing,
        }

    def mark_registered(self):
        self._registered = True


# ---------------------------------------------------------------------------
# Message splitting (UTF-8 byte-safe, word-boundary-aware)
# ---------------------------------------------------------------------------

def _split_message_bytes(text: str, max_bytes: int) -> list:
    """Split text into chunks that fit within max_bytes UTF-8 encoded length,
    preferring natural break points (newlines, then spaces).
    Always preserves character boundaries (no split mid-codepoint).

    Also normalizes line endings: \r\n → \n, and standalone \r → \n,
    so the output never contains stray \r.
    """
    # Normalize CRLF to LF, plus standalone \r (old Mac line endings) to \n.
    # .replace('\r', '\n') handles both in a single pass: \r\n becomes \n\n,
    # which is fine for our purposes (we treat newlines as whitespace at split points).
    text = text.replace('\r', '\n')

    if len(text.encode("utf-8")) <= max_bytes:
        return [text]

    chunks: list = []
    remaining = text

    while remaining:
        if len(remaining.encode("utf-8")) <= max_bytes:
            chunks.append(remaining)
            break

        # Binary-search the largest slice whose UTF-8 fits in max_bytes
        lo, hi = 0, len(remaining)
        while lo < hi:
            mid = (lo + hi + 1) // 2
            if len(remaining[:mid].encode("utf-8")) <= max_bytes:
                lo = mid
            else:
                hi = mid - 1

        if lo == 0:
            # Single character exceeds max_bytes — just take it anyway
            chunks.append(remaining[0])
            remaining = remaining[1:]
            continue

        cut = remaining[:lo]

        # Prefer breaking at newline
        nl = cut.rfind("\n")
        if nl > 0:
            chunks.append(cut[:nl])
            remaining = remaining[nl + 1:]  # skip the newline
            continue

        # Then at a space
        sp = cut.rfind(" ")
        if sp > 0:
            chunks.append(cut[:sp])
            remaining = remaining[sp + 1:]  # skip the space
            continue

        # No good break point — hard cut at the byte limit
        chunks.append(cut)
        remaining = remaining[lo:]

    return chunks


# ---------------------------------------------------------------------------
# Message queue (inbound DMs from DarkIRC)
# ---------------------------------------------------------------------------

message_queue: deque = deque(maxlen=MAX_QUEUE)

# Messages delivered via /poll but not yet acked (M4: at-least-once delivery).
# Re-served on the next /poll until /ack clears them, so a host crash between
# poll and processing doesn't lose DMs.
pending_ack: deque = deque(maxlen=MAX_QUEUE)


# ---------------------------------------------------------------------------
# IRC loop
# ---------------------------------------------------------------------------

irc = IRCClient()
_running = True


async def irc_loop():
    global _running
    delay = 5

    while _running:
        try:
            await irc.connect()
            delay = 5

            while _running:
                line = await asyncio.wait_for(irc.readline(), timeout=300)
                if line is None:
                    log.warning("IRC EOF, reconnecting")
                    break

                parsed = irc.parse_line(line)
                cmd = parsed["command"]

                if cmd == "PING":
                    await irc.pong(parsed["trailing"] or "")
                    continue

                if cmd == "001":
                    irc.mark_registered()
                    log.info("IRC: registered as %s", irc.nick)
                    continue

                if cmd == "433":
                    irc.nick += "_"
                    await irc._send(f"NICK {irc.nick}")
                    continue

                if cmd == "PRIVMSG":
                    target = parsed["params"][0] if parsed["params"] else ""
                    text = parsed["trailing"] or ""
                    prefix = parsed["prefix"] or ""

                    # Only DMs (target == our nick)
                    if target.startswith("#") or target.startswith("&"):
                        continue

                    sender = prefix.split("!")[0] if prefix else ""
                    if not sender:
                        continue

                    clean = _CTRL_RE.sub("", text).strip()
                    if not clean:
                        continue

                    message_queue.append({
                        "from": sender,
                        "text": clean,
                        "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                    })
                    log.info("← DM from %s queued (%d chars)", sender, len(clean))

        except asyncio.TimeoutError:
            log.warning("IRC timeout, reconnecting")
        except (ConnectionError, OSError) as e:
            log.error("IRC error: %s", e)
        finally:
            await irc.close()

        if _running:
            log.info("IRC reconnecting in %ds", delay)
            await asyncio.sleep(delay)
            delay = min(delay * 2, 300)


# ---------------------------------------------------------------------------
# HTTP server (async, stdlib only — no aiohttp/flask)
# ---------------------------------------------------------------------------

async def handle_http(reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
    try:
        # Read request line
        request_line = await asyncio.wait_for(reader.readline(), timeout=10)
        if not request_line:
            writer.close()
            return

        request_str = request_line.decode("utf-8", errors="replace").strip()
        parts = request_str.split(" ")
        if len(parts) < 2:
            await send_response(writer, 400, {"error": "bad request"})
            return

        method, path = parts[0], parts[1]

        # Read headers
        headers = {}
        while True:
            header_line = await asyncio.wait_for(reader.readline(), timeout=5)
            if not header_line or header_line == b"\r\n" or header_line == b"\n":
                break
            decoded = header_line.decode("utf-8", errors="replace").strip()
            if ":" in decoded:
                key, val = decoded.split(":", 1)
                headers[key.strip().lower()] = val.strip()

        # Auth check (M6: constant-time comparison to avoid a timing oracle on
        # the bearer secret). Empty ADAPTER_SECRET => no auth (dev); mt-admin
        # always sets a secret, so multi-tenant deployments are always authed.
        if ADAPTER_SECRET:
            auth = headers.get("authorization", "")
            if not hmac.compare_digest(auth, f"Bearer {ADAPTER_SECRET}"):
                await send_response(writer, 401, {"error": "unauthorized"})
                return

        # Read body if present (M5: cap Content-Length and tolerate a malformed
        # value instead of trusting it blindly into readexactly → OOM).
        body = b""
        try:
            content_length = int(headers.get("content-length", "0"))
        except ValueError:
            await send_response(writer, 400, {"error": "invalid content-length"})
            return
        if content_length < 0 or content_length > MAX_BODY_BYTES:
            await send_response(writer, 413, {"error": "payload too large"})
            return
        if content_length > 0:
            body = await asyncio.wait_for(
                reader.readexactly(content_length), timeout=10
            )

        # Route
        if method == "GET" and path == "/health":
            await send_response(writer, 200, {
                "status": "ok",
                "irc_connected": irc.connected,
                "irc_nick": irc.nick,
                "queue_size": len(message_queue),
            })

        elif method == "GET" and path == "/poll":
            # Serve unacked (pending) + fresh; hold the batch until /ack so a
            # host crash between poll and processing re-delivers rather than
            # loses (at-least-once).
            messages = list(pending_ack) + list(message_queue)
            pending_ack.clear()
            message_queue.clear()
            pending_ack.extend(messages)
            await send_response(writer, 200, {"messages": messages})

        elif method == "POST" and path == "/ack":
            pending_ack.clear()
            await send_response(writer, 200, {"status": "acked"})

        elif method == "POST" and path == "/send":
            if not body:
                await send_response(writer, 400, {"error": "empty body"})
                return
            try:
                payload = json.loads(body)
            except json.JSONDecodeError:
                await send_response(writer, 400, {"error": "invalid json"})
                return

            to = payload.get("to", "").strip()
            text = payload.get("text", "").strip()

            if not to or not text:
                await send_response(writer, 400, {"error": "missing 'to' or 'text'"})
                return

            if not irc.connected:
                await send_response(writer, 503, {"error": "irc not connected"})
                return

            await irc.privmsg(to, text)
            # Logging is handled within privmsg method now
            await send_response(writer, 200, {"status": "sent"})

        else:
            await send_response(writer, 404, {"error": "not found"})

    except (asyncio.TimeoutError, ConnectionError, OSError):
        pass
    finally:
        try:
            writer.close()
            await writer.wait_closed()
        except Exception:
            pass


async def send_response(writer, status_code: int, body: dict):
    status_text = HTTPStatus(status_code).phrase
    payload = json.dumps(body, ensure_ascii=False).encode("utf-8")
    response = (
        f"HTTP/1.1 {status_code} {status_text}\r\n"
        f"Content-Type: application/json\r\n"
        f"Content-Length: {len(payload)}\r\n"
        f"Connection: close\r\n"
        f"\r\n"
    ).encode("utf-8") + payload
    writer.write(response)
    await writer.drain()


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

async def main():
    global _running
    setup_logging()

    log.info("darkirc-http-adapter starting")
    log.info("  IRC: %s:%d nick=%s", IRC_HOST, IRC_PORT, IRC_NICK)
    log.info("  HTTP: %s:%d", HTTP_HOST, HTTP_PORT)
    if not ADAPTER_SECRET:
        log.warning(
            "ADAPTER_SECRET not set — running WITHOUT auth. This is dev-only; "
            "multi-tenant deployments must set it (lunarwing-mt-admin.sh does so "
            "automatically). Without it any local process can read/send DMs."
        )

    # Start HTTP server
    server = await asyncio.start_server(
        handle_http, HTTP_HOST, HTTP_PORT
    )
    log.info("HTTP server listening on %s:%d", HTTP_HOST, HTTP_PORT)

    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, lambda: _shutdown())

    # Run IRC loop and HTTP server concurrently
    irc_task = asyncio.create_task(irc_loop())

    async with server:
        await server.serve_forever()


def _shutdown():
    global _running
    _running = False
    log.info("Shutdown signal received")
    # Stop the event loop
    for task in asyncio.all_tasks():
        task.cancel()


if __name__ == "__main__":
    asyncio.run(main())
