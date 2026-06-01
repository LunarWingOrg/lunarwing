#!/usr/bin/env python3
"""
lunarwing_toolcall_diag.py

Diagnostic script to test whether each lunarwing entrypoint variant handles
native tool calls properly. Sends N requests through TensorZero with tool
definitions modeled after OpenClaw built-ins, then classifies each response:

  - NATIVE_TOOL_CALL : model returned a proper tool_calls object
  - XML_LEAK         : model emitted tool-call XML in plain text content
  - PLAIN_TEXT       : model ignored the tools entirely and just responded
  - ERROR            : request failed or returned an unexpected shape

Prints a per-variant summary at the end.
"""

import json
import re
import sys
import time
from collections import defaultdict
from urllib.request import Request, urlopen
from urllib.error import URLError, HTTPError

# ============================================================================
# CONFIGURATION
# ============================================================================

GATEWAY_HOST = "127.0.0.1"
GATEWAY_PORT = 3000
FUNCTION_NAME = "lunarwing"
NUM_ITERATIONS = 40          # bump higher to hit low-weight variants
REQUEST_TIMEOUT = 120        # seconds per request
STREAM = False
SLEEP_BETWEEN = 0.5          # seconds between requests (be nice to providers)

# ============================================================================
# TOOL DEFINITIONS (modeled after OpenClaw built-ins)
# ============================================================================

TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "time",
            "description": "Returns the current date and time.",
            "parameters": {
                "type": "object",
                "properties": {},
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "read_file",
            "description": "Read the contents of a file at the given path.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "Absolute or relative file path to read.",
                    }
                },
                "required": ["path"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "shell",
            "description": "Execute a shell command and return stdout/stderr.",
            "parameters": {
                "type": "object",
                "properties": {
                    "command": {
                        "type": "string",
                        "description": "The shell command to execute.",
                    }
                },
                "required": ["command"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "memory_search",
            "description": "Search agent memory for relevant context by query string.",
            "parameters": {
                "type": "object",
                "properties": {
                    "query": {
                        "type": "string",
                        "description": "Natural language search query.",
                    },
                    "limit": {
                        "type": "integer",
                        "description": "Max number of results to return.",
                        "default": 5,
                    },
                },
                "required": ["query"],
            },
        },
    },
]

# Prompt that strongly implies tool use is needed
TEST_PROMPT = (
    "Please check the current time using your time tool, "
    "then read the file /etc/hostname using read_file. "
    "Use the tools — do not guess or fabricate the results."
)

# ============================================================================
# XML LEAK DETECTION PATTERNS
# ============================================================================

XML_PATTERNS = [
    re.compile(r"<tool_call>", re.IGNORECASE),
    re.compile(r"</tool_call>", re.IGNORECASE),
    re.compile(r"<function_call>", re.IGNORECASE),
    re.compile(r"<\|tool", re.IGNORECASE),            # <|tool▁call|> etc.
    re.compile(r'"name"\s*:\s*"(time|read_file|shell|memory_search)"'),
    re.compile(r"<invoke\s", re.IGNORECASE),
    re.compile(r"<tool_use>", re.IGNORECASE),
    re.compile(r"<function[>\s]", re.IGNORECASE),
    re.compile(r"\{\\?\"name\\?\"", re.IGNORECASE),   # raw JSON tool struct in text
]


def classify_response(data: dict) -> tuple[str, str]:
    """
    Classify a TensorZero inference response.
    Returns (classification, detail_snippet).
    """
    # Check for native tool_calls in the response content blocks
    content = data.get("content", [])
    if not isinstance(content, list):
        content = []

    has_tool_call = False
    text_parts = []

    for block in content:
        btype = block.get("type", "")
        if btype == "tool_call":
            has_tool_call = True
        elif btype == "text":
            text_parts.append(block.get("text", ""))

    full_text = "\n".join(text_parts)

    if has_tool_call:
        return "NATIVE_TOOL_CALL", "(proper tool_calls block in response)"

    # Check for XML leak in text content
    for pat in XML_PATTERNS:
        m = pat.search(full_text)
        if m:
            # Grab surrounding context
            start = max(0, m.start() - 40)
            end = min(len(full_text), m.end() + 40)
            snippet = full_text[start:end].replace("\n", "\\n")
            return "XML_LEAK", snippet

    if full_text.strip():
        snippet = full_text[:120].replace("\n", "\\n")
        return "PLAIN_TEXT", snippet

    return "ERROR", "empty response content"


def send_inference(gateway_url: str) -> dict:
    """Send a single inference request to TensorZero and return the JSON response."""
    payload = {
        "function_name": FUNCTION_NAME,
        "stream": STREAM,
        "input": {
            "messages": [
                {"role": "user", "content": TEST_PROMPT},
            ]
        },
        "params": {
            "chat_completion": {
                "tools": TOOLS,
                "tool_choice": "auto",
            }
        },
    }

    req = Request(
        gateway_url,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    with urlopen(req, timeout=REQUEST_TIMEOUT) as resp:
        return json.loads(resp.read().decode())


def main():
    gateway_url = f"http://{GATEWAY_HOST}:{GATEWAY_PORT}/inference"

    print(f"lunarwing tool-call diagnostic")
    print(f"gateway:    {gateway_url}")
    print(f"function:   {FUNCTION_NAME}")
    print(f"iterations: {NUM_ITERATIONS}")
    print(f"tools:      {', '.join(t['function']['name'] for t in TOOLS)}")
    print("=" * 72)

    # variant_name -> list of (classification, detail)
    results: dict[str, list[tuple[str, str]]] = defaultdict(list)
    errors = []

    for i in range(1, NUM_ITERATIONS + 1):
        sys.stdout.write(f"\r  [{i:3d}/{NUM_ITERATIONS}] sending... ")
        sys.stdout.flush()

        try:
            data = send_inference(gateway_url)
            variant = data.get("variant_name", "UNKNOWN")
            classification, detail = classify_response(data)
            results[variant].append((classification, detail))

            icon = {
                "NATIVE_TOOL_CALL": "✓",
                "XML_LEAK": "⚠",
                "PLAIN_TEXT": "—",
                "ERROR": "✗",
            }.get(classification, "?")

            sys.stdout.write(
                f"\r  [{i:3d}/{NUM_ITERATIONS}] {icon} {variant:<40s} {classification}\n"
            )

        except (HTTPError, URLError, TimeoutError, Exception) as e:
            errors.append(str(e))
            sys.stdout.write(f"\r  [{i:3d}/{NUM_ITERATIONS}] ✗ ERROR: {e}\n")

        if i < NUM_ITERATIONS:
            time.sleep(SLEEP_BETWEEN)

    # ========================================================================
    # SUMMARY
    # ========================================================================
    print()
    print("=" * 72)
    print("RESULTS BY VARIANT")
    print("=" * 72)

    for variant in sorted(results.keys()):
        entries = results[variant]
        total = len(entries)
        counts = defaultdict(int)
        for cls, _ in entries:
            counts[cls] += 1

        print(f"\n  {variant}  ({total} samples)")
        for cls in ["NATIVE_TOOL_CALL", "XML_LEAK", "PLAIN_TEXT", "ERROR"]:
            if counts[cls]:
                pct = counts[cls] / total * 100
                bar = "█" * int(pct / 5)
                print(f"    {cls:<20s} {counts[cls]:3d} ({pct:5.1f}%)  {bar}")

    # Overall stats
    all_entries = [e for elist in results.values() for e in elist]
    total = len(all_entries)
    overall = defaultdict(int)
    for cls, _ in all_entries:
        overall[cls] += 1

    print()
    print("-" * 72)
    print(f"OVERALL ({total} successful / {len(errors)} errors)")
    for cls in ["NATIVE_TOOL_CALL", "XML_LEAK", "PLAIN_TEXT", "ERROR"]:
        if overall[cls]:
            pct = overall[cls] / total * 100
            print(f"  {cls:<20s} {overall[cls]:3d} ({pct:5.1f}%)")
    print("-" * 72)

    if errors:
        print(f"\n{len(errors)} request error(s) (first 5):")
        for e in errors[:5]:
            print(f"  • {e}")

    # Exit code: nonzero if any XML leaks detected
    if overall.get("XML_LEAK", 0) > 0:
        sys.exit(1)


if __name__ == "__main__":
    main()
