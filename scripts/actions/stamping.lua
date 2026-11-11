-- Reusable step for blueprint-driven actions: place the action's assigned blueprint over an
-- ore patch, one copy at a time, while the normal task system builds the resulting ghosts.
-- Expects the action table to hold: id, ore, patch.

local names = require("scripts.names")
local blueprints = require("scripts.blueprints")
local core       = require("scripts.actions.core")

local M = {}

local STAMP_INTERVAL = 60 -- ticks between blueprint stamps

function M.step(player, data, a)
  local c = data.entity
  local bp = blueprints.get(player.index, a.id)
  if not bp then
    core.cancel(data, "cancelled (blueprint was removed)")
    return false
  end

  if not a.stamps then
    a.stamps = blueprints.plan_stamps(c.surface, player.force, bp, a.ore, a.patch, player.index)
    a.index, a.total, a.ghosts = 1, #a.stamps, 0
    if a.total == 0 then
      core.cancel(data, "nothing to place (patch area is already built on, or the blueprint is too big)")
      return false
    end
  end

  if game.tick >= (a.next_stamp or 0) then
    if a.index <= a.total then
      local s = a.stamps[a.index]
      a.index = a.index + 1
      a.ghosts = a.ghosts + blueprints.stamp(c.surface, player.force, bp, {x = s.x, y = s.y})
      a.next_stamp = game.tick + STAMP_INTERVAL
    else
      player.print(names.prefix() .. string.format("placed the blueprint %d times (%d ghosts) on the %s patch.",
        a.total, a.ghosts, a.ore))
      core.cancel(data, "done (" .. a.total .. " blueprint copies placed)")
      return false
    end
  end
  data.action_status = string.format("placing blueprint %d/%d", math.min(a.index - 1, a.total), a.total)
  return false
end

return M
