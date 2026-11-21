-- Bonsai's plant words for the status line, one pool per state (owner,
-- 2026-11-21: like Claude Code's spinner words, "but for plants only").
-- Add or change words here; a new one is picked each time a state starts.
local M = {}

M.POOLS = {
  thinking = {
    "Photosynthesizing",
    "Germinating",
    "Sprouting",
    "Taking root",
    "Budding",
    "Pollinating",
    "Composting",
  },
  working = {
    "Pruning",
    "Repotting",
    "Grafting",
    "Wiring branches",
    "Weeding",
    "Mulching",
    "Watering",
  },
  speaking = { "Blossoming", "Unfurling", "Leafing out", "Branching out", "Flowering" },
  listening = { "Soaking it in", "Drinking it in", "Rooting around" },
  success = { "In full bloom", "Harvested", "Bore fruit" },
}

-- A word for the state; `rng(n)` returns 1..n (math.random unless a test gives one).
function M.pick(state, rng)
  local pool = M.POOLS[state]
  if not pool then
    return nil
  end
  rng = rng or math.random
  return pool[rng(#pool)]
end

return M
