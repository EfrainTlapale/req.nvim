local parser = require("req.parser")
local util = require("req.util")

local M = {}

local VERSIONS = {
  { "HTTP/1.0", "--http1.0" },
  { "HTTP/1.1", "--http1.1" },
  { "HTTP/2", "--http2" },
  { "HTTP/2.0", "--http2" },
  { "HTTP/3", "--http3" },
}

local function version_flag(version)
  for _, v in ipairs(VERSIONS) do
    if v[1] == version then return v[2] end
  end
end

local function version_of_flag(flag)
  for _, v in ipairs(VERSIONS) do
    if v[2] == flag then return v[1] end
  end
end

---@return string|nil
function M.effective_body(req)
  local content_type = parser.get_header(req.headers, "content-type") or ""
  local is_form = content_type:lower():match("application/x%-www%-form%-urlencoded")
  if req.body and is_form then return vim.trim((req.body:gsub("%s*\n%s*", ""))) end
  return req.body
end

---@param body_source "stdin"|"inline"
local function curl_args(req, opts, body_source)
  local args = { "-X", req.method }
  local http_version = version_flag(req.version)
  if http_version then table.insert(args, http_version) end
  if opts.follow_redirects then table.insert(args, "-L") end
  if opts.insecure then table.insert(args, "-k") end
  if opts.timeout_seconds then vim.list_extend(args, { "--max-time", tostring(opts.timeout_seconds) }) end
  for _, h in ipairs(req.headers) do
    vim.list_extend(args, { "-H", h.name .. ": " .. h.value })
  end
  local body = M.effective_body(req)
  if req.body_file then
    vim.list_extend(args, { "--data-binary", "@" .. req.body_file })
  elseif body then
    vim.list_extend(args, body_source == "inline" and { "--data-raw", body } or { "--data-binary", "@-" })
  end
  return args
end

---@return string[] argv, { headers: string, body: string } output_paths, string|nil stdin
function M.build_args(req, opts)
  local paths = { headers = vim.fn.tempname(), body = vim.fn.tempname() }
  local args = { opts.curl_path or "curl", "-sS" }
  vim.list_extend(args, curl_args(req, opts, "stdin"))
  vim.list_extend(args, { "-D", paths.headers, "-o", paths.body, "-w", "%{json}", "--url", req.url })
  return args, paths, not req.body_file and M.effective_body(req) or nil
end

---@class req.Response
---@field ok boolean curl succeeded, whatever the HTTP status
---@field status integer
---@field status_text string
---@field time number
---@field size integer
---@field content_type string|nil
---@field headers string[]
---@field body string
---@field error string|nil
---@field request req.Request
---@field command string

---@return string[] lines, string status_text
local function final_response_headers(raw)
  local block = {}
  for line in raw:gsub("\r", ""):gmatch("[^\n]+") do
    if line:match("^HTTP/") then block = {} end
    table.insert(block, line)
  end
  return block, block[1] and block[1]:match("^HTTP/%S+%s+%d+%s*(.*)$") or ""
end

---@type vim.SystemObj|nil
local active

function M.cancel()
  if not active then return false end
  active:kill(15)
  return true
end

---@param on_done fun(res: req.Response)
function M.run(req, opts, on_done)
  M.cancel()
  local args, paths, stdin = M.build_args(req, opts)
  local job
  job = vim.system(args, { text = true, stdin = stdin }, function(obj)
    vim.schedule(function()
      local superseded = active ~= job
      if not superseded then active = nil end
      local ok, info = pcall(vim.json.decode, obj.stdout or "", { luanil = { object = true } })
      info = ok and type(info) == "table" and info or {}
      local headers, status_text = final_response_headers(util.read_file(paths.headers) or "")
      local body = util.read_file(paths.body) or ""
      os.remove(paths.headers)
      os.remove(paths.body)
      if superseded then return end

      local err
      if obj.signal == 15 then
        err = "cancelled"
      elseif obj.code ~= 0 then
        err = info.errormsg or vim.trim(obj.stderr or "")
      end
      on_done({
        ok = obj.code == 0,
        status = tonumber(info.http_code) or 0,
        status_text = status_text,
        time = tonumber(info.time_total) or 0,
        size = tonumber(info.size_download) or 0,
        content_type = info.content_type,
        headers = headers,
        body = body,
        error = err,
        request = req,
        command = M.to_curl_string(req, opts),
      })
    end)
  end)
  active = job
end

local function quote(arg)
  if arg:match("^[%w%-%./:=@_,+]+$") then return arg end
  return vim.fn.shellescape(arg)
end

function M.to_curl_string(req, opts)
  local parts = { "curl" }
  for _, arg in ipairs(curl_args(req, opts, "inline")) do
    table.insert(parts, quote(arg))
  end
  table.insert(parts, quote(req.url))
  return table.concat(parts, " ")
end

local ANSI_ESCAPES = { n = "\n", t = "\t", r = "\r", ["\\"] = "\\", ["'"] = "'", ['"'] = '"' }

---Handles single/double quotes, $'...', backslash escapes and line continuations.
---@return string[]
function M.shell_split(str)
  str = str:gsub("\r\n", "\n")
  local words, current, has_word = {}, {}, false
  local i, n = 1, #str
  local function push()
    if has_word then table.insert(words, table.concat(current)) end
    current, has_word = {}, false
  end
  local function append(s)
    table.insert(current, s)
    has_word = true
  end
  while i <= n do
    local c, next_c = str:sub(i, i), str:sub(i + 1, i + 1)
    if c == "\\" and next_c == "\n" then
      i = i + 2
    elseif c:match("%s") then
      push()
      i = i + 1
    elseif c == "'" then
      local close = str:find("'", i + 1, true) or (n + 1)
      append(str:sub(i + 1, close - 1))
      i = close + 1
    elseif c == "$" and next_c == "'" then
      i = i + 2
      append("")
      while i <= n and str:sub(i, i) ~= "'" do
        local ch, escaped = str:sub(i, i), str:sub(i + 1, i + 1)
        if ch == "\\" and escaped ~= "" then
          append(ANSI_ESCAPES[escaped] or ("\\" .. escaped))
          i = i + 2
        else
          append(ch)
          i = i + 1
        end
      end
      i = i + 1
    elseif c == '"' then
      i = i + 1
      append("")
      while i <= n and str:sub(i, i) ~= '"' do
        local ch, escaped = str:sub(i, i), str:sub(i + 1, i + 1)
        if ch == "\\" and escaped:match('["\\$`]') then
          append(escaped)
          i = i + 2
        elseif ch == "\\" and escaped == "\n" then
          i = i + 2
        else
          append(ch)
          i = i + 1
        end
      end
      i = i + 1
    elseif c == "\\" and next_c ~= "" then
      append(next_c)
      i = i + 2
    else
      append(c)
      i = i + 1
    end
  end
  push()
  return words
end

local IGNORED_WITH_VALUE = {
  ["-o"] = true,
  ["--output"] = true,
  ["-m"] = true,
  ["--max-time"] = true,
  ["--connect-timeout"] = true,
  ["-w"] = true,
  ["--write-out"] = true,
  ["-x"] = true,
  ["--proxy"] = true,
  ["-c"] = true,
  ["--cookie-jar"] = true,
  ["--retry"] = true,
  ["-D"] = true,
  ["--dump-header"] = true,
  ["--resolve"] = true,
  ["--cacert"] = true,
  ["--cert"] = true,
  ["--key"] = true,
}

local DATA_FLAGS = {
  ["-d"] = true,
  ["--data"] = true,
  ["--data-raw"] = true,
  ["--data-binary"] = true,
  ["--data-ascii"] = true,
  ["--data-urlencode"] = true,
}

local HEADER_FLAGS = {
  ["-b"] = "Cookie",
  ["--cookie"] = "Cookie",
  ["-A"] = "User-Agent",
  ["--user-agent"] = "User-Agent",
  ["-e"] = "Referer",
  ["--referer"] = "Referer",
}

---@return string[]|nil lines, string|nil err
function M.from_curl(str)
  local words = M.shell_split(vim.trim(str))
  if words[1] ~= "curl" then return nil, "clipboard does not contain a curl command" end
  local method, url, version
  local headers, data = {}, {}
  local function add_header(name, value)
    table.insert(headers, { name = name, value = value })
  end

  local i = 2
  while i <= #words do
    local word = words[i]
    local long_flag, inline_value = word:match("^(%-%-[%w%-]+)=(.*)$")
    local flag = long_flag or word
    local function value()
      if inline_value then return inline_value end
      i = i + 1
      return words[i] or ""
    end

    if flag == "-X" or flag == "--request" then
      method = value():upper()
    elseif flag:match("^%-X.") then
      method = flag:sub(3):upper()
    elseif flag == "-H" or flag == "--header" then
      local name, header_value = value():match("^%s*([^:]+):%s*(.-)%s*$")
      if name then add_header(name, header_value) end
    elseif DATA_FLAGS[flag] then
      table.insert(data, value())
    elseif flag == "--json" then
      table.insert(data, value())
      add_header("Content-Type", "application/json")
      add_header("Accept", "application/json")
    elseif flag == "-u" or flag == "--user" then
      add_header("Authorization", "Basic " .. value())
    elseif HEADER_FLAGS[flag] then
      add_header(HEADER_FLAGS[flag], value())
    elseif flag == "--url" then
      url = value()
    elseif version_of_flag(flag) then
      version = version_of_flag(flag)
    elseif flag == "-F" or flag == "--form" then
      return nil, "multipart forms (-F) are not supported"
    elseif IGNORED_WITH_VALUE[flag] then
      value()
    elseif not flag:match("^%-") then
      url = word
    end
    i = i + 1
  end
  if not url then return nil, "no URL found in curl command" end

  local has_body = #data > 0
  if has_body and not parser.get_header(headers, "content-type") then
    add_header("Content-Type", "application/x-www-form-urlencoded")
  end
  local lines = { "###", "", table.concat({ method or (has_body and "POST" or "GET"), url, version }, " ") }
  for _, h in ipairs(headers) do
    table.insert(lines, h.name .. ": " .. h.value)
  end
  if has_body then
    local body = table.concat(data, "&")
    body = vim.trim(util.jq(".", body) or body)
    table.insert(lines, "")
    vim.list_extend(lines, vim.split(body, "\n", { plain = true }))
  end
  table.insert(lines, "")
  return lines
end

return M
