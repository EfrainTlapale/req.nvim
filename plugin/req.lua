if vim.g.loaded_req then return end
vim.g.loaded_req = true

vim.filetype.add({ extension = { rest = "http" } })

local SUBCOMMANDS = {
  run = "run",
  cancel = "cancel",
  copy = "copy",
  format = "format",
  from_curl = "from_curl",
  search = "search",
  env = "set_env",
  close = "close",
  jump_next = "jump_next",
  jump_prev = "jump_prev",
}

vim.api.nvim_create_user_command("Req", function(cmd)
  local subcommand = cmd.fargs[1] or "run"
  local fn_name = SUBCOMMANDS[subcommand]
  if not fn_name then
    vim.notify("req.nvim: unknown subcommand " .. subcommand, vim.log.levels.ERROR)
    return
  end
  require("req")[fn_name](cmd.fargs[2])
end, {
  nargs = "*",
  complete = function(arg_lead, cmdline)
    local words = vim.split(cmdline, "%s+", { trimempty = true })
    local completed_position = #words + (arg_lead == "" and 1 or 0)
    local candidates = {}
    if completed_position == 2 then
      candidates = vim.tbl_keys(SUBCOMMANDS)
    elseif completed_position == 3 and words[2] == "env" then
      candidates = require("req.vars").list_envs(require("req.util").buf_dir(0))
    end
    return vim.tbl_filter(function(c) return vim.startswith(c, arg_lead) end, candidates)
  end,
  desc = "req.nvim HTTP client",
})

local highlight = require("req.highlight")
highlight.define_colors()
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("req.colors", { clear = true }),
  callback = highlight.define_colors,
})
vim.api.nvim_create_autocmd("FileType", {
  group = vim.api.nvim_create_augroup("req.filetype", { clear = true }),
  pattern = "http",
  callback = function(args) highlight.attach(args.buf) end,
})
vim.api.nvim_create_autocmd("BufWritePre", {
  group = vim.api.nvim_create_augroup("req.format", { clear = true }),
  callback = function(args)
    if vim.bo[args.buf].filetype == "http" and require("req").options.format_on_save then
      require("req").format(args.buf)
    end
  end,
})
for _, buf in ipairs(vim.api.nvim_list_bufs()) do
  local opened_before_plugin_loaded = vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype == "http"
  if opened_before_plugin_loaded then highlight.attach(buf) end
end
