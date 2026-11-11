-- Map presence of the companion, like a player's character:
--   * it requests terrain generation around itself and charts what is around it for the force
--     (so water/ore beyond the charted area can be found and shows up on the map),
--   * it shows up on the map as a chart tag that follows it.

local names = require("scripts.names")
local M = {}

local CHART_RADIUS    = 96  -- tiles revealed around the companion (about 3 chunks, like a player)
local GENERATE_RADIUS = 3   -- chunks of terrain requested around the companion
local INTERVAL        = 60  -- ticks between updates
local TAG_MOVE        = 4   -- tiles the companion must move before its tag is moved

local function drop_tag(data)
  local tag = data.map_tag
  if tag and tag.valid then tag.destroy() end
  data.map_tag = nil
end

local function update_tag(force, surface, pos, data)
  local tag = data.map_tag
  if tag and tag.valid and tag.surface.index == surface.index then
    local dx, dy = tag.position.x - pos.x, tag.position.y - pos.y
    if dx * dx + dy * dy < TAG_MOVE * TAG_MOVE then return end
  end
  drop_tag(data)
  local spec = {position = pos, text = names.get(), icon = {type = "virtual", name = "signal-E"}}
  local ok, new = pcall(function() return force.add_chart_tag(surface, spec) end)
  if not (ok and new) then -- the icon may not exist: a text-only tag still shows
    spec.icon = nil
    ok, new = pcall(function() return force.add_chart_tag(surface, spec) end)
  end
  if ok and new then data.map_tag = new end
end

function M.tick(player, data)
  if game.tick < (data.next_map or 0) then return end
  data.next_map = game.tick + INTERVAL

  local c = data.entity
  local surface, pos, force = c.surface, c.position, player.force

  pcall(function() surface.request_to_generate_chunks(pos, GENERATE_RADIUS) end)
  pcall(function()
    force.chart(surface, {{pos.x - CHART_RADIUS, pos.y - CHART_RADIUS}, {pos.x + CHART_RADIUS, pos.y + CHART_RADIUS}})
  end)
  update_tag(force, surface, pos, data)
end

function M.remove(data)
  if data then drop_tag(data) end
end

return M
