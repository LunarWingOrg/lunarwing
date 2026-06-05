local M = {}

---Wraps `require("nanocode").prompt` as an operator, supporting ranges and dot-repeat.
---
---@param prompt string
---@param opts? nanocode.api.prompt.Opts
function M.operator(prompt, opts)
  ---@param kind "char"|"line"|"block"
  _G.nanocode_prompt_operator = function(kind)
    local start_pos = vim.api.nvim_buf_get_mark(0, "[")
    local end_pos = vim.api.nvim_buf_get_mark(0, "]")
    if start_pos[1] > end_pos[1] or (start_pos[1] == end_pos[1] and start_pos[2] > end_pos[2]) then
      start_pos, end_pos = end_pos, start_pos
    end

    ---@type nanocode.context.Range
    local range = {
      from = { start_pos[1], start_pos[2] },
      to = { end_pos[1], end_pos[2] },
      kind = kind,
    }

    opts = vim.tbl_extend("force", opts or {}, {
      context = require("nanocode.context").new(range),
    })

    require("nanocode").prompt(prompt, opts)
  end

  vim.o.operatorfunc = "v:lua.nanocode_prompt_operator"
  return "g@"
end

return M
