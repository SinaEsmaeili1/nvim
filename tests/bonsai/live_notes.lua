-- Live check of the Markdown notes with the real model (needs Bonsai running).
-- Uses a temporary rules folder. Gives Bonsai a rule and checks that the notes
-- index is in the chat, that Bonsai tries to save the rule with the memory
-- tool, and that nothing is written before the owner approves.
--   NVIM_APPNAME=nvim-bonsai-agent nvim --headless -c "luafile tests/bonsai/live_notes.lua"
local rules = vim.fn.tempname() .. "-rules"
vim.env.BONSAI_RULES = rules
vim.defer_fn(function()
  print("LIVE FAIL: timed out")
  vim.cmd("cquit 2")
end, 240000)

require("lazy").load { plugins = { "codecompanion.nvim" } }

local chat = require("codecompanion").chat()
chat:add_buf_message {
  role = "user",
  content = "New rule for you: when you write Lua, always use two spaces for indentation. Save it as a note.",
}
chat:submit()

-- Wait until the chat asks for approval, or the reply is done.
local function text()
  return table.concat(vim.api.nvim_buf_get_lines(chat.bufnr, 0, -1, false), "\n")
end
vim.wait(220000, function()
  local t = text()
  return t:find("memory", 1, true)
    and (t:lower():find("approv", 1, true) or t:find("%[y%]") or t:find("Allow", 1, true))
end, 500)

local t = text()
print(t:sub(-900))
local index_loaded = t:find("INDEX.md", 1, true) ~= nil
local asked = t:find("memory", 1, true) ~= nil
local notes_written = vim.fn.glob(rules .. "/*.md", false, true)
print(
  ("index in chat: %s | memory tool requested: %s | notes written before approval: %d (INDEX.md excluded: %s)"):format(
    tostring(index_loaded),
    tostring(asked),
    #notes_written - 1,
    vim.inspect(vim.tbl_map(vim.fs.basename, notes_written))
  )
)
local ok = index_loaded and asked and #notes_written == 1
print(
  ok and "LIVE OK: notes index loaded, rule save requested, nothing written without approval"
    or "LIVE FAIL"
)
vim.cmd(ok and "qall!" or "cquit 1")
