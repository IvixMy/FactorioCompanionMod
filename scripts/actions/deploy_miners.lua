-- Action "deploy_miners": travel to the best patch of the assigned ore, then stamp the
-- assigned blueprint over it.

local names = require("scripts.names")
local common      = require("scripts.common")
local prospecting = require("scripts.prospecting")
local stamping    = require("scripts.actions.stamping")

local ARRIVE_DISTANCE = 6

return {
  id = "deploy_miners",
  caption = "Deploy miners on the assigned ore patch",
  description = "Travels to the best patch of the assigned ore and places the assigned blueprint over it.",
  complex = true,

  prepare = function(player, data)
    local ore = storage.assigned_ore[player.index]
    local result = prospecting.get_result(player.index)
    if not (ore and result and result.ore == ore and result.best) then
      return nil, "run 'Find best patch' for the assigned ore first."
    end
    if result.surface_index ~= data.entity.surface.index then
      return nil, "that patch is on a different surface than " .. names.get() .. "."
    end
    local best = result.best
    return {
      phase = "travel", ore = ore, surface_index = result.surface_index,
      patch = {x = best.x, y = best.y, x0 = best.x0, y0 = best.y0, x1 = best.x1, y1 = best.y1},
    }
  end,

  start_message = function(a) return "deploying miners on the " .. a.ore .. " patch." end,

  step = function(player, data, a)
    if a.phase == "travel" then
      data.status = "Heading to the " .. a.ore .. " patch"
      data.action_status = "travelling to the " .. a.ore .. " patch"
      if common.walk_towards(data, {x = a.patch.x, y = a.patch.y}, ARRIVE_DISTANCE) then
        a.phase = "stamp"
      end
      return true
    end
    return stamping.step(player, data, a)
  end,
}
