vim.api.nvim_create_autocmd("VimLeave", {
  group = vim.api.nvim_create_augroup("nanocodeProvider", { clear = true }),
  pattern = "*",
  callback = function()
    pcall(require("nanocode.provider").stop)
  end,
  desc = "Stop `nanocode` provider on exit",
})
