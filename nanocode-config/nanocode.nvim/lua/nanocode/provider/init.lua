---@module 'snacks.terminal'

---Provide an integrated `nanocode`.
---Providers should ignore manually-started `nanocode` instances,
---operating only on those they start themselves.
---@class nanocode.Provider
---
---The name of the provider.
---@field name? string
---
---The command to start `nanocode`.
---The `--port` flag _must_ be present to expose the server for `nanocode.nvim` to connect to.
---`nanocode.nvim` will set `--port <opts.port>` if present.
---See all available flags [here](https://nanocode.ai/docs/cli/#flags).
---@field cmd? string
---
---@field new? fun(opts: table): nanocode.Provider
---
---Toggle `nanocode`.
---@field toggle? fun(self: nanocode.Provider)
---
---Start `nanocode`.
---Called when attempting to interact with `nanocode` but none was found.
---`nanocode.nvim` then polls for a couple seconds waiting for one to appear.
---Should not steal focus by default, if possible.
---@field start? fun(self: nanocode.Provider)
---
---Stop the previously started `nanocode`.
---Called when Neovim is exiting.
---@field stop? fun(self: nanocode.Provider)
---
---Health check for the provider.
---Should return `true` if the provider is available,
---else a reason string and optional advice (for `vim.health.warn`).
---@field health? fun(): boolean|string, ...string|string[]

---Configure and enable built-in providers.
---@class nanocode.provider.Opts
---
---The built-in provider to use, or `false` for none.
---Default order:
---  - `"snacks"` if `snacks.terminal` is available and enabled
---  - `"kitty"` if in a `kitty` session with remote control enabled
---  - `"wezterm"` if in a `wezterm` window
---  - `"tmux"` if in a `tmux` session
---  - `"terminal"` as a fallback
---@field enabled? "terminal"|"snacks"|"kitty"|"wezterm"|"tmux"|false
---
---@field terminal? nanocode.provider.terminal.Opts
---@field snacks? nanocode.provider.snacks.Opts
---@field kitty? nanocode.provider.kitty.Opts
---@field wezterm? nanocode.provider.wezterm.Opts
---@field tmux? nanocode.provider.tmux.Opts

local M = {}

---Get all providers.
---@return nanocode.Provider[]
function M.list()
  return {
    require("nanocode.provider.snacks"),
    require("nanocode.provider.kitty"),
    require("nanocode.provider.wezterm"),
    require("nanocode.provider.tmux"),
    require("nanocode.provider.terminal"),
  }
end

---Toggle `nanocode` via the configured provider.
function M.toggle()
  local provider = require("nanocode.config").provider
  if provider and provider.toggle then
    provider:toggle()
    require("nanocode.events").subscribe()
  else
    error("`provider.toggle` unavailable — run `:checkhealth nanocode` for details", 0)
  end
end

---Start `nanocode` via the configured provider.
function M.start()
  local provider = require("nanocode.config").provider
  if provider and provider.start then
    provider:start()
    require("nanocode.events").subscribe()
  else
    error("`provider.start` unavailable — run `:checkhealth nanocode` for details", 0)
  end
end

---Stop `nanocode` via the configured provider.
function M.stop()
  local provider = require("nanocode.config").provider
  if provider and provider.stop then
    provider:stop()
    require("nanocode.events").unsubscribe()
  else
    error("`provider.stop` unavailable — run `:checkhealth nanocode` for details", 0)
  end
end

return M
