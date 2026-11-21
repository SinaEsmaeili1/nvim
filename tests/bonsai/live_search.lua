-- Live check of web search (needs SearXNG on 127.0.0.1:8888 and Bonsai running).
-- 1) The adapter reads a real SearXNG answer. 2) Asked to search, Bonsai stops
-- at "Approval Required" for web_search: no search runs without the owner's yes.
--   NVIM_APPNAME=nvim-bonsai-agent nvim --headless -c "luafile tests/bonsai/live_search.lua"
vim.defer_fn(function() print("LIVE FAIL: timed out"); vim.cmd("cquit 2") end, 240000)

local sx = require("bonsai.searxng")
local r = vim.system({ "curl", "-s", "-m", "30", "-w", "\n%{http_code}",
  "http://127.0.0.1:8888/search?q=" .. vim.uri_encode("neovim codecompanion") .. "&format=json" }, { text = true }):wait()
local body, code = r.stdout:match("^(.*)\n(%d+)$")
local out = sx.methods.tools.web_search.callback(sx, { status = tonumber(code), body = body })
print(("adapter: %s, %d results; first: %s"):format(out.status, type(out.content) == "table" and #out.content or 0,
  type(out.content) == "table" and out.content[1].url or tostring(out.content)))
local adapter_ok = out.status == "success" and #out.content > 0

require("lazy").load({ plugins = { "codecompanion.nvim" } })
local chat = require("codecompanion").chat()
chat:add_buf_message({ role = "user", content = "@{web_search} Search the web: what is the latest stable Neovim release?" })
chat:submit()
local function text() return table.concat(vim.api.nvim_buf_get_lines(chat.bufnr, 0, -1, false), "\n") end
vim.wait(220000, function() return text():find("Approval Required", 1, true) end, 500)
local t = text()
print(t:sub(-500))
local asked = t:find("Approval Required", 1, true) and t:lower():find("web", 1, true)
local ok = adapter_ok and asked
print(ok and "LIVE OK: real SearXNG results, and Bonsai waits for approval before searching" or "LIVE FAIL")
vim.cmd(ok and "qall!" or "cquit 1")
