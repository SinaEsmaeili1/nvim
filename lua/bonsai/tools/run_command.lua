-- codecompanion's run_command, with every command run inside the sandbox
-- (bonsai.sandbox): only the project folder is writable, no network, no
-- privilege escalation. Each command still waits for the owner's yes.
local sandbox = require("bonsai.sandbox")
local base = require("codecompanion.interactions.chat.tools.builtin.run_command")

local tool = vim.tbl_extend("force", {}, base)
tool.handlers = vim.tbl_extend("force", {}, base.handlers)

tool.handlers.setup = function(self, meta)
  local args = self.args
  local cmd
  if sandbox.usable() then
    cmd = { cmd = sandbox.wrap(args.cmd) }
  else
    -- Too wide a folder: run nothing but a message.
    cmd = { cmd = { "/bin/sh", "-c", "echo " .. vim.fn.shellescape(sandbox.refusal(args.cmd)) .. " >&2; exit 1" } }
  end
  if args.flag and args.flag ~= vim.NIL then
    cmd.flag = args.flag
  end
  table.insert(self.cmds, cmd)
end

return tool
