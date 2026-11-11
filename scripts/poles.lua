-- Power poles: which pole the companion should use, and how to get one.
--
--   poles.researched(force)               -> list of pole infos, WOODEN (small) pole first
--   poles.get_available_power_pole(ctx)   -> {name, status, ...} (see below)
--
-- get_available_power_pole:
--   1. builds the list of poles whose recipe is researched (wooden pole first, then medium, big, substation)
--   2. looks for one in the companion's logistics (what it carries + the chests)  -> status "stock"
--   3. if there is none, it creates it: the first pole of the list that can be hand-crafted from what
--      is available -> status "craftable"; the auto-build then crafts it once its ghost exists
--   4. if even that is not possible yet -> status "missing" with `raw` = base materials still needed
--      (the caller gathers them: wood, copper plates, ...)

local common   = require("scripts.common")
local supply   = require("scripts.supply")
local crafting = require("scripts.crafting")

local M = {}

-- name, tile size, fallback reach / supply area (used when the prototype can't be read)
local CATALOG = {
  {name = "small-electric-pole",  size = 1, reach = 7.5,  supply = 2.5},  -- the wooden pole
  {name = "medium-electric-pole", size = 1, reach = 9,    supply = 3.5},
  {name = "big-electric-pole",    size = 2, reach = 30,   supply = 2},
  {name = "substation",           size = 2, reach = 18,   supply = 9},
}

local function read_number(proto, getter, property, fallback)
  local ok, v = pcall(function() return proto[getter]("normal") end) -- 2.x: get_xxx(quality)
  if ok and type(v) == "number" then return v end
  ok, v = pcall(function() return proto[property] end)
  if ok and type(v) == "number" then return v end
  return fallback
end

local function info(entry)
  local proto = prototypes.entity[entry.name]
  if not proto then return nil end
  return {
    name = entry.name,
    size = entry.size,
    reach = read_number(proto, "get_max_wire_distance", "max_wire_distance", entry.reach),
    supply = read_number(proto, "get_supply_area_distance", "supply_area_distance", entry.supply),
  }
end

-- Wire reach (max wire distance) of any pole prototype. Two poles connect when their distance is within
-- the LOWER of the two reaches.
function M.reach_of(name)
  local proto = prototypes.entity[name]
  if not proto then return 7.5 end
  local fallback = 7.5
  for _, entry in ipairs(CATALOG) do
    if entry.name == name then fallback = entry.reach end
  end
  return read_number(proto, "get_max_wire_distance", "max_wire_distance", fallback)
end

-- Poles the force can build (their recipe is enabled), wooden pole first.
function M.researched(force)
  local list = {}
  for _, entry in ipairs(CATALOG) do
    local recipe = force.recipes[entry.name]
    if recipe and recipe.enabled then
      local i = info(entry)
      if i then list[#list + 1] = i end
    end
  end
  return list
end

local function carried(data, item)
  return data.entity.get_main_inventory().get_item_count(item)
end

local function chest_total(force, surface, item)
  return supply.get(force, surface).totals[item] or 0
end

-- ctx: {player, data, surface}   count: how many poles are needed (default 1)
-- `only_small` limits the choice to poles that take one tile (what the lab layout needs).
-- Returns {name, size, reach, supply, status = "stock" | "craftable" | "missing", raw = {...}} or nil
-- when no pole is researched at all.
function M.get_available_power_pole(ctx, count, only_small)
  count = count or 1
  local force, data = ctx.player.force, ctx.data
  local surface = ctx.surface or data.entity.surface

  local list = {}
  for _, p in ipairs(M.researched(force)) do
    if not only_small or p.size == 1 then list[#list + 1] = p end
  end
  if #list == 0 then return nil end

  -- 2. already in the logistics (carried or in a chest)?
  for _, p in ipairs(list) do
    if carried(data, p.name) + chest_total(force, surface, p.name) >= count then
      p.status = "stock"
      return p
    end
  end

  -- 3. not in stock: create it - the first pole that can be crafted from what there is
  local stock = crafting.inventory_counts(data.entity.get_main_inventory())
  for k, v in pairs(supply.get(force, surface).totals) do stock[k] = (stock[k] or 0) + v end
  for k, v in pairs(data.pending or {}) do stock[k] = (stock[k] or 0) + v end
  for _, p in ipairs(list) do
    if crafting.resolve(common.ENTITY_NAME, force, p.name, count, crafting.copy(stock)) then
      p.status = "craftable"
      return p
    end
  end

  -- 4. nothing can be made yet: report what the first (wooden) pole costs in base materials
  local first = list[1]
  local plenty = {["iron-plate"] = 1e6, ["copper-plate"] = 1e6, ["stone"] = 1e6, ["wood"] = 1e6}
  local plan = crafting.resolve(common.ENTITY_NAME, force, first.name, count, plenty)
  first.status = "missing"
  first.raw = plan and plan.raw or {}
  return first
end

return M
