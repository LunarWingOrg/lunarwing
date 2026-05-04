---`nanocode.nvim` public API.
local M = {}

M.ask = require("nanocode.ui.ask").ask
M.select = require("nanocode.ui.select").select
M.select_session = require("nanocode.ui.select_session").select_session

M.prompt = require("nanocode.api.prompt").prompt
M.operator = require("nanocode.api.operator").operator
M.command = require("nanocode.api.command").command

M.toggle = require("nanocode.provider").toggle
M.start = require("nanocode.provider").start
M.stop = require("nanocode.provider").stop

M.statusline = require("nanocode.status").statusline

return M
