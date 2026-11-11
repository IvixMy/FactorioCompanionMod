-- What the building zones still need, in the raw materials the companion mines by hand.
--
-- When a mine task is about to start (tasks.start), its target is raised so ONE trip also covers everything
-- the zones are missing that is made from the same material:
--
--   wood      <- poles, chests...            (planned entries that are not built yet, crafted down to raw materials)
--   stone     <- furnaces, boilers, rails... (the same)
--   iron-ore  <- iron plates missing         (hand-smelted; 1 ore per plate)
--   copper-ore<- copper plates missing
--
-- Missing = what the unbuilt entries need - what the companion carries - what the chests hold. Capped per trip so
-- one task never turns into an endless mining run.

local common   = require("scripts.common")
local crafting = require("scripts.crafting")
local supply   = require("scripts.supply")
local zones    = require("scripts.zones")

local M = {}

-- mined item -> {raw material it covers, cap per trip}
local COVERS = {
  ["wood"]       = {raw = "wood", cap = 100},
  ["stone"]      = {raw = "stone", cap = 150},
  ["iron-ore"]   = {raw = "iron-plate", cap = 100},
  ["copper-ore"] = {raw = "copper-plate", cap = 100},
}

-- Raw materials the unbuilt entries of the force's zones still need: {[raw item] = amount}.
local function zone_raw_demand(force, surface, stock)
  local need_items = {}
  for _, p in pairs(game.players) do
    if p.force == force then
      for _, zone in ipairs(zones.all(p.index)) do
        if zone.surface_index == surface.index then
          local found = zones.index_entities(zone, force)
          for _, e in ipairs(zone.entries or {}) do
            local f = found[zones.key(e.name, {x = e.x, y = e.y})]
            if not f or f.ghost then
              local proto = prototypes.entity[e.name]
              local item = proto and proto.items_to_place_this and proto.items_to_place_this[1]
              if item then need_items[item.name] = (need_items[item.name] or 0) + (item.count or 1) end
            end
          end
        end
      end
    end
  end

  local plenty = {["iron-plate"] = 1e9, ["copper-plate"] = 1e9, ["stone"] = 1e9, ["wood"] = 1e9, ["coal"] = 1e9}
  local raw = {}
  for item, count in pairs(need_items) do
    local have = stock[item] or 0 -- finished items already carried / in chests
    local missing = count - have
    if missing > 0 then
      local plan = crafting.resolve(common.ENTITY_NAME, force, item, missing, crafting.copy(plenty))
      if plan then
        for r, n in pairs(plan.raw) do raw[r] = (raw[r] or 0) + n end
      end
    end
  end
  return raw
end

-- New target for a mine task: at least its own, more when the zones are missing the same material.
-- `carried` = how much of the mined item the companion carries now.
function M.mine_target(data, task)
  local cover = COVERS[task.item]
  if not cover then return task.target end
  local c = data.entity
  local force, surface = c.force, c.surface

  local stock = crafting.inventory_counts(c.get_main_inventory())
  for item, n in pairs(supply.get(force, surface).totals) do stock[item] = (stock[item] or 0) + n end
  for item, n in pairs(data.pending or {}) do stock[item] = (stock[item] or 0) + n end

  local raw = zone_raw_demand(force, surface, stock)
  local missing = (raw[cover.raw] or 0) - (stock[cover.raw] or 0)
  -- ore: plates are made from it, so ore already carried counts too
  if task.item ~= cover.raw then missing = missing - (stock[task.item] or 0) end
  if missing <= 0 then return task.target end

  local carried = c.get_main_inventory().get_item_count(task.item)
  return math.max(task.target, carried + math.min(cover.cap, math.ceil(missing)))
end

require("scripts.tasks.core").mine_batcher = M.mine_target

return M
