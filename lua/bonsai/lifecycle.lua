-- Bonsai runs only while Neovim is open (contract: ~/Documents/projects/NEOVIM-AGENT.md,
-- Addendum 9). Each Neovim with a UI writes a file named by its PID while it is open. The
-- last one to close stops bonsai-serve, unless a bonsai-web session runs. A start takes
-- one lock folder, so two Neovims don't start Bonsai at once (O2).
local M = {}

local LOCK_MAX_AGE = 300 -- seconds: an older start.lock is stale (O2)
local STOP_WAIT_MS = 10000 -- O5: the stop finishes before Neovim exits

-- Set by setup; a missing field means the real thing.
local opts = {}
-- O4a: only a Neovim that registered stops Bonsai when it closes.
local registered = false

local function state_dir()
  return opts.state_dir or (vim.fn.stdpath("state") .. "/bonsai")
end

local function open_dir()
  return state_dir() .. "/open"
end

local function open_file(name)
  return open_dir() .. "/" .. tostring(name)
end

local function pid()
  return opts.pid or vim.uv.os_getpid()
end

local function alive(p)
  if opts.alive then
    return opts.alive(p)
  end
  return vim.uv.kill(p, 0) == 0
end

local function run(cmd, run_opts)
  if opts.run then
    return opts.run(cmd, run_opts)
  end
  return vim.system(cmd, run_opts)
end

-- A bonsai-web session is its agent (bonsai-27b/web/agent.py) or its launcher. pgrep
-- exits 1 when none runs. When pgrep can't tell (an error or a timeout), a session is
-- assumed, so nothing is stopped.
local WEB_PATTERN = "bonsai-27b/web/agent\\.py|/bonsai-web( |$)"

local function web_running()
  if opts.web_running then
    return opts.web_running()
  end
  local ok, r = pcall(function()
    return vim.system({ "pgrep", "-f", WEB_PATTERN }, { text = true }):wait(3000)
  end)
  return not ok or r.code ~= 1
end

-- True in a Neovim with a UI (O1a, O6). Ui-less Neovims never start or stop Bonsai.
function M.has_ui()
  if opts.has_ui then
    return opts.has_ui()
  end
  return #vim.api.nvim_list_uis() > 0
end

-- Called once at startup, before the UI attaches (plugin_specs.lua, codecompanion's init),
-- so the UIEnter autocmd exists when it fires (O4a). Setup never registers by itself.
function M.setup(o)
  opts = o or {}
  registered = false
  local group = vim.api.nvim_create_augroup("BonsaiLifecycle", { clear = true })
  vim.api.nvim_create_autocmd("UIEnter", {
    group = group,
    callback = function()
      M.register()
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      M.on_leave()
    end,
  })
end

-- O4: a Neovim with a UI writes its PID file. Without a UI it writes nothing (O6).
function M.register()
  if not M.has_ui() then
    return
  end
  vim.fn.mkdir(open_dir(), "p")
  local f = io.open(open_file(pid()), "w")
  if not f then
    return
  end
  f:close()
  registered = true
end

-- O4: the PIDs of the Neovims still open. A file whose process is gone is removed.
function M.open_count()
  if not vim.uv.fs_stat(open_dir()) then
    return 0
  end
  local names = {}
  for name in vim.fs.dir(open_dir()) do
    table.insert(names, name)
  end
  local n = 0
  for _, name in ipairs(names) do
    local p = tonumber(name)
    if p then
      if alive(p) then
        n = n + 1
      else
        os.remove(open_file(name))
      end
    end
  end
  return n
end

-- O5: the last Neovim with a UI to close stops Bonsai, unless bonsai-web runs. It acts
-- only in a Neovim that registered (O4a), so a headless one never stops it (O6).
function M.on_leave()
  if not registered then
    return
  end
  registered = false
  os.remove(open_file(pid()))
  if M.open_count() > 0 or web_running() then
    return
  end
  -- Stopping a server that isn't running is fine.
  pcall(function()
    run({ "bonsai-serve", "stop" }, { text = true }):wait(STOP_WAIT_MS)
  end)
end

-- O2: the lock is a folder made by one mkdir. A lock younger than 300 s belongs to another
-- start (false). An older one is stale and is taken over.
function M.try_lock()
  vim.fn.mkdir(state_dir(), "p")
  local lock = state_dir() .. "/start.lock"
  if vim.uv.fs_mkdir(lock, 448) then
    return true
  end
  local st = vim.uv.fs_stat(lock)
  if not st or os.time() - st.mtime.sec < LOCK_MAX_AGE then
    return false
  end
  vim.uv.fs_rmdir(lock)
  return vim.uv.fs_mkdir(lock, 448) == true
end

-- Only after a successful try_lock.
function M.unlock()
  vim.uv.fs_rmdir(state_dir() .. "/start.lock")
end

return M
