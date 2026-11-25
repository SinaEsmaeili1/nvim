-- Tests for Bonsai on demand (contract: ~/Documents/projects/NEOVIM-AGENT.md, Addendum 9,
-- O1-O6, with the amendment "Addendum 9, after the RED review": O1a and O4a).
-- Run in an isolated Neovim, never the owner's config or server:
--   timeout 120 env XDG_DATA_HOME=$SCR/xdg-data XDG_STATE_HOME=$SCR/xdg-state \
--     XDG_CACHE_HOME=$SCR/xdg-cache NVIM_APPNAME=nvim-bonsai-ondemand \
--     nvim --headless -c "luafile tests/bonsai/ondemand.lua"
-- Prints one line per test and exits 1 if any test fails.
--
-- Nothing here starts or stops the real Bonsai server. vim.system is replaced before any
-- module is required. It records every command, answers status and stop from a fake
-- server state, and never executes anything. vim.fn.system and vim.fn.jobstart are
-- replaced too and record what they are given.
--
-- Interface the tests are written against (lua/bonsai/lifecycle.lua is new):
--   lifecycle.setup(opts)  always adds the UIEnter (-> register) and VimLeavePre
--                          (-> on_leave) autocmds, and no VimEnter one. They live in the
--                          augroup "BonsaiLifecycle" (created with clear = true by setup).
--                          The tests fire and inspect only that group:
--                          nvim_exec_autocmds(event, { group = "BonsaiLifecycle" }) and
--                          nvim_get_autocmds({ group = "BonsaiLifecycle" }).
--     opts.state_dir    folder for open/<pid> and start.lock
--                       (default stdpath("state") .. "/bonsai")
--     opts.run          runs a command like vim.system(cmd, opts, on_exit). The fake also
--                       returns an object with :wait(timeout) and the result fields.
--     opts.has_ui       function() -> boolean (default #nvim_list_uis() > 0)
--     opts.pid          this Neovim's PID (default vim.uv.os_getpid())
--     opts.alive        function(pid) -> boolean (default vim.uv.kill(pid, 0) == 0)
--     opts.web_running  function() -> boolean, true while a bonsai-web session runs
--   lifecycle.has_ui()      the has_ui from setup opts. ui/init.lua asks it before it
--                           starts Bonsai when the panel opens (O1a).
--   lifecycle.register()    writes <state_dir>/open/<pid>. No-op without a UI. Runs on UIEnter.
--   lifecycle.on_leave()    acts only in a Neovim that registered (O4a). Then it removes
--                           its own file and, if no other open PID is alive and
--                           web_running() is false, runs {"bonsai-serve", "stop"} and
--                           waits at most 10 s.
--   lifecycle.open_count()  the live open PIDs; stale files are removed.
--   lifecycle.try_lock() / lifecycle.unlock()
--                           <state_dir>/start.lock: one mkdir. A lock younger than 300 s
--                           is held by another start; an older one is stale.
-- bonsai.ui is reached through its public functions: M.start() (Ask Bonsai, always starts),
-- M.open(), M.toggle() (Ctrl+A when it opens: starts only with a UI) and M.submit(text).
-- start_server(cb) is local.
--
-- The contract does not fix where "Bonsai didn't start: <reason>" shows. The test accepts
-- the status line, the transcript, or a vim.notify message.
--
-- Not tested (known limit, accepted in the amendment): a message sent while another
-- Neovim holds the start lock.
--
-- Command shapes checked: {"bonsai-serve","status"}, {"bonsai-serve","stop"} and
-- {"bonsai-serve", <low|medium|high|max>}. The saved effort is "high" (BONSAI_STATE).

local results, failed = {}, 0

-- Never hang: give up after 90 s.
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

-- ---- fakes: nothing here runs a real command ----

-- Stubs go in before any module under test is required.
local LEVELS = { low = true, medium = true, high = true, max = true }
local UP = "Bonsai is up at effort high on localhost:8089.\n"
local DOWN = "Bonsai is down (last effort: high).\n"
local OK = { code = 0, stdout = UP, stderr = "" }
local FAILED = { code = 1, stdout = "", stderr = "no GPU memory\n" }

local commands = {} -- every command the code under test asked for, in order
local unexpected = {} -- anything that is not bonsai-serve, or a system call
local waiting = {} -- starts not finished yet: { on_exit = fn }
local notices = {} -- vim.notify messages
local LIVE = { [4242] = true } -- PIDs the fake says are alive
local STATUS = { up = false } -- the fake server's state

-- Callbacks arrive on a timer, as vim.system's do: in a fast event context.
local function deliver(on_exit, result)
  if not on_exit then
    return
  end
  local t = vim.uv.new_timer()
  t:start(0, 0, function()
    t:close()
    on_exit(result)
  end)
end

local function fake_run(cmd, opts, on_exit)
  if type(opts) == "function" then
    on_exit, opts = opts, nil
  end
  table.insert(commands, cmd)
  local is_bonsai = cmd[1] == "bonsai-serve"
  if not is_bonsai then
    table.insert(unexpected, cmd)
  end
  local handle = {
    pid = 0,
    kill = function() end,
    is_closing = function()
      return false
    end,
  }
  if is_bonsai and #cmd == 2 and LEVELS[cmd[2]] then
    -- A start stays running until the test finishes it (finish_start).
    table.insert(waiting, { on_exit = on_exit })
    return handle
  end
  local result = { code = 0, stdout = "", stderr = "" }
  if is_bonsai and cmd[2] == "status" then
    result.stdout = STATUS.up and UP or DOWN
  elseif is_bonsai and cmd[2] == "stop" then
    result.stdout = "Bonsai stopped.\n"
  end
  handle.wait = function()
    return result
  end
  for k, v in pairs(result) do
    handle[k] = v
  end
  deliver(on_exit, result)
  return handle
end

vim.system = fake_run

vim.fn.system = function(cmd)
  table.insert(unexpected, { "vim.fn.system", cmd })
  return ""
end

vim.fn.jobstart = function(cmd)
  table.insert(unexpected, { "vim.fn.jobstart", cmd })
  return -1
end

vim.notify = function(msg)
  table.insert(notices, tostring(msg))
end

local function finish_start(result)
  local held = table.remove(waiting, 1)
  if not held then
    error("no start is waiting", 2)
  end
  deliver(held.on_exit, result)
end

-- ---- helpers ----

local function since(mark)
  return vim.list_slice(commands, mark + 1)
end

local function count_cmd(list, name)
  local n = 0
  for _, cmd in ipairs(list) do
    if cmd[2] == name then
      n = n + 1
    end
  end
  return n
end

local function count_starts(list)
  local n = 0
  for _, cmd in ipairs(list) do
    if LEVELS[cmd[2]] then
      n = n + 1
    end
  end
  return n
end

local function wait_until(cond, ms)
  return vim.wait(ms or 1500, cond, 10)
end

local function settle(ms)
  vim.wait(ms or 150, function()
    return false
  end, 10)
end

local function exists(path)
  return vim.uv.fs_stat(path) ~= nil
end

local function files_in(dir)
  if not exists(dir) then
    return {}
  end
  local names = {}
  for name in vim.fs.dir(dir) do
    table.insert(names, name)
  end
  table.sort(names)
  return names
end

local function write(path, text)
  local f = assert(io.open(path, "w"))
  f:write(text)
  f:close()
end

-- The autocmds the lifecycle hooks: id -> autocmd.
local function autocmds()
  local found = {}
  for _, event in ipairs { "VimEnter", "UIEnter", "VimLeavePre" } do
    for _, a in ipairs(vim.api.nvim_get_autocmds { event = event }) do
      found[a.id] = a
    end
  end
  return found
end

-- Runs fn, then deletes every VimEnter, UIEnter and VimLeavePre autocmd it added.
local function keeping_autocmds(fn)
  local before = autocmds()
  local ok, err = pcall(fn)
  for id in pairs(autocmds()) do
    if not before[id] then
      pcall(vim.api.nvim_del_autocmd, id)
    end
  end
  if not ok then
    error(err, 0)
  end
end

local function window_text(win)
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return ""
  end
  local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
  return table.concat(lines, "\n")
end

-- The error text may show in the status line, the transcript, or a notification.
local function error_shown(text)
  local wins = require("bonsai.ui").windows()
  local shown =
    { table.concat(notices, "\n"), window_text(wins.status), window_text(wins.transcript) }
  for _, s in ipairs(shown) do
    if s:find(text, 1, true) then
      return true
    end
  end
  return false
end

local state_dir -- the lock and open-PID folder of the current test
local serve_dir -- where bonsai-serve keeps the saved effort (BONSAI_STATE)

local function load_lifecycle()
  local ok, mod = pcall(require, "bonsai.lifecycle")
  if not ok then
    error("bonsai.lifecycle does not exist yet: " .. tostring(mod):match("[^\n]*"), 2)
  end
  return mod
end

-- Runs fn with a lifecycle module as a new Neovim has it: nothing registered yet. The
-- shared module is put back afterwards, so later tests see the one they always did.
local function as_new_neovim(fn)
  local shared = package.loaded["bonsai.lifecycle"]
  package.loaded["bonsai.lifecycle"] = nil
  local ok, mod = pcall(require, "bonsai.lifecycle")
  if not ok then
    package.loaded["bonsai.lifecycle"] = shared
    error("bonsai.lifecycle does not exist yet: " .. tostring(mod):match("[^\n]*"), 2)
  end
  local ran, err = pcall(fn, mod)
  package.loaded["bonsai.lifecycle"] = shared
  if not ran then
    error(err, 0)
  end
end

local function lifecycle_opts(extra)
  return vim.tbl_extend("force", {
    state_dir = state_dir,
    has_ui = function()
      return true
    end,
    pid = 4242,
    alive = function(pid)
      return LIVE[pid] == true
    end,
    run = fake_run,
    web_running = function()
      return false
    end,
  }, extra or {})
end

-- Autocmds that setup_lock_folder added. The next fresh() removes them.
local made = {}

local function remove_made()
  for id in pairs(made) do
    pcall(vim.api.nvim_del_autocmd, id)
  end
  made = {}
end

-- The panel tests don't need lifecycle, but the start lock lives in its folder once it
-- exists, so the folder is passed in when the module is there.
local function setup_lock_folder(dir, attached)
  local ok, lc = pcall(require, "bonsai.lifecycle")
  if ok then
    local before = autocmds()
    lc.setup {
      state_dir = dir,
      has_ui = function()
        return attached == true
      end,
      run = fake_run,
      pid = 4242,
      alive = function(pid)
        return LIVE[pid] == true
      end,
      web_running = function()
        return false
      end,
    }
    for id in pairs(autocmds()) do
      if not before[id] then
        made[id] = true
      end
    end
  end
end

-- ---- the panel's fake chat: one for the whole file, since the panel keeps the first ----

local ui = require("bonsai.ui")
local chat = { bufnr = vim.api.nvim_create_buf(false, true), sent = {}, submitted = 0 }
function chat:add_buf_message(msg)
  table.insert(self.sent, msg)
end
function chat:submit()
  self.submitted = self.submitted + 1
end
ui.set_chat_factory(function()
  return chat
end)

-- Starts a test from a clean world: the panel closed, nothing running, a new folder.
-- Returns the mark: how many commands ran before this test.
local function fresh(up)
  -- Let whatever an earlier test started finish, so no state carries over.
  for _, w in ipairs(waiting) do
    deliver(w.on_exit, OK)
  end
  waiting = {}
  settle(100)
  pcall(ui.close)
  remove_made()
  chat.sent, chat.submitted = {}, 0
  notices, LIVE, STATUS.up = {}, { [4242] = true }, up
  local root = vim.fn.tempname()
  serve_dir = root .. "/serve"
  state_dir = root .. "/bonsai"
  vim.fn.mkdir(serve_dir, "p")
  vim.fn.mkdir(state_dir, "p")
  write(serve_dir .. "/effort", "high\n")
  vim.env.BONSAI_STATE = serve_dir
  setup_lock_folder(state_dir, false)
  return #commands
end

-- ---- O1: with a UI, opening the panel starts Bonsai; Ask Bonsai always does (O1a) ----

test("O1a with a UI, Ctrl+A opens the panel and starts Bonsai when it is down", function()
  local mark = fresh(false)
  setup_lock_folder(state_dir, true)
  ui.toggle()
  wait_until(function()
    return #since(mark) >= 2
  end)
  settle()
  eq(since(mark), { { "bonsai-serve", "status" }, { "bonsai-serve", "high" } }, "commands")
end)

test("O1a with a UI, M.open starts Bonsai at the saved effort when it is down", function()
  local mark = fresh(false)
  setup_lock_folder(state_dir, true)
  ui.open()
  wait_until(function()
    return #since(mark) >= 2
  end)
  settle()
  eq(since(mark), { { "bonsai-serve", "status" }, { "bonsai-serve", "high" } }, "commands")
end)

test(
  "O1a with a UI, Ctrl+A opens the panel and only checks the status when Bonsai is up",
  function()
    local mark = fresh(true)
    setup_lock_folder(state_dir, true)
    ui.toggle()
    wait_until(function()
      return #since(mark) >= 1
    end)
    settle()
    eq(since(mark), { { "bonsai-serve", "status" } }, "commands")
  end
)

test("O1a with no UI attached, opening the panel runs no command at all", function()
  local lc = load_lifecycle()
  local mark = fresh(false)
  keeping_autocmds(function()
    lc.setup(lifecycle_opts {
      has_ui = function()
        return false
      end,
    })
    eq(lc.has_ui(), false, "lifecycle.has_ui()")
    ui.toggle()
    settle(300)
    eq(since(mark), {}, "commands from Ctrl+A")
    ui.close()
    local after_toggle = #commands
    ui.open()
    settle(300)
    eq(#commands - after_toggle, 0, "commands from M.open")
  end)
end)

test("O1 Ask Bonsai starts Bonsai at the saved effort when it is down", function()
  local mark = fresh(false)
  ui.start()
  wait_until(function()
    return #since(mark) >= 2
  end)
  settle()
  eq(since(mark), { { "bonsai-serve", "status" }, { "bonsai-serve", "high" } }, "commands")
end)

test("O1 Ask Bonsai only checks the status when Bonsai is up", function()
  local mark = fresh(true)
  ui.start()
  wait_until(function()
    return #since(mark) >= 1
  end)
  settle()
  eq(since(mark), { { "bonsai-serve", "status" } }, "commands")
end)

-- ---- O2: one start at a time, guarded by the lock folder ----

test("O2 a second start while one runs starts nothing more", function()
  local mark = fresh(false)
  ui.start()
  truthy(
    wait_until(function()
      return count_starts(since(mark)) == 1
    end),
    "the first start ran"
  )
  local before = #commands
  ui.start()
  settle()
  eq(#commands - before, 0, "commands from the second start")
  eq(count_starts(since(mark)), 1, "starts")
  finish_start(OK)
end)

test("O2 a fresh lock held by another Neovim stops this one starting Bonsai", function()
  local mark = fresh(false)
  local lock = state_dir .. "/start.lock"
  vim.fn.mkdir(lock)
  ui.start()
  settle(400)
  eq(count_starts(since(mark)), 0, "starts while another Neovim holds the lock")
  truthy(exists(lock), "the other Neovim's lock is left alone")
end)

test("O2 a stale lock (older than 300 s) is taken over, and the start goes ahead", function()
  local mark = fresh(false)
  local lock = state_dir .. "/start.lock"
  vim.fn.mkdir(lock)
  local old = os.time() - 400
  vim.uv.fs_utime(lock, old, old)
  truthy(vim.uv.fs_stat(lock).mtime.sec <= os.time() - 300, "the lock is older than 300 s")
  ui.start()
  truthy(
    wait_until(function()
      return count_starts(since(mark)) == 1
    end),
    "the start went ahead"
  )
  finish_start(OK)
  truthy(
    wait_until(function()
      return not exists(lock)
    end),
    "the lock is removed when the start ends"
  )
end)

test("O2 the lock is held while the start runs and removed when it ends", function()
  local mark = fresh(false)
  local lock = state_dir .. "/start.lock"
  ui.start()
  truthy(
    wait_until(function()
      return count_starts(since(mark)) == 1
    end),
    "the start ran"
  )
  truthy(exists(lock), "the lock is held while the start runs")
  finish_start(OK)
  truthy(
    wait_until(function()
      return not exists(lock)
    end),
    "the lock is removed when the start ends"
  )
end)

-- ---- O3: a message waits for the start, and a failed start keeps it ----

test("O3 a message submitted while the start runs is sent when it succeeds", function()
  local mark = fresh(false)
  ui.start()
  truthy(
    wait_until(function()
      return count_starts(since(mark)) == 1
    end),
    "the start is running"
  )
  ui.submit("hello")
  settle()
  eq(chat.submitted, 0, "requests sent before the start finished")
  finish_start(OK)
  truthy(
    wait_until(function()
      return chat.submitted == 1
    end),
    "the message is sent after the start"
  )
  eq(#chat.sent, 1, "messages added")
  eq(chat.sent[1].content, "hello", "message text")
end)

test(
  "O3 when the start fails, the panel says why, the message stays in the input, and nothing is sent",
  function()
    local mark = fresh(false)
    ui.start()
    truthy(
      wait_until(function()
        return count_starts(since(mark)) == 1
      end),
      "the start is running"
    )
    ui.submit("hello")
    settle()
    finish_start(FAILED)
    truthy(
      wait_until(function()
        return error_shown("Bonsai didn't start: no GPU memory")
      end),
      "the panel says the start failed"
    )
    settle()
    eq(chat.submitted, 0, "requests sent after the failed start")
    eq(window_text(ui.windows().input), "hello", "the input keeps the message")
  end
)

-- ---- O4: each Neovim with a UI writes its PID file and drops stale ones (O4a: on UIEnter) ----

test("O4 register writes this Neovim's PID file", function()
  local lc = load_lifecycle()
  fresh(false)
  keeping_autocmds(function()
    lc.setup(lifecycle_opts())
    lc.register()
  end)
  eq(files_in(state_dir .. "/open"), { "4242" }, "open files")
end)

test("O4 open_count drops a PID whose process is gone", function()
  local lc = load_lifecycle()
  fresh(false)
  keeping_autocmds(function()
    lc.setup(lifecycle_opts())
    lc.register()
    vim.fn.mkdir(state_dir .. "/open", "p")
    write(state_dir .. "/open/999999", "")
    eq(lc.open_count(), 1, "live open PIDs")
  end)
  eq(files_in(state_dir .. "/open"), { "4242" }, "the stale file is removed")
end)

test(
  "O4a setup creates UIEnter and VimLeavePre autocmds even without a UI, and no VimEnter one",
  function()
    local lc = load_lifecycle()
    fresh(false)
    keeping_autocmds(function()
      lc.setup(lifecycle_opts {
        has_ui = function()
          return false
        end,
      })
      local in_group = {}
      for _, a in ipairs(vim.api.nvim_get_autocmds { group = "BonsaiLifecycle" }) do
        in_group[a.event] = true
      end
      truthy(in_group.UIEnter, "a UIEnter autocmd in the BonsaiLifecycle group")
      truthy(in_group.VimLeavePre, "a VimLeavePre autocmd in the BonsaiLifecycle group")
      eq(in_group.VimEnter, nil, "a VimEnter autocmd (registration must not happen on VimEnter)")
    end)
  end
)

test("O4a firing VimLeavePre without a prior register runs no command", function()
  local mark = fresh(true)
  as_new_neovim(function(lc)
    keeping_autocmds(function()
      -- A UI is attached, but this Neovim never registered.
      lc.setup(lifecycle_opts())
      vim.api.nvim_exec_autocmds("VimLeavePre", { group = "BonsaiLifecycle" })
      settle(200)
      eq(since(mark), {}, "commands")
    end)
  end)
end)

test("O4a firing UIEnter with a UI writes this Neovim's PID file", function()
  fresh(false)
  as_new_neovim(function(lc)
    keeping_autocmds(function()
      lc.setup(lifecycle_opts())
      eq(files_in(state_dir .. "/open"), {}, "open files before UIEnter")
      vim.api.nvim_exec_autocmds("UIEnter", { group = "BonsaiLifecycle" })
      eq(files_in(state_dir .. "/open"), { "4242" }, "open files after UIEnter")
    end)
  end)
end)

-- ---- O5: the last Neovim to leave stops Bonsai, unless something still needs it ----

test("O5 the last Neovim to leave stops Bonsai and removes its own file", function()
  local lc = load_lifecycle()
  local mark = fresh(true)
  keeping_autocmds(function()
    lc.setup(lifecycle_opts())
    lc.register()
    lc.on_leave()
  end)
  eq(count_cmd(since(mark), "stop"), 1, "stop runs")
  eq(files_in(state_dir .. "/open"), {}, "open files")
end)

test("O5 another Neovim still open: Bonsai keeps running", function()
  local lc = load_lifecycle()
  local mark = fresh(true)
  LIVE[5151] = true
  vim.fn.mkdir(state_dir .. "/open", "p")
  write(state_dir .. "/open/5151", "")
  keeping_autocmds(function()
    lc.setup(lifecycle_opts())
    lc.register()
    lc.on_leave()
  end)
  eq(count_cmd(since(mark), "stop"), 0, "stop runs")
  eq(files_in(state_dir .. "/open"), { "5151" }, "the other Neovim's file is kept")
end)

test("O5 bonsai-web running: Bonsai keeps running", function()
  local lc = load_lifecycle()
  local mark = fresh(true)
  keeping_autocmds(function()
    lc.setup(lifecycle_opts {
      web_running = function()
        return true
      end,
    })
    lc.register()
    lc.on_leave()
  end)
  eq(count_cmd(since(mark), "stop"), 0, "stop runs")
  eq(files_in(state_dir .. "/open"), {}, "open files")
end)

test("O5 stopping when Bonsai is already down is fine", function()
  local lc = load_lifecycle()
  local mark = fresh(false)
  local ok, err = pcall(function()
    keeping_autocmds(function()
      lc.setup(lifecycle_opts())
      lc.register()
      lc.on_leave()
    end)
  end)
  truthy(ok, "on_leave raised: " .. tostring(err))
  eq(count_cmd(since(mark), "stop"), 1, "stop runs")
  eq(count_starts(since(mark)), 0, "starts")
end)

-- ---- O6: without a UI (tests, headless) nothing is written, stopped or hooked ----

test("O6 without a UI, register writes nothing", function()
  local lc = load_lifecycle()
  fresh(false)
  keeping_autocmds(function()
    lc.setup(lifecycle_opts {
      has_ui = function()
        return false
      end,
    })
    lc.register()
  end)
  eq(files_in(state_dir .. "/open"), {}, "open files")
end)

test("O6 without a UI, on_leave runs no command", function()
  local lc = load_lifecycle()
  local mark = fresh(true)
  keeping_autocmds(function()
    lc.setup(lifecycle_opts {
      has_ui = function()
        return false
      end,
    })
    lc.on_leave()
  end)
  eq(since(mark), {}, "commands")
end)

test("O6 without a UI, firing UIEnter writes no PID file (headless never registers)", function()
  fresh(false)
  as_new_neovim(function(lc)
    keeping_autocmds(function()
      lc.setup(lifecycle_opts {
        has_ui = function()
          return false
        end,
      })
      vim.api.nvim_exec_autocmds("UIEnter", { group = "BonsaiLifecycle" })
      eq(files_in(state_dir .. "/open"), {}, "open files")
    end)
  end)
end)

-- ---- guard: whatever ran, only bonsai-serve status, stop and the effort levels ----

test("guard: only bonsai-serve status, stop and effort levels were ever run", function()
  eq(unexpected, {}, "commands other than bonsai-serve")
  for _, cmd in ipairs(commands) do
    local allowed = #cmd == 2
      and cmd[1] == "bonsai-serve"
      and (cmd[2] == "status" or cmd[2] == "stop" or LEVELS[cmd[2]] ~= nil)
    truthy(allowed, "unexpected command " .. vim.inspect(cmd))
  end
end)

-- Remove the autocmds the tests added, so the process exits as it started.
remove_made()

for _, line in ipairs(results) do
  print(line)
end
print(("%d passed, %d failed"):format(#results - failed, failed))
vim.cmd(failed > 0 and "cquit 1" or "qall!")
