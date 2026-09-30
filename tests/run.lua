local root = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, "S").source:sub(2))))
vim.opt.rtp:prepend(root)

local parser = require("req.parser")
local vars = require("req.vars")
local curl = require("req.curl")

local failures, passed = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    print("ok   " .. name)
  else
    failures = failures + 1
    print("FAIL " .. name .. "\n     " .. tostring(err))
  end
end
local function eq(actual, expected, msg)
  if not vim.deep_equal(actual, expected) then
    error((msg and (msg .. ": ") or "") .. "expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual), 2)
  end
end

local fixture = vim.fn.readfile(root .. "/tests/fixtures/requests.http")
local dir = vim.fn.tempname()
local git_root_stops_env_lookup = dir .. "/.git"
vim.fn.mkdir(git_root_stops_env_lookup, "p")

local function write_json(path, tbl)
  vim.fn.writefile({ vim.json.encode(tbl) }, path)
end

local doc = parser.parse(fixture)
local by_name = {}
for _, r in ipairs(doc.requests) do
  if r.name then by_name[r.name] = r end
end

test("parser: finds all requests", function()
  eq(#doc.requests, 4)
  eq(doc.requests[4].name, nil)
end)

test("parser: file-level vars from request-less section", function()
  eq(doc.vars.SERVICE_ID, "MG123")
  eq(doc.vars.BASE_URL, "localhost:{{PORT}}")
end)

test("parser: request line, version, headers", function()
  local r = by_name.getService
  eq(r.method, "GET")
  eq(r.url, "{{BASE_URL}}/v1/Services/{{SERVICE_ID}}")
  eq(r.version, "HTTP/1.1")
  eq(r.headers, { { name = "Authorization", value = "Basic {{ACCOUNT_SID}}:{{ACCOUNT_TOKEN}}" } })
  eq(r.body, nil)
end)

test("parser: // @name, section vars, url continuation, body trims trailing comment", function()
  local r = by_name.createThing
  eq(r.vars, { ["local"] = "overridden" })
  eq(r.url, "http://{{BASE_URL}}/things?a=1&b={{local}}")
  eq(r.body, '{\n  "id": "{{SERVICE_ID}}",\n  "env": "{{envVar}}"\n}')
end)

test("parser: request_at uses section ranges", function()
  local r = by_name.setHooks
  eq(parser.request_at(doc, r.start).name, "setHooks")
  eq(parser.request_at(doc, r.stop).name, "setHooks")
  eq(parser.request_at(doc, 1), nil)
end)

test("parser: bare URL means GET, body file", function()
  local d = parser.parse({ "https://x.test/a", "", "< ./payload.json" })
  eq(d.requests[1].method, "GET")
  eq(d.requests[1].body_file, "./payload.json")
end)

write_json(dir .. "/http-client.env.json", {
  ["$shared"] = { envVar = "shared", PORT = "1" },
  dev = { envVar = "from-dev" },
  prod = { envVar = "from-prod" },
})
write_json(dir .. "/http-client.private.env.json", { dev = { ACCOUNT_TOKEN = "private-token" } })
vim.fn.writefile({ "# comment", "export DOT=dotenv-value", "QUOTED='q v'" }, dir .. "/.env")

test("vars: list envs", function()
  eq(vars.list_envs(dir), { "dev", "prod" })
end)

test("vars: precedence section > file > private > public > shared > dotenv", function()
  local r = by_name.createThing
  local ctx = vars.context(doc, r, dir, "dev")
  eq(ctx["local"], "overridden")
  eq(ctx.envVar, "from-dev")
  eq(ctx.ACCOUNT_TOKEN, "secret789", "file var beats private env")
  eq(ctx.DOT, "dotenv-value")
  eq(ctx.QUOTED, "q v")
  eq(vars.context(doc, r, dir, nil).envVar, "shared")
end)

test("vars: recursive interpolation and missing names", function()
  local missing = {}
  eq(vars.interpolate("{{BASE_URL}}/{{nope}}", { BASE_URL = "h:{{P}}", P = "80" }, missing), "h:80/{{nope}}")
  eq(missing, { nope = true })
  eq(vars.interpolate("{{a}}", { a = "{{a}}" }), "{{a}}", "self reference terminates")
end)

test("vars: dynamic variables", function()
  local id = vars.interpolate("{{$uuid}}", {})
  assert(id:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-4%x%x%x%-[89ab]%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"), id)
  assert(id ~= vars.interpolate("{{$uuid}}", {}), "uuids repeat")
  local n = tonumber(vars.interpolate("{{$randomInt}}", {}))
  assert(n and n >= 0 and n <= 1000, "randomInt out of range")
end)

test("vars: basic auth encoding", function()
  eq(vars.encode_basic_auth("Basic user:pass"), "Basic " .. vim.base64.encode("user:pass"))
  eq(vars.encode_basic_auth("Basic user pass"), "Basic " .. vim.base64.encode("user:pass"))
  local encoded = "Basic " .. vim.base64.encode("u:p")
  eq(vars.encode_basic_auth(encoded), encoded)
  eq(vars.encode_basic_auth("Bearer abc"), "Bearer abc")
end)

test("vars: resolve interpolates and encodes basic auth", function()
  local r = vars.resolve(doc, by_name.getService, dir, nil)
  eq(r.url, "localhost:1/v1/Services/MG123")
  eq(r.headers[1].value, "Basic " .. vim.base64.encode("AC456:secret789"))
end)

test("vars: @no-auth-encoding sends basic auth as written", function()
  local d = parser.parse({ "# @name raw", "# @no-auth-encoding", "@U = u", "GET https://x.test", "Authorization: Basic {{U}}:pw" })
  local r = d.requests[1]
  eq(r.name, "raw")
  eq(r.no_auth_encoding, true)
  eq(vars.resolve(d, r, dir, nil).headers[1].value, "Basic u:pw")
  eq(by_name.getService.no_auth_encoding, nil)
end)

test("curl: form body lines are joined", function()
  local r = vars.resolve(doc, by_name.setHooks, dir, nil)
  eq(curl.effective_body(r), "InboundRequestUrl=https://example.com/api/webhook&StatusCallback=https://example.com/api/status-callback")
end)

test("curl: build_args", function()
  local get = vars.resolve(doc, by_name.getService, dir, nil)
  local args, _, stdin = curl.build_args(get, { timeout_seconds = 5 })
  eq(args[1], "curl")
  assert(vim.tbl_contains(args, "--http1.1"))
  assert(vim.tbl_contains(args, "--max-time"))
  eq(args[#args], "localhost:1/v1/Services/MG123")
  eq(stdin, nil)

  local post = vars.resolve(doc, by_name.setHooks, dir, nil)
  args, _, stdin = curl.build_args(post, {})
  assert(vim.tbl_contains(args, "@-"), "body is read from stdin")
  eq(stdin, curl.effective_body(post))
end)

test("curl: shell_split", function()
  eq(curl.shell_split([[curl -H 'A: b c' "x\"y" $'l1\nl2' a\ b \
  --data=1]]), { "curl", "-H", "A: b c", 'x"y', "l1\nl2", "a b", "--data=1" })
end)

test("curl: from_curl", function()
  local lines = assert(curl.from_curl([[curl 'https://api.test/x?y=1' \
  -H 'Accept: application/json' -u user:pw --compressed \
  --data-raw '{"a":1}' -H 'Content-Type: application/json']]))
  eq(lines[3], "POST https://api.test/x?y=1")
  assert(vim.tbl_contains(lines, "Authorization: Basic user:pw"))
  assert(vim.tbl_contains(lines, "Accept: application/json"))
  local d = parser.parse(lines)
  eq(d.requests[1].method, "POST")
  eq(vim.json.decode(d.requests[1].body), { a = 1 })
end)

test("curl: to_curl_string -> from_curl round trip", function()
  local r = vars.resolve(doc, by_name.setHooks, dir, nil)
  local d = parser.parse(assert(curl.from_curl(curl.to_curl_string(r, {}))))
  local back = d.requests[1]
  eq(back.method, "POST")
  eq(back.url, r.url)
  eq(back.version, "HTTP/1.1")
  eq(parser.get_header(back.headers, "authorization"), r.headers[1].value)
  eq(back.body, curl.effective_body(r))
end)

local port
local server = vim.system({ "python3", root .. "/tests/echo_server.py" }, {
  text = true,
  stdout = function(_, data) port = port or (data and data:match("%d+")) end,
})
local ready = vim.wait(5000, function() return port ~= nil end, 20)
write_json(dir .. "/http-client.env.json", { dev = { PORT = port, envVar = "from-dev" } })

local function send(resolved)
  local res
  curl.run(resolved, {}, function(x) res = x end)
  assert(vim.wait(10000, function() return res ~= nil end, 20), "request timed out")
  return res
end

local function run(name_or_index, env)
  local r = type(name_or_index) == "number" and doc.requests[name_or_index] or by_name[name_or_index]
  local res = send(vars.resolve(doc, r, dir, env))
  return res, res.status == 200 and vim.json.decode(res.body) or nil
end

test("e2e: server started", function() assert(ready, "echo server did not start") end)

test("e2e: GET with basic auth and HTTP/1.1", function()
  local res, echo = run("getService", "dev")
  eq(res.ok, true)
  eq(res.status, 200)
  eq(res.status_text, "OK")
  eq(echo.method, "GET")
  eq(echo.path, "/v1/Services/MG123")
  eq(echo.version, "HTTP/1.1")
  eq(echo.headers.authorization, "Basic " .. vim.base64.encode("AC456:secret789"))
  assert(res.content_type:match("application/json"))
  assert(#res.headers > 1 and res.headers[1]:match("^HTTP/"))
end)

test("e2e: form POST", function()
  local _, echo = run("setHooks", "dev")
  eq(echo.method, "POST")
  eq(echo.headers["content-type"], "application/x-www-form-urlencoded")
  eq(echo.body, "InboundRequestUrl=https://example.com/api/webhook&StatusCallback=https://example.com/api/status-callback")
end)

test("e2e: JSON POST with env var and query continuation", function()
  local _, echo = run("createThing", "dev")
  eq(echo.path, "/things?a=1&b=overridden")
  eq(echo.headers.authorization, "token-abc")
  eq(vim.json.decode(echo.body), { id = "MG123", env = "from-dev" })
end)

test("e2e: non-2xx status", function()
  local res = run(4, "dev")
  eq(res.ok, true)
  eq(res.status, 404)
end)

test("e2e: connection error is reported", function()
  local r = vars.resolve(doc, by_name.getService, dir, "dev")
  r.url = "http://127.0.0.1:1/"
  local res = send(r)
  eq(res.ok, false)
  assert(res.error and res.error ~= "", "expected an error message")
end)

test("e2e: a superseded request never reports", function()
  local r = vars.resolve(doc, by_name.getService, dir, "dev")
  local first_reported = false
  curl.run(r, {}, function() first_reported = true end)
  local second = send(r)
  vim.wait(200)
  eq(second.status, 200)
  eq(first_reported, false)
end)

test("e2e: cancel reports cancelled", function()
  local r = vars.resolve(doc, by_name.getService, dir, "dev")
  local res
  curl.run(r, {}, function(x) res = x end)
  eq(curl.cancel(), true)
  assert(vim.wait(5000, function() return res ~= nil end, 20))
  eq(res.error, "cancelled")
end)

server:kill(15)
vim.fn.delete(dir, "rf")
print(string.format("\n%d passed, %d failed", passed, failures))
os.exit(failures == 0 and 0 or 1)
