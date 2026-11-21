-- Wraps one of codecompanion's file tools so it refuses any path outside the
-- project folder (bonsai.sandbox). The tool's own approvals still apply.
local sandbox = require("bonsai.sandbox")

return function(module)
  local base = require(module)
  local tool = vim.tbl_extend("force", {}, base)
  tool.cmds = {}
  for i, run in ipairs(base.cmds) do
    tool.cmds[i] = function(self, args, opts)
      local path = args and args.filepath
      if path and (not sandbox.usable() or not sandbox.inside(path)) then
        return opts.output_cb({ status = "error", data = sandbox.refusal(path) })
      end
      return run(self, args, opts)
    end
  end
  return tool
end
