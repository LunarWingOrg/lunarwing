# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is a configuration repository for [nanocode](https://github.com/nanogpt-community/nanocode), a community AI coding agent. It contains custom JSON configuration files — there is no application code, build system, or test suite.

## Key Files

- **opencode.json** — Main nanocode configuration: theme, plugins, and MCP server definitions. Uses the schema at `https://github.com/nanogpt-community/nanocode/config.json`.
- **optionalprovider.json** — Defines additional LLM providers (currently a CLIProxyAPI provider using `@ai-sdk/openai-compatible`). Environment variables `CLIPROXYAPI_API_KEY` and `CLIPROXYAPI_BASE_URL` must be set for this provider.

## Configuration Patterns

- Environment variables are referenced with `{env:VAR_NAME}` syntax in JSON values.
- MCP servers can be `"type": "remote"` with a `"url"` and optional `"headers"`.
- Plugins are listed by npm package name in the `"plugin"` array.
