-- Bonsai's notes: Markdown-driven rather than context-driven (owner,
-- 2026-11-21: global rules, "as less context dependent as possible").
-- One global folder of short .md notes. Only INDEX.md is loaded into each
-- chat; Bonsai reads a note when its index line applies, and writes notes
-- with the memory tool (each write asks the owner first).
local M = {}

function M.rules_dir()
  return vim.env.BONSAI_RULES or (vim.env.HOME .. "/.config/bonsai/rules")
end

-- Written once, if INDEX.md is missing. Never overwrites it.
M.INDEX = {
  "# Bonsai's notes (index)",
  "",
  "How to use this folder, which is /rules in the memory tool:",
  '- When the owner gives you a rule or a preference, save it right away with the memory tool: one short file, /rules/<short-name>.md, holding the rule and a "Why:" line. Then add one line below: `- [Title](short-name.md): when it applies`. Each write waits for the owner\'s OK.',
  "- Before a task, read only the notes whose lines below apply.",
  "- Keep notes short and current. Update a note instead of adding a new one. Prefer notes to long chats: what matters goes in a note, not in the conversation.",
  "",
  "## Notes",
  "",
}

function M.ensure_index()
  local dir = M.rules_dir()
  local index = dir .. "/INDEX.md"
  if vim.uv.fs_stat(index) then
    return
  end
  vim.fn.mkdir(dir, "p")
  vim.fn.writefile(M.INDEX, index)
end

return M
