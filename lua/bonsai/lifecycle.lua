-- Bonsai runs only while Neovim is open (contract: ~/Documents/projects/NEOVIM-AGENT.md,
-- Addendum 9). Each Neovim with a UI writes a file named by its PID while it is open. The
-- last one to close stops bonsai-serve, unless a bonsai-web session runs. A start takes
-- one lock folder, so two Neovims don't start Bonsai at once (O2).
local M = {}

local LOCK_MAX_AGE = 300 -- seconds: an older start.lock is stale (O2)
local STOP_WAIT_MS = 10000 -- O5: the stop finishes before Neovim exits
local AGENT = "bonsai-27b/web/agent.py" -- the bonsai-web agent (O5a)

-- Set by setup; a missing field means the real thing.
local opts = {}
-- O4a: only a Neovim that registered stops Bonsai when it closes.
local registered = false
-- O4b: the "can't track this Neovim" notice shows once.
local warned = false

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

local function ends_with(text, suffix)
  return text:sub(-#suffix) == suffix
end

-- The argv of a process, from its cmdline (NUL-separated). nil when it can't be read.
local function read_argv(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local text = f:read("*a") or ""
  f:close()
  local argv = vim.split(text, "\0", { plain = true })
  if argv[#argv] == "" then
    table.remove(argv)
  end
  return argv
end

-- O5a: the three shapes of a bonsai-web session: an sh or bash whose first argument ends
-- in "/bonsai-web"; uv run with an argument that ends in the agent; a python whose first
-- argument ends in the agent.
local function is_web_session(argv)
  local exe = (argv[1] or ""):match("([^/]*)$")
  local first = argv[2] or ""
  if (exe == "sh" or exe == "bash") and ends_with(first, "/bonsai-web") then
    return true
  end
  if exe == "uv" and first == "run" then
    for i = 3, #argv do
      if ends_with(argv[i], AGENT) then
        return true
      end
    end
  end
  return exe:find("^python") ~= nil and ends_with(first, AGENT)
end

-- O5a: true while a bonsai-web session runs, other than this Neovim and its parent (the
-- TUI). opts.web_running overrides the check. If the proc folder can't be read, a session
-- is assumed, so nothing is stopped.
function M.web_running()
  if opts.web_running then
    return opts.web_running()
  end
  local root = opts.proc_root or "/proc"
  local handle = vim.uv.fs_scandir(root)
  if not handle then
    return true
  end
  local me, parent = pid(), opts.ppid or vim.uv.os_getppid()
  while true do
    local name = vim.uv.fs_scandir_next(handle)
    if not name then
      break
    end
    local p = tonumber(name)
    if p and p ~= me and p ~= parent then
      local argv = read_argv(root .. "/" .. name .. "/cmdline")
      if argv and is_web_session(argv) then
        return true
      end
    end
  end
  return false
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
  warned = false
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

-- O4b: says once that this Neovim can't be tracked, so it won't stop Bonsai on close.
local function warn_unwritable()
  if warned then
    return
  end
  warned = true
  local text =
    "Bonsai can't track this Neovim (%s isn't writable), so it won't stop Bonsai on close"
  vim.notify(text:format(open_dir()), vim.log.levels.WARN, { title = "Bonsai" })
end

-- O4: a Neovim with a UI writes its PID file. Without a UI it writes nothing (O6). A folder
-- that can't be written is reported, never raised (O4b).
function M.register()
  if not M.has_ui() then
    return
  end
  local made = pcall(vim.fn.mkdir, open_dir(), "p")
  local f = made and io.open(open_file(pid()), "w")
  if not f then
    return warn_unwritable()
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
  if M.open_count() > 0 or M.web_running() then
    return
  end
  -- Stopping a server that isn't running is fine.
  pcall(function()
    run({ "bonsai-serve", "stop" }, { text = true }):wait(STOP_WAIT_MS)
  end)
end

-- O2a: the lock folder holds a "pid" file with the starter's PID.
local function read_pid(lock)
  local f = io.open(lock .. "/pid", "r")
  if not f then
    return nil
  end
  local text = f:read("*a") or ""
  f:close()
  return tonumber(vim.trim(text))
end

local function write_pid(lock)
  local f = io.open(lock .. "/pid", "w")
  if f then
    f:write(pid() .. "\n")
    f:close()
  end
  return true
end

-- O2: the lock is a folder made by one mkdir. A lock whose PID is dead is stale at once
-- (O2a). Any other lock younger than 300 s belongs to another start. Returns true when
-- this Neovim holds the lock. Otherwise false, and true as the second value when a live
-- other Neovim holds it.
function M.try_lock()
  vim.fn.mkdir(state_dir(), "p")
  local lock = state_dir() .. "/start.lock"
  if vim.uv.fs_mkdir(lock, 448) then
    return write_pid(lock)
  end
  local st = vim.uv.fs_stat(lock)
  if not st then
    return false, false
  end
  local holder = read_pid(lock)
  local holder_alive = holder ~= nil and alive(holder)
  local dead = holder ~= nil and not holder_alive
  if not dead and os.time() - st.mtime.sec < LOCK_MAX_AGE then
    return false, holder_alive
  end
  -- Stale: take it over.
  os.remove(lock .. "/pid")
  vim.uv.fs_rmdir(lock)
  if vim.uv.fs_mkdir(lock, 448) then
    return write_pid(lock)
  end
  return false, false
end

-- Only after a successful try_lock.
function M.unlock()
  local lock = state_dir() .. "/start.lock"
  os.remove(lock .. "/pid")
  vim.uv.fs_rmdir(lock)
end

return M
