local M = {}

---@class nanocode.events.Opts
---
---Whether to subscribe to Server-Sent Events (SSE) from `nanocode` and execute `nanocodeEvent:<event.type>` autocmds.
---@field enabled? boolean
---
---Reload buffers edited by `nanocode` in real-time.
---Requires `vim.o.autoread = true`.
---@field reload? boolean
---
---@field permissions? nanocode.events.permissions.Opts

local heartbeat_timer = vim.uv.new_timer()
local nanocode_HEARTBEAT_INTERVAL_MS = 30000

---Subscribe to `nanocode`'s Server-Sent Events (SSE) to execute `nanocodeEvent:<event.type>` autocmds.
function M.subscribe()
  if not require("nanocode.config").opts.events.enabled then
    return
  end

  require("nanocode.cli.server")
    .get_port(false)
    :next(function(port)
      require("nanocode.cli.client").sse_subscribe(
        port,
        ---@param response nanocode.cli.client.Event
        function(response)
          heartbeat_timer:stop()
          heartbeat_timer:start(
            nanocode_HEARTBEAT_INTERVAL_MS + 5000,
            0,
            vim.schedule_wrap(require("nanocode.events").unsubscribe)
          )

          vim.api.nvim_exec_autocmds("User", {
            pattern = "nanocodeEvent:" .. response.type,
            data = {
              event = response,
              port = port,
            },
          })
        end
      )
    end)
    :catch(function(err)
      vim.notify("Failed to subscribe to SSE: " .. err, vim.log.levels.WARN)
    end)
end

function M.unsubscribe()
  heartbeat_timer:stop()
  require("nanocode.cli.client").sse_unsubscribe()

  vim.api.nvim_exec_autocmds("User", {

    pattern = "nanocodeEvent:server.disconnected",
    data = {
      event = {
        type = "server.disconnected",
      },
    },
  })
end

return M
