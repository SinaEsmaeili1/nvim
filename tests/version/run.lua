-- Tests for the minimum Neovim version, 0.12.0
-- (contract: ~/Documents/projects/NEOVIM-AGENT.md, Addendum 7).
-- Run in the sandbox, which loads this config:
--   NVIM_APPNAME=nvim-min-version nvim --headless -c "luafile tests/version/run.lua"
-- Prints one line per test and exits 1 if any test fails.

local results, failed = {}, 0

-- Never hang: give up after 30 s.
vim.defer_fn(function()
  print("TIMEOUT: tests did not finish")
  vim.cmd("cquit 2")
end, 30000)

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

local function read(path)
  local f = assert(io.open(CONFIG .. "/" .. path, "r"))
  local text = f:read("*a")
  f:close()
  return text
end

-- The version init.lua asks for.
local function expected()
  return read("init.lua"):match('local expected_version = "(.-)"')
end

-- Runs the config's startup check as if this were Neovim `pretend`, and
-- returns the warnings it showed.
local function warnings_on(pretend)
  local utils = require("utils")
  local mt = getmetatable(vim.version)
  local orig_call, orig_echo = mt.__call, vim.api.nvim_echo
  local shown = {}
  mt.__call = function()
    return vim.version.parse(pretend)
  end
  vim.api.nvim_echo = function(chunks)
    table.insert(shown, chunks[1][1])
  end
  local ok, err = pcall(utils.is_compatible_version, expected())
  mt.__call, vim.api.nvim_echo = orig_call, orig_echo
  assert(ok, err)
  return shown
end

test("init.lua asks for Neovim 0.12.0 or newer", function()
  eq(expected(), "0.12.0", "expected_version")
end)

test("Neovim 0.12.0, 0.12.6, 0.13.0 and 1.0.0 start without a warning", function()
  for _, v in ipairs { "0.12.0", "0.12.6", "0.13.0", "1.0.0" } do
    eq(warnings_on(v), {}, "warnings on " .. v)
  end
end)

test("an older Neovim gets a warning that names 0.12.0 or newer", function()
  local shown = warnings_on("0.11.5")
  eq(#shown, 1, "warnings on 0.11.5")
  truthy(shown[1]:find("0.12.0 or newer", 1, true), "the minimum is named in: " .. shown[1])
  truthy(shown[1]:find("0.11.5", 1, true), "the version in use is named in: " .. shown[1])
end)

test("the README says Neovim 0.12 or newer", function()
  truthy(read("README.md"):find("Neovim 0.12 or newer", 1, true), "README")
end)

for _, line in ipairs(results) do
  print(line)
end
print(("%d passed, %d failed"):format(#results - failed, failed))
vim.cmd(failed > 0 and "cquit 1" or "qall!")
