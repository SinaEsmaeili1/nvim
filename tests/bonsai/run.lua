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
-- Changed 2026-11-21: the owner then chose global rules, so the index of
-- Bonsai's notes (INDEX.md only) is attached too. Still never ~/.claude/CLAUDE.md.
test("only the project's AGENTS.md and .rules, and the notes index, are attached to chats", function()
  local opts = cc.opts()
  eq(opts.rules.opts.chat.autoload, "bonsai", "autoloaded group")
  local files = vim.tbl_map(function(f) return type(f) == "table" and f.path or f end, opts.rules.bonsai.files)
  eq({ files[1], files[2] }, { "AGENTS.md", ".rules" }, "project files")
  eq(#files, 3, "nothing else")
  eq(opts.rules.bonsai.files[3].files, "INDEX.md", "only the notes index")
  for _, f in ipairs(files) do
    eq(tostring(f):find("CLAUDE", 1, true), nil, "no CLAUDE.md")
  end
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

-- ---- sandbox (owner, 2026-11-21: "sanboxed based on the current directory and no esclation") ----

local real_home = vim.uv.os_homedir()
local project = vim.fn.tempname() .. "-project"
vim.fn.mkdir(project .. "/src", "p")
project = vim.uv.fs_realpath(project)
local outside = vim.fn.tempname() .. "-outside"
vim.fn.mkdir(outside, "p")
vim.uv.fs_symlink(outside, project .. "/link-out")

test("paths inside the project are allowed, others are refused", function()
  local sandbox = require("bonsai.sandbox")
  sandbox.set_root(project)
  eq(sandbox.inside("src/main.lua"), true, "relative inside")
  eq(sandbox.inside(project .. "/new/file.txt"), true, "new file inside")
  eq(sandbox.inside("../escape.txt"), false, "../")
  eq(sandbox.inside(real_home .. "/.ssh/id_ed25519"), false, "~/.ssh")
  eq(sandbox.inside("/etc/passwd"), false, "/etc")
  eq(sandbox.inside("link-out/secret.txt"), false, "a symlink that leads outside")
end)

test("Bonsai's tools are off when Neovim was opened in the home folder or /", function()
  local sandbox = require("bonsai.sandbox")
  sandbox.set_root(real_home); eq(sandbox.usable(), false, "home")
  sandbox.set_root("/"); eq(sandbox.usable(), false, "/")
  sandbox.set_root(project); eq(sandbox.usable(), true, "a project folder")
end)

local function run_sandboxed(cmd)
  local sandbox = require("bonsai.sandbox")
  sandbox.set_root(project)
  return vim.system(sandbox.wrap(cmd), { text = true }):wait()
end

test("a command can write inside the project", function()
  local r = run_sandboxed("echo hello > made-here.txt")
  eq(r.code, 0, "exit code: " .. (r.stderr or ""))
  eq(vim.fn.readfile(project .. "/made-here.txt"), { "hello" }, "file")
end)

test("a command cannot write outside the project", function()
  local target = outside .. "/escaped.txt"
  local r = run_sandboxed("echo x > " .. target)
  truthy(r.code ~= 0, "exit code")
  eq(vim.uv.fs_stat(target), nil, "file outside")
  local home_target = real_home .. "/bonsai-sandbox-escape-test"
  run_sandboxed("touch " .. home_target)
  eq(vim.uv.fs_stat(home_target), nil, "file in home")
end)

test("a command cannot read the home folder", function()
  local r = run_sandboxed("ls " .. real_home .. "/.ssh")
  truthy(r.code ~= 0, "listing ~/.ssh must fail")
end)

test("a command has no network", function()
  local r = run_sandboxed("getent hosts example.com || curl -s -m 5 -o /dev/null https://example.com")
  truthy(r.code ~= 0, "network must fail")
end)

test("a command cannot escalate with sudo", function()
  local r = run_sandboxed("sudo -n true")
  truthy(r.code ~= 0, "sudo must fail")
end)

test("run_command runs every command inside the sandbox", function()
  local sandbox = require("bonsai.sandbox")
  sandbox.set_root(project)
  local tool = require("bonsai.tools.run_command")
  local fake = { args = { cmd = "make test", flag = vim.NIL }, cmds = {} }
  tool.handlers.setup(fake, {})
  eq(#fake.cmds, 1, "one command")
  eq(fake.cmds[1].cmd[1], "bwrap", "runs through bwrap")
  eq(fake.cmds[1].cmd[#fake.cmds[1].cmd], "make test", "the command itself")
end)

test("file tools refuse paths outside the project", function()
  local sandbox = require("bonsai.sandbox")
  sandbox.set_root(project)
  for _, name in ipairs({ "read_file", "edit_file", "create_file", "overwrite_file", "delete_file" }) do
    local tool = require("bonsai.tools." .. name)
    local got
    tool.cmds[1](nil, { filepath = real_home .. "/.ssh/id_ed25519" }, { output_cb = function(o) got = o end })
    vim.wait(1000, function() return got ~= nil end)
    eq(got and got.status, "error", name .. " status")
    truthy(got and got.data:find("outside the project", 1, true), name .. " message")
  end
end)

test("the chat uses the sandboxed tools", function()
  local tools = cc.opts().interactions.chat.tools
  for _, name in ipairs({ "run_command", "read_file", "edit_file", "create_file", "overwrite_file", "delete_file" }) do
    eq(tools[name].path, "bonsai.tools." .. name, name)
  end
end)

-- Owner, 2026-11-21: every website Bonsai visits needs approval first.
test("web search and page fetches wait for approval", function()
  local tools = cc.opts().interactions.chat.tools
  eq(tools.web_search.opts.require_approval_before, true, "web_search")
  eq(tools.fetch_webpage.opts.require_approval_before, true, "fetch_webpage")
  eq(tools.fetch_webpage.opts.adapter, "markitdown", "pages are read locally, never through a third party")
end)

-- ---- Markdown-driven notes (owner, 2026-11-21: global rules; "markdown driven
-- rather than context driven for efficiency"; "as less context dependent as possible") ----

local rules = vim.fn.tempname() .. "-rules"
vim.env.BONSAI_RULES = rules

test("only the global rules index is loaded into each chat, besides the project's AGENTS.md", function()
  local files = cc.opts().rules.bonsai.files
  local index
  for _, f in ipairs(files) do
    if type(f) == "table" and f.files == "INDEX.md" then index = f end
  end
  truthy(index, "INDEX.md entry")
  eq(index.path, rules, "rules folder")
end)

test("the index is created with how-to lines if missing, and never overwritten", function()
  local notes = require("bonsai.notes")
  vim.fn.delete(rules, "rf")
  notes.ensure_index()
  local text = table.concat(vim.fn.readfile(rules .. "/INDEX.md"), "\n")
  truthy(text:find("/rules/", 1, true), "explains where rules go")
  truthy(text:find("Why:", 1, true), "asks for a Why: line")
  vim.fn.writefile({ "# mine" }, rules .. "/INDEX.md")
  notes.ensure_index()
  eq(vim.fn.readfile(rules .. "/INDEX.md"), { "# mine" }, "kept as it was")
end)

test("Bonsai's memory tool reaches the rules folder as /rules and is on in every chat", function()
  local tools = cc.opts().interactions.chat.tools
  eq(tools.memory.opts.whitelist, { { path = rules, as = "/rules" } }, "whitelist")
  truthy(vim.tbl_contains(tools.opts.default_tools, "memory"), "default tool")
end)

test("reading notes is free; every write to them asks first", function()
  local ask = cc.opts().interactions.chat.tools.memory.opts.require_approval_before
  eq(type(ask), "function", "decided per call")
  eq(ask({ args = { command = "view", path = "/rules" } }), false, "view")
  for _, command in ipairs({ "create", "str_replace", "insert", "delete", "rename" }) do
    eq(ask({ args = { command = command, path = "/rules/x.md" } }), true, command)
  end
  eq(ask({ args = {} }), true, "unknown asks")
end)

test("only the memory tool is on by default; others are added per task", function()
  eq(cc.opts().interactions.chat.tools.opts.default_tools, { "memory" }, "default tools")
end)

test("the context size follows the effort level", function()
  local shared = require("codecompanion.adapters.shared")
  set_level_file("low")
  eq(shared.context_window(cc.opts().adapters.http.bonsai()), 16384, "low")
  set_level_file("high")
  eq(shared.context_window(cc.opts().adapters.http.bonsai()), 65536, "high")
end)

test("old tool output is trimmed early, and long chats are summarised early", function()
  local cm = cc.opts().interactions.chat.opts.context_management
  eq(cm.editing.trigger, 0.5, "editing")
  eq(cm.compaction.trigger, 0.7, "compaction")
end)

-- ---- search through the owner's own SearXNG (owner, 2026-11-21: no search API) ----

test("search goes to the local SearXNG only, as JSON", function()
  local opts = cc.opts()
  eq(opts.interactions.chat.tools.web_search.opts.adapter, "searxng", "adapter")
  local sx = require("bonsai.searxng")
  eq(sx.url, "http://127.0.0.1:8888/search?q=${query}&format=json", "url")
  sx.methods.tools.web_search.setup(sx, {}, { query = "neovim lua & tests" })
  eq(sx.env.query, vim.uri_encode("neovim lua & tests"), "query is encoded")
end)

test("SearXNG results become title, url and snippet, at most 8", function()
  local sx = require("bonsai.searxng")
  local results = {}
  for i = 1, 12 do
    table.insert(results, { title = "T" .. i, url = "https://example.com/" .. i, content = "snippet " .. i, engine = "x" })
  end
  local out = sx.methods.tools.web_search.callback(sx, { status = 200, body = vim.json.encode({ results = results }) })
  eq(out.status, "success", "status")
  eq(#out.content, 8, "count")
  eq(out.content[1], { title = "T1", url = "https://example.com/1", content = "snippet 1" }, "first")
end)

test("a SearXNG error, a non-JSON answer or no results come back as clear errors", function()
  local sx = require("bonsai.searxng")
  local cb = sx.methods.tools.web_search.callback
  local down = cb(sx, { status = 502, body = "" })
  eq(down.status, "error", "502")
  truthy(down.content:find("searxng", 1, true), "says how to check SearXNG")
  eq(cb(sx, { status = 200, body = "<html>" }).status, "error", "not JSON")
  local none = cb(sx, { status = 200, body = vim.json.encode({ results = {} }) })
  eq(none.status, "error", "no results")
  eq(none.content, "No results found", "no-results message")
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
