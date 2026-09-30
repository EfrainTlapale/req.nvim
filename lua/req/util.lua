local M = {}

function M.notify(msg, level)
  vim.notify("req.nvim: " .. msg, level or vim.log.levels.INFO)
end

---@return string|nil
function M.read_file(path)
  local fd = path and io.open(path, "rb")
  if not fd then return nil end
  local data = fd:read("*a")
  fd:close()
  return data
end

---@return string|nil output, string|nil err
function M.jq(filter, input)
  if vim.fn.executable("jq") == 0 then return nil, "jq not found" end
  local res = vim.system({ "jq", filter }, { stdin = input, text = true }):wait()
  if res.code ~= 0 then return nil, vim.trim(res.stderr or "") end
  return res.stdout
end

function M.buf_dir(buf)
  local name = vim.api.nvim_buf_get_name(buf or 0)
  if name == "" then return vim.fn.getcwd() end
  return vim.fs.dirname(vim.fs.normalize(vim.fn.fnamemodify(name, ":p")))
end

return M
