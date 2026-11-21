-- Tests for :Live / :live (contract: ~/Documents/projects/NEOVIM-AGENT.md, Addendum 5).
--   NVIM_APPNAME=nvim-live nvim --headless -c "luafile tests/live/run.lua"
-- One line per test; exits 1 on failure. Never opens a browser (no_browser test option).

local results, failed = {}, 0

vim.defer_fn(function()
  print("TIMEOUT: tests did not finish")
  vim.cmd("cquit 2")
end, 90000)

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    table.insert(results, "ok   " .. name)
  else
    failed = failed + 1
    table.insert(results, "FAIL " .. name .. "\n     " .. tostring(err))
  end
end

local function eq(a, b, what)
  if not vim.deep_equal(a, b) then
    error(("%s: expected %s, got %s"):format(what or "value", vim.inspect(b), vim.inspect(a)), 2)
  end
end
local function truthy(v, what)
  if not v then
    error((what or "value") .. " is not true", 2)
  end
end

local function has(list, item)
  for _, v in ipairs(list) do
    if v == item then
      return true
    end
  end
  return false
end

local function http_get(port)
  local r = vim
    .system({
      "curl",
      "-s",
      "-m",
      "3",
      "-o",
      "-",
      "-w",
      "\n%{http_code}",
      "http://127.0.0.1:" .. port .. "/",
    })
    :wait()
  local body, code = r.stdout:match("^(.*)\n(%d+)$")
  return tonumber(code), body or ""
end

local function listening(port)
  local out = vim.system({ "ss", "-ltnH" }):wait().stdout
  for line in out:gmatch("[^\n]+") do
    if line:find("[:%.]" .. port .. "%s") then
      return true
    end
  end
  return false
end

local function mkdir_with(files)
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, "p")
  for name, text in pairs(files) do
    vim.fn.writefile({ text }, d .. "/" .. name)
  end
  return d
end

local function children()
  local out =
    vim.system({ "pgrep", "-P", tostring(vim.fn.getpid()), "-f", "live-server" }):wait().stdout
  local n = 0
  for _ in out:gmatch("%d+") do
    n = n + 1
  end
  return n
end

local L = require("live_server")
L.opts.no_browser = true
L.opts.sync_install = true

local msgs = {}
local orig_notify = vim.notify
vim.notify = function(m)
  table.insert(msgs, m)
end

local page = "<html><body><h1>hi</h1></body></html>"

-- ---- command and abbreviation ----

test(":Live exists", function()
  eq(vim.fn.exists(":Live"), 2, ":Live")
end)

local function typed(keys)
  vim.g.cl_seen = nil
  local k = vim.api.nvim_replace_termcodes(
    ":" .. keys .. [[<C-\>e(execute('let g:cl_seen = getcmdline()') . 'let g:cl_done = 1')<CR>]],
    true,
    false,
    true
  )
  vim.api.nvim_feedkeys(k, "x", false)
  return vim.g.cl_seen
end

test("abbreviation: bare live becomes Live", function()
  eq(typed("live "), "Live ", "cmdline")
end)
test('abbreviation: not inside echo "live"', function()
  eq(typed('echo "live" '), 'echo "live" ', "cmdline")
end)
test("abbreviation: not for lived", function()
  eq(typed("lived "), "lived ", "cmdline")
end)
test("abbreviation: not with arguments (live x)", function()
  eq(typed("echo live "), "echo live ", "cmdline")
end)

-- ---- pure functions ----

test("plan: html file opens that file", function()
  local p = L.plan("/tmp/site/about.html", "/elsewhere")
  eq(p.root, "/tmp/site", "root")
  eq(p.open, "about.html", "open")
end)
test("plan: js file opens index.html when present", function()
  local d = mkdir_with { ["index.html"] = page, ["a.js"] = "1" }
  local p = L.plan(d .. "/a.js", "/elsewhere")
  eq(p.root, d, "root")
  eq(p.open, "index.html", "open")
end)
test("plan: js file without index.html opens the folder", function()
  local d = mkdir_with { ["a.js"] = "1" }
  local p = L.plan(d .. "/a.js", "/elsewhere")
  eq(p.root, d, "root")
  eq(p.open, nil, "open")
end)
test("plan: no file uses cwd", function()
  local d = mkdir_with { ["index.html"] = page }
  local p = L.plan("", d)
  eq(p.root, d, "root")
end)
test("argv: host 127.0.0.1, port 5500, folder, --open", function()
  local a = L.argv { root = "/tmp/site", port = 5500, open = "about.html" }
  truthy(a[1]:find("node_modules/.bin/live-server", 1, true), "binary " .. a[1])
  truthy(has(a, "--host=127.0.0.1"), "--host")
  truthy(has(a, "--port=5500"), "--port")
  truthy(has(a, "--open=about.html"), "--open")
  eq(a[#a], "/tmp/site", "folder last")
  truthy(not has(a, "--no-browser"), "no --no-browser by default")
end)
test("argv: no open => browser opens folder root; no_browser adds flag", function()
  local a = L.argv { root = "/tmp/site", port = 5500, no_browser = true }
  truthy(has(a, "--no-browser"), "--no-browser")
  for _, v in ipairs(a) do
    truthy(not v:find("^%-%-open"), "no --open")
  end
end)
test("data folder is stdpath(data)/live-server", function()
  eq(L.dir(), vim.fn.stdpath("data") .. "/live-server", "dir")
end)

-- ---- real server ----

test("install live-server@1.2.2 into the data folder", function()
  local ok, err = L.ensure_installed()
  truthy(ok, tostring(err))
  truthy(vim.fn.executable(L.dir() .. "/node_modules/.bin/live-server") == 1, "binary")
  local pkg = vim.json.decode(
    table.concat(vim.fn.readfile(L.dir() .. "/node_modules/live-server/package.json"), "\n")
  )
  eq(pkg.version, "1.2.2", "version")
end)

local dirA = mkdir_with { ["index.html"] = page, ["a.js"] = "1", ["s.css"] = "h1{}" }
local dirB = mkdir_with { ["index.html"] = "<html><body>B</body></html>" }

local function wait_http(port)
  vim.wait(8000, function()
    return (http_get(port)) == 200
  end, 200)
end

test("start serves 200 with injected reload script on 127.0.0.1", function()
  local before = vim.fn.glob(dirA .. "/*", false, true)
  L.toggle { file = dirA .. "/index.html", cwd = dirA }
  local st = L.state()
  truthy(st, "state")
  eq(st.port, 5500, "port")
  wait_http(st.port)
  local code, body = http_get(st.port)
  eq(code, 200, "http code")
  truthy(
    body:find("live-server", 1, true) or body:find("WebSocket", 1, true),
    "reload script injected"
  )
  truthy(table.concat(msgs, "\n"):find("localhost:5500", 1, true), "message has localhost:5500")
  eq(vim.fn.glob(dirA .. "/*", false, true), before, "served folder untouched")
end)

test("listens only on 127.0.0.1", function()
  local st = L.state()
  local out = vim.system({ "ss", "-ltnHp" }):wait().stdout
  local found = false
  for line in out:gmatch("[^\n]+") do
    if line:find("pid=" .. st.pid .. ",", 1, true) then
      found = true
      local local_addr = line:match("^%S+%s+%S+%s+%S+%s+(%S+)") -- Local Address:Port column only
      eq(local_addr, "127.0.0.1:" .. st.port, "local address")
    end
  end
  truthy(found, "no listener found for pid " .. st.pid)
end)

test(":Live again stops it", function()
  local port = L.state().port
  L.toggle { file = dirA .. "/index.html", cwd = dirA }
  eq(L.state(), nil, "state")
  vim.wait(3000, function()
    return not listening(port)
  end, 100)
  truthy(not listening(port), "port closed")
  vim.wait(2000, function()
    return children() == 0
  end, 100)
  eq(children(), 0, "live-server processes")
end)

test("starting in folder B stops A first; only one runs", function()
  L.toggle { file = dirA .. "/index.html", cwd = dirA }
  local pa = L.state().port
  wait_http(pa)
  L.start { file = dirB .. "/index.html", cwd = dirB }
  local st = L.state()
  eq(st.root, dirB, "root")
  truthy(st.port == 5500, "reuses 5500 once A is stopped, got " .. st.port)
  wait_http(st.port)
  local _, body = http_get(st.port)
  truthy(body:find("B", 1, true), "serves B")
  eq(children(), 1, "one process")
end)

-- Added 2026-11-21 (lead's review): :live from another folder moves the server there.
test(":live from another folder moves the server there", function()
  L.toggle { file = dirA .. "/index.html", cwd = dirA }
  local st = L.state()
  truthy(st and st.root == dirA, "now serving A, got " .. vim.inspect(st))
  wait_http(st.port)
  eq(children(), 1, "one process")
end)

-- Added 2026-11-21 (lead's review): a server that dies by itself is reported and forgotten.
test("a server that stops by itself says so", function()
  msgs = {}
  vim.uv.kill(L.state().pid, 15)
  vim.wait(3000, function()
    return L.state() == nil
  end, 100)
  eq(L.state(), nil, "state cleared")
  truthy(
    table.concat(msgs, "\n"):find("stopped by itself", 1, true),
    "message: " .. table.concat(msgs, "|")
  )
end)

test("falls back to a free port when 5500 is taken", function()
  L.stop()
  vim.wait(2000, function()
    return not listening(5500)
  end, 100)
  local srv = vim.uv.new_tcp()
  srv:bind("127.0.0.1", 5500)
  srv:listen(1, function() end)
  L.start { file = dirA .. "/index.html", cwd = dirA }
  local st = L.state()
  truthy(st.port ~= 5500 and st.port > 0, "port " .. tostring(st.port))
  wait_http(st.port)
  eq((http_get(st.port)), 200, "http")
  L.stop()
  srv:close()
end)

test("real :Live command from a buffer (js file -> index.html)", function()
  vim.cmd("edit " .. vim.fn.fnameescape(dirA .. "/a.js"))
  vim.cmd("Live")
  local st = L.state()
  truthy(st, "state")
  eq(st.root, dirA, "root")
  vim.cmd("Live")
  eq(L.state(), nil, "stopped")
end)

test("VimLeavePre stops it", function()
  L.start { file = dirA .. "/index.html", cwd = dirA }
  local port = L.state().port
  wait_http(port)
  vim.api.nvim_exec_autocmds("VimLeavePre", {})
  eq(L.state(), nil, "state")
  vim.wait(3000, function()
    return not listening(port)
  end, 100)
  truthy(not listening(port), "port closed")
  eq(children(), 0, "processes")
end)

test("without npm: clear message, nothing starts", function()
  local orig = vim.fn.executable
  vim.fn.executable = function(x)
    if x == "npm" then
      return 0
    end
    return orig(x)
  end
  msgs = {}
  L.start { file = dirA .. "/index.html", cwd = dirA }
  vim.fn.executable = orig
  eq(L.state(), nil, "state")
  truthy(
    table.concat(msgs, "\n"):lower():find("npm", 1, true),
    "message mentions npm: " .. table.concat(msgs, "|")
  )
  eq(children(), 0, "processes")
end)

L.stop()
vim.notify = orig_notify
for _, line in ipairs(results) do
  print(line)
end
print(("%d passed, %d failed"):format(#results - failed, failed))
vim.cmd(failed > 0 and "cquit 1" or "qall!")
