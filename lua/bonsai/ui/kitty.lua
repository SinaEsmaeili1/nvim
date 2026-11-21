-- The animated Bonsai logo, drawn with kitty's graphics protocol.
-- Each state's 48 frames (assets/bonsai/frames/<state>/NN.png, split from the
-- atlas by tools/split_bonsai_atlas.py) are sent to kitty once, as one
-- animated image that kitty loops by itself: Neovim does no per-frame work.
-- The image sits in text cells through kitty's Unicode placeholders, so it
-- stays put when Neovim redraws. Without kitty and true colour there is no
-- logo; the status line shows the words alone.
local M = {}

M.STATES = { "idle", "listening", "thinking", "working", "speaking", "success" }
M.FRAMES = 48
M.FRAME_MS = 80

local ESC = "\27"
local BASE_ID = 0xB0A500 -- image ids 0xB0A501..0xB0A506, one per state

-- kitty's row and column diacritics for Unicode placeholders (the first 8).
local DIACRITICS =
  { "\u{0305}", "\u{030D}", "\u{030E}", "\u{0310}", "\u{0312}", "\u{033D}", "\u{033E}", "\u{033F}" }
local PLACEHOLDER = "\u{10EEEE}"

function M.image_id(state)
  for i, s in ipairs(M.STATES) do
    if s == state then
      return BASE_ID + i
    end
  end
end

-- The highlight colour that tells kitty which image a placeholder shows.
function M.hl_color(id)
  return ("#%06x"):format(id)
end

local function assets()
  return vim.fs.joinpath(vim.fn.stdpath("config"), "assets", "bonsai", "frames")
end

function M.frames(state)
  local files = {}
  for i = 0, M.FRAMES - 1 do
    table.insert(files, vim.fs.joinpath(assets(), state, ("%02d.png"):format(i)))
  end
  return files
end

local function cmd(control, payload)
  return ESC .. "_G" .. control .. (payload and (";" .. payload) or "") .. ESC .. "\\"
end

-- The commands that upload a state's frames and start its loop. kitty reads
-- each PNG from its file (t=f); success plays once (v=2), the others forever.
function M.upload_commands(state, files)
  local id = M.image_id(state)
  local out = { cmd(("a=t,f=100,t=f,i=%d,q=2"):format(id), vim.base64.encode(files[1])) }
  for i = 2, #files do
    table.insert(
      out,
      cmd(("a=f,f=100,t=f,i=%d,z=%d,q=2"):format(id, M.FRAME_MS), vim.base64.encode(files[i]))
    )
  end
  table.insert(out, cmd(("a=a,i=%d,r=1,z=%d,q=2"):format(id, M.FRAME_MS)))
  table.insert(out, cmd(("a=a,i=%d,s=3,v=%d,q=2"):format(id, state == "success" and 2 or 1)))
  return out
end

-- A virtual placement: the image is shown wherever its placeholders are.
function M.placement_command(id, cols, rows)
  return cmd(("a=p,U=1,i=%d,c=%d,r=%d,q=2"):format(id, cols, rows))
end

-- The placeholder text, one string per row; colour it with hl_color(id).
function M.placeholder_lines(cols, rows)
  local lines = {}
  for r = 1, rows do
    local row = {}
    for c = 1, cols do
      table.insert(row, PLACEHOLDER .. DIACRITICS[r] .. DIACRITICS[c])
    end
    lines[r] = table.concat(row)
  end
  return lines
end

-- Where the commands go: straight to the terminal (as snacks.nvim does).
function M.write(data)
  if vim.api.nvim_ui_send then
    vim.api.nvim_ui_send(data)
  else
    io.stdout:write(data)
  end
end

function M.available()
  local term = vim.env.TERM or ""
  return (term:find("kitty", 1, true) ~= nil or vim.env.KITTY_WINDOW_ID ~= nil)
    and vim.o.termguicolors
end

local ready = {}

-- Uploads a state's animation the first time it is needed.
function M.ensure(state, cols, rows)
  if ready[state] or not M.available() then
    return
  end
  for _, c in ipairs(M.upload_commands(state, M.frames(state))) do
    M.write(c)
  end
  M.write(M.placement_command(M.image_id(state), cols, rows))
  ready[state] = true
end

return M
