# Host-Local stdio MCP Installation Design

## Status

Approved for implementation on 2026-07-09.

## Goal

Make host-local stdio MCP servers first-class across LunarWing's registry,
conversational extension tool, web API, and web settings surfaces while preserving
all existing HTTP MCP behavior.

## Scope

This change adds structured stdio installation inputs:

- server name
- executable command
- argument vector
- non-secret environment variables
- optional description where the calling surface already carries one

The existing MCP runtime remains authoritative. Installation persists an
`McpServerConfig`; activation uses `McpProcessManager` and the existing stdio
transport to spawn the process, negotiate MCP, discover tools, and register tool
wrappers.

## Non-Goals

- Worker-local MCP execution
- Runtime npm, pip, or Cargo package installation
- An MCP gateway
- Unix-socket installation in the web or conversational surfaces
- A general V2 extension manifest redesign
- Passing secrets through stdio environment fields
- Automatically activating arbitrary custom stdio commands immediately after install

## Architecture

### Registry manifests

MCP registry manifests retain the existing top-level `url` form for HTTP servers.
They may alternatively declare a typed stdio transport:

```json
{
  "name": "example",
  "display_name": "Example",
  "kind": "mcp_server",
  "description": "Example local MCP server",
  "transport": {
    "type": "stdio",
    "command": "npx",
    "args": ["-y", "@example/mcp"],
    "env": {}
  },
  "auth": "none"
}
```

Manifest conversion produces an `ExtensionSource::McpStdio` entry. Existing URL
manifests continue to produce `ExtensionSource::McpUrl`.

### Extension manager

`ExtensionManager` gains one public installation boundary that accepts a complete
`McpServerConfig`. It validates the extension name and MCP configuration, rejects
duplicate installs consistently with the current web/chat behavior, and persists
through the existing database-or-disk MCP config helpers.

URL and registry installation paths delegate to this boundary. Activation remains
unchanged and dispatches through `create_client_from_config`.

Non-HTTP MCP transports report authentication as not required. Removing an MCP
extension explicitly shuts down any managed stdio process before deleting its
configuration.

### Web API and conversational tool

The extension install request and `tool_install` schema gain additive fields:

- `transport`: `http` or `stdio`
- `command`: required for stdio
- `args`: JSON array of argument strings
- `env`: JSON object of non-secret environment variables

Existing callers that send only `name`, `url`, and `kind` retain current behavior.
The argument vector is structured; LunarWing does not parse a shell command string.

### Web settings

The custom MCP form uses an HTTP/stdio segmented mode control. HTTP mode keeps the
URL field. stdio mode exposes command, one-argument-per-line, and non-secret
`KEY=VALUE` environment inputs. The browser sends structured arrays and objects to
the existing extension install endpoint.

Installed MCP entries expose their transport and stdio command summary so the UI
does not render a blank endpoint for local servers.

### Registry CLI

`lunarwing registry list --kind mcp` recognizes MCP manifests. Registry info shows
the stdio command and arguments. Installing a single MCP registry entry persists
its MCP configuration instead of sending it through the WASM artifact installer.

Existing `lunarwing mcp add --transport stdio` remains supported and shares the same
configuration validation rules.

## Security

- Installing a stdio server remains approval-gated when initiated by the LLM.
- The command and arguments are stored exactly and executed without a shell.
- Environment keys and values are validated for process-environment safety.
- Web copy explicitly labels environment values as non-secret.
- Secrets continue to use LunarWing's secrets and credential systems rather than
  stdio installation fields.
- stdio activation is explicit; installation alone does not execute the command.

## Error Handling

- Missing or empty stdio commands fail before persistence.
- Unsupported transport names fail with a clear validation error.
- Invalid environment names or embedded NUL values fail configuration validation.
- Spawn or MCP negotiation errors remain activation failures and do not corrupt the
  stored configuration.
- Removal attempts to stop the child process before deleting configuration and
  returns a lifecycle error if shutdown fails.

## Verification

- Manifest parsing and conversion tests for HTTP and stdio entries
- Request-deserialization and request-to-config tests
- Tool schema tests for all additive fields
- Manager tests for persistence, duplicate rejection, no-auth status, listing, and
  stdio process shutdown during removal
- Registry CLI parsing/conversion tests
- JavaScript syntax validation
- Targeted Rust tests, formatting, and `cargo check` under the repository's
  six-thread constraint

