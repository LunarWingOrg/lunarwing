Finding: LunarWing MCP Tool Layer — No stdio Support (Feature Gap)

Date: 2026-07-09

Issue: LunarWing's MCP server installation (tool_install with kind: mcp_server) only supports remote HTTP/SSE endpoints. It cannot install or launch stdio-based MCP servers (e.g. npx -y @nanogpt/mcp).

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

Status: Workaround not yet implemented. Awaiting Christopher's API key and host confirmation.
