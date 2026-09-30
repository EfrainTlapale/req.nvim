-- Complements treesitter's http parser, which treats bodies as plain text.
local parser = require("req.parser")

local M = {}

local ns = vim.api.nvim_create_namespace("req.highlight")
local group = vim.api.nvim_create_augroup("req.highlight", { clear = true })

function M.refresh(buf)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for row, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    for start_col, end_col in line:gmatch("(){{.-}}()") do
      vim.api.nvim_buf_set_extmark(buf, ns, row - 1, start_col - 1, { end_col = end_col - 1, hl_group = "ReqVariable" })
    end
    local prefix, name = line:match(parser.NAME_PATTERN)
    if name then
      vim.api.nvim_buf_set_extmark(buf, ns, row - 1, #prefix, { end_col = #prefix + #name, hl_group = "ReqName" })
    end
  end
end

function M.attach(buf)
  vim.api.nvim_clear_autocmds({ group = group, buffer = buf })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    buffer = buf,
    callback = function() M.refresh(buf) end,
  })
  M.refresh(buf)
end

function M.define_colors()
  vim.api.nvim_set_hl(0, "ReqVariable", { link = "@variable", default = true })
  vim.api.nvim_set_hl(0, "ReqName", { link = "@function", default = true })
end

return M
