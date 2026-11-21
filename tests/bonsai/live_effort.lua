-- Live check of /effort with the real model: needs Bonsai running at medium.
-- Picks "high" through the /effort command, waits for bonsai-serve to reload,
-- checks the level and that Bonsai answers with thinking on, then goes back to medium.
--   NVIM_APPNAME=nvim-bonsai-agent nvim --headless -c "luafile tests/bonsai/live_effort.lua"
vim.defer_fn(function()
  print("LIVE FAIL: timed out")
  vim.cmd("cquit 2")
end, 420000)

local effort = require("bonsai.effort")
local cc = require("config.codecompanion")

local function pick(level)
  local finished, ok_result = false, false
  local orig = vim.ui.select
  vim.ui.select = function(items, _, choose)
    for _, item in ipairs(items) do
      if item.name == level then
        return choose(item)
      end
    end
  end
  effort.pick(function(ok)
    finished, ok_result = true, ok
  end)
  vim.ui.select = orig
  vim.wait(300000, function()
    return finished
  end, 500)
  return ok_result
end

local function status()
  return vim.trim(vim.system({ "bonsai-serve", "status" }, { text = true }):wait().stdout)
end

print("before: " .. status())
local ok = pick("high")
print("after /effort high: " .. status() .. " (ok=" .. tostring(ok) .. ")")
local good = ok
  and effort.current().name == "high"
  and status():find("up at effort high", 1, true)
  and effort.thinking() == true

-- A request at high carries thinking on, and Bonsai answers.
local body = vim.json.encode {
  messages = { { role = "user", content = "Is 91 prime? One line." } },
  chat_template_kwargs = cc.handlers.form_parameters({}, {}, {}).chat_template_kwargs,
  max_tokens = 600,
}
-- Changed 2026-11-21: the server needs its key (Addendum 3). curl reads the header from a
-- file in Neovim's private temp folder, so the key is never on a command line.
local header_file = vim.fn.tempname()
vim.fn.writefile({ "Authorization: Bearer " .. cc.api_key() }, header_file)
local out = vim
  .system({
    "curl",
    "-s",
    "-m",
    "120",
    "http://127.0.0.1:8089/v1/chat/completions",
    "-H",
    "Content-Type: application/json",
    "-H",
    "@" .. header_file,
    "-d",
    body,
  }, { text = true })
  :wait().stdout
os.remove(header_file)
local msg = vim.json.decode(out).choices[1].message
print(
  ("reply: %s | thinking chars: %d"):format(
    vim.trim(msg.content or ""):sub(1, 80),
    #(msg.reasoning_content or "")
  )
)
good = good and #(msg.reasoning_content or "") > 0

local back = pick("medium")
print("after /effort medium: " .. status())
good = good and back and effort.current().name == "medium" and effort.thinking() == false

print(good and "LIVE OK: /effort changes the effort" or "LIVE FAIL")
vim.cmd(good and "qall!" or "cquit 1")
