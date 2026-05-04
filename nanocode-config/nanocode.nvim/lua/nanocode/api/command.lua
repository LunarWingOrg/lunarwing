local M = {}

---See available commands [here](https://github.com/sst/nanocode/blob/dev/packages/nanocode/src/cli/cmd/tui/event.ts).
---@alias nanocode.Command
---| 'session.list'
---| 'session.new'
---| 'session.share'
---| 'session.interrupt'
---| 'session.compact'
---| 'session.page.up'
---| 'session.page.down'
---| 'session.half.page.up'
---| 'session.half.page.down'
---| 'session.first'
---| 'session.last'
---| 'session.undo'
---| 'session.redo'
---| 'prompt.submit'
---| 'prompt.clear'
---| 'agent.cycle'

---Command `nanocode`.
---
---@param command nanocode.Command|string The command to send. Can be built-in or reference your custom commands.
function M.command(command)
  require("nanocode.cli.server")
    .get_port()
    :next(function(port)
      -- No need to register SSE here - commands don't trigger any.
      -- (except maybe the `input_*` commands? but no reason for user to use those).
      require("nanocode.cli.client").tui_execute_command(command, port)
    end)
    :catch(function(err)
      vim.notify(err, vim.log.levels.ERROR, { title = "nanocode" })
    end)
end

return M
