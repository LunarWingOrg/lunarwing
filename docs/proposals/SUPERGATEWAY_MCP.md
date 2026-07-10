# Historical Finding: LunarWing MCP Installation Lacked stdio Surfaces

Date: 2026-07-09

Status: Superseded on 2026-07-09. LunarWing's core MCP runtime already supported
stdio child processes, and the registry, conversational `tool_install`, web API,
web settings, and registry CLI installation surfaces now accept structured stdio
configuration. Installation is host-local and activation remains explicit.

Supergateway remains a valid operational choice when an HTTP boundary, independent
process supervision, or remote access is desirable. It is no longer required only
to make a local stdio MCP server usable by LunarWing.

Original issue: LunarWing's MCP server installation (`tool_install` with
`kind: mcp_server`) only exposed remote HTTP/SSE endpoints. It could not install a
stdio command even though the lower-level runtime could launch one.

Affected servers: Any MCP server distributed as a local stdio process — NanoGPT, and potentially many others in the MCP ecosystem.

Attempted: tool_install + tool_auth against NanoGPT. Discovery found the server at https://nanogpt.com/mcp, but tool_auth failed with HTTP 308 Permanent Redirect during OAuth endpoint discovery. The server is designed for stdio, not remote HTTP.

Workaround: Bridge the stdio server to HTTP/SSE using supergateway:

LunarWing ──HTTP/SSE──> supergateway ─-stdio──> @nanogpt/mcp

Example:

NANOGPT_API_KEY=sk-... npx -y supergateway \
  --stdio "npx -y @nanogpt/mcp" \
  --port 8002 --outputTransport streamableHttp

Then install http://localhost:8002/mcp as an MCP server in LunarWing.

Prerequisites for workaround:

    Node.js 22+ on the host running supergateway
    NanoGPT API key (from nano-gpt.com/settings/api-keys)
    Persistent process management (systemd) so bridge survives reboots

Historical workaround status: Not implemented as part of the original attempt.
