local curl = require("req.curl")
local parser = require("req.parser")
local ui = require("req.ui")
local util = require("req.util")
local vars = require("req.vars")

local M = {}

---@class req.Options
local defaults = {
  curl_path = "curl",
  split = "vertical", ---@type "vertical"|"horizontal"
  follow_redirects = false,
  insecure = false,
  timeout_seconds = nil, ---@type number|nil
  format_json = true,
  default_env = nil, ---@type string|nil
}

---@type req.Options
M.options = vim.deepcopy(defaults)

local function current_env()
  return vim.g.req_env or M.options.default_env
end

---@return req.Request|nil
local function resolved_request_under_cursor()
  local doc = parser.parse_buffer(0)
  local req = parser.request_at(doc, vim.fn.line("."))
  if not req then
    util.notify("no request under cursor", vim.log.levels.WARN)
    return nil
  end
  local resolved, missing = vars.resolve(doc, req, util.buf_dir(0), current_env())
  if #missing > 0 then
    util.notify("unresolved variables: " .. table.concat(missing, ", "), vim.log.levels.WARN)
  end
  return resolved
end

function M.run()
  local req = resolved_request_under_cursor()
  if not req then return end
  local env = current_env()
  ui.loading(req)
  curl.run(req, M.options, function(res) ui.show(res, env) end)
end

function M.cancel()
  if curl.cancel() then util.notify("request cancelled") end
end

function M.copy()
  local req = resolved_request_under_cursor()
  if not req then return end
  local command = curl.to_curl_string(req, M.options)
  vim.fn.setreg("+", command)
  vim.fn.setreg('"', command)
  util.notify("copied curl command")
end

function M.from_curl()
  local lines, err = curl.from_curl(vim.fn.getreg("+"))
  if not lines then
    util.notify(err, vim.log.levels.ERROR)
    return
  end
  local row = vim.fn.line(".")
  vim.api.nvim_buf_set_lines(0, row, row, false, lines)
  vim.api.nvim_win_set_cursor(0, { row + 1, 0 })
  M.jump_next()
end

local function jump_to_request(pick)
  local lines = vim.tbl_map(function(req) return req.line end, parser.parse_buffer(0).requests)
  local target = pick(lines, vim.fn.line("."))
  if target then vim.api.nvim_win_set_cursor(0, { target, 0 }) end
end

function M.jump_next()
  jump_to_request(function(lines, cursor)
    return vim.iter(lines):find(function(line) return line > cursor end)
  end)
end

function M.jump_prev()
  jump_to_request(function(lines, cursor)
    return vim.iter(lines):rev():find(function(line) return line < cursor end)
  end)
end

function M.search()
  local requests = parser.parse_buffer(0).requests
  if #requests == 0 then
    util.notify("no requests in buffer", vim.log.levels.WARN)
    return
  end
  vim.ui.select(requests, {
    prompt = "Request",
    format_item = function(req) return (req.name and (req.name .. "  ") or "") .. req.method .. " " .. req.url end,
  }, function(req)
    if req then vim.api.nvim_win_set_cursor(0, { req.line, 0 }) end
  end)
end

local NO_ENV = "(none)"

---@param name string|nil prompts when nil; "" clears
function M.set_env(name)
  if name then
    vim.g.req_env = name ~= "" and name ~= NO_ENV and name or nil
    util.notify("environment: " .. (vim.g.req_env or "none"))
    return
  end
  local envs = vars.list_envs(util.buf_dir(0))
  if #envs == 0 then
    util.notify("no environments found (http-client.env.json)", vim.log.levels.WARN)
    return
  end
  table.insert(envs, NO_ENV)
  vim.ui.select(envs, { prompt = "Environment (current: " .. (current_env() or "none") .. ")" }, function(choice)
    if choice then M.set_env(choice) end
  end)
end

M.close = ui.close

---@param opts req.Options|nil
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
end

return M
