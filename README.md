# req.nvim

A small HTTP client for `.http` / `.rest` files. Pure Lua on top of `curl`; no
backend binary, no parser downloads, never touches `runtimepath`.

Requirements: Neovim ≥ 0.11, `curl` ≥ 7.70. Optional: `jq` (JSON pretty-printing and
response filtering), nvim-treesitter's `http` parser (highlighting).

## File format

```http
@BASE_URL = localhost:3000
@TOKEN = abc

###
# @name getUser
GET {{BASE_URL}}/users/1 HTTP/1.1
Authorization: Basic {{USER}}:{{PASSWORD}}

###
// @name createUser
@local = only-for-this-request
POST {{BASE_URL}}/users
  ?notify=true
  &tag={{local}}
Content-Type: application/json

{ "name": "efra" }

###
POST {{BASE_URL}}/form
Content-Type: application/x-www-form-urlencoded

a=1&
b=2
```

- Sections start with `###`. Variables in a section without a request are
  file-wide; variables in a request's section only apply to that request.
- `Authorization: Basic user:password` is base64-encoded when sent. Add a
  `# @no-auth-encoding` line before the request line to send it as written.
- Form-urlencoded bodies are joined into a single line (trimmed lines).
- `< ./file.json` as the whole body sends that file.
- Query lines starting with `?` / `&` right after the request line are appended
  to the URL.
- Dynamic variables: `{{$uuid}}` (alias `{{$random.uuid}}`), `{{$timestamp}}`,
  `{{$isoTimestamp}}`, `{{$randomInt}}` (0–1000), `{{$processEnv NAME}}`
  (alias `{{$env NAME}}`).

## Environments

Searched upward from the `.http` file (stops at the git root or `$HOME`):

- `http-client.env.json` and `http-client.private.env.json`:
  `{ "$shared": {...}, "dev": {...}, "prod": {...} }`
- `.env` (`KEY=value`)

Precedence: request vars > file vars > private env > public env > `$shared` > `.env`.
Pick the environment with `:Req env` (or `:Req env dev`).

## Commands

`:Req run | cancel | copy | from_curl | search | env [name] | close | jump_next | jump_prev`

Lua: `require("req").run()`, `.copy()`, `.from_curl()`, `.search()`,
`.set_env()`, `.close()`, `.jump_next()`, `.jump_prev()`, `.cancel()`.

Response window keys: `B` body, `H` headers, `I` request info (curl command,
timings), `F` jq filter (empty resets), `q` close.

## Setup (lazy.nvim)

```lua
{
  "EfrainTlapale/req.nvim",
  ft = "http",
  init = function()
    vim.filetype.add({ extension = { rest = "http" } })
  end,
  opts = {
    split = "vertical", -- or "horizontal"
    follow_redirects = false,
    insecure = false,
    timeout_seconds = nil,
    format_json = true,
    default_env = nil,
  },
  keys = {
    { "<CR>", function() require("req").run() end, ft = "http" },
    { "[r", function() require("req").jump_prev() end, ft = "http" },
    { "]r", function() require("req").jump_next() end, ft = "http" },
  },
}
```

## Tests

```sh
nvim -l tests/run.lua
```

Unit tests plus end-to-end requests against `tests/echo_server.py` (python3).
