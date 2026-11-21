-- What Bonsai is doing, for the status line and the animated logo.
-- States: idle, listening, thinking, speaking, working, success.
-- Driven by codecompanion's events (see bonsai.ui) and by typing in the input box.
local words = require("bonsai.ui.words")

local M = {}

M.SUCCESS_MS = 48 * 80 -- the success animation plays once: 48 frames of 80 ms

local function human_time(s)
  s = math.max(0, math.floor(s))
  if s < 60 then return s .. "s" end
  return ("%dm %ds"):format(math.floor(s / 60), s % 60)
end

local function human_tokens(n)
  n = math.max(0, math.floor(n or 0))
  if n < 1000 then return "~" .. n end
  return ("~%.1fk"):format(n / 1000):gsub("%.0k$", "k")
end

-- The status line's text.
-- info: { state, word, elapsed (s), tokens, effort (name), thinking (bool) }
function M.format(info)
  if info.state == "idle" then
    return "Ready · /effort: " .. (info.effort or "medium")
  end
  if info.state == "listening" and not info.elapsed then
    return info.word .. "…"
  end
  local head = info.state == "success" and (info.word .. " ✓") or (info.word .. "…")
  local effort = info.thinking and ("thinking with " .. info.effort .. " effort") or (info.effort .. " effort")
  return ("%s (%s · ↓ %s tokens · %s)"):format(head, human_time(info.elapsed or 0), human_tokens(info.tokens), effort)
end

local Machine = {}
Machine.__index = Machine

-- opts: clock() -> seconds, after(ms, fn), on_change(state, word), rng
function M.new(opts)
  opts = opts or {}
  return setmetatable({
    opts = opts,
    clock = opts.clock or function() return vim.uv.now() / 1000 end,
    after = opts.after or function(ms, fn) vim.defer_fn(fn, ms) end,
    current = "idle",
    word = nil,
    started = nil,
    busy = false,
    generation = 0,
  }, Machine)
end

function Machine:state() return self.current end

function Machine:elapsed()
  return self.started and (self.clock() - self.started) or 0
end

function Machine:set(state)
  if state == self.current then return end
  self.current = state
  self.word = words.pick(state, self.opts.rng)
  if self.opts.on_change then self.opts.on_change(state, self.word) end
end

-- name: a codecompanion event name without its "CodeCompanion" prefix, or "InputChanged".
function Machine:event(name, data)
  if name == "InputChanged" then
    if self.busy then return end
    self:set((data and data.text and data.text ~= "") and "listening" or "idle")
  elseif name == "ChatSubmitted" then
    self.busy = true
    self.started = self.clock()
    self:set("thinking")
  elseif name == "RequestStarted" then
    if self.current ~= "speaking" then self:set("thinking") end
  elseif name == "RequestStreaming" then
    self:set("speaking")
  elseif name == "ToolStarted" or name == "ToolApprovalFinished" then
    self:set("working")
  elseif name == "ToolApprovalRequested" then
    self:set("listening")
  elseif name == "ToolFinished" then
    self:set("thinking")
  elseif name == "ChatDone" then
    self.busy = false
    self:set("success")
    self.generation = self.generation + 1
    local gen = self.generation
    self.after(M.SUCCESS_MS, function()
      if self.generation == gen and self.current == "success" then self:set("idle") end
    end)
  elseif name == "ChatStopped" then
    self.busy = false
    self:set("idle")
  end
end

return M
