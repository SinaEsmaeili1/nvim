-- Live check with the real model: needs Bonsai running (bonsai-serve <level>).
-- Opens a codecompanion chat, sends a message and waits for Bonsai's reply.
--   NVIM_APPNAME=nvim-bonsai-agent nvim --headless -c "luafile tests/bonsai/live.lua"
vim.defer_fn(function()
  print("LIVE FAIL: no reply within 3 minutes")
  vim.cmd("cquit 2")
end, 180000)

require("lazy").load({ plugins = { "codecompanion.nvim" } })

local done = false
vim.api.nvim_create_autocmd("User", {
  pattern = "CodeCompanionChatDone",
  callback = function() done = true end,
})

local chat = require("codecompanion").chat()
chat:add_buf_message({ role = "user", content = "Reply with exactly one word: pong" })
chat:submit()

vim.wait(175000, function() return done end, 200)

local text = table.concat(vim.api.nvim_buf_get_lines(chat.bufnr, 0, -1, false), "\n")
print(text:sub(-300))
-- Added 2026-11-21: Bonsai must not get the owner's Claude instructions.
if text:find(".claude/CLAUDE.md", 1, true) then
  print("LIVE FAIL: ~/.claude/CLAUDE.md was attached to the chat")
  vim.cmd("cquit 1")
end
if text:lower():find("pong", 1, true) then
  print("LIVE OK: Bonsai replied in the chat")
  vim.cmd("qall!")
else
  print("LIVE FAIL: no pong in the chat")
  vim.cmd("cquit 1")
end
