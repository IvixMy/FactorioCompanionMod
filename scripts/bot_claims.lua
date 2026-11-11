-- Construction robots (0.19.9): is a ghost about to be built by BOTS? Then the companion does not make a trip for it.
--
-- A ghost counts as claimed when a logistic network whose CONSTRUCTION area covers it has construction robots and
-- holds the item (the game's own rule for bots to take the job). This is a check, not a reservation: the companion
-- may still build the ghost when it is close, and it never blocks the bots.
--
-- Settings (per player): ec-skip-bot-ghosts (default on), ec-bot-skip-distance (only ghosts farther than this).

local M = {}

M.RECHECK = 300 -- ticks a claimed ghost is left alone before it is looked at again

local function net_count(net, name)
  -- the item count of a network, whatever the form the running version of the API takes
  local ok, n = pcall(function() return net.get_item_count{name = name, quality = "normal"} end)
  if ok and type(n) == "number" then return n end
  ok, n = pcall(function() return net.get_item_count(name) end)
  if ok and type(n) == "number" then return n end
  ok, n = pcall(function()
    local sum = 0
    for _, e in pairs(net.get_contents()) do
      if e.name == name then sum = sum + (e.count or 0) end
    end
    return sum
  end)
  if ok and type(n) == "number" then return n end
  return nil
end

function M.enabled(player)
  local s = settings.get_player_settings(player)["ec-skip-bot-ghosts"]
  return not s or s.value ~= false
end

function M.min_distance(player)
  local s = settings.get_player_settings(player)["ec-bot-skip-distance"]
  return s and s.value or 20
end

-- Will bots build `ghost` (which needs `count` of `item`)? false when they cannot tell.
function M.claimed(ghost, item, count)
  if not (ghost and ghost.valid and item) then return false end
  local ok, nets = pcall(function()
    return ghost.surface.find_logistic_networks_by_construction_area(ghost.position, ghost.force)
  end)
  if not ok or not nets then return false end
  for _, net in pairs(nets) do
    if net.valid and (net.all_construction_robots or 0) > 0 then
      local have = net_count(net, item)
      if have and have >= (count or 1) then return true end
    end
  end
  return false
end

return M
