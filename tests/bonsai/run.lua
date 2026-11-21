-- Tests for the Bonsai coding agent in Neovim (contract: ~/Documents/projects/NEOVIM-AGENT.md).
-- Run in the sandbox, which loads this config and its plugins:
--   NVIM_APPNAME=nvim-bonsai-agent nvim --headless -c "luafile tests/bonsai/run.lua"
-- Prints one line per test and exits 1 if any test fails.

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
  if not v then error((what or "value") .. " is not true", 2) end
end

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
vim.env.BONSAI_STATE = tmp

local function set_level_file(name)
  local f = assert(io.open(tmp .. "/effort", "w"))
  f:write(name .. "\n")
  f:close()
end

-- ---- effort levels ----

test("four effort levels in order, with their context and thinking", function()
  local effort = require("bonsai.effort")
  local got = vim.tbl_map(function(l) return { l.name, l.ctx, l.thinking } end, effort.LEVELS)
  eq(got, {
    { "low", 16384, false },
    { "medium", 32768, false },
    { "high", 65536, true },
    { "max", 184320, true },
  }, "levels")
end)

test("the level is medium when nothing is saved", function()
  os.remove(tmp .. "/effort")
  eq(require("bonsai.effort").current().name, "medium")
end)

test("the level is read from bonsai-serve's state file", function()
  set_level_file("high")
  eq(require("bonsai.effort").current().name, "high")
  set_level_file("nonsense")
  eq(require("bonsai.effort").current().name, "medium", "an unknown level falls back")
end)

test("thinking follows the level", function()
  local effort = require("bonsai.effort")
  set_level_file("low");    eq(effort.thinking(), false, "low")
  set_level_file("medium"); eq(effort.thinking(), false, "medium")
  set_level_file("high");   eq(effort.thinking(), true, "high")
  set_level_file("max");    eq(effort.thinking(), true, "max")
end)

test("switching level runs bonsai-serve with that level", function()
  local seen
  require("bonsai.effort").set("high", function() end, function(cmd, _, on_exit)
    seen = cmd
    on_exit({ code = 0, stdout = "", stderr = "" })
  end)
  eq(seen, { "bonsai-serve", "high" }, "command")
end)

test("an unknown level is refused without running anything", function()
  local ran = false
  local ok = require("bonsai.effort").set("turbo", function() end, function() ran = true end)
  eq(ok, false, "result")
  eq(ran, false, "ran")
end)

-- ---- the codecompanion adapter ----

-- Loaded inside each test, so a missing module fails tests instead of the run.
local cc = setmetatable({}, { __index = function(_, k) return require("config.codecompanion")[k] end })

test("each request carries the level's thinking switch", function()
  set_level_file("high")
  local p = cc.handlers.form_parameters({}, { temperature = 0.2 }, {})
  eq(p.chat_template_kwargs, { enable_thinking = true }, "high")
  eq(p.temperature, 0.2, "other parameters are kept")
  set_level_file("medium")
  p = cc.handlers.form_parameters({}, {}, {})
  eq(p.chat_template_kwargs, { enable_thinking = false }, "medium")
end)

-- Changed 2026-11-21: the test passed an empty adapter ({}), but the built-in
-- form_messages reads the model name from the adapter, so it now passes the
-- real Bonsai adapter.
test("a request has exactly one system message, and it comes first", function()
  local adapter = cc.opts().adapters.http.bonsai()
  local formed = cc.handlers.form_messages(adapter, {
    { role = "system", content = "You are a coding assistant." },
    { role = "user", content = "Hi" },
    { role = "system", content = "Tool instructions." },
    { role = "assistant", content = "Hello" },
    { role = "system", content = "More rules." },
  })
  local msgs = formed.messages or formed
  local systems = vim.tbl_filter(function(m) return m.role == "system" end, msgs)
  eq(#systems, 1, "system messages")
  eq(msgs[1].role, "system", "first message")
end)

-- ---- the codecompanion setup ----

test("chat and inline both use the Bonsai adapter on localhost:8089", function()
  local opts = cc.opts()
  eq(opts.interactions.chat.adapter, "bonsai", "chat")
  eq(opts.interactions.inline.adapter, "bonsai", "inline")
  local adapter = opts.adapters.http.bonsai()
  eq(adapter.env.url, "http://127.0.0.1:8089", "url")
end)

test("/effort is a slash command in the chat", function()
  local cmd = cc.opts().interactions.chat.slash_commands.effort
  truthy(cmd, "effort command")
  eq(type(cmd.callback), "function", "callback")
end)

test("every command waits for approval, with no safe list", function()
  local tools = cc.opts().interactions.chat.tools
  eq(tools.run_command.opts.require_approval_before, true, "run_command")
  eq(tools.run_command.opts.require_cmd_approval, true, "each command")
  eq(tools.run_command.opts.safe_commands, {}, "safe list")
  eq(tools.opts.approval_mode, "ask", "approval mode")
end)

test("edits, new files, overwrites and deletes wait for approval first", function()
  local tools = cc.opts().interactions.chat.tools
  eq(tools.edit_file.opts.require_approval_before, { buffer = true, file = true }, "edit_file")
  eq(tools.create_file.opts.require_approval_before, true, "create_file")
  eq(tools.overwrite_file.opts.require_approval_before, true, "overwrite_file")
  eq(tools.delete_file.opts.require_approval_before, true, "delete_file")
end)

-- Added 2026-11-21 (owner): Bonsai sees only a project's own AGENTS.md / .rules,
-- never ~/.claude/CLAUDE.md or other Claude-specific files.
test("only the project's AGENTS.md and .rules are attached to chats", function()
  local opts = cc.opts()
  eq(opts.rules.opts.chat.autoload, "bonsai", "autoloaded group")
  local files = vim.tbl_map(function(f) return type(f) == "table" and f.path or f end, opts.rules.bonsai.files)
  eq(files, { "AGENTS.md", ".rules" }, "files")
end)

-- Added 2026-11-21 (owner): Ctrl+A in normal mode opens or closes the chat.
test("Ctrl+A in normal mode toggles the Bonsai chat; insert and command line keep theirs", function()
  local n = vim.fn.maparg("<C-a>", "n", false, true)
  truthy(n.rhs and n.rhs:find("CodeCompanionChat Toggle", 1, true), "normal-mode Ctrl+A: " .. vim.inspect(n.rhs))
  -- Neovim reports the key as <Home>; the config writes <HOME>. Same key.
  eq(vim.fn.maparg("<C-a>", "i"):lower(), "<home>", "insert-mode Ctrl+A")
  eq(vim.fn.maparg("<C-a>", "c"):lower(), "<home>", "command-line Ctrl+A")
end)

test("/effort switches the level through bonsai-serve", function()
  local effort = require("bonsai.effort")
  set_level_file("medium")
  local ran, orig_select, orig_set = nil, vim.ui.select, effort.set
  vim.ui.select = function(items, _, choose)
    for _, item in ipairs(items) do if item.name == "high" then return choose(item) end end
  end
  effort.set = function(name, done) ran = name; done(true, "ok"); return true end
  local ok, err = pcall(cc.opts().interactions.chat.slash_commands.effort.callback, nil)
  vim.ui.select, effort.set = orig_select, orig_set
  assert(ok, err)
  eq(ran, "high", "level started")
end)

-- ---- plugin list ----

test("Copilot is gone and codecompanion is in the plugin list", function()
  local path = vim.fn.stdpath("config") .. "/lua/plugin_specs.lua"
  local text = table.concat(vim.fn.readfile(path), "\n")
  eq(text:find("CopilotChat", 1, true), nil, "CopilotChat")
  eq(text:find("copilot.lua", 1, true), nil, "copilot.lua")
  truthy(text:find("olimorris/codecompanion.nvim", 1, true), "codecompanion spec")
end)

test("codecompanion loads and its commands exist", function()
  require("lazy").load({ plugins = { "codecompanion.nvim" } })
  truthy(vim.fn.exists(":CodeCompanionChat") == 2, ":CodeCompanionChat")
end)

for _, line in ipairs(results) do print(line) end
print(("%d passed, %d failed"):format(#results - failed, failed))
vim.cmd(failed > 0 and "cquit 1" or "qall!")
