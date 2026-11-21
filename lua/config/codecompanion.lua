-- Bonsai as a coding agent in Neovim, through codecompanion.nvim
-- (contract: ~/Documents/projects/NEOVIM-AGENT.md).
-- Bonsai runs locally (bonsai-serve, localhost:8089). Reading and searching
-- are free; every edit and every shell command waits for my yes.
local effort = require("bonsai.effort")
local notes = require("bonsai.notes")

local M = {}

M.URL = "http://127.0.0.1:8089"

-- The server's key, which bonsai-serve keeps next to its effort level (contract:
-- NEOVIM-AGENT.md, Addendum 3). Read for every request and never logged.
function M.api_key()
  local f = io.open(vim.fs.joinpath(vim.fs.dirname(effort.state_file()), "api-key"), "r")
  local key = f and vim.trim(f:read("*a") or "") or ""
  if f then f:close() end
  return key
end

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
      -- The server answers only requests that carry its key.
      api_key = function() return M.api_key() end,
    },
    schema = {
      -- llama-server serves one model whatever the name says, so the model
      -- list is never asked for. Its context size is the effort level's, so
      -- trimming and summarising (context_management) scale with /effort.
      model = {
        default = "bonsai",
        choices = function()
          return { bonsai = { formatted_name = "Bonsai", meta = { context_window = effort.current().ctx } } }
        end,
      },
    },
    handlers = {
      form_parameters = M.handlers.form_parameters,
      form_messages = M.handlers.form_messages,
    },
  })
end

function M.opts()
  return {
    -- The chat is drawn inside Bonsai's own panel (bonsai.ui), in the window it is given.
    display = { chat = { window = { layout = "buffer" } } },
    -- Only a project's own AGENTS.md or .rules reach Bonsai, never
    -- ~/.claude/CLAUDE.md or other Claude-specific files (owner, 2026-11-21).
    -- They'd use up its 16-32K context and aren't written for it.
    rules = {
      bonsai = {
        description = "The project's own agent rules",
        files = {
          { path = "AGENTS.md", parser = "claude" },
          ".rules",
          -- Only the index of Bonsai's global notes; notes are read on demand.
          { path = notes.rules_dir(), files = "INDEX.md" },
        },
      },
      opts = { chat = { autoload = "bonsai" } },
    },
    adapters = {
      http = {
        bonsai = bonsai_adapter,
        -- Web search through the owner's own SearXNG (no API, no key).
        searxng = function()
          return require("bonsai.searxng")
        end,
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
        opts = {
          -- Keep chats small: trim old tool output at half the context, and
          -- summarise the chat at 70% (the context is the effort level's).
          context_management = {
            editing = { trigger = 0.5 },
            compaction = { trigger = 0.7 },
          },
        },
        tools = {
          opts = {
            approval_mode = "ask", -- never auto or yolo by default
            -- Every tool's description costs context, so only the notes tool
            -- is on by default; add others per task (for example @{agent}).
            default_tools = { "memory" },
          },
          -- Bonsai's notes, as /rules. Reading is free; every write asks first.
          ["memory"] = {
            opts = {
              whitelist = { { path = notes.rules_dir(), as = "/rules" } },
              require_approval_before = function(tool)
                local command = tool and tool.args and tool.args.command
                return command ~= "view"
              end,
            },
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
          ["web_search"] = { opts = { require_approval_before = true, adapter = "searxng" } },
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
          -- Diagnostics open the file they're given, so they pass the file guard too. Search and
          -- git tools work in Neovim's current folder, so they run only while it's in the project.
          ["get_diagnostics"] = { path = "bonsai.tools.get_diagnostics" },
          ["grep_search"] = { path = "bonsai.tools.grep_search" },
          ["file_search"] = { path = "bonsai.tools.file_search" },
          ["get_changed_files"] = { path = "bonsai.tools.get_changed_files" },
        },
      },
      inline = { adapter = "bonsai" },
    },
  }
end

function M.setup()
  notes.ensure_index()
  require("codecompanion").setup(M.opts())
end

return M
