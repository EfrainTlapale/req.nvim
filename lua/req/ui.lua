local util = require("req.util")

local M = {}

local state = {
  buf = nil, ---@type integer|nil
  response = nil, ---@type req.Response|nil
  env = nil, ---@type string|nil
  view = "body", ---@type "body"|"headers"|"info"
  body = "",
  filter = nil, ---@type string|nil
  filtered = nil, ---@type string|nil
}

local function options()
  return require("req").options
end

local function get_buf()
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then return state.buf end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, "req://response")
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, desc = "req: " .. desc })
  end
  map("B", function() M.set_view("body") end, "body")
  map("H", function() M.set_view("headers") end, "headers")
  map("I", function() M.set_view("info") end, "request info")
  map("F", M.prompt_filter, "jq filter")
  map("q", M.close, "close")
  state.buf = buf
  return buf
end

local function ensure_win(buf)
  local win = vim.fn.bufwinid(buf)
  if win ~= -1 then return win end
  local split = options().split == "horizontal" and "below" or "right"
  win = vim.api.nvim_open_win(buf, false, { split = split, win = 0 })
  vim.wo[win].wrap = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldenable = false
  return win
end

local function set_content(lines, filetype, bar)
  local buf = get_buf()
  local win = ensure_win(buf)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  if vim.bo[buf].filetype ~= filetype then vim.bo[buf].filetype = filetype end
  vim.wo[win].winbar = bar
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
end

local function filetype_for(content_type)
  content_type = (content_type or ""):lower()
  for _, ft in ipairs({ "json", "html", "xml", "javascript", "css", "yaml" }) do
    if content_type:find(ft, 1, true) then return ft end
  end
  return "text"
end

local function human_size(bytes)
  if bytes < 1024 then return bytes .. " B" end
  if bytes < 1024 * 1024 then return string.format("%.1f KB", bytes / 1024) end
  return string.format("%.1f MB", bytes / 1024 / 1024)
end

local function status_hl(status)
  if status >= 200 and status < 300 then return "DiagnosticOk" end
  if status >= 300 and status < 400 then return "DiagnosticWarn" end
  return "DiagnosticError"
end

local function escape_statusline(s)
  return (s:gsub("%%", "%%%%"))
end

local function winbar()
  local res = state.response
  local parts = {}
  if res.error then
    table.insert(parts, "%#DiagnosticError#" .. escape_statusline(res.error) .. "%*")
  else
    local status = vim.trim(res.status .. " " .. res.status_text)
    table.insert(parts, "%#" .. status_hl(res.status) .. "#" .. escape_statusline(status) .. "%*")
    table.insert(parts, math.floor(res.time * 1000 + 0.5) .. " ms")
    table.insert(parts, human_size(res.size))
  end
  if state.env then table.insert(parts, "env: " .. escape_statusline(state.env)) end
  if state.filter then table.insert(parts, "jq: " .. escape_statusline(state.filter)) end

  local tabs = {}
  for _, tab in ipairs({ { "body", "B" }, { "headers", "H" }, { "info", "I" } }) do
    local view, key = tab[1], tab[2]
    local label = " " .. key .. " " .. view .. " "
    table.insert(tabs, view == state.view and ("%#TabLineSel#" .. label .. "%*") or label)
  end
  return " " .. table.concat(parts, " · ") .. "%=" .. table.concat(tabs)
end

local function split_lines(text)
  return vim.split(text, "\n", { plain = true, trimempty = true })
end

local function info_lines()
  local res, req = state.response, state.response.request
  local lines = {}
  if req.name then table.insert(lines, "# " .. req.name) end
  vim.list_extend(lines, { req.method .. " " .. req.url, "", "curl command:" })
  vim.list_extend(lines, split_lines(res.command))
  vim.list_extend(lines, {
    "",
    string.format("time: %.3f s   size: %s   status: %d", res.time, human_size(res.size), res.status),
  })
  if res.error then vim.list_extend(lines, { "", "error: " .. res.error }) end
  return lines
end

function M.render()
  if not state.response then return end
  if state.view == "headers" then
    set_content(state.response.headers, "text", winbar())
  elseif state.view == "info" then
    set_content(info_lines(), "text", winbar())
  elseif state.filtered then
    set_content(split_lines(state.filtered), "json", winbar())
  else
    set_content(split_lines(state.body), filetype_for(state.response.content_type), winbar())
  end
end

---@param req req.Request
function M.loading(req)
  set_content({ "Running " .. req.method .. " " .. req.url .. " ..." }, "text", " %#Comment#running…%*")
end

---@param res req.Response
function M.show(res, env)
  local body = res.body:gsub("\r\n", "\n")
  if filetype_for(res.content_type) == "json" and options().format_json then
    body = util.jq(".", body) or body
  end
  state.response, state.env, state.body = res, env, body
  state.filter, state.filtered = nil, nil
  state.view = res.error and "info" or "body"
  M.render()
end

function M.set_view(view)
  state.view = view
  M.render()
end

---@param filter string|nil empty resets
function M.apply_filter(filter)
  if not state.response then return end
  filter = filter and vim.trim(filter) or ""
  if filter == "" then
    state.filter, state.filtered = nil, nil
  else
    local output, err = util.jq(filter, state.response.body)
    if not output then
      util.notify("jq: " .. err, vim.log.levels.ERROR)
      return
    end
    state.filter, state.filtered = filter, output
  end
  state.view = "body"
  M.render()
end

function M.prompt_filter()
  vim.ui.input({ prompt = "jq filter: ", default = state.filter or "" }, function(input)
    if input then M.apply_filter(input) end
  end)
end

function M.close()
  local win = state.buf and vim.fn.bufwinid(state.buf) or -1
  if win ~= -1 and #vim.api.nvim_tabpage_list_wins(0) > 1 then vim.api.nvim_win_close(win, true) end
end

return M
