-- Bonsai's memory tool: codecompanion's, with every path checked on disk first.
-- The plugin compares paths as text, so a link inside memories/ or the rules
-- folder could lead outside them (owner, 2026-11-21: Bonsai "can't access a
-- higher working directory than it's launched from"). The tool's own checks
-- and approvals still apply. Contract: NEOVIM-AGENT.md, Addendum 8.
local memory = require("codecompanion.memory")
local sandbox = require("bonsai.sandbox")

-- The project's memories folder: in the real folder Neovim was opened in.
local function project_memories()
  return vim.fs.joinpath(sandbox.root(), memory.DIR)
end

-- Where the plugin will read and write /memories now, with links resolved.
local function current_memories()
  return sandbox.resolve(vim.fs.normalize(memory.get_root()))
end

-- The folders the tool may use, by the prefix Bonsai writes. Each allowed folder
-- is built from its parent's real path, so a folder that is a link counts as
-- outside. Longest prefix first, as the plugin matches them.
local function folders(whitelist)
  local list = {
    { prefix = memory.PREFIX, dir = memory.get_root(), allowed = project_memories() },
  }
  for _, entry in ipairs(whitelist or {}) do
    local usable = type(entry.path) == "string" and entry.path ~= ""
    if usable and type(entry.as) == "string" and entry.as ~= "" then
      local dir = vim.fs.normalize(entry.path)
      local parent = sandbox.resolve(vim.fs.dirname(dir))
      table.insert(list, {
        prefix = vim.startswith(entry.as, "/") and entry.as or ("/" .. entry.as),
        dir = dir,
        allowed = parent and vim.fs.joinpath(parent, vim.fs.basename(dir)),
      })
    end
  end
  table.sort(list, function(a, b)
    return #a.prefix > #b.prefix
  end)
  return list
end

-- Why a path is refused, or nil. It is mapped the way the plugin maps it, then
-- resolved one part at a time, and must stay inside its own folder.
local function refusal(path, whitelist)
  if type(path) ~= "string" then
    return nil -- the plugin reports a missing path itself
  end
  path = vim.trim(path)
  for _, folder in ipairs(folders(whitelist)) do
    local rest = vim.startswith(path, folder.prefix) and path:sub(#folder.prefix + 1)
    if rest and (rest == "" or vim.startswith(rest, "/")) then
      local mapped = vim.fs.normalize(vim.fs.joinpath(folder.dir, rest))
      local real = sandbox.resolve(mapped)
      if not real then
        return ("Refused: %s goes through a link that leads nowhere, so Bonsai can't use it."):format(
          path
        )
      end
      local allowed = folder.allowed
      if allowed and (real == allowed or vim.startswith(real, allowed .. "/")) then
        return nil
      end
      return ("Refused: %s leads outside %s, so Bonsai can't use it."):format(path, folder.prefix)
    end
  end
  return nil -- no known prefix: the plugin refuses it
end

-- The list of memories in Bonsai's prompt is read from <current folder>/memories.
-- When that isn't really the project's memories folder (it is a link, or Neovim
-- moved to another folder), the list stays empty, so no names from elsewhere get in.
local get_index = memory.get_index
memory.get_index = function()
  if current_memories() ~= project_memories() then
    return {}
  end
  return get_index()
end

local base = require("codecompanion.interactions.chat.tools.builtin.memory")
local tool = vim.tbl_extend("force", {}, base)
tool.cmds = {}
for i, run in ipairs(base.cmds) do
  tool.cmds[i] = function(self, args, opts)
    local whitelist = vim.tbl_get(self or {}, "tool", "opts", "whitelist")
    if type(args) == "table" then
      for _, name in ipairs { "path", "old_path", "new_path" } do
        local reason = refusal(args[name], whitelist)
        if reason then
          return opts.output_cb { status = "error", data = reason }
        end
      end
    end
    return run(self, args, opts)
  end
end
return tool
