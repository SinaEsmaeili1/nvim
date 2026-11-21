-- Wraps one of codecompanion's search or git tools. They work in Neovim's
-- current folder, so they run only while that folder is inside the project
-- (bonsai.sandbox). Contract: NEOVIM-AGENT.md, Addendum 3, B2 and B4.
local sandbox = require("bonsai.sandbox")

return function(module)
  local base = require(module)
  local tool = vim.tbl_extend("force", {}, base)
  tool.cmds = {}
  for i, run in ipairs(base.cmds) do
    tool.cmds[i] = function(self, args, opts)
      local reason = sandbox.folder_refusal()
      if reason then
        return opts.output_cb { status = "error", data = reason }
      end
      return run(self, args, opts)
    end
  end
  return tool
end
