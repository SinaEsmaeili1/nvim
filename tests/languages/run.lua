-- Tests for C++/Java/Python parity and Hello World templates (contract: NEOVIM-AGENT.md, Addendum 4).
--   cd ~/.config/nvim-langs && NVIM_APPNAME=nvim-langs nvim --headless -c "luafile tests/languages/run.lua"
-- Prints one line per test and exits 1 if any test fails. Set LANGS_SKIP_JDTLS=1 to skip the jdtls attach test.

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
  if not v then error((what or "value") .. " is not true", 2) end
end

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local function write(path, text)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local f = assert(io.open(path, "w")); f:write(text); f:close()
end
local function buf_lines() return vim.api.nvim_buf_get_lines(0, 0, -1, false) end
local function term_text(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

-- ---- projects for the language servers (opened first so they start while the other tests run) ----
local proj = tmp .. "/proj"
vim.fn.mkdir(proj .. "/.git", "p")
write(proj .. "/hello.py", 'def main():\n    print("Hello, World!")\n\n\nmain()\n')
write(proj .. "/hello.cpp", '#include <iostream>\nint main() {\n    std::cout << "Hello, World!" << std::endl;\n}\n')
write(proj .. "/Main.java", 'public class Main {\n    public static void main(String[] args) {\n        System.out.println("Hello, World!");\n    }\n}\n')
write(proj .. "/pyproject.toml", "[project]\nname='x'\n")
write(proj .. "/compile_commands.json", "[]")

local lsp_bufs = {}
local servers = { cpp = "clangd", python = "pyright", java = "jdtls" }
local files = { cpp = "hello.cpp", python = "hello.py", java = "Main.java" }
local skip_jdtls = vim.env.LANGS_SKIP_JDTLS == "1"
for ft, file in pairs(files) do
  if not (ft == "java" and skip_jdtls) then
    vim.cmd("edit " .. proj .. "/" .. file)
    lsp_bufs[ft] = vim.api.nvim_get_current_buf()
  end
end

-- ---- <space>r mapping ----

local function map_callback(file)
  vim.cmd("edit " .. file)
  local m = vim.fn.maparg("<space>r", "n", false, true)
  return m.callback, m.buffer
end

test("<space>r is mapped in java, python and cpp buffers to one shared function", function()
  local rf = require("run_file")
  for _, file in ipairs { proj .. "/Main.java", proj .. "/hello.py", proj .. "/hello.cpp" } do
    local cb, buffer = map_callback(file)
    eq(buffer, 1, file .. " buffer-local")
    truthy(cb == rf.toggle, file .. " callback is run_file.toggle")
  end
end)

-- ---- run commands ----

test("python command is python3 -u <file>", function()
  eq(require("run_file").command("python", "/x/hello.py"), "python3 -u 'hello.py'")
end)

test("java command is java <file>", function()
  eq(require("run_file").command("java", "/x/Main.java"), "java 'Main.java'")
end)

test("cpp command builds with c++17 flags into the cache, runs only when the build works", function()
  local cmd = require("run_file").command("cpp", "/x/hello.cpp")
  truthy(cmd:match("^clang%+%+ ") or cmd:match("^g%+%+ "), "compiler")
  truthy(cmd:find("-std=c++17 -Wall -Wextra -g", 1, true), "flags")
  local cache = vim.fn.stdpath("cache")
  truthy(cmd:find(cache, 1, true), "output in cache")
  truthy(not cmd:find("/x/hello'", 1, true) or cmd:find(cache, 1, true), "not next to source")
  truthy(cmd:find("&&", 1, true), "run after build with &&")
end)

local function run_and_wait(file, want, secs)
  vim.cmd("only")
  vim.cmd("edit " .. file)
  require("run_file").toggle()
  local buf = vim.api.nvim_get_current_buf()
  eq(vim.bo[buf].buftype, "terminal", "run opens a terminal")
  eq(vim.api.nvim_win_get_height(0), 15, "terminal height")
  local ok = vim.wait((secs or 30) * 1000, function() return term_text(buf):find(want, 1, true) ~= nil end, 100)
  truthy(ok, "output has '" .. want .. "', got: " .. term_text(buf))
  return buf
end

local real = tmp .. "/real"
write(real .. "/hello.py", 'print("Hello, World!")\n')
write(real .. "/hello.cpp", '#include <iostream>\nint main() { std::cout << "Hello, World!" << std::endl; }\n')
write(real .. "/Main.java", 'public class Main { public static void main(String[] a) { System.out.println("Hello, World!"); } }\n')
write(real .. "/sleep.py", 'import time\nprint("started", flush=True)\ntime.sleep(60)\n')
write(real .. "/bad.cpp", 'int main() { this is not c++ }\n')

test("python run shows Hello, World! in the terminal", function() run_and_wait(real .. "/hello.py", "Hello, World!") end)
test("cpp run shows Hello, World! and leaves no binary next to the source", function()
  run_and_wait(real .. "/hello.cpp", "Hello, World!")
  eq(vim.fn.glob(real .. "/hello"), "", "binary next to source")
end)
test("java run shows Hello, World!", function() run_and_wait(real .. "/Main.java", "Hello, World!") end)

test("a failed cpp build does not run the program", function()
  local buf = run_and_wait(real .. "/bad.cpp", "error", 30)
  vim.wait(500)
  truthy(not term_text(buf):find("Hello", 1, true), "no program output")
end)

test("the next run replaces the old output buffer", function()
  local first = run_and_wait(real .. "/hello.py", "Hello, World!")
  vim.wait(1000, function() return false end, 100)
  vim.cmd("wincmd k")
  require("run_file").toggle()
  local second = vim.api.nvim_get_current_buf()
  -- let the second run finish, so the next test starts a run instead of stopping this one
  vim.wait(10000, function() return vim.fn.jobwait({ vim.b[second].terminal_job_id }, 0)[1] ~= -1 end, 50)
  truthy(first ~= second, "new buffer")
  truthy(not vim.api.nvim_buf_is_valid(first), "old output buffer is gone")
end)

test("<space>r stops a run, also from inside the terminal", function()
  local buf = run_and_wait(real .. "/sleep.py", "started")
  local job = vim.b[buf].terminal_job_id
  eq(vim.fn.jobwait({ job }, 0)[1], -1, "still running")
  local cb = vim.fn.maparg("<space>r", "t", false, true).callback
  truthy(cb, "terminal-mode <space>r mapping")
  cb()
  truthy(vim.wait(5000, function() return vim.fn.jobwait({ job }, 0)[1] ~= -1 end, 50), "run stopped")
  -- toggling from the source window while a run is going also stops
  vim.cmd("wincmd k")
  require("run_file").toggle()
  local buf2 = vim.api.nvim_get_current_buf()
  local job2 = vim.b[buf2].terminal_job_id
  vim.wait(1500, function() return false end, 100)
  vim.cmd("wincmd k")
  require("run_file").toggle()
  truthy(vim.wait(5000, function() return vim.fn.jobwait({ job2 }, 0)[1] ~= -1 end, 50), "second run stopped by toggle")
end)

-- ---- templates ----

local expected = {
  ["hello.py"] = { "def main():", '    print("Hello, World!")', "", "", 'if __name__ == "__main__":', "    main()" },
  ["hello.cpp"] = { "#include <iostream>", "", "int main() {", '    std::cout << "Hello, World!" << std::endl;', "    return 0;", "}" },
  ["Main.java"] = { "public class Main {", "    public static void main(String[] args) {", '        System.out.println("Hello, World!");', "    }", "}" },
  ["index.html"] = {
    "<!DOCTYPE html>", '<html lang="en">', "<head>", '    <meta charset="UTF-8">',
    '    <meta name="viewport" content="width=device-width, initial-scale=1.0">',
    "    <title>Hello, World!</title>", "</head>", "<body>", "    <h1>Hello, World!</h1>", "</body>", "</html>",
  },
}
local cursor_line = { ["hello.py"] = 2, ["hello.cpp"] = 4, ["Main.java"] = 3, ["index.html"] = 9 }

for name, text in pairs(expected) do
  test("new " .. name .. " gets the template, unmodified, cursor on the Hello line", function()
    local dir = tmp .. "/new_" .. name:gsub("%.", "_")
    vim.fn.mkdir(dir, "p")
    vim.cmd("only")
    vim.cmd("edit " .. dir .. "/" .. name)
    eq(buf_lines(), text, "lines")
    eq(vim.bo.modified, false, "modified")
    eq(vim.api.nvim_win_get_cursor(0)[1], cursor_line[name], "cursor line")
    eq(vim.uv.fs_stat(dir .. "/" .. name), nil, "file not written")
  end)
end

test("a Java file under src/main/java/com/example gets the package line first", function()
  local dir = tmp .. "/mvn/src/main/java/com/example"
  vim.fn.mkdir(dir, "p")
  vim.cmd("edit " .. dir .. "/App.java")
  eq(buf_lines(), {
    "package com.example;", "", "public class App {", "    public static void main(String[] args) {",
    '        System.out.println("Hello, World!");', "    }", "}",
  }, "lines")
  eq(vim.api.nvim_win_get_cursor(0)[1], 5, "cursor line")
  eq(vim.bo.modified, false, "modified")
end)

test("randomfile.java gets class randomfile, randomfile.py and randomfile.cpp get the template", function()
  local dir = tmp .. "/rand"
  vim.fn.mkdir(dir, "p")
  vim.cmd("edit " .. dir .. "/randomfile.java")
  eq(buf_lines()[1], "public class randomfile {", "java class")
  vim.cmd("edit " .. dir .. "/randomfile.py")
  eq(buf_lines(), expected["hello.py"], "python lines")
  vim.cmd("edit " .. dir .. "/randomfile.cpp")
  eq(buf_lines(), expected["hello.cpp"], "cpp lines")
end)

test("a new .js file starts with console.log(\"Hello, World!\"); cursor on it, unmodified", function()
  vim.cmd("edit " .. tmp .. "/anything.js")
  eq(buf_lines(), { 'console.log("Hello, World!");' }, "lines")
  eq(vim.api.nvim_win_get_cursor(0)[1], 1, "cursor line")
  eq(vim.bo.modified, false, "modified")
end)

test("neo-tree hook gives a new empty .js file the template", function()
  write(tmp .. "/tree_new.js", "")
  require("templates").fill_file(tmp .. "/tree_new.js")
  eq(vim.fn.readfile(tmp .. "/tree_new.js"), { 'console.log("Hello, World!");' }, "lines")
  write(tmp .. "/tree_old.js", "let a = 1\n")
  require("templates").fill_file(tmp .. "/tree_old.js")
  eq(vim.fn.readfile(tmp .. "/tree_old.js"), { "let a = 1" }, "untouched")
end)

test("an existing empty file opened with :e stays empty", function()
  write(tmp .. "/empty.py", "")
  vim.cmd("edit " .. tmp .. "/empty.py")
  eq(buf_lines(), { "" }, "lines")
  eq(vim.bo.modified, false, "modified")
end)

test("a new __init__.py stays empty", function()
  vim.cmd("edit " .. tmp .. "/__init__.py")
  eq(buf_lines(), { "" }, "lines")
end)

test("a new .txt file stays empty", function()
  vim.cmd("edit " .. tmp .. "/notes.txt")
  eq(buf_lines(), { "" }, "lines")
end)

test("neo-tree hook: new empty .py file gets the template, a file with content is left alone", function()
  local t = require("templates")
  write(tmp .. "/tree_new.py", "")
  t.fill_file(tmp .. "/tree_new.py")
  eq(vim.fn.readfile(tmp .. "/tree_new.py"), expected["hello.py"], "template written")
  write(tmp .. "/tree_old.py", "x = 1\n")
  t.fill_file(tmp .. "/tree_old.py")
  eq(vim.fn.readfile(tmp .. "/tree_old.py"), { "x = 1" }, "untouched")
  write(tmp .. "/__init__.py", "")
  t.fill_file(tmp .. "/__init__.py")
  eq(vim.fn.getfsize(tmp .. "/__init__.py"), 0, "__init__.py stays empty")
  write(tmp .. "/tree.txt", "")
  t.fill_file(tmp .. "/tree.txt")
  eq(vim.fn.getfsize(tmp .. "/tree.txt"), 0, ".txt stays empty")
end)

test("neo-tree has a file_added handler wired to the templates", function()
  local spec = io.open(vim.fn.stdpath("config") .. "/lua/plugin_specs.lua"):read("*a")
  truthy(spec:find('event = "file_added"', 1, true) and spec:find('require("templates").fill_file', 1, true), "handler in plugin_specs")
end)

-- ---- treesitter ----

test("treesitter highlighting is active for java, python, cpp and html", function()
  for _, f in ipairs { proj .. "/Main.java", proj .. "/hello.py", proj .. "/hello.cpp", tmp .. "/page.html" } do
    write(f, f:match("html$") and "<p>x</p>\n" or vim.fn.readfile(f)[1] and table.concat(vim.fn.readfile(f), "\n") or "")
    vim.cmd("edit " .. f)
    truthy(vim.wait(5000, function() return vim.treesitter.highlighter.active[vim.api.nvim_get_current_buf()] ~= nil end, 50),
      "highlighter active for " .. f)
  end
end)

-- ---- language servers ----

local function clients_for(buf, name)
  return vim.lsp.get_clients { bufnr = buf, name = name }
end

local wait_s = 40
vim.wait(wait_s * 1000, function()
  for ft, buf in pairs(lsp_bufs) do
    if #clients_for(buf, servers[ft]) == 0 then return false end
  end
  return true
end, 200)

for ft, name in pairs(servers) do
  test(name .. " attaches to a real " .. ft .. " file", function()
    if ft == "java" and skip_jdtls then
      error("skipped by LANGS_SKIP_JDTLS (not run)")
    end
    truthy(#clients_for(lsp_bufs[ft], name) > 0, name .. " attached within " .. wait_s .. " s")
  end)
end

test("attach setup is the same for all three: keymaps, completion capabilities, hints", function()
  local ref
  for ft, buf in pairs(lsp_bufs) do
    vim.api.nvim_set_current_buf(buf)
    local seen = {}
    for _, key in ipairs { "gd", "K", "<C-k>", "<space>rn", "<space>ca" } do
      seen[key] = vim.fn.maparg(key, "n", false, true).buffer == 1
    end
    for _, c in ipairs(clients_for(buf, servers[ft])) do
      truthy(c.capabilities.textDocument.completion.completionItem.snippetSupport, servers[ft] .. " snippet support")
    end
    seen.inlay = vim.lsp.inlay_hint.is_enabled { bufnr = buf }
    seen.ts = vim.treesitter.highlighter.active[buf] ~= nil
    if not ref then ref = seen else eq(seen, ref, ft .. " attach setup") end
    for k, v in pairs(seen) do if k ~= "inlay" then truthy(v, ft .. " " .. k) end end
  end
end)

-- ---- cleanup: no language server left behind ----
vim.lsp.stop_client(vim.lsp.get_clients(), true)
vim.wait(10000, function() return #vim.lsp.get_clients() == 0 end, 100)

for _, r in ipairs(results) do print(r) end
print(("%d passed, %d failed"):format(#results - failed, failed))
vim.fn.delete(tmp, "rf")
vim.cmd(failed == 0 and "qall!" or "cquit 1")
