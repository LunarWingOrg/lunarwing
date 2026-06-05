#!/usr/bin/env python3
"""
TensorZero Proxy — OpenClaw chat routing with roleplay support.

Features:
- Detects /me commands and routes to slash_me function
- Handles both literal "/me" and IRC ACTION format
- Strips WeeChat metadata preamble from all messages (saves context window)
- Removes tool definitions for roleplay models (they don't support tools)
- Normal messages route to openclaw function
- Passes through embedding requests unchanged
- Binds to all interfaces (0.0.0.0) for LAN access
- Streams responses to avoid buffering large payloads
- Graceful BrokenPipeError handling on client disconnect
- 5-minute timeout for slow model fallback chains

Usage:
    python3 tensorzero-proxy.py --port 3001 --tensorzero http://192.168.1.XXX:3000
"""

import re
import json
import time
import random
import socket
import socketserver
import http.server
import threading
import urllib.request
import urllib.error
import argparse
import sys
import os
import traceback

# Default configuration
TENSORZERO_URL = "http://192.168.1.157:3000"
EMBEDDINGS_URL = "http://192.168.1.213:5556"
PROXY_PORT = 3001

# Load .env file from same directory as script (if it exists)
_env_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), '.env')
if os.path.exists(_env_path):
    with open(_env_path) as _f:
        for _line in _f:
            _line = _line.strip()
            if _line and not _line.startswith('#') and '=' in _line:
                _key, _val = _line.split('=', 1)
                os.environ.setdefault(_key.strip(), _val.strip().strip('"').strip("'"))

# CTCP ACTION character (ASCII 0x01)
CTCP_CHAR = '\x01'

# Soul files: map client IP → soul content loaded at startup
_SOUL_IP_MAP = {
    '192.168.1.192': 'SWEETIESOUL.md',
    '192.168.1.170': 'VOLTASOUL.md',
}
_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
SOULS_BY_IP: dict[str, str] = {}
for _ip, _fname in _SOUL_IP_MAP.items():
    _soul_path = os.path.join(_SCRIPT_DIR, _fname)
    if os.path.exists(_soul_path):
        with open(_soul_path) as _f:
            SOULS_BY_IP[_ip] = _f.read().strip()
        print(f"[soul] loaded {_fname} for {_ip} ({len(SOULS_BY_IP[_ip])} chars)", flush=True)
    else:
        print(f"[soul] WARNING: {_soul_path} not found, {_ip} will use generic framing", flush=True)

# Pattern to match WeeChat metadata preamble blocks
METADATA_PATTERN = re.compile(
    r'(?:Conversation info|Sender)\s*\(untrusted metadata\):\s*```json\s*\{[^}]*\}\s*```\s*',
    re.DOTALL
)


# ── OpenClaw helpers ───────────────────────────────────────────────────────────

def strip_metadata(msg: str) -> str:
    if not isinstance(msg, str):
        return msg
    stripped = METADATA_PATTERN.sub('', msg).strip()
    return stripped if stripped else msg


_SUMMARIZATION_MARKERS = (
    'The messages above are a conversation to summarize',
    'Create a structured context checkpoint summary',
    '<conversation>',
)

def route_function(message: str) -> str:
    # Summarization prompts wrap queued /me messages — don't treat as roleplay
    for marker in _SUMMARIZATION_MARKERS:
        if marker in message:
            return "openclaw"
    # Only check the first line for /me — roleplay commands are always typed first
    first_line = message.lstrip().split('\n', 1)[0]
    if re.match(r'/me\b', first_line):
        return "slash_me"
    if f'{CTCP_CHAR}ACTION ' in message:
        return "slash_me"
    return "openclaw"


def clean_message(msg: str) -> str:
    match = re.search(rf'{CTCP_CHAR}ACTION\s+(.*?){CTCP_CHAR}', msg)
    if match:
        return match.group(1).strip()
    cleaned = re.sub(r'(?:^|\n)\s*/me\s+', '', msg).strip()
    if cleaned != msg.strip():
        return cleaned
    return msg.strip()


def content_text(content) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for part in content:
            if isinstance(part, dict) and part.get('type') == 'text':
                parts.append(part.get('text', ''))
            elif isinstance(part, str):
                parts.append(part)
        return ' '.join(parts)
    if content is None:
        return ''
    return str(content)


def keep_only_roleplay_actions(messages: list, limit: int = 7, soul: str = '') -> tuple[list, int]:
    """
    Keep only the most recent /me (slash_me) messages for roleplay context.
    If a soul string is provided it replaces all system messages wholesale;
    otherwise system messages are dropped entirely.
    """
    dropped = 0
    roleplay_msgs = []

    for msg in messages:
        if not isinstance(msg, dict):
            dropped += 1
            continue

        role = msg.get('role')

        if role == 'system':
            # Replaced by the injected soul below — drop originals
            dropped += 1
            continue

        if role not in {'user', 'assistant'}:
            dropped += 1
            continue

        text = strip_metadata(content_text(msg.get('content', '')))
        if route_function(text) != 'slash_me':
            dropped += 1
            continue

        cleaned = msg.copy()
        cleaned['content'] = clean_message(text)
        cleaned.pop('tool_calls', None)
        cleaned.pop('tool_call_id', None)
        roleplay_msgs.append(cleaned)

    if len(roleplay_msgs) > limit:
        dropped += len(roleplay_msgs) - limit
        roleplay_msgs = roleplay_msgs[-limit:]

    if soul:
        system_msgs = [{'role': 'system', 'content': soul}]
    else:
        system_msgs = []

    return system_msgs + roleplay_msgs, dropped


def _safe_write(wfile, data: bytes, log_func=None) -> bool:
    try:
        wfile.write(data)
        return True
    except BrokenPipeError:
        if log_func:
            log_func("Client disconnected during write")
        return False


def _detect_degenerate_stream(window: bytearray, chunk: bytes,
                              threshold: float = 0.85, min_window: int = 1024) -> bool:
    """Detect repetition degeneration in a streaming response.

    Maintains a rolling byte window; returns True when a single byte value
    accounts for more than `threshold` of the window (after it reaches
    `min_window` bytes).  Works even through SSE JSON framing because a
    model stuck on a single character will dominate the raw byte stream.
    """
    window += chunk
    # Trim to last 2048 bytes
    if len(window) > 2048:
        del window[:len(window) - 2048]
    if len(window) < min_window:
        return False
    # Find the most common byte
    counts: dict[int, int] = {}
    for b in window:
        counts[b] = counts.get(b, 0) + 1
    max_count = max(counts.values())
    return max_count / len(window) > threshold


def _is_timeout_error(exc: urllib.error.URLError) -> bool:
    """Check if a URLError wraps a socket timeout."""
    reason = exc.reason
    if isinstance(reason, socket.timeout):
        return True
    if isinstance(reason, OSError) and reason.errno in (110, 60):  # ETIMEDOUT, ECONNREFUSED-like
        return True
    return False


# ── Circuit breaker & retry ────────────────────────────────────────────────────

class CircuitOpenError(Exception):
    """Raised when the circuit breaker is open and requests are blocked."""


class CircuitBreaker:
    """Per-upstream circuit breaker (thread-safe)."""

    def __init__(self, name, failure_threshold=5, reset_timeout=30):
        self.name = name
        self.failure_threshold = failure_threshold
        self.reset_timeout = reset_timeout
        self.failure_count = 0
        self.state = "closed"        # closed | open | half_open
        self.opened_at = 0.0
        self._lock = threading.Lock()

    def allow_request(self) -> bool:
        with self._lock:
            if self.state == "closed":
                return True
            if self.state == "open":
                if time.time() - self.opened_at >= self.reset_timeout:
                    self.state = "half_open"
                    return True
                return False
            # half_open — one probe already in flight, block others
            return False

    def record_success(self):
        with self._lock:
            self.failure_count = 0
            if self.state == "half_open":
                self.state = "closed"

    def record_failure(self):
        with self._lock:
            self.failure_count += 1
            if self.state == "half_open":
                self.state = "open"
                self.opened_at = time.time()
            elif self.failure_count >= self.failure_threshold:
                self.state = "open"
                self.opened_at = time.time()


# Module-level circuit breakers — one per upstream
cb_tensorzero = CircuitBreaker("tensorzero")
cb_embeddings = CircuitBreaker("embeddings")


_RETRYABLE_HTTP_CODES = {429, 502, 503}


def _urlopen_with_retry(req, timeout, circuit, max_retries=3, log=None):
    """urlopen with retry + exponential backoff + circuit breaker.

    Returns the response object on success.  Raises CircuitOpenError,
    urllib.error.HTTPError, or urllib.error.URLError on final failure.
    """
    last_exc = None
    for attempt in range(max_retries):
        if not circuit.allow_request():
            raise CircuitOpenError(f"Circuit breaker '{circuit.name}' is open")

        try:
            response = urllib.request.urlopen(req, timeout=timeout)
            circuit.record_success()
            return response

        except urllib.error.HTTPError as e:
            last_exc = e
            if e.code in _RETRYABLE_HTTP_CODES:
                circuit.record_failure()
                if attempt < max_retries - 1:
                    delay = (0.5 * (2 ** attempt)) + random.uniform(0, 0.3)
                    if log:
                        log(f"[retry] attempt {attempt+1}/{max_retries} "
                            f"HTTP {e.code} from {circuit.name}, "
                            f"retrying in {delay:.1f}s")
                    time.sleep(delay)
                    continue
            else:
                # Non-retryable HTTP error — don't count as circuit failure
                raise

        except urllib.error.URLError as e:
            last_exc = e
            circuit.record_failure()
            if attempt < max_retries - 1:
                delay = (0.5 * (2 ** attempt)) + random.uniform(0, 0.3)
                if log:
                    log(f"[retry] attempt {attempt+1}/{max_retries} "
                        f"URLError from {circuit.name}: {e.reason}, "
                        f"retrying in {delay:.1f}s")
                time.sleep(delay)
                continue

    # Exhausted retries
    raise last_exc


# ── HTTP handler ───────────────────────────────────────────────────────────────

class ProxyHandler(http.server.BaseHTTPRequestHandler):

    def log_message(self, format, *args):
        from datetime import datetime
        timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        msg = format % args if args else format
        print(f"[{timestamp}] {self.address_string()} - {msg}")

    def do_POST(self):
        # OpenClaw: chat completions with /me routing
        if '/chat/completions' in self.path:
            self.handle_chat_completions()

        # Embeddings → KoboldCpp
        elif '/embeddings' in self.path:
            self.handle_embeddings()

        # Everything else → TensorZero passthrough
        elif '/completions' in self.path or '/models' in self.path:
            self.handle_passthrough()

        else:
            self.send_response(404)
            self.end_headers()
            _safe_write(self.wfile, b'{"error": "Not found"}', self.log_message)

    def do_GET(self):
        if '/health' in self.path:
            health = {
                "status": "ok",
                "circuits": {
                    "tensorzero": cb_tensorzero.state,
                    "embeddings": cb_embeddings.state,
                },
            }
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            _safe_write(self.wfile, json.dumps(health).encode(), self.log_message)
        elif '/models' in self.path:
            self.handle_passthrough()
        else:
            self.send_response(404)
            self.end_headers()
            _safe_write(self.wfile, b'{"error": "Not found"}', self.log_message)

    def _read_body(self):
        content_length = int(self.headers.get('Content-Length', 0))
        if content_length == 0:
            return b''
        chunks = []
        remaining = content_length
        while remaining > 0:
            chunk = self.rfile.read(min(remaining, 65536))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        return b''.join(chunks)

    # ── OpenClaw: /chat/completions with /me routing ───────────────────────────

    def handle_chat_completions(self):
        """Handle chat completion requests with /me routing."""
        try:
            post_data = self._read_body()
            data = json.loads(post_data.decode('utf-8'))

            messages = data.get('messages', [])
            is_stream = data.get('stream', False)

            if messages:
                last_msg = messages[-1]
                if last_msg.get('role') == 'user':
                    content = last_msg.get('content', '')

                    if isinstance(content, list):
                        text_parts = []
                        for part in content:
                            if isinstance(part, dict) and part.get('type') == 'text':
                                text_parts.append(part.get('text', ''))
                            elif isinstance(part, str):
                                text_parts.append(part)
                        content = ' '.join(text_parts)
                    elif not isinstance(content, str):
                        content = str(content)

                    func = route_function(content)
                    data['model'] = f"tensorzero::function_name::{func}"

                    if func == 'slash_me':
                        cleaned = clean_message(content)

                        client_ip = self.client_address[0]
                        soul = SOULS_BY_IP.get(client_ip, '')
                        messages, dropped_count = keep_only_roleplay_actions(messages, soul=soul)
                        data['messages'] = messages

                        data.pop('tools', None)
                        data.pop('tool_choice', None)
                        data.setdefault('frequency_penalty', 0.5)

                        if data.get('max_tokens', 0) > 1024:
                            data['max_tokens'] = 1024

                        sys_msgs = [m for m in messages if m.get('role') == 'system']
                        sys_count = len(sys_msgs)
                        self.log_message(
                            f"Routed to {func} -> {len(messages)} msgs "
                            f"(sys={sys_count} roleplay={len(messages)-sys_count}), "
                            f"dropped={dropped_count}, cleaned: {cleaned!r}"
                        )
                        for i, sm in enumerate(sys_msgs):
                            soul_preview = sm.get('content', '')[:200].replace('\n', ' ')
                            self.log_message(f"soul[{i}]: {soul_preview!r}")
                    else:
                        # Strip metadata from all user messages for openclaw too
                        for msg in data.get('messages', []):
                            if msg.get('role') == 'user' and isinstance(msg.get('content'), str):
                                msg['content'] = strip_metadata(msg['content'])
                        self.log_message(f"Routed to {func}")

            req = urllib.request.Request(
                TENSORZERO_URL + '/openai/v1/chat/completions',
                data=json.dumps(data).encode('utf-8'),
                headers={
                    'Content-Type': 'application/json',
                    'Authorization': 'Bearer tensorzero-proxy'
                },
                method='POST'
            )

            if is_stream:
                # Streaming: single attempt (can't retry after headers sent),
                # but still consult and update the circuit breaker.
                if not cb_tensorzero.allow_request():
                    self.log_message("Circuit breaker open for tensorzero (stream)")
                    self.send_response(503)
                    self.end_headers()
                    _safe_write(self.wfile, json.dumps({"error": "Service unavailable (circuit open)"}).encode(), self.log_message)
                    return

                try:
                    with urllib.request.urlopen(req, timeout=300) as response:
                        cb_tensorzero.record_success()
                        self.send_response(response.status)
                        self.send_header('Content-Type', 'text/event-stream')
                        self.send_header('Access-Control-Allow-Origin', '*')
                        self.end_headers()

                        stream_window = bytearray()
                        has_tools = bool(data.get('tools'))
                        while True:
                            chunk = response.read(8192)
                            if not chunk:
                                break
                            if not has_tools and _detect_degenerate_stream(stream_window, chunk):
                                self.log_message("Aborting degenerate stream (repetition detected)")
                                response.close()
                                abort_chunk = json.dumps({
                                    "choices": [{"delta": {"content": "\n\n[generation aborted -- repetition detected]"}, "finish_reason": "stop"}]
                                })
                                try:
                                    self.wfile.write(f"data: {abort_chunk}\n\ndata: [DONE]\n\n".encode())
                                    self.wfile.flush()
                                except BrokenPipeError:
                                    pass
                                return
                            try:
                                self.wfile.write(chunk)
                                self.wfile.flush()
                            except BrokenPipeError:
                                self.log_message("Client disconnected during streaming")
                                return

                except (urllib.error.URLError, urllib.error.HTTPError):
                    cb_tensorzero.record_failure()
                    raise

                except BrokenPipeError:
                    self.log_message("Client disconnected before response")
                    return

            else:
                # Non-streaming: retry with backoff + circuit breaker
                response = _urlopen_with_retry(req, 300, cb_tensorzero,
                                               log=self.log_message)
                content = response.read()
                response.close()
                self.send_response(response.status)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Access-Control-Allow-Origin', '*')
                self.end_headers()
                _safe_write(self.wfile, content, self.log_message)

        except CircuitOpenError:
            self.log_message("Circuit breaker open for tensorzero")
            self.send_response(503)
            self.end_headers()
            _safe_write(self.wfile, json.dumps({"error": "Service unavailable (circuit open)"}).encode(), self.log_message)

        except BrokenPipeError:
            self.log_message("Client disconnected before response")

        except urllib.error.HTTPError as e:
            error_msg = f"HTTP Error {e.code}: {e.reason}"
            self.log_message(f"Error: {error_msg}")
            self.send_response(e.code)
            self.end_headers()
            _safe_write(self.wfile, json.dumps({"error": error_msg}).encode(), self.log_message)

        except urllib.error.URLError as e:
            if _is_timeout_error(e):
                self.log_message(f"Upstream timeout: {e.reason}")
                self.send_response(504)
                self.end_headers()
                _safe_write(self.wfile, json.dumps({"error": "Gateway timeout"}).encode(), self.log_message)
            else:
                self.log_message(f"Upstream connection error: {e.reason}")
                self.send_response(502)
                self.end_headers()
                _safe_write(self.wfile, json.dumps({"error": f"Bad gateway: {e.reason}"}).encode(), self.log_message)

        except Exception as e:
            error_msg = f"Error: {str(e)}"
            self.log_message(f"Error: {error_msg}")
            traceback.print_exc()
            self.send_response(500)
            self.end_headers()
            _safe_write(self.wfile, json.dumps({"error": error_msg}).encode(), self.log_message)

    # ── Embeddings ─────────────────────────────────────────────────────────────

    def handle_embeddings(self):
        try:
            post_data = self._read_body()

            try:
                embed_data = json.loads(post_data.decode('utf-8'))
                inp = embed_data.get('input', '')
                batch_size = len(inp) if isinstance(inp, list) else 1
                self.log_message(f"Embedding request -> {EMBEDDINGS_URL} (batch={batch_size})")
            except Exception:
                self.log_message(f"Embedding request -> {EMBEDDINGS_URL}")

            req = urllib.request.Request(
                EMBEDDINGS_URL + '/v1/embeddings',
                data=post_data,
                headers={'Content-Type': 'application/json'},
                method='POST'
            )

            response = _urlopen_with_retry(req, 600, cb_embeddings,
                                           log=self.log_message)
            content = response.read()
            response.close()

            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            _safe_write(self.wfile, content, self.log_message)

        except CircuitOpenError:
            self.log_message("Circuit breaker open for embeddings")
            self.send_response(503)
            self.end_headers()
            _safe_write(self.wfile, json.dumps({"error": "Service unavailable (circuit open)"}).encode(), self.log_message)

        except urllib.error.HTTPError as e:
            error_msg = f"HTTP Error {e.code}: {e.reason}"
            self.log_message(f"Error: {error_msg}")
            self.send_response(e.code)
            self.end_headers()
            _safe_write(self.wfile, json.dumps({"error": error_msg}).encode(), self.log_message)

        except urllib.error.URLError as e:
            if _is_timeout_error(e):
                self.log_message(f"Embeddings timeout: {e.reason}")
                self.send_response(504)
                self.end_headers()
                _safe_write(self.wfile, json.dumps({"error": "Embeddings gateway timeout"}).encode(), self.log_message)
            else:
                self.log_message(f"Embeddings connection error: {e.reason}")
                self.send_response(502)
                self.end_headers()
                _safe_write(self.wfile, json.dumps({"error": f"Bad gateway: {e.reason}"}).encode(), self.log_message)

        except Exception as e:
            error_msg = f"Error: {str(e)}"
            self.log_message(f"Error: {error_msg}")
            traceback.print_exc()
            self.send_response(500)
            self.end_headers()
            _safe_write(self.wfile, json.dumps({"error": error_msg}).encode(), self.log_message)

    def handle_passthrough(self):
        try:
            post_data = self._read_body() or None

            req = urllib.request.Request(
                TENSORZERO_URL + self.path,
                data=post_data,
                headers={
                    'Content-Type': 'application/json',
                    'Authorization': 'Bearer tensorzero-proxy'
                },
                method=self.command
            )

            self.log_message(f"Passthrough request: {self.path}")

            response = _urlopen_with_retry(req, 300, cb_tensorzero,
                                           log=self.log_message)
            content = response.read()

            self.send_response(response.status)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            for header, value in response.getheaders():
                if header.lower() not in ['transfer-encoding', 'connection']:
                    self.send_header(header, value)
            self.end_headers()
            response.close()
            _safe_write(self.wfile, content, self.log_message)

        except CircuitOpenError:
            self.log_message("Circuit breaker open for tensorzero (passthrough)")
            self.send_response(503)
            self.end_headers()
            _safe_write(self.wfile, json.dumps({"error": "Service unavailable (circuit open)"}).encode(), self.log_message)

        except urllib.error.HTTPError as e:
            error_msg = f"HTTP Error {e.code}: {e.reason}"
            self.log_message(f"Error: {error_msg}")
            self.send_response(e.code)
            self.end_headers()
            _safe_write(self.wfile, json.dumps({"error": error_msg}).encode(), self.log_message)

        except urllib.error.URLError as e:
            if _is_timeout_error(e):
                self.log_message(f"Passthrough timeout: {e.reason}")
                self.send_response(504)
                self.end_headers()
                _safe_write(self.wfile, json.dumps({"error": "Gateway timeout"}).encode(), self.log_message)
            else:
                self.log_message(f"Passthrough connection error: {e.reason}")
                self.send_response(502)
                self.end_headers()
                _safe_write(self.wfile, json.dumps({"error": f"Bad gateway: {e.reason}"}).encode(), self.log_message)

        except Exception as e:
            error_msg = f"Error: {str(e)}"
            self.log_message(f"Error: {error_msg}")
            traceback.print_exc()
            self.send_response(500)
            self.end_headers()
            _safe_write(self.wfile, json.dumps({"error": error_msg}).encode(), self.log_message)


class ThreadedTCPServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    global TENSORZERO_URL, EMBEDDINGS_URL, PROXY_PORT

    parser = argparse.ArgumentParser(
        description='TensorZero Proxy with /me routing and embeddings passthrough',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
    python3 tensorzero-proxy.py
    python3 tensorzero-proxy.py --tensorzero http://192.168.1.100:3000
    python3 tensorzero-proxy.py --port 3001
        """
    )

    parser.add_argument('--port', '-p', type=int, default=PROXY_PORT,
                        help=f'Port to listen on (default: {PROXY_PORT})')
    parser.add_argument('--tensorzero', '-t', type=str, default=TENSORZERO_URL,
                        help=f'TensorZero URL (default: {TENSORZERO_URL})')
    parser.add_argument('--embeddings', '-e', type=str, default=EMBEDDINGS_URL,
                        help=f'Embeddings server URL (default: {EMBEDDINGS_URL})')
    parser.add_argument('--bind', '-b', type=str, default='0.0.0.0',
                        help='Address to bind to (default: 0.0.0.0 for LAN access)')

    args = parser.parse_args()

    TENSORZERO_URL = args.tensorzero.rstrip('/')
    EMBEDDINGS_URL = args.embeddings.rstrip('/')
    PROXY_PORT = args.port

    print("=" * 70)
    print("TensorZero Proxy - /me Routing + Embeddings")
    print("=" * 70)
    print(f"Listening on:   {args.bind}:{PROXY_PORT}")
    print(f"Chat ->         {TENSORZERO_URL}")
    print(f"Embeddings ->   {EMBEDDINGS_URL}")
    print()
    print("Routing Rules:")
    print("   /me commands    -> slash_me function (metadata stripped, tools removed)")
    print("   IRC ACTION      -> slash_me function (metadata stripped, tools removed)")
    print("   Normal chat     -> openclaw function (metadata stripped)")
    print()
    print("Endpoints:")
    print(f"   /health         -> 200 OK (monitoring)")
    print(f"   /chat/completions -> OpenClaw routing")
    print(f"   /embeddings     -> {EMBEDDINGS_URL}")
    print()
    print("Client Configuration:")
    print(f"   OpenClaw:   OPENAI_BASE_URL=http://<lan-ip>:{PROXY_PORT}/openai")
    print("=" * 70)
    print()

    try:
        with ThreadedTCPServer((args.bind, PROXY_PORT), ProxyHandler) as httpd:
            print(f"Server running on {args.bind}:{PROXY_PORT}")
            print("   Press Ctrl+C to stop")
            print()
            httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n\nProxy stopped by user")
    except Exception as e:
        print(f"\nError starting proxy: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
