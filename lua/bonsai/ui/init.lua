-- Bonsai's chat in a Claude Code-style layout (owner approved, 2026-11-21):
--   transcript   codecompanion's chat buffer, in a bordered window titled with the effort
--   status       the animated Bonsai logo (2 lines) + plant word, time, tokens, effort
--   input        a bordered box to type in, with the hints underneath
-- In the editor it sits on the right (Ctrl+A shows or hides it); the terminal
-- agent (bonsai-agent) opens it full-screen. Rules, approvals and the sandbox
-- are the chat's own and don't change here.
local effort = require("bonsai.effort")
local sandbox = require("bonsai.sandbox")
local status = require("bonsai.ui.status")
local kitty = require("bonsai.ui.kitty")

local M = {}

local LOGO_COLS, LOGO_ROWS = 4, 2
local INPUT_HEIGHT = 3
local HINTS = " Ctrl+A hide · /effort · @{agent} tools · ? help "
local AGENT_HINTS = " /exit quit · /effort · @{agent} tools · ? help "
local HELP = table.concat({
  "Bonsai: type a message and press Enter (Shift+Enter or Ctrl+J for a new line).",
  "/effort    change the effort: more context, and thinking at high and max",
  "/clear     start a new chat",
  "@{agent}   let Bonsai read, search and edit the project (every edit and command asks you)",
  "@{web_search}  search the web through your SearXNG (every search asks you)",
  "Ctrl+A     hide or show this panel (in the editor)",
}, "\n")

local S = {
  chat = nil,
  wins = {},
  input_buf = nil,
  status_buf = nil,
  fullscreen = false,
  agent = false,
  timer = nil,
  base_bytes = 0,
}

-- ---- the chat ----

-- codecompanion draws its chat in the window it is given (layout "buffer").
local function default_chat_factory(win)
  vim.api.nvim_set_current_win(win)
  return require("codecompanion").chat()
end

local chat_factory = default_chat_factory

-- For tests: make chats some other way.
function M.set_chat_factory(factory)
  chat_factory = factory
end

-- ---- the status line ----

local function chat_bytes()
  if not (S.chat and S.chat.bufnr and vim.api.nvim_buf_is_valid(S.chat.bufnr)) then
    return 0
  end
  local b = S.chat.bufnr
  return vim.api.nvim_buf_get_offset(b, vim.api.nvim_buf_line_count(b))
end

local machine

local function status_text()
  local level = effort.current()
  return status.format {
    state = machine:state(),
    word = machine.word,
    elapsed = machine.busy and machine:elapsed()
      or (machine:state() == "success" and machine:elapsed() or nil),
    tokens = (chat_bytes() - S.base_bytes) / 4, -- about four characters per token
    effort = level.name,
    thinking = level.thinking,
  }
end

local function render()
  local buf = S.status_buf
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  local state = machine:state()
  local logo
  if kitty.available() then
    kitty.ensure(state, LOGO_COLS, LOGO_ROWS)
    logo = kitty.placeholder_lines(LOGO_COLS, LOGO_ROWS)
    vim.api.nvim_set_hl(0, "BonsaiLogo", { fg = kitty.hl_color(kitty.image_id(state)) })
  else
    logo = { (" "):rep(LOGO_COLS), (" "):rep(LOGO_COLS) }
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { logo[1] .. " " .. status_text(), logo[2] })
  vim.bo[buf].modifiable = false
  local ns = vim.api.nvim_create_namespace("bonsai_logo")
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  if kitty.available() then
    for row = 0, LOGO_ROWS - 1 do
      vim.api.nvim_buf_set_extmark(
        buf,
        ns,
        row,
        0,
        { end_col = #logo[row + 1], hl_group = "BonsaiLogo" }
      )
    end
  end
end

local function stop_timer()
  if S.timer then
    S.timer:stop()
    S.timer:close()
    S.timer = nil
  end
end

local function start_timer()
  stop_timer()
  S.timer = vim.uv.new_timer()
  S.timer:start(
    1000,
    1000,
    vim.schedule_wrap(function()
      if machine.busy then
        render()
      else
        stop_timer()
      end
    end)
  )
end

machine = status.new {
  on_change = function()
    vim.schedule(render)
  end,
}

-- ---- windows ----

local function title()
  return {
    { " Bonsai ", "FloatTitle" },
    { "· /effort: " .. effort.current().name .. " ", "Comment" },
  }
end

local function geometry()
  local cols = vim.o.columns
  local lines = vim.o.lines - vim.o.cmdheight - 1
  local width = S.fullscreen and cols or math.max(50, math.floor(cols * 0.42))
  local inner = width - 2
  local transcript_h = math.max(5, lines - 2 - LOGO_ROWS - (INPUT_HEIGHT + 2))
  return {
    col = cols - width,
    inner = inner,
    transcript = { row = 0, height = transcript_h },
    status = { row = transcript_h + 2, height = LOGO_ROWS },
    input = { row = transcript_h + 2 + LOGO_ROWS, height = INPUT_HEIGHT },
  }
end

local function win_configs()
  local g = geometry()
  return {
    transcript = {
      relative = "editor",
      row = g.transcript.row,
      col = g.col,
      width = g.inner,
      height = g.transcript.height,
      border = "rounded",
      title = title(),
      title_pos = "left",
      zindex = 50,
    },
    status = {
      relative = "editor",
      row = g.status.row,
      col = g.col + 1,
      width = g.inner,
      height = g.status.height,
      style = "minimal",
      focusable = false,
      zindex = 50,
    },
    input = {
      relative = "editor",
      row = g.input.row,
      col = g.col,
      width = g.inner,
      height = g.input.height,
      border = "rounded",
      footer = { { S.agent and AGENT_HINTS or HINTS, "Comment" } },
      footer_pos = "left",
      zindex = 50,
    },
  }
end

local function valid(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

function M.is_open()
  return valid(S.wins.transcript)
end

function M.windows()
  return S.wins
end

local function focus_input()
  if valid(S.wins.input) then
    vim.api.nvim_set_current_win(S.wins.input)
    vim.cmd("startinsert!")
    -- Again once whatever is still closing (the project picker) is done, or the
    -- box is left in normal mode and typing runs commands instead of text.
    vim.defer_fn(function()
      if valid(S.wins.input) and vim.api.nvim_get_current_win() == S.wins.input then
        vim.cmd("startinsert!")
      end
    end, 50)
  end
end

local function scratch(name)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "hide"
  pcall(vim.api.nvim_buf_set_name, buf, name)
  return buf
end

-- A greyed-out hint in the empty input box, so it's clear where to type.
local hint_ns = vim.api.nvim_create_namespace("bonsai_input_hint")
local INPUT_HINT = "Ask Bonsai anything… (Enter to send · Shift+Enter for a new line)"

local function update_hint(buf)
  vim.api.nvim_buf_clear_namespace(buf, hint_ns, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  if #lines <= 1 and (lines[1] or "") == "" then
    vim.api.nvim_buf_set_extmark(
      buf,
      hint_ns,
      0,
      0,
      { virt_text = { { INPUT_HINT, "Comment" } }, virt_text_pos = "overlay" }
    )
  end
end

local function setup_input(buf)
  vim.bo[buf].filetype = "markdown"
  update_hint(buf)
  local function send()
    local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
    M.submit(text)
  end
  vim.keymap.set({ "i", "n" }, "<CR>", send, { buffer = buf, desc = "Bonsai: send" })
  vim.keymap.set("i", "<S-CR>", "<CR>", { buffer = buf, noremap = true, desc = "Bonsai: new line" })
  vim.keymap.set("i", "<C-j>", "<CR>", { buffer = buf, noremap = true, desc = "Bonsai: new line" })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = buf,
    callback = function()
      local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      update_hint(buf)
      machine:event("InputChanged", { text = vim.trim(text) })
    end,
  })
end

local function new_chat()
  S.chat = chat_factory(S.wins.transcript)
  S.base_bytes = chat_bytes()
end

function M.open(opts)
  opts = opts or {}
  if M.is_open() then
    return focus_input()
  end
  S.fullscreen = opts.fullscreen or false
  if not (S.input_buf and vim.api.nvim_buf_is_valid(S.input_buf)) then
    S.input_buf = scratch("bonsai://input")
    setup_input(S.input_buf)
  end
  if not (S.status_buf and vim.api.nvim_buf_is_valid(S.status_buf)) then
    S.status_buf = scratch("bonsai://status")
  end
  local cfg = win_configs()
  local placeholder = scratch("")
  S.wins.transcript = vim.api.nvim_open_win(
    (S.chat and S.chat.bufnr and vim.api.nvim_buf_is_valid(S.chat.bufnr)) and S.chat.bufnr
      or placeholder,
    true,
    cfg.transcript
  )
  if not (S.chat and S.chat.bufnr and vim.api.nvim_buf_is_valid(S.chat.bufnr)) then
    new_chat()
  end
  -- A clean transcript: no line numbers or gutters. Set after the chat opens,
  -- since codecompanion sets its own window options then.
  for opt, value in pairs {
    wrap = true,
    linebreak = true,
    number = false,
    relativenumber = false,
    signcolumn = "no",
    foldcolumn = "0",
  } do
    vim.wo[S.wins.transcript][opt] = value
  end
  if
    vim.api.nvim_buf_is_valid(placeholder)
    and vim.api.nvim_win_get_buf(S.wins.transcript) ~= placeholder
  then
    pcall(vim.api.nvim_buf_delete, placeholder, { force = true })
  end
  S.wins.status = vim.api.nvim_open_win(S.status_buf, false, cfg.status)
  S.wins.input = vim.api.nvim_open_win(S.input_buf, true, cfg.input)
  render()
  focus_input()
end

function M.close()
  stop_timer()
  for _, name in ipairs { "input", "status", "transcript" } do
    if valid(S.wins[name]) then
      pcall(vim.api.nvim_win_close, S.wins[name], true)
    end
    S.wins[name] = nil
  end
end

function M.toggle()
  if M.is_open() then
    M.close()
  else
    M.open()
  end
end

local function refresh_title()
  if valid(S.wins.transcript) then
    vim.api.nvim_win_set_config(S.wins.transcript, { title = title(), title_pos = "left" })
  end
  render()
end

-- What the input box sends: /effort, /clear, ? and /exit are handled here;
-- everything else goes to the chat (so @{tools} still work).
function M.submit(text)
  text = vim.trim(text or "")
  if text == "" then
    return
  end
  if text == "/effort" then
    return effort.pick(function()
      refresh_title()
    end)
  elseif text == "/clear" then
    new_chat()
    return render()
  elseif text == "?" then
    return vim.notify(HELP, vim.log.levels.INFO, { title = "Bonsai" })
  elseif text == "/exit" and S.agent then
    return vim.cmd("qall")
  end
  S.base_bytes = chat_bytes()
  S.chat:add_buf_message { role = "user", content = text }
  S.chat:submit()
end

-- ---- codecompanion's events drive the status line and the focus ----

local EVENTS = {
  "ChatSubmitted",
  "RequestStarted",
  "RequestStreaming",
  "ToolStarted",
  "ToolFinished",
  "ToolApprovalRequested",
  "ToolApprovalFinished",
  "ChatDone",
  "ChatStopped",
}

local group = vim.api.nvim_create_augroup("bonsai_ui", { clear = true })
for _, name in ipairs(EVENTS) do
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "CodeCompanion" .. name,
    callback = function(ev)
      local data = ev.data or {}
      if data.bufnr and S.chat and data.bufnr ~= S.chat.bufnr then
        return
      end
      machine:event(name, data)
      if name == "ChatSubmitted" then
        start_timer()
      end
      if not M.is_open() then
        return
      end
      if name == "ToolApprovalRequested" then
        -- The approval keys live in the chat buffer: go to the prompt.
        vim.cmd("stopinsert")
        vim.api.nvim_set_current_win(S.wins.transcript)
        vim.api.nvim_win_set_cursor(
          S.wins.transcript,
          { vim.api.nvim_buf_line_count(S.chat.bufnr), 0 }
        )
      elseif name == "ToolApprovalFinished" then
        focus_input()
      end
    end,
  })
end

vim.api.nvim_create_autocmd("VimResized", {
  group = group,
  callback = function()
    if not M.is_open() then
      return
    end
    local cfg = win_configs()
    for name, win in pairs(S.wins) do
      if valid(win) then
        vim.api.nvim_win_set_config(win, cfg[name])
      end
    end
  end,
})

-- ---- the terminal agent (bonsai-agent) ----

-- Project folders to offer when the agent starts somewhere too wide (home, /):
-- the editor's recent folders that still exist, never home or /.
function M.project_choices(history_path)
  history_path = history_path or vim.fs.joinpath(vim.fn.stdpath("state"), "recent_folders.txt")
  local home = vim.uv.fs_realpath(vim.uv.os_homedir())
  local out, seen = {}, {}
  local ok, lines = pcall(vim.fn.readfile, history_path)
  for _, dir in ipairs(ok and lines or {}) do
    local real = vim.uv.fs_realpath(vim.fs.normalize(dir))
    if
      real
      and real ~= home
      and real ~= "/"
      and not seen[real]
      and vim.fn.isdirectory(real) == 1
    then
      seen[real] = true
      table.insert(out, real)
    end
  end
  return out
end

local function start_agent()
  M.open { fullscreen = true }
  -- Start Bonsai at the saved effort if it isn't running yet.
  vim.system({ "bonsai-serve", "status" }, { text = true }, function(r)
    if (r.stdout or ""):find("is up", 1, true) then
      return
    end
    vim.schedule(function()
      local level = effort.current().name
      vim.notify("Starting Bonsai at effort " .. level .. "…", vim.log.levels.INFO)
      effort.set(level, function(ok, out)
        vim.notify(out, ok and vim.log.levels.INFO or vim.log.levels.ERROR)
      end)
    end)
  end)
end

-- bonsai-agent: Bonsai as a terminal coding agent, full-screen. Started from
-- the app menu it is in home, so it asks for a project folder first.
function M.agent_mode()
  S.agent = true
  if sandbox.usable() then
    return start_agent()
  end
  local choices = M.project_choices()
  if #choices == 0 then
    return vim.notify(
      "Open bonsai-agent inside a project folder (cd there first).",
      vim.log.levels.WARN
    )
  end
  local function open_project(dir)
    if not dir then
      return vim.cmd("qall")
    end
    vim.cmd.cd(dir)
    vim.g.bonsai_root = dir
    start_agent()
  end
  -- The same searchable picker as the dashboard's "Recently opened folders";
  -- Neovim's plain list if fzf-lua isn't there.
  local ok, fzf = pcall(require, "fzf-lua")
  if ok then
    local items = vim.tbl_map(function(d)
      return vim.fn.fnamemodify(d, ":~")
    end, choices)
    local picked = false
    return fzf.fzf_exec(items, {
      prompt = "Bonsai: which project?> ",
      winopts = {
        -- Closing the picker without a choice quits the agent, as the plain list does.
        on_close = function()
          vim.schedule(function()
            if not picked then
              vim.cmd("qall")
            end
          end)
        end,
      },
      actions = {
        ["default"] = function(selected)
          picked = selected ~= nil and selected[1] ~= nil
          open_project(picked and vim.fs.normalize(vim.fn.expand(selected[1])) or nil)
        end,
      },
    })
  end
  vim.ui.select(choices, {
    prompt = "Bonsai: which project?",
    format_item = function(d)
      return vim.fn.fnamemodify(d, ":~")
    end,
  }, open_project)
end

return M
