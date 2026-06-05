vim.api.nvim_create_autocmd("User", {
  group = vim.api.nvim_create_augroup("nanocodeReload", { clear = true }),
  pattern = "nanocodeEvent:file.edited",
  callback = function(args)
    if require("nanocode.config").opts.events.reload then
      if not vim.o.autoread then
        -- Unfortunately `autoread` is kinda necessary, for `:checktime`.
        -- Alternatively we could `:edit!` but that would lose any unsaved changes.
        vim.notify(
          "Please set `vim.o.autoread = true` to use `nanocode.nvim` auto-reload",
          vim.log.levels.WARN,
          { title = "nanocode" }
        )
      else
        -- `schedule` because blocking the event loop during rapid SSE influx can drop events
        vim.schedule(function()
          -- `:checktime` checks all buffers - no need to check the event's file
          vim.cmd("checktime")
        end)
      end
    end
  end,
  desc = "Reload buffers edited by nanocode",
})
