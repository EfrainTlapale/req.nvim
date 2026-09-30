local util = require("req.util")

local M = {}

local function find_up(name, dir)
  local home = vim.uv.os_homedir()
  local current = dir
  while true do
    local candidate = vim.fs.joinpath(current, name)
    if vim.uv.fs_stat(candidate) then return candidate end
    local parent = vim.fs.dirname(current)
    local is_boundary = current == home or parent == current or vim.uv.fs_stat(vim.fs.joinpath(current, ".git"))
    if is_boundary then return nil end
    current = parent
  end
end

local function read_json(path)
  local content = util.read_file(path)
  if not content then return {} end
  local ok, data = pcall(vim.json.decode, content, { luanil = { object = true } })
  if not ok or type(data) ~= "table" then
    util.notify("invalid JSON in " .. path, vim.log.levels.WARN)
    return {}
  end
  return data
end

local function read_dotenv(path)
  local vars = {}
  for line in (util.read_file(path) or ""):gmatch("[^\n]+") do
    local key, value = line:gsub("^%s*export%s+", ""):match("^%s*([%w_%.%-]+)%s*=%s*(.-)%s*$")
    if key then vars[key] = value:match('^"(.*)"$') or value:match("^'(.*)'$") or value end
  end
  return vars
end

local function stringify(tbl)
  local out = {}
  for k, v in pairs(tbl or {}) do
    out[k] = type(v) == "table" and vim.json.encode(v) or tostring(v)
  end
  return out
end

local function load_env_files(dir)
  return {
    public = read_json(find_up("http-client.env.json", dir)),
    private = read_json(find_up("http-client.private.env.json", dir)),
    dotenv = read_dotenv(find_up(".env", dir)),
  }
end

---@return string[]
function M.list_envs(dir)
  local files = load_env_files(dir)
  local names = {}
  for _, tbl in ipairs({ files.public, files.private }) do
    for name, value in pairs(tbl) do
      if name ~= "$shared" and type(value) == "table" then names[name] = true end
    end
  end
  local list = vim.tbl_keys(names)
  table.sort(list)
  return list
end

---@return table<string, string>
function M.context(doc, req, dir, env)
  local files = load_env_files(dir)
  local lowest_to_highest_precedence = {
    files.dotenv,
    stringify(files.public["$shared"]),
    stringify(files.private["$shared"]),
    env and stringify(files.public[env]) or {},
    env and stringify(files.private[env]) or {},
    doc.vars,
    req.vars,
  }
  return vim.tbl_extend("force", unpack(lowest_to_highest_precedence))
end

local function random_bytes(n)
  return { assert(vim.uv.random(n)):byte(1, n) }
end

local function uuid()
  local b = random_bytes(16)
  b[7] = bit.bor(bit.band(b[7], 0x0f), 0x40)
  b[9] = bit.bor(bit.band(b[9], 0x3f), 0x80)
  return string.format("%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x", unpack(b))
end

local function random_int(max)
  local b = random_bytes(4)
  return ((b[1] * 0x1000000) + (b[2] * 0x10000) + (b[3] * 0x100) + b[4]) % (max + 1)
end

local DYNAMIC = {
  ["$uuid"] = uuid,
  ["$random.uuid"] = uuid,
  ["$timestamp"] = function() return tostring(os.time()) end,
  ["$isoTimestamp"] = function() return os.date("!%Y-%m-%dT%H:%M:%SZ") end,
  ["$randomInt"] = function() return tostring(random_int(1000)) end,
}

local function dynamic(name)
  if DYNAMIC[name] then return DYNAMIC[name]() end
  local env_name = name:match("^%$processEnv%s+(%S+)$") or name:match("^%$env%s+(%S+)$")
  return env_name and vim.env[env_name]
end

local MAX_NESTING = 10

---@param missing table<string, boolean>|nil collects unresolved names
function M.interpolate(str, ctx, missing)
  for _ = 1, MAX_NESTING do
    local changed = false
    str = str:gsub("{{%s*(.-)%s*}}", function(name)
      local value = ctx[name] or dynamic(name)
      if value then
        changed = true
      elseif missing then
        missing[name] = true
      end
      return value
    end)
    if not changed then break end
  end
  return str
end

local function is_encoded_credentials(s)
  if #s % 4 ~= 0 or not s:match("^[%w%+/]+=*$") then return false end
  local ok, decoded = pcall(vim.base64.decode, s)
  return ok and decoded:find(":", 1, true) ~= nil
end

function M.encode_basic_auth(value)
  local creds = value:match("^[Bb]asic%s+(.+)$")
  if not creds or is_encoded_credentials(creds) then return value end
  local user, password = creds:match("^(.-):(.*)$")
  if not user then
    user, password = creds:match("^(%S+)%s+(.*)$")
  end
  if not user then return value end
  return "Basic " .. vim.base64.encode(user .. ":" .. password)
end

---@return req.Request resolved, string[] missing
function M.resolve(doc, req, dir, env)
  local ctx = M.context(doc, req, dir, env)
  local missing = {}
  local out = vim.deepcopy(req)
  out.url = M.interpolate(out.url, ctx, missing)
  for _, h in ipairs(out.headers) do
    h.value = M.interpolate(h.value, ctx, missing)
    if h.name:lower() == "authorization" and not out.no_auth_encoding then
      h.value = M.encode_basic_auth(h.value)
    end
  end
  if out.body then out.body = M.interpolate(out.body, ctx, missing) end
  if out.body_file then
    local path = M.interpolate(out.body_file, ctx, missing)
    if not path:match("^[/~]") then path = vim.fs.joinpath(dir, path) end
    out.body_file = vim.fs.normalize(path)
  end
  local missing_names = vim.tbl_keys(missing)
  table.sort(missing_names)
  return out, missing_names
end

return M
