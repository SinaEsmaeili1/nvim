-- Live check of the Claude Code-style layout with the real model (needs Bonsai running).
-- Types a message into the input box and checks the reply lands in the
-- transcript, and the status line went through to success.
--   NVIM_APPNAME=nvim-bonsai-ui nvim --headless -c "luafile tests/bonsai/live_ui.lua"
vim.defer_fn(function()
  print("LIVE FAIL: timed out")
  vim.cmd("cquit 2")
end, 200000)
local ui = require("bonsai.ui")
local seen = {}
for _, e in ipairs { "ChatSubmitted", "RequestStarted", "RequestStreaming", "ChatDone" } do
  vim.api.nvim_create_autocmd("User", {
    pattern = "CodeCompanion" .. e,
    callback = function()
      table.insert(seen, e)
    end,
  })
end
ui.open()
local w = ui.windows()
local status_buf = vim.api.nvim_win_get_buf(w.status)
local mid_status
vim.api.nvim_create_autocmd("User", {
  pattern = "CodeCompanionRequestStreaming",
  callback = function()
    vim.defer_fn(function()
      mid_status = vim.api.nvim_buf_get_lines(status_buf, 0, 1, false)[1]
    end, 300)
  end,
})
ui.submit("Reply with exactly one word: pong")
vim.wait(180000, function()
  return vim.tbl_contains(seen, "ChatDone")
end, 200)
vim.wait(500)
local transcript = table.concat(
  vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w.transcript), 0, -1, false),
  "\n"
)
local final_status = vim.api.nvim_buf_get_lines(status_buf, 0, 1, false)[1]
print("events: " .. table.concat(seen, " > "))
print("status while streaming: " .. tostring(mid_status))
print("status when done: " .. tostring(final_status))
print("transcript ends: " .. transcript:sub(-120):gsub("\n", " | "))
local ok = transcript:lower():find("pong", 1, true) and (final_status or ""):find("✓", 1, true)
print(ok and "LIVE OK: the layout chats with Bonsai and the status line follows it" or "LIVE FAIL")
vim.cmd(ok and "qall!" or "cquit 1")
