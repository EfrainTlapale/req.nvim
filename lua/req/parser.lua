local M = {}

---@class req.Header
---@field name string
---@field value string

---@class req.Request
---@field name string|nil
---@field no_auth_encoding boolean|nil
---@field method string
---@field url string
---@field version string|nil
---@field headers req.Header[]
---@field body string|nil
---@field body_file string|nil
---@field body_start integer|nil first buffer line of an inline body
---@field body_stop integer|nil
---@field vars table<string, string>
---@field line integer
---@field start integer
---@field stop integer

---@class req.Document
---@field vars table<string, string>
---@field requests req.Request[]

M.NAME_PATTERN = "^(%s*[#/]+%s*@name%s+)(%S+)"
local NO_AUTH_ENCODING_PATTERN = "^%s*[#/]+%s*@no%-auth%-encoding%s*$"

local METHODS = {
  GET = true,
  POST = true,
  PUT = true,
  PATCH = true,
  DELETE = true,
  HEAD = true,
  OPTIONS = true,
  TRACE = true,
  CONNECT = true,
}

local function is_blank(line)
  return line:match("^%s*$") ~= nil
end

local function is_comment(line)
  return line:match("^%s*#") ~= nil or line:match("^%s*//") ~= nil
end

local function looks_like_url(line)
  return line:match("^https?://") or line:match("^{{") or line:match("^[%w%.%-]+:%d+") or line:match("^/")
end

local function parse_request_line(line)
  line = vim.trim(line)
  local without_version, version = line:match("^(.-)%s+(HTTP/[%d%.]+)$")
  line = without_version or line
  local method, url = line:match("^(%u+)%s+(.+)$")
  if method and METHODS[method] then return method, vim.trim(url), version end
  if looks_like_url(line) then return "GET", line, version end
end

---@return req.Request|nil request, table<string, string> vars
local function parse_section(lines, start, stop)
  local vars, name, no_auth_encoding = {}, nil, nil
  local method, url, version, request_line

  for i = start, stop do
    local line = lines[i]
    local var_name, var_value = line:match("^%s*@([%w_%-%.]+)%s*=%s*(.-)%s*$")
    local _, request_name = line:match(M.NAME_PATTERN)
    if var_name then
      vars[var_name] = var_value
    elseif request_name then
      name = request_name
    elseif line:match(NO_AUTH_ENCODING_PATTERN) then
      no_auth_encoding = true
    elseif not is_blank(line) and not is_comment(line) then
      method, url, version = parse_request_line(line)
      if method then
        request_line = i
        break
      end
    end
  end
  if not request_line then return nil, vars end

  ---@type req.Request
  local req = {
    name = name,
    no_auth_encoding = no_auth_encoding,
    method = method,
    url = url,
    version = version,
    headers = {},
    vars = vars,
    line = request_line,
    start = start,
    stop = stop,
  }

  local i = request_line + 1
  while i <= stop and lines[i]:match("^%s*[?&]") do
    req.url = req.url .. vim.trim(lines[i])
    i = i + 1
  end

  while i <= stop and not is_blank(lines[i]) do
    local header_name, header_value = lines[i]:match("^%s*([^:%s]+)%s*:%s*(.-)%s*$")
    if header_name and not is_comment(lines[i]) then
      table.insert(req.headers, { name = header_name, value = header_value })
    end
    i = i + 1
  end

  local first, last = i, stop
  while first <= last and is_blank(lines[first]) do
    first = first + 1
  end
  while last >= first and (is_blank(lines[last]) or is_comment(lines[last])) do
    last = last - 1
  end
  if first <= last then
    local body = table.concat(lines, "\n", first, last)
    req.body_file = first == last and body:match("^%s*<%s+(%S.-)%s*$") or nil
    if not req.body_file then
      req.body, req.body_start, req.body_stop = body, first, last
    end
  end

  return req, vars
end

---@param lines string[]
---@return req.Document
function M.parse(lines)
  local doc = { vars = {}, requests = {} }
  local function add_section(start, stop)
    local req, vars = parse_section(lines, start, stop)
    if req then
      table.insert(doc.requests, req)
    else
      doc.vars = vim.tbl_extend("force", doc.vars, vars)
    end
  end
  local start = 1
  for i, line in ipairs(lines) do
    if line:match("^###") and i > start then
      add_section(start, i - 1)
      start = i
    end
  end
  if start <= #lines then add_section(start, #lines) end
  return doc
end

function M.parse_buffer(buf)
  return M.parse(vim.api.nvim_buf_get_lines(buf or 0, 0, -1, false))
end

---@return req.Request|nil
function M.request_at(doc, line)
  for _, req in ipairs(doc.requests) do
    if line >= req.start and line <= req.stop then return req end
  end
end

---@return string|nil
function M.get_header(headers, name)
  for _, h in ipairs(headers) do
    if h.name:lower() == name:lower() then return h.value end
  end
end

return M
