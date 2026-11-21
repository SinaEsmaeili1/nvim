-- Bonsai as a coding agent in Neovim, through codecompanion.nvim
-- (contract: ~/Documents/projects/NEOVIM-AGENT.md).
-- Bonsai runs locally (bonsai-serve, localhost:8089). Reading and searching
-- are free; every edit and every shell command waits for my yes.
local effort = require("bonsai.effort")

local M = {}

M.URL = "http://127.0.0.1:8089"

M.handlers = {
  -- Thinking follows the effort level, and is sent with every request.
  form_parameters = function(self, params, messages)
    params = vim.deepcopy(params or {})
    params.chat_template_kwargs = { enable_thinking = effort.thinking() }
    return params
  end,

  -- Bonsai is Qwen3.5-based, and llama.cpp rejects a request whose system
  -- messages aren't all at the top ("System message must be at the
  -- beginning"). Tools add system messages later on, so they are merged into
  -- one at the top (codecompanion's guide, running-local-models.md).
  form_messages = function(self, messages)
    local merged = require("codecompanion.adapters.utils").merge_system_messages(messages)
    return require("codecompanion.adapters.http.openai_compatible").handlers.form_messages(self, merged)
  end,
}

local function bonsai_adapter()
  return require("codecompanion.adapters").extend("openai_compatible", {
    name = "bonsai",
    formatted_name = "Bonsai",
    env = {
      url = M.URL,
      api_key = "local", -- llama-server on localhost needs no key
    },
    schema = {
      -- llama-server serves one model whatever the name says, so the model
      -- list is never asked for.
      model = { default = "bonsai", choices = { "bonsai" } },
    },
    handlers = {
      form_parameters = M.handlers.form_parameters,
      form_messages = M.handlers.form_messages,
    },
  })
end

function M.opts()
  return {
    -- Only a project's own AGENTS.md or .rules reach Bonsai, never
    -- ~/.claude/CLAUDE.md or other Claude-specific files (owner, 2026-11-21).
    -- They'd use up its 16-32K context and aren't written for it.
    rules = {
      bonsai = {
        description = "The project's own agent rules",
        files = {
          { path = "AGENTS.md", parser = "claude" },
          ".rules",
        },
      },
      opts = { chat = { autoload = "bonsai" } },
    },
    adapters = {
      http = {
        bonsai = bonsai_adapter,
        opts = { show_presets = false },
      },
    },
    interactions = {
      chat = {
        adapter = "bonsai",
        slash_commands = {
          ["effort"] = {
            description = "Bonsai effort: more context, and thinking at high and max",
            callback = function(chat)
              effort.pick()
            end,
            opts = { contains_code = false },
          },
        },
        tools = {
          opts = {
            approval_mode = "ask", -- never auto or yolo by default
          },
          ["run_command"] = {
            path = "bonsai.tools.run_command", -- runs inside the sandbox
            opts = {
              require_approval_before = true,
              require_cmd_approval = true,
              safe_commands = {}, -- no command runs without asking
            },
          },
          -- Every website needs the owner's approval first (owner, 2026-11-21).
          -- Pages are read locally with markitdown, never through a third party.
          ["web_search"] = { opts = { require_approval_before = true } },
          ["fetch_webpage"] = { opts = { require_approval_before = true, adapter = "markitdown" } },
          -- File tools refuse paths outside the project folder (bonsai.sandbox).
          ["read_file"] = { path = "bonsai.tools.read_file" },
          ["edit_file"] = {
            path = "bonsai.tools.edit_file",
            opts = { require_approval_before = { buffer = true, file = true } },
          },
          ["create_file"] = { path = "bonsai.tools.create_file", opts = { require_approval_before = true } },
          ["overwrite_file"] = { path = "bonsai.tools.overwrite_file", opts = { require_approval_before = true } },
          ["delete_file"] = { path = "bonsai.tools.delete_file", opts = { require_approval_before = true } },
        },
      },
      inline = { adapter = "bonsai" },
    },
  }
end

function M.setup()
  require("codecompanion").setup(M.opts())
end

return M
