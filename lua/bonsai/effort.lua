-- Bonsai's effort levels (contract: ~/Documents/projects/NEOVIM-AGENT.md).
-- More effort means more context; at high and max Bonsai also thinks before
-- answering. The context is set when the model loads (bonsai-serve), while
-- thinking is sent with every request, so only a context change reloads.
local M = {}

-- Measured on the RTX 3060 (12 GB), 2026-11-21, with a forced 128-token answer.
M.LEVELS = {
  { name = "low", ctx = 16384, thinking = false, about = "16K context, fast (~34 tok/s)" },
  { name = "medium", ctx = 32768, thinking = false, about = "32K context, fast (~34 tok/s)" },
  { name = "high", ctx = 65536, thinking = true, about = "64K context, thinks first (~34 tok/s)" },
  { name = "max", ctx = 184320, thinking = true, about = "180K context, thinks first (slower if the GPU is full)" },
}

local DEFAULT = "medium"

local function find(name)
  for _, level in ipairs(M.LEVELS) do
    if level.name == name then return level end
  end
end

-- bonsai-serve saves the level it last started.
function M.state_file()
  local dir = vim.env.BONSAI_STATE or (vim.env.HOME .. "/.config/bonsai")
  return dir .. "/effort"
end

function M.current()
  local f = io.open(M.state_file(), "r")
  local name = f and vim.trim(f:read("*a") or "") or ""
  if f then f:close() end
  return find(name) or find(DEFAULT)
end

function M.thinking()
  return M.current().thinking
end

-- Starts Bonsai at a level. `done(ok, output)` is called when bonsai-serve
-- finishes. `run` is vim.system unless a test passes its own. Returns false,
-- and runs nothing, for an unknown level.
function M.set(name, done, run)
  if not find(name) then return false end
  run = run or vim.system
  run({ "bonsai-serve", name }, { text = true }, function(result)
    local output = vim.trim((result.stdout or "") .. "\n" .. (result.stderr or ""))
    vim.schedule(function() done(result.code == 0, output) end)
  end)
  return true
end

-- The /effort picker: shows each level with what it costs, then switches.
function M.pick(on_switched)
  local current = M.current().name
  vim.ui.select(M.LEVELS, {
    prompt = "Bonsai effort (now: " .. current .. ")",
    format_item = function(level)
      return ("%s%s  %s"):format(level.name, level.name == current and " (current)" or "", level.about)
    end,
  }, function(level)
    if not level or level.name == current then return end
    vim.notify("Bonsai: loading effort " .. level.name .. "...", vim.log.levels.INFO)
    M.set(level.name, function(ok, output)
      vim.notify(output ~= "" and output or ("Bonsai: effort " .. level.name),
        ok and vim.log.levels.INFO or vim.log.levels.ERROR)
      if on_switched then on_switched(ok, level) end
    end)
  end)
end

return M
