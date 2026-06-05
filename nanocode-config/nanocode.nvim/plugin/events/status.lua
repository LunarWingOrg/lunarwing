vim.api.nvim_create_autocmd("User", {
  group = vim.api.nvim_create_augroup("nanocodeStatus", { clear = true }),
  pattern = "nanocodeEvent:*",
  callback = function(args)
    ---@type nanocode.cli.client.Event
    local event = args.data.event
    require("nanocode.status").update(event)
  end,
  desc = "Update nanocode status",
})
