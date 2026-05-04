local M = {}

---@class nanocode.api.prompt.Opts
---@field clear? boolean Clear the TUI input before.
---@field submit? boolean Submit the TUI input after.
---@field context? nanocode.Context The context the prompt is being made in.

---Prompt `nanocode`.
---
--- - Resolves `prompt` if it references an `opts.prompts` entry by name.
--- - Injects `opts.contexts` into `prompt`.
--- - `nanocode` will interpret `@` references to files or subagents
---
---@param prompt string
---@param opts? nanocode.api.prompt.Opts
function M.prompt(prompt, opts)
  -- TODO: Referencing `ask = true` prompts doesn't actually ask.
  local referenced_prompt = require("nanocode.config").opts.prompts[prompt]
  prompt = referenced_prompt and referenced_prompt.prompt or prompt
  opts = {
    clear = opts and opts.clear or false,
    submit = opts and opts.submit or false,
    context = opts and opts.context or require("nanocode.context").new(),
  }

  require("nanocode.cli.server")
    .get_port()
    :next(function(port)
      if opts.clear then
        return require("nanocode.promise").new(function(resolve)
          require("nanocode.cli.client").tui_execute_command("prompt.clear", port, function()
            resolve(port)
          end)
        end)
      end
      return port
    end)
    :next(function(port)
      local rendered = opts.context:render(prompt)
      local plaintext = opts.context.plaintext(rendered.output)
      return require("nanocode.promise").new(function(resolve)
        require("nanocode.cli.client").tui_append_prompt(plaintext, port, function()
          resolve(port)
        end)
      end)
    end)
    :next(function(port)
      require("nanocode.events").subscribe()

      if opts.submit then
        require("nanocode.cli.client").tui_execute_command("prompt.submit", port)
      end

      return port
    end)
    :catch(function(err)
      vim.notify(err, vim.log.levels.ERROR, { title = "nanocode" })
      return true
    end)
    :next(function()
      opts.context:clear()
    end)
end

return M
