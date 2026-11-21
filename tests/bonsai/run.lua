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
  if not v then
    error((what or "value") .. " is not true", 2)
  end
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
  local got = vim.tbl_map(function(l)
    return { l.name, l.ctx, l.thinking }
  end, effort.LEVELS)
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
  set_level_file("low")
  eq(effort.thinking(), false, "low")
  set_level_file("medium")
  eq(effort.thinking(), false, "medium")
  set_level_file("high")
  eq(effort.thinking(), true, "high")
  set_level_file("max")
  eq(effort.thinking(), true, "max")
end)

test("switching level runs bonsai-serve with that level", function()
  local seen
  require("bonsai.effort").set("high", function() end, function(cmd, _, on_exit)
    seen = cmd
    on_exit { code = 0, stdout = "", stderr = "" }
  end)
  eq(seen, { "bonsai-serve", "high" }, "command")
end)

test("an unknown level is refused without running anything", function()
  local ran = false
  local ok = require("bonsai.effort").set("turbo", function() end, function()
    ran = true
  end)
  eq(ok, false, "result")
  eq(ran, false, "ran")
end)

-- ---- the codecompanion adapter ----

-- Loaded inside each test, so a missing module fails tests instead of the run.
local cc = setmetatable({}, {
  __index = function(_, k)
    return require("config.codecompanion")[k]
  end,
})

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
  local systems = vim.tbl_filter(function(m)
    return m.role == "system"
  end, msgs)
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
test(
  "only the project's AGENTS.md and .rules, and the notes index, are attached to chats",
  function()
    local opts = cc.opts()
    eq(opts.rules.opts.chat.autoload, "bonsai", "autoloaded group")
    local files = vim.tbl_map(function(f)
      return type(f) == "table" and f.path or f
    end, opts.rules.bonsai.files)
    eq({ files[1], files[2] }, { "AGENTS.md", ".rules" }, "project files")
    eq(#files, 3, "nothing else")
    eq(opts.rules.bonsai.files[3].files, "INDEX.md", "only the notes index")
    for _, f in ipairs(files) do
      eq(tostring(f):find("CLAUDE", 1, true), nil, "no CLAUDE.md")
    end
  end
)

-- Added 2026-11-21 (owner): Ctrl+A in normal mode opens or closes the chat.
-- Changed 2026-11-21: Ctrl+A now toggles the whole Bonsai layout (the owner
-- approved the Claude Code-style layout), not codecompanion's own window.
test(
  "Ctrl+A in normal mode toggles the Bonsai chat; insert and command line keep theirs",
  function()
    local n = vim.fn.maparg("<C-a>", "n", false, true)
    truthy(
      n.rhs and n.rhs:find("require('bonsai.ui').toggle()", 1, true),
      "normal-mode Ctrl+A: " .. vim.inspect(n.rhs)
    )
    -- Neovim reports the key as <Home>; the config writes <HOME>. Same key.
    eq(vim.fn.maparg("<C-a>", "i"):lower(), "<home>", "insert-mode Ctrl+A")
    eq(vim.fn.maparg("<C-a>", "c"):lower(), "<home>", "command-line Ctrl+A")
  end
)

test("/effort switches the level through bonsai-serve", function()
  local effort = require("bonsai.effort")
  set_level_file("medium")
  local ran, orig_select, orig_set = nil, vim.ui.select, effort.set
  vim.ui.select = function(items, _, choose)
    for _, item in ipairs(items) do
      if item.name == "high" then
        return choose(item)
      end
    end
  end
  effort.set = function(name, done)
    ran = name
    done(true, "ok")
    return true
  end
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
  sandbox.set_root(real_home)
  eq(sandbox.usable(), false, "home")
  sandbox.set_root("/")
  eq(sandbox.usable(), false, "/")
  sandbox.set_root(project)
  eq(sandbox.usable(), true, "a project folder")
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
  local r =
    run_sandboxed("getent hosts example.com || curl -s -m 5 -o /dev/null https://example.com")
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
  for _, name in ipairs { "read_file", "edit_file", "create_file", "overwrite_file", "delete_file" } do
    local tool = require("bonsai.tools." .. name)
    local got
    tool.cmds[1](nil, { filepath = real_home .. "/.ssh/id_ed25519" }, {
      output_cb = function(o)
        got = o
      end,
    })
    vim.wait(1000, function()
      return got ~= nil
    end)
    eq(got and got.status, "error", name .. " status")
    truthy(got and got.data:find("outside the project", 1, true), name .. " message")
  end
end)

test("the chat uses the sandboxed tools", function()
  local tools = cc.opts().interactions.chat.tools
  for _, name in ipairs {
    "run_command",
    "read_file",
    "edit_file",
    "create_file",
    "overwrite_file",
    "delete_file",
  } do
    eq(tools[name].path, "bonsai.tools." .. name, name)
  end
end)

-- ---- the server key and the full guards (owner, 2026-11-21: "other than the second and the
-- third security leave the rest"; contract: NEOVIM-AGENT.md, Addendum 3) ----

local function write_file(path, text)
  local f = assert(io.open(path, "w"))
  f:write(text)
  f:close()
end

-- Runs fn with Neovim's current folder set to dir, then goes back.
local function in_dir(dir, fn)
  local before = vim.fn.getcwd()
  vim.cmd.cd(vim.fn.fnameescape(dir))
  local ok, err = pcall(fn)
  vim.cmd.cd(vim.fn.fnameescape(before))
  if not ok then
    error(err, 0)
  end
end

-- Calls a guarded tool the way codecompanion's runner does, and returns what it reports.
local function call_tool(name, args)
  local tool = require("bonsai.tools." .. name)
  local got
  local returned = tool.cmds[1]({ tool = { opts = {} } }, args, {
    output_cb = function(o)
      got = o
    end,
    register_job = function() end,
  })
  if returned ~= nil then
    return returned
  end
  vim.wait(3000, function()
    return got ~= nil
  end)
  return got
end

test("requests carry the Bonsai server's key from bonsai-serve's key file", function()
  write_file(tmp .. "/api-key", "test-key-123\n")
  local adapter_utils = require("codecompanion.adapters.utils")
  local adapter = adapter_utils.get_env_vars(cc.opts().adapters.http.bonsai())
  eq(
    adapter_utils.set_env_vars(adapter, adapter.headers).Authorization,
    "Bearer test-key-123",
    "Authorization"
  )
  os.remove(tmp .. "/api-key")
end)

test("a tool with no path argument can't be put behind the file guard", function()
  package.loaded["bonsai_test.no_path_tool"] = {
    schema = { ["function"] = { parameters = { properties = { query = { type = "string" } } } } },
    cmds = {
      function()
        return { status = "success", data = "ran" }
      end,
    },
  }
  local ok, err = pcall(require("bonsai.tools.guard"), "bonsai_test.no_path_tool")
  eq(ok, false, "wrapping fails")
  truthy(tostring(err):find("bonsai_test.no_path_tool", 1, true), "the error names the tool")
end)

test(
  "file tools refuse a call with no path, a path under another name, or a path that isn't text",
  function()
    require("bonsai.sandbox").set_root(project)
    in_dir(project, function()
      for _, name in ipairs {
        "read_file",
        "edit_file",
        "create_file",
        "overwrite_file",
        "delete_file",
        "get_diagnostics",
      } do
        for _, case in ipairs {
          { "no path", {} },
          { "a path under another name", { path = outside .. "/secret.txt" } },
          {
            "a second path outside",
            { filepath = project .. "/src/scratch.txt", file_path = outside .. "/secret.txt" },
          },
          { "a path that isn't text", { filepath = { outside .. "/secret.txt" } } },
        } do
          local ok, got = pcall(call_tool, name, case[2])
          truthy(
            ok,
            name
              .. ", "
              .. case[1]
              .. ": the guard answers instead of the tool failing: "
              .. tostring(got)
          )
          eq(got and got.status, "error", name .. ", " .. case[1])
          truthy(
            got and tostring(got.data):find("Refused", 1, true),
            name .. ", " .. case[1] .. ": refused"
          )
        end
      end
    end)
  end
)

test(
  "file tools refuse when Neovim's current folder is outside the project, even for a relative path",
  function()
    require("bonsai.sandbox").set_root(project)
    write_file(outside .. "/secret.txt", "top secret\n")
    in_dir(outside, function()
      local got = call_tool("read_file", { filepath = "secret.txt" })
      eq(got and got.status, "error", "status")
      -- vim.inspect, since a tool's data can be a table ({ for_llm = ... }); fixed 2026-11-21 before GREEN.
      truthy(not vim.inspect(got and got.data):find("top secret", 1, true), "the file stays unread")
    end)
  end
)

test("read_file still reads a file inside the project", function()
  require("bonsai.sandbox").set_root(project)
  write_file(project .. "/src/hello.txt", "hello from the project\n")
  in_dir(project, function()
    local got = call_tool("read_file", { filepath = project .. "/src/hello.txt" })
    eq(got and got.status, "success", "status")
    -- read_file returns its text in data.for_llm, a table; fixed 2026-11-21 before GREEN.
    truthy(vim.inspect(got and got.data):find("hello from the project", 1, true), "content")
  end)
end)

test(
  "search and git tools refuse when Neovim was opened in / or its current folder is outside the project",
  function()
    local sandbox = require("bonsai.sandbox")
    for _, name in ipairs { "grep_search", "file_search", "get_changed_files" } do
      local args = name == "get_changed_files" and {} or { query = "secret" }
      sandbox.set_root("/")
      in_dir(outside, function()
        local got = call_tool(name, args)
        eq(got and got.status, "error", name .. ", opened in /")
      end)
      sandbox.set_root(project)
      in_dir(outside, function()
        local got = call_tool(name, args)
        eq(got and got.status, "error", name .. ", current folder outside")
        truthy(got and tostring(got.data):find("Refused", 1, true), name .. ": refused")
      end)
    end
    sandbox.set_root(project)
  end
)

test("file_search still finds a project file", function()
  require("bonsai.sandbox").set_root(project)
  write_file(project .. "/src/hello.txt", "hello from the project\n")
  in_dir(project, function()
    local got = call_tool("file_search", { query = "**/hello.txt" })
    eq(got and got.status, "success", "status")
    truthy(vim.inspect(got and got.data):find("hello.txt", 1, true), "found")
  end)
end)

test("the chat uses the guarded tools, and every agent and files group tool is guarded", function()
  local tools = cc.opts().interactions.chat.tools
  for _, name in ipairs { "get_diagnostics", "grep_search", "file_search", "get_changed_files" } do
    eq(tools[name] and tools[name].path, "bonsai.tools." .. name, name)
  end
  local groups = require("codecompanion.config").interactions.chat.tools.groups
  for _, group in ipairs { "agent", "files" } do
    for _, name in ipairs(groups[group].tools) do
      if name ~= "ask_questions" then
        eq(tools[name] and tools[name].path, "bonsai.tools." .. name, group .. " group: " .. name)
      end
    end
  end
end)

-- Owner, 2026-11-21: every website Bonsai visits needs approval first.
test("web search and page fetches wait for approval", function()
  local tools = cc.opts().interactions.chat.tools
  eq(tools.web_search.opts.require_approval_before, true, "web_search")
  eq(tools.fetch_webpage.opts.require_approval_before, true, "fetch_webpage")
  eq(
    tools.fetch_webpage.opts.adapter,
    "markitdown",
    "pages are read locally, never through a third party"
  )
end)

-- ---- Markdown-driven notes (owner, 2026-11-21: global rules; "markdown driven
-- rather than context driven for efficiency"; "as less context dependent as possible") ----

local rules = vim.fn.tempname() .. "-rules"
vim.env.BONSAI_RULES = rules

test(
  "only the global rules index is loaded into each chat, besides the project's AGENTS.md",
  function()
    local files = cc.opts().rules.bonsai.files
    local index
    for _, f in ipairs(files) do
      if type(f) == "table" and f.files == "INDEX.md" then
        index = f
      end
    end
    truthy(index, "INDEX.md entry")
    eq(index.path, rules, "rules folder")
  end
)

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
  eq(ask { args = { command = "view", path = "/rules" } }, false, "view")
  for _, command in ipairs { "create", "str_replace", "insert", "delete", "rename" } do
    eq(ask { args = { command = command, path = "/rules/x.md" } }, true, command)
  end
  eq(ask { args = {} }, true, "unknown asks")
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
    table.insert(results, {
      title = "T" .. i,
      url = "https://example.com/" .. i,
      content = "snippet " .. i,
      engine = "x",
    })
  end
  local out = sx.methods.tools.web_search.callback(
    sx,
    { status = 200, body = vim.json.encode { results = results } }
  )
  eq(out.status, "success", "status")
  eq(#out.content, 8, "count")
  eq(
    out.content[1],
    { title = "T1", url = "https://example.com/1", content = "snippet 1" },
    "first"
  )
end)

test("a SearXNG error, a non-JSON answer or no results come back as clear errors", function()
  local sx = require("bonsai.searxng")
  local cb = sx.methods.tools.web_search.callback
  local down = cb(sx, { status = 502, body = "" })
  eq(down.status, "error", "502")
  truthy(down.content:find("searxng", 1, true), "says how to check SearXNG")
  eq(cb(sx, { status = 200, body = "<html>" }).status, "error", "not JSON")
  local none = cb(sx, { status = 200, body = vim.json.encode { results = {} } })
  eq(none.status, "error", "no results")
  eq(none.content, "No results found", "no-results message")
end)

-- ---- the Claude Code-style layout, the animated logo and plant words (owner, 2026-11-21: "approaved") ----

test("plant words: each state's pool is the agreed list", function()
  local words = require("bonsai.ui.words")
  eq(words.POOLS.thinking, {
    "Photosynthesizing",
    "Germinating",
    "Sprouting",
    "Taking root",
    "Budding",
    "Pollinating",
    "Composting",
  }, "thinking")
  eq(
    words.POOLS.working,
    { "Pruning", "Repotting", "Grafting", "Wiring branches", "Weeding", "Mulching", "Watering" },
    "working"
  )
  eq(
    words.POOLS.speaking,
    { "Blossoming", "Unfurling", "Leafing out", "Branching out", "Flowering" },
    "speaking"
  )
  eq(words.POOLS.listening, { "Soaking it in", "Drinking it in", "Rooting around" }, "listening")
  eq(words.POOLS.success, { "In full bloom", "Harvested", "Bore fruit" }, "success")
  for state, pool in pairs(words.POOLS) do
    for i = 1, 20 do
      truthy(vim.tbl_contains(pool, words.pick(state)), state .. " pick")
    end
  end
end)

test("the status line reads like Claude Code's, with plant words", function()
  local status = require("bonsai.ui.status")
  eq(
    status.format {
      state = "thinking",
      word = "Photosynthesizing",
      elapsed = 12,
      tokens = 1234,
      effort = "high",
      thinking = true,
    },
    "Photosynthesizing… (12s · ↓ ~1.2k tokens · thinking with high effort)",
    "thinking"
  )
  eq(
    status.format {
      state = "speaking",
      word = "Blossoming",
      elapsed = 65,
      tokens = 850,
      effort = "medium",
      thinking = false,
    },
    "Blossoming… (1m 5s · ↓ ~850 tokens · medium effort)",
    "speaking"
  )
  eq(
    status.format {
      state = "success",
      word = "In full bloom",
      elapsed = 14,
      tokens = 2300,
      effort = "high",
      thinking = true,
    },
    "In full bloom ✓ (14s · ↓ ~2.3k tokens · thinking with high effort)",
    "success"
  )
  eq(status.format { state = "listening", word = "Soaking it in" }, "Soaking it in…", "listening")
  -- Changed 2026-11-21: the idle line now also says where to type (owner couldn't find the input).
  eq(
    status.format { state = "idle", effort = "medium" },
    "Ready · /effort: medium · type below and press Enter",
    "idle"
  )
end)

test("the animation follows what Bonsai is doing", function()
  local status = require("bonsai.ui.status")
  local now, timers, seen = 100, {}, {}
  local m = status.new {
    clock = function()
      return now
    end,
    after = function(ms, fn)
      table.insert(timers, { ms = ms, fn = fn })
    end,
    on_change = function(state)
      table.insert(seen, state)
    end,
  }
  eq(m:state(), "idle", "starts idle")
  m:event("InputChanged", { text = "hi" })
  eq(m:state(), "listening", "typing")
  m:event("InputChanged", { text = "" })
  eq(m:state(), "idle", "cleared input")
  m:event("ChatSubmitted")
  eq(m:state(), "thinking", "submitted")
  now = 103
  m:event("RequestStreaming")
  eq(m:state(), "speaking", "streaming")
  m:event("ToolStarted")
  eq(m:state(), "working", "tool")
  m:event("ToolApprovalRequested")
  eq(m:state(), "listening", "approval asked")
  m:event("ToolApprovalFinished")
  eq(m:state(), "working", "approved")
  m:event("ToolFinished")
  eq(m:state(), "thinking", "tool done")
  now = 112
  eq(m:elapsed(), 12, "seconds since the message was sent")
  m:event("ChatDone")
  eq(m:state(), "success", "done")
  eq(timers[#timers].ms, 3840, "success plays once: 48 frames x 80 ms")
  timers[#timers].fn()
  eq(m:state(), "idle", "then idle")
  m:event("ChatSubmitted")
  m:event("ChatStopped")
  eq(m:state(), "idle", "stopped")
  truthy(#seen > 5, "changes reported")
end)

test("kitty uploads each state once and loops it itself", function()
  local kitty = require("bonsai.ui.kitty")
  local files = kitty.frames("thinking")
  eq(#files, 48, "frames")
  local id = kitty.image_id("thinking")
  local cmds = kitty.upload_commands("thinking", files)
  eq(#cmds, 50, "1 + 47 frames + gap + start")
  local function has(cmd, ...)
    for _, k in ipairs { ... } do
      if not cmd:find(k, 1, true) then
        return false
      end
    end
    return true
  end
  truthy(
    cmds[1]:sub(1, 3) == "\27_G" and has(cmds[1], "a=t", "f=100", "t=f", "i=" .. id, "q=2"),
    "first frame: " .. cmds[1]:sub(1, 60)
  )
  truthy(cmds[1]:find(vim.base64.encode(files[1]), 1, true), "first frame is read from its file")
  for i = 2, 48 do
    truthy(has(cmds[i], "a=f", "f=100", "t=f", "i=" .. id, "z=80"), "frame " .. i)
  end
  truthy(has(cmds[49], "a=a", "i=" .. id, "r=1", "z=80"), "first frame's gap")
  truthy(has(cmds[50], "a=a", "i=" .. id, "s=3", "v=1"), "loops forever")
  local once = kitty.upload_commands("success", kitty.frames("success"))
  truthy(has(once[50], "s=3", "v=2"), "success plays once")
end)

test("the logo sits in text cells as kitty placeholders, 4 wide and 2 tall", function()
  local kitty = require("bonsai.ui.kitty")
  local id = kitty.image_id("idle")
  eq(kitty.hl_color(id), ("#%06x"):format(id), "the colour carries the image id")
  local lines = kitty.placeholder_lines(4, 2)
  eq(#lines, 2, "rows")
  local p, d = "\u{10EEEE}", { "\u{0305}", "\u{030D}", "\u{030E}", "\u{0310}" }
  eq(
    lines[1],
    p .. d[1] .. d[1] .. p .. d[1] .. d[2] .. p .. d[1] .. d[3] .. p .. d[1] .. d[4],
    "row 1"
  )
  eq(
    lines[2],
    p .. d[2] .. d[1] .. p .. d[2] .. d[2] .. p .. d[2] .. d[3] .. p .. d[2] .. d[4],
    "row 2"
  )
  truthy(
    kitty.placement_command(id, 4, 2):find("a=p,U=1,i=" .. id .. ",c=4,r=2", 1, true),
    "virtual placement"
  )
end)

test("all 288 frames are in the config's assets", function()
  local kitty = require("bonsai.ui.kitty")
  local total = 0
  for _, state in ipairs(kitty.STATES) do
    for _, f in ipairs(kitty.frames(state)) do
      truthy(vim.uv.fs_stat(f), f)
      total = total + 1
    end
  end
  eq(total, 288, "frames")
end)

-- A stand-in chat, so the layout can be tested without a model.
local made = {}
local function fake_chat()
  local chat = { bufnr = vim.api.nvim_create_buf(false, true), sent = {}, submitted = 0 }
  function chat:add_buf_message(msg)
    table.insert(self.sent, msg)
  end
  function chat:submit()
    self.submitted = self.submitted + 1
  end
  table.insert(made, chat)
  return chat
end

test(
  "the layout: transcript, status line with the logo, and an input box with the hints",
  function()
    local ui = require("bonsai.ui")
    ui.set_chat_factory(function(win)
      local c = fake_chat()
      vim.api.nvim_win_set_buf(win, c.bufnr)
      return c
    end)
    ui.open()
    local w = ui.windows()
    for _, name in ipairs { "transcript", "status", "input" } do
      truthy(w[name] and vim.api.nvim_win_is_valid(w[name]), name)
    end
    local t = vim.api.nvim_win_get_config(w.transcript)
    truthy(
      vim.inspect(t.title):find("Bonsai", 1, true) and vim.inspect(t.title):find("effort", 1, true),
      "title: " .. vim.inspect(t.title)
    )
    eq(
      vim.api.nvim_win_get_buf(w.transcript),
      made[#made].bufnr,
      "the chat is in the transcript window"
    )
    eq(vim.api.nvim_win_get_height(w.status), 2, "status is 2 lines (the logo's height)")
    local i = vim.api.nvim_win_get_config(w.input)
    truthy(
      vim.inspect(i.footer):find("Ctrl+A", 1, true)
        and vim.inspect(i.footer):find("/effort", 1, true),
      "hints: " .. vim.inspect(i.footer)
    )
    eq(vim.api.nvim_get_current_win(), w.input, "the cursor starts in the input box")
  end
)

-- Added 2026-11-21: the owner launched the agent and asked "where can I chat with the agent?":
-- the input box was an empty box with no prompt, and the transcript had line numbers.
test(
  "the input box says what to do when it's empty, and the transcript has no line numbers",
  function()
    local ui = require("bonsai.ui")
    local w = ui.windows()
    local buf = vim.api.nvim_win_get_buf(w.input)
    local ns = vim.api.nvim_create_namespace("bonsai_input_hint")
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
    truthy(#marks == 1, "one placeholder")
    local text = marks[1][4].virt_text[1][1]
    truthy(
      text:find("Ask Bonsai", 1, true) and text:find("Enter", 1, true),
      "placeholder: " .. text
    )
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "hello" })
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
    eq(#vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}), 0, "gone while typing")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
    eq(#vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}), 1, "back when empty")
    eq(vim.wo[w.transcript].number, false, "no line numbers")
    eq(vim.wo[w.transcript].relativenumber, false, "no relative numbers")
    eq(
      require("bonsai.ui.status").format { state = "idle", effort = "medium" },
      "Ready · /effort: medium · type below and press Enter",
      "idle text"
    )
  end
)

test("Ctrl+A hides the layout and brings back the same chat", function()
  local ui = require("bonsai.ui")
  local chat = made[#made]
  ui.toggle()
  eq(ui.is_open(), false, "hidden")
  ui.toggle()
  eq(ui.is_open(), true, "shown")
  eq(vim.api.nvim_win_get_buf(ui.windows().transcript), chat.bufnr, "same chat")
end)

test("the input box sends messages to the chat, and handles /effort and /clear", function()
  local ui = require("bonsai.ui")
  local effort = require("bonsai.effort")
  local chat = made[#made]
  ui.submit("fix the off-by-one @{agent}")
  eq(chat.sent[#chat.sent], { role = "user", content = "fix the off-by-one @{agent}" }, "message")
  eq(chat.submitted, 1, "submitted")
  local picked, orig = false, effort.pick
  effort.pick = function()
    picked = true
  end
  ui.submit("/effort")
  effort.pick = orig
  eq(picked, true, "/effort opens the picker")
  eq(chat.submitted, 1, "/effort is not sent to Bonsai")
  local before = #made
  ui.submit("/clear")
  eq(#made, before + 1, "/clear starts a new chat")
end)

test("a tool waiting for approval moves the cursor to the transcript, then back", function()
  local ui = require("bonsai.ui")
  vim.api.nvim_exec_autocmds("User", { pattern = "CodeCompanionToolApprovalRequested", data = {} })
  eq(vim.api.nvim_get_current_win(), ui.windows().transcript, "to the prompt")
  vim.api.nvim_exec_autocmds("User", { pattern = "CodeCompanionToolApprovalFinished", data = {} })
  eq(vim.api.nvim_get_current_win(), ui.windows().input, "back to the input box")
  ui.close()
end)

test(
  "the terminal agent opens full-screen, and asks for a project folder when started in home",
  function()
    local ui = require("bonsai.ui")
    local sandbox = require("bonsai.sandbox")
    sandbox.set_root(project)
    ui.open { fullscreen = true }
    truthy(vim.api.nvim_win_get_width(ui.windows().transcript) >= vim.o.columns - 2, "full width")
    ui.close()
    local history = vim.fn.tempname()
    vim.fn.writefile({ project, real_home, "/does/not/exist" }, history)
    eq(ui.project_choices(history), { project }, "existing folders only, never home")
  end
)

-- ---- plugin list ----

test("Copilot is gone and codecompanion is in the plugin list", function()
  local path = vim.fn.stdpath("config") .. "/lua/plugin_specs.lua"
  local text = table.concat(vim.fn.readfile(path), "\n")
  eq(text:find("CopilotChat", 1, true), nil, "CopilotChat")
  eq(text:find("copilot.lua", 1, true), nil, "copilot.lua")
  truthy(text:find("olimorris/codecompanion.nvim", 1, true), "codecompanion spec")
end)

test("codecompanion loads and its commands exist", function()
  require("lazy").load { plugins = { "codecompanion.nvim" } }
  truthy(vim.fn.exists(":CodeCompanionChat") == 2, ":CodeCompanionChat")
end)

for _, line in ipairs(results) do
  print(line)
end
print(("%d passed, %d failed"):format(#results - failed, failed))
vim.cmd(failed > 0 and "cquit 1" or "qall!")
