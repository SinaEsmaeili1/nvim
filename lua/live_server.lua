-- :Live, a live server for the current HTML/JS/CSS folder (like VS Code's Live Server).
-- Contract: ~/Documents/projects/NEOVIM-AGENT.md, Addendum 5.
-- Server: npm live-server@1.2.2, installed once into stdpath("data")/live-server.
local M = {}

M.opts = {
  no_browser = false, -- tests set this so no browser ever opens
  sync_install = false, -- tests set this; normally the install runs asynchronously
  port = 5500,
}

local HOST = "127.0.0.1"
local VERSION = "1.2.2"
local current = nil -- { job, pid, root, port }
local installing = false

local function notify(msg, level)
  vim.notify("live: " .. msg, level or vim.log.levels.INFO)
end

function M.dir()
  return vim.fn.stdpath("data") .. "/live-server"
end

function M.bin()
  return M.dir() .. "/node_modules/.bin/live-server"
end

-- Which folder to serve and what to open; pure apart from the index.html check.
function M.plan(file, cwd)
  if file and file ~= "" then
    local root = vim.fn.fnamemodify(file, ":h")
    local name = vim.fn.fnamemodify(file, ":t")
    local ext = name:match("%.([^.]+)$")
    ext = ext and ext:lower() or ""
    if ext == "html" or ext == "htm" then
      return { root = root, open = name }
    end
    if vim.uv.fs_stat(root .. "/index.html") then
      return { root = root, open = "index.html" }
    end
    return { root = root }
  end
  return { root = cwd }
end

-- argv of the server: always bound to 127.0.0.1.
function M.argv(o)
  local a = { M.bin(), "--host=" .. HOST, "--port=" .. o.port }
  if o.no_browser then
    table.insert(a, "--no-browser")
  elseif o.open then
    table.insert(a, "--open=" .. o.open)
  end
  table.insert(a, o.root)
  return a
end

-- 5500 if free, else a free port chosen by the OS. Both checked on 127.0.0.1.
local function pick_port(preferred)
  local function try(p)
    local t = vim.uv.new_tcp()
    local ok = t:bind(HOST, p) and t:listen(1, function() end)
    local port = ok and t:getsockname().port or nil
    t:close()
    return port
  end
  return try(preferred) or try(0)
end

local function have_node()
  return vim.fn.executable("node") == 1 and vim.fn.executable("npm") == 1
end

local function install_cmd()
  return { "npm", "install", "--prefix", M.dir(), "live-server@" .. VERSION, "--no-audit", "--no-fund" }
end

function M.installed()
  return vim.fn.executable(M.bin()) == 1
end

-- Synchronous install; returns ok, err.
function M.ensure_installed()
  if M.installed() then return true end
  if not have_node() then return false, "node and npm are required" end
  vim.fn.mkdir(M.dir(), "p")
  local r = vim.system(install_cmd(), { text = true, cwd = M.dir() }):wait(180000)
  if r.code ~= 0 or not M.installed() then
    return false, "npm install failed: " .. (r.stderr or "")
  end
  return true
end

function M.state()
  if not current then return nil end
  return { pid = current.pid, root = current.root, port = current.port }
end

function M.stop()
  if not current then return false end
  local job = current
  current = nil
  pcall(function() job.job:kill(15) end)
  pcall(function() job.job:wait(1500) end)
  return true
end

local function launch(o)
  local file = o.file
  if file == nil then file = vim.api.nvim_buf_get_name(0) end
  local plan = M.plan(file, o.cwd or vim.fn.getcwd())
  local port = pick_port(M.opts.port)
  if not port then return notify("no free port on " .. HOST, vim.log.levels.ERROR) end
  local argv = M.argv({ root = plan.root, port = port, open = plan.open, no_browser = M.opts.no_browser })
  -- `job` is declared first: inside `local ok, job = pcall(...)` the callback would see a global
  -- `job`, so a server that died by itself was never noticed (lead's review, 2026-11-21).
  local job
  local ok, err = pcall(function()
    job = vim.system(argv, { cwd = plan.root, text = true }, function(result)
      vim.schedule(function()
        if current and current.job == job then
          current = nil
          local why = vim.trim(result.stderr or "")
          notify("the server stopped by itself" .. (why ~= "" and (": " .. why:sub(1, 200)) or ""), vim.log.levels.WARN)
        end
      end)
    end)
  end)
  if not ok then return notify("could not start live-server: " .. tostring(err), vim.log.levels.ERROR) end
  current = { job = job, pid = job.pid, root = plan.root, port = port }
  notify(("serving %s at localhost:%d (:live again to stop)"):format(plan.root, port))
end

function M.start(o)
  o = o or {}
  M.stop() -- only one server at a time
  if not have_node() then
    return notify("node and npm are required for :live, but were not found", vim.log.levels.ERROR)
  end
  if M.installed() then return launch(o) end
  if M.opts.sync_install then
    local ok, err = M.ensure_installed()
    if not ok then return notify(err, vim.log.levels.ERROR) end
    return launch(o)
  end
  if installing then return notify("live-server is still installing, try again shortly") end
  installing = true
  vim.fn.mkdir(M.dir(), "p")
  notify("installing live-server@" .. VERSION .. " into " .. M.dir() .. " (first use)")
  vim.system(install_cmd(), { text = true, cwd = M.dir() }, function(r)
    vim.schedule(function()
      installing = false
      if r.code ~= 0 or not M.installed() then
        return notify("npm install failed: " .. (r.stderr or ""), vim.log.levels.ERROR)
      end
      launch(o)
    end)
  end)
end

-- Same folder: stop. Another folder: move the server there.
function M.toggle(o)
  o = o or {}
  local file = o.file
  if file == nil then file = vim.api.nvim_buf_get_name(0) end
  if current and current.root == M.plan(file, o.cwd or vim.fn.getcwd()).root then
    M.stop()
    return notify("stopped")
  end
  M.start(o)
end

function M.setup()
  vim.api.nvim_create_user_command("Live", function() M.toggle() end, {
    nargs = 0,
    desc = "Start or stop a live server for the current folder",
  })
  -- Neovim commands start with a capital: typing a bare "live" at ":" means "Live".
  vim.cmd([[cnoreabbrev <expr> live (getcmdtype() ==# ':' && getcmdline() ==# 'live') ? 'Live' : 'live']])
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("LiveServer", { clear = true }),
    callback = function() M.stop() end,
  })
end

return M
