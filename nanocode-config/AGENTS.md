# Repository Guidelines

## Project Structure & Module Organization
This repository is a flat configuration workspace rather than an application. The main files live at the root:

- `opencode.json` for the primary nanocode configuration, including theme, plugins, and MCP servers
- `optionalprovider.json` and `newoptionalprovider.json` for OpenAI-compatible provider definitions
- `tensorzero.toml` for TensorZero gateway, model, and routing configuration
- `README.md`, `NextSteps.md`, `CLAUDE.md`, `NOTES.md` for setup notes and operational context
- `.opencode/package.json` for plugin dependency pinning
- `.gitignore` excludes `.env` and `.key` files (secrets go there, never in tracked files)
- `.envexample` is a placeholder for documenting required env vars

There is no `src/` or `tests/` tree. Keep new config files top-level unless a tool requires its own directory.

## Build, Lint, Test, and Validation Commands
There is no formal build pipeline or test framework in this repo. Use lightweight validation commands before committing:

- `jq . opencode.json` — validates the main config is syntactically valid JSON
- `jq . optionalprovider.json` and `jq . newoptionalprovider.json` — validate provider files
- `jq . tensorzero.toml` is NOT valid (TOML, not JSON); instead visually inspect or use `taplo check tensorzero.toml` if taplo is installed
- `git diff --check` — catches trailing whitespace and patch-format issues before commit
- `rg -n "{env:" *.json` — audits environment-variable placeholders in tracked JSON files to ensure no hardcoded secrets
- `rg -n "{env:" tensorzero.toml` — same audit for the TOML config (env var references use `"env::VAR_NAME"` syntax)
- `git status` and `git diff --cached` — review staged changes before committing
- `git log --oneline -10` — review recent commit style before writing a commit message

**Running a single validation**: Each `jq` command above acts as a single-file syntax check. There are no unit tests, integration tests, or test runners in this repo.

**Testing config changes**: After editing, confirm provider or gateway changes against a local nanocode or TensorZero instance. For TensorZero route changes, reload the gateway and manually verify affected routes. When updating docs, verify ports, hostnames, model names, and env var names match the live config.

## Coding Style & Naming Conventions

### Indentation and Formatting
- Use 2-space indentation in all JSON files
- Keep keys grouped logically within objects (order: `provider`, `name`, `npm`, `options`, `models`, `mcp`, etc.)
- In `tensorzero.toml`, preserve the existing section order and comment banners (e.g., `# ====== MODELS ======`, `# --- DS on DeepSeek native API ---`)

### Naming
- Prefer lowercase, descriptive filenames (e.g., `optionalprovider.json`, `newoptionalprovider.json`, `tensorzero.toml`)
- Model IDs should remain explicit and routeable: `tensorzero::function_name::FrontierCODE` or `[models.qwen397b_openrouter]`
- TensorZero model keys use snake_case with provider suffixes (e.g., `ds_native`, `qwen397b_openrouter`, `glm5_nanogpt_tee`)
- JSON provider keys use lowercase (e.g., `cliproxyapi`, `tensorzero`)

### Secrets Management
- Keep secrets out of tracked files by using placeholders:
  - In JSON: `"{env:CLIPROXYAPI_API_KEY}"`
  - In TOML: `api_key_location = "env::DEEPSEEK_API_KEY"` or `api_key_location = "none"` for local models
- `.env` and `.key` files are gitignored — store live secrets there
- Sanitize tokens and private credentials in docs before committing
- Never hardcode API keys, base URLs with embedded tokens, or any credential in tracked files

### TOML Conventions (`tensorzero.toml`)
- Models are grouped by provider/family with comment banners (DEEPSEEK, QWEN, GLM, OTHER, LOCAL, ROLEPLAY, IRONCLAW FALLBACK)
- Each model block follows this structure:
  ```toml
  [models.model_key]
  routing = ["provider_routing_key"]

  [models.model_key.timeouts.streaming]
  ttft_ms = <number>
  total_ms = <number>

  [models.model_key.timeouts.non_streaming]
  total_ms = <number>

  [models.model_key.providers.provider_key]
  type = "openai"
  model_name = "<exact-model-name>"
  api_base = "<url>"
  api_key_location = "env::VAR_NAME"
  ```
- Redundant/fallback models aggregate multiple providers under one model key
- Function definitions reference model keys and use experimentation blocks for weighted routing:
  ```toml
  [functions.function_name.experimentation]
  type = "static"
  candidate_variants = { "variant1" = 0.70, "variant2" = 0.30 }
  fallback_variants = ["fallback1", "fallback2"]
  ```

### JSON Conventions (`opencode.json`, provider files)
- Use `$schema` at the top when referencing an external schema
- Plugins are listed in the `"plugin"` array as npm package names with optional scope (e.g., `"@gotgenes/opencode-agent-identity"`)
- MCP server entries use `"type": "remote"` with `"url"` and optional `"headers"` containing env var placeholders
- Provider definitions use:
  ```json
  {
    "provider": {
      "provider_key": {
        "name": "Display Name",
        "npm": "@ai-sdk/openai-compatible",
        "options": { "apiKey": "{env:VAR_NAME}", "baseURL": "..." },
        "models": { "model_id": { "name": "model_id" } }
      }
    }
  }
  ```
- Model IDs in provider JSON should match TensorZero function references (e.g., `"tensorzero::function_name::FrontierCODE"`)

## Commit & Pull Request Guidelines
- Use short, imperative commit subjects: `Update tensorzero.toml`, `Create NOTES.md`, `Add Qwen 3.5 397B model config`
- Keep each commit scoped to one config or documentation concern (no mixed-purpose commits)
- Pull requests should explain why the config changed, list impacted files and env vars, and call out any model-routing, plugin, or endpoint changes
- Short command output or a focused diff is more useful than screenshots
- Run `git diff --check` before committing to catch whitespace issues

## Plugin Management
- Plugins are declared in `opencode.json` under the `"plugin"` array
- Their actual npm packages are pinned in `.opencode/package.json`
- When adding a plugin, add it to both files (array entry in `opencode.json`, dependency in `.opencode/package.json`)
- Current plugins include: agent-identity, agent-memory, agent-skills, background, envsitter-guard, oh-my-openagent, planning-toolkit, opentmux, subtask2

## MCP Server Configuration
- MCP servers are declared in `opencode.json` under `"mcp"`
- Each entry has `type` (typically `"remote"`), `url`, `enabled`, and optional `headers`
- API keys in headers should use `"{env:VAR_NAME}"` placeholders
- Current servers: context7 (with CONTEXT7_API_KEY header), exa (no auth header needed)

## Security & Configuration Tips
- Never commit `.env` or `.key` files (they are gitignored)
- Use `{env:VAR_NAME}` in JSON and `"env::VAR_NAME"` in TOML for all secrets
- Use `api_key_location = "none"` in TOML for local/offline models that don't require authentication
- Internal network addresses (192.168.x.x) in configs are acceptable for local/LAN model servers
- When sharing config snippets or screenshots, blur or replace any real API keys

## Error Handling & Debugging
- JSON syntax errors: run `jq . <file>` to get precise line/column error messages
- TOML syntax errors: use `taplo check tensorzero.toml` or visually inspect for missing `[]` section headers
- TensorZero route issues: check that model keys in `[models.*]` match references in `[functions.*.variants.*.model]`
- Missing env vars: TensorZero logs a warning at startup; check gateway logs for "api_key_location" resolution errors
- Plugin issues: check nanocode logs or run nanocode with `--verbose` flag
