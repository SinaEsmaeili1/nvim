-- A terminal panel at the bottom of the screen, toggled with Ctrl+T (mapped in mappings.lua).
-- Hiding the panel keeps the shell running, so its history and state are there when it reopens.
-- The shell starts in Nvim's working directory.
local M = {}

local height = 15
local buf = nil

local function shell_running()
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return false
  end
  local job = vim.b[buf].terminal_job_id
  return job ~= nil and vim.fn.jobwait({ job }, 0)[1] == -1
end

local function panel_win()
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return nil
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == buf then
      return win
    end
  end
end

local function hide(win)
  if #vim.api.nvim_tabpage_list_wins(0) > 1 then
    vim.api.nvim_win_hide(win)
  else
    -- the panel is the only window left: show another buffer in it instead of closing Nvim
    vim.api.nvim_win_call(win, function()
      if vim.fn.bufnr("#") > 0 and vim.fn.bufnr("#") ~= buf then
        vim.cmd("buffer #")
      else
        vim.cmd.enew()
      end
    end)
  end
end

--- Open a full-width window at the bottom of the screen showing buffer `b`.
local function open_window(b)
  local win = vim.api.nvim_open_win(b, true, { split = "below", win = -1, height = height })
  vim.wo[win].winfixheight = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  return win
end

function M.toggle()
  local win = panel_win()
  if win then
    hide(win)
    return
  end

  if shell_running() then
    open_window(buf)
    vim.cmd.startinsert()
    return
  end

  -- start a new shell; a finished one (e.g., after `exit`) is replaced
  if buf and vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_delete(buf, { force = true })
  end
  local placeholder = vim.api.nvim_create_buf(false, true)
  vim.bo[placeholder].bufhidden = "wipe"
  open_window(placeholder)
  vim.cmd.terminal() -- the TermOpen autocmd in custom-autocmd.lua starts insert mode

  buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].buflisted = false
  vim.bo[buf].bufhidden = "hide"
  -- Ctrl+T inside the panel hides it; only in this buffer, so other terminals
  -- (e.g., fzf pickers, where Ctrl+T opens a file in a new tab) keep their Ctrl+T
  vim.keymap.set("t", "<C-t>", M.toggle, { buffer = buf, desc = "hide terminal panel" })
end

return M
