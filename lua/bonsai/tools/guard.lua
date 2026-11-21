-- Wraps one of codecompanion's file tools so it refuses anything outside the
-- project folder (bonsai.sandbox). The tool's own approvals still apply.
-- Contract: NEOVIM-AGENT.md, Addendum 3, B1 to B3.
local sandbox = require("bonsai.sandbox")

local function is_path_name(name)
  return type(name) == "string" and name:lower():find("path", 1, true) ~= nil
end

-- The tool's own path arguments, from its schema. A tool without one can't be
-- guarded, so wrapping it fails loudly instead of letting every call through.
local function path_params(tool, module)
  local properties = vim.tbl_get(tool, "schema", "function", "parameters", "properties") or {}
  local names = vim.tbl_filter(is_path_name, vim.tbl_keys(properties))
  if #names == 0 then
    error(("bonsai.tools.guard: %s has no path argument, so it can't be guarded"):format(module), 0)
  end
  return names
end

-- Why a call is refused, or nil when every path it names is inside the project.
-- Paths are resolved the way the plugin opens them: from Neovim's current folder.
local function refusal(params, args)
  local folder = sandbox.folder_refusal()
  if folder then return folder end
  args = type(args) == "table" and args or {}
  local given = vim.iter(params):any(function(name) return args[name] ~= nil end)
  if not given then return "Refused: no file path was given." end
  for name, value in pairs(args) do
    if is_path_name(name) then
      if type(value) ~= "string" or value == "" then
        return ("Refused: `%s` is not a file path."):format(name)
      end
      if not sandbox.inside(vim.fs.abspath(value)) then return sandbox.refusal(value) end
    end
  end
end

return function(module)
  local base = require(module)
  local params = path_params(base, module)
  local tool = vim.tbl_extend("force", {}, base)
  tool.cmds = {}
  for i, run in ipairs(base.cmds) do
    tool.cmds[i] = function(self, args, opts)
      local reason = refusal(params, args)
      if reason then
        return opts.output_cb({ status = "error", data = reason })
      end
      return run(self, args, opts)
    end
  end
  return tool
end
