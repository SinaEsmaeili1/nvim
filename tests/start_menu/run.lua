-- Tests for the start menu: the Ask Bonsai entry and the random ASCII art
-- (contract: ~/Documents/projects/NEOVIM-AGENT.md, Addendum 6).
-- Run in the sandbox, which loads this config and its plugins:
--   NVIM_APPNAME=nvim-start-menu nvim --headless -c "luafile tests/start_menu/run.lua"
-- Prints one line per test and exits 1 if any test fails.

local results, failed = {}, 0

-- Never hang: give up after 60 s.
vim.defer_fn(function()
  print("TIMEOUT: tests did not finish")
  vim.cmd("cquit 2")
end, 60000)

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

local CONFIG = vim.fn.stdpath("config")

-- The menu as it was before this change (main and bonsai-agent at 0ab6723).
local BEFORE = "0ab6723"

local function git_show(spec)
  local out = vim.fn.system { "git", "-C", CONFIG, "show", spec }
  assert(vim.v.shell_error == 0, "git show " .. spec .. " failed")
  return out
end

-- Runs a version of the menu file with the dashboard plugin replaced by one
-- that keeps the settings it is given, and returns them.
local function settings_from(chunk)
  local real, got = package.loaded.dashboard, nil
  package.loaded.dashboard = {
    setup = function(opts)
      got = opts
    end,
  }
  local ok, err = pcall(chunk)
  package.loaded.dashboard = real
  assert(ok, err)
  return got.config
end

local function menu_config()
  return settings_from(function()
    dofile(CONFIG .. "/lua/config/dashboard-nvim.lua")
  end)
end

local function old_menu_config()
  return settings_from(assert(loadstring(git_show(BEFORE .. ":lua/config/dashboard-nvim.lua"))))
end

-- What a menu entry runs: its command, or which folders function it calls.
local function what_it_runs(action)
  if type(action) == "string" then
    return action
  end
  local real, ran = package.loaded.folders, nil
  package.loaded.folders = setmetatable({}, {
    __index = function(_, name)
      return function()
        ran = "folders." .. name
      end
    end,
  })
  local ok, err = pcall(action)
  package.loaded.folders = real
  assert(ok, err)
  return ran
end

local function art()
  return require("dashboard_art")
end

local function names(list)
  return vim.tbl_map(function(a)
    return a.name
  end, list)
end

local ALL = {
  "neovim",
  "cyberpunk",
  "mikasa",
  "chainsawman",
  "gojo",
  "oni",
  "katana",
  "inosuke",
  "lucy",
}

-- ---- M1: the entry ----

test("the menu starts with Ask Bonsai, picked with b", function()
  local first = menu_config().center[1]
  eq(vim.trim(first.desc), "Ask Bonsai", "first entry")
  eq(first.key, "b", "its key")
  eq(type(first.action), "function", "its action")
  truthy(first.icon and vim.trim(first.icon) ~= "", "it has an icon")
  eq(#first.desc, 40, "its text is padded like the others")
end)

test("the seven entries that were there keep their icons, text, keys, actions and order", function()
  local old, new = old_menu_config().center, menu_config().center
  eq(#old, 7, "entries before")
  eq(#new, 8, "entries now")
  for i, o in ipairs(old) do
    local n = new[i + 1]
    eq(
      { n.icon, n.desc, n.key, what_it_runs(n.action) },
      { o.icon, o.desc, o.key, what_it_runs(o.action) },
      "entry " .. i
    )
  end
end)

test("picking Ask Bonsai runs bonsai.ui's start", function()
  local ui = require("bonsai.ui")
  local orig, ran = ui.start, 0
  ui.start = function()
    ran = ran + 1
  end
  local ok, err = pcall(menu_config().center[1].action)
  ui.start = orig
  assert(ok, err)
  eq(ran, 1, "start calls")
end)

-- ---- M2, M3: what start does ----

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
vim.env.BONSAI_STATE = tmp

local function set_level_file(name)
  local f = assert(io.open(tmp .. "/effort", "w"))
  f:write(name .. "\n")
  f:close()
end

local ui = require("bonsai.ui")
-- A stand-in for codecompanion's chat, so the panel opens without the model.
ui.set_chat_factory(function(win)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(win, buf)
  return { bufnr = buf, add_buf_message = function() end, submit = function() end }
end)

-- Runs fn with `bonsai-serve status` answering status_line. Returns the
-- commands run, the level started (if any) and the messages shown.
local function with_server(status_line, fn)
  local effort = require("bonsai.effort")
  local orig_system, orig_set, orig_notify = vim.system, effort.set, vim.notify
  local log = { commands = {}, started = nil, notes = {} }
  vim.system = function(cmd, _, on_exit)
    table.insert(log.commands, table.concat(cmd, " "))
    local r = { code = 0, signal = 0, stdout = status_line .. "\n", stderr = "" }
    on_exit(r)
    return {
      wait = function()
        return r
      end,
    }
  end
  effort.set = function(name, done)
    log.started = name
    if done then
      done(true, "started")
    end
    return true
  end
  vim.notify = function(msg)
    table.insert(log.notes, msg)
  end
  local ok, err = pcall(fn)
  -- The server check answers on the event loop; let it finish.
  vim.wait(300, function()
    return log.started ~= nil
  end)
  vim.system, effort.set, vim.notify = orig_system, orig_set, orig_notify
  assert(ok, err)
  return log
end

local function close_panel()
  ui.close()
  vim.cmd("stopinsert")
end

test(
  "start opens the panel Ctrl+A opens, at the same size, with the cursor in its input box",
  function()
    with_server("Bonsai is up at effort medium on localhost:8089.", function()
      ui.start()
    end)
    truthy(ui.is_open(), "the panel is open")
    local w = ui.windows()
    local in_input = vim.api.nvim_get_current_win() == w.input
    local width = vim.api.nvim_win_get_width(w.transcript)
    close_panel()
    ui.toggle() -- what Ctrl+A runs
    local ctrl_a_width = vim.api.nvim_win_get_width(ui.windows().transcript)
    close_panel()
    truthy(in_input, "the cursor is in the input box")
    eq(width, ctrl_a_width, "width, as with Ctrl+A")
    truthy(width < vim.o.columns - 2, "not full screen (" .. width .. " columns)")
  end
)

test("when Bonsai is up, start starts nothing", function()
  local log = with_server("Bonsai is up at effort medium on localhost:8089.", function()
    ui.start()
  end)
  close_panel()
  eq(log.commands, { "bonsai-serve status" }, "commands run")
  eq(log.started, nil, "level started")
end)

test(
  "when Bonsai is down, start starts it at the saved level, with the bonsai-agent app's messages",
  function()
    set_level_file("high")
    local log = with_server("Bonsai is down (last effort: high).", function()
      ui.start()
    end)
    close_panel()
    eq(log.commands, { "bonsai-serve status" }, "commands run")
    eq(log.started, "high", "level started")
    eq(log.notes, { "Starting Bonsai at effort high…", "started" }, "messages")
  end
)

-- ---- R1, R2, R3: the arts ----

test("the nine arts, in the menu file's order, at their sizes", function()
  local got = vim.tbl_map(function(a)
    return { a.name, #a.lines, math.max(unpack(vim.tbl_map(vim.api.nvim_strwidth, a.lines))) }
  end, art().arts)
  eq(got, {
    { "neovim", 13, 55 },
    { "cyberpunk", 26, 142 },
    { "mikasa", 37, 60 },
    { "chainsawman", 30, 62 },
    { "gojo", 41, 65 },
    { "oni", 34, 120 },
    { "katana", 57, 200 },
    { "inosuke", 21, 65 },
    { "lucy", 31, 50 },
  }, "arts")
end)

test("each art's text is exactly what the menu file had", function()
  -- The arts as the old file had them: commented out tables, one table
  -- inside --[[ ]], and the one that was showing, a [[ ]] string split on newlines.
  local lines, old, i = vim.split(git_show(BEFORE .. ":lua/config/dashboard-nvim.lua"), "\n"), {}, 1
  while i <= #lines do
    if lines[i]:match("^%s*%-?%-?%s*conf%.header%s*=%s*{%s*$") then
      local a = {}
      i = i + 1
      while not lines[i]:match("^%s*%-?%-?%s*}%s*$") do
        local s = lines[i]:match('^%s*%-?%-?%s*"(.*)",?%s*$')
        if s then
          table.insert(a, s)
        end
        i = i + 1
      end
      table.insert(old, a)
    elseif lines[i]:match("^local braille_header = %[%[") then
      local a = {}
      i = i + 1
      while vim.trim(lines[i]) ~= "]]" do
        table.insert(a, lines[i])
        i = i + 1
      end
      table.insert(a, "") -- vim.split keeps the piece after the last newline
      table.insert(old, a)
    end
    i = i + 1
  end
  eq(#old, 9, "arts in the old file")
  for k, a in ipairs(art().arts) do
    eq(a.lines, old[k], a.name)
  end
end)

test("only arts that fit above the menu are candidates", function()
  local fitting = art().fitting
  eq(names(fitting(400, 100, 19)), ALL, "a big screen")
  eq(
    names(fitting(168, 86, 19)),
    { "neovim", "cyberpunk", "mikasa", "chainsawman", "gojo", "oni", "inosuke", "lucy" },
    "a half screen window"
  )
  eq(names(fitting(142, 45, 19)), { "neovim", "cyberpunk", "inosuke" }, "142 x 45")
  eq(names(fitting(141, 45, 19)), { "neovim", "inosuke" }, "one column less")
  eq(names(fitting(142, 44, 19)), { "neovim", "inosuke" }, "one row less")
  eq(names(fitting(80, 21, 19)), {}, "a small window")
end)

test("pick takes the art the random number points at, among those that fit", function()
  local asked
  local lines = art().pick(142, 45, 19, function(n)
    asked = n
    return 2
  end)
  eq(asked, 3, "choices")
  eq(lines, art().arts[2].lines, "the second that fits, cyberpunk")
  local called = false
  eq(
    art().pick(80, 21, 19, function()
      called = true
      return 1
    end),
    {},
    "nothing fits"
  )
  eq(called, false, "a random number was asked for with nothing to pick")
end)

test("separate starts pick different arts (Lua's math.random isn't seeded at start)", function()
  local seen = {}
  for _ = 1, 6 do
    local out = vim.fn.system {
      "nvim",
      "--clean",
      "--headless",
      "--cmd",
      "set rtp^=" .. CONFIG,
      "-c",
      "lua io.stdout:write(#require('dashboard_art').pick(400, 100, 19))",
      "-c",
      "qall!",
    }
    seen[vim.trim(out)] = true
  end
  truthy(
    vim.tbl_count(seen) > 1,
    "six starts all picked an art with " .. vim.inspect(seen) .. " rows"
  )
end)

test(
  "the menu asks for an art that fits the screen above its 8 entries and the startup time",
  function()
    local a = art()
    local orig, args = a.pick, nil
    a.pick = function(...)
      args = { ... }
      return {}
    end
    local cols, rows = vim.o.columns, vim.o.lines
    vim.o.columns, vim.o.lines = 168, 90
    local ok, err = pcall(menu_config)
    vim.o.columns, vim.o.lines = cols, rows
    a.pick = orig
    assert(ok, err)
    eq(args, { 168, 90 - vim.o.cmdheight - 2, 8 * 2 + 3 }, "pick's arguments")
  end
)

test("a small window shows the menu without an art", function()
  local cols, rows = vim.o.columns, vim.o.lines
  vim.o.columns, vim.o.lines = 80, 24
  local ok, header = pcall(function()
    return menu_config().header
  end)
  vim.o.columns, vim.o.lines = cols, rows
  assert(ok, header)
  eq(header, {}, "header")
end)

-- Last, since agent mode stays on for the rest of the session.
test("the bonsai-agent app still opens full screen and starts Bonsai when it's down", function()
  set_level_file("medium")
  local log = with_server("Bonsai is down (last effort: medium).", function()
    ui.agent_mode()
  end)
  local width = ui.is_open() and vim.api.nvim_win_get_width(ui.windows().transcript)
  close_panel()
  eq(width, vim.o.columns - 2, "transcript width")
  eq(log.started, "medium", "level started")
end)

for _, line in ipairs(results) do
  print(line)
end
print(("%d passed, %d failed"):format(#results - failed, failed))
vim.cmd(failed > 0 and "cquit 1" or "qall!")
