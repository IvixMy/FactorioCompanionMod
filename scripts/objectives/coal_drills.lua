-- Objective "coal_drills": automatic coal supply.
--
--   [burner drill] --> <-- [burner drill]      two burner drills on coal, FACING EACH OTHER
--
-- Each drill drops its coal into the OTHER drill's fuel slot, so the pair feeds itself and the
-- surplus piles up in their fuel slots (up to a stack each). When any machine needs fuel, the
-- companion takes the coal from these drills (scripts/fuel.lua, "stock") instead of hand-mining
-- it at the ore patch. A few items are always left in each drill so it keeps running.
--
-- Used in two places:
--   * scripts/objectives/iron_start.lua  calls step() once the first iron cells stand, so coal
--                                        takes priority over scaling the iron up
--   * the playbook lists it right after iron_start (covers games where iron is already done)
--
-- Params (playbook): coal_pairs (default 1), coal_ore (resource name, default "coal").

local common   = require("scripts.common")
local geometry = require("scripts.geometry")
local zones    = require("scripts.zones")
local supply   = require("scripts.supply")
local crafting = require("scripts.crafting")
local fuel     = require("scripts.fuel")
local ore      = require("scripts.ore")
local tasks    = require("scripts.tasks")

local PURPOSE = "coal"
local DRILL = "burner-mining-drill"
local SEARCH_RADII = {40, 100, 200}
local DEFAULT_PAIRS = 1
local ORE_UNDER_DRILL = 3 -- ore tiles (of the drill's 4) required under EACH drill

local DIR = defines.direction

---------------------------------------------------------------------
-- Fuel stock: the coal piled up inside the drills (registered with scripts/fuel.lua)
---------------------------------------------------------------------

fuel.register_stock(function(player, data, item)
  local out = {}
  local surface_index = data.entity.surface.index
  for _, zone in ipairs(zones.list(player.index, PURPOSE)) do
    if zone.surface_index == surface_index then
      for _, f in pairs(zones.index_entities(zone, player.force)) do
        local e = f.entity
        if not f.ghost and e.valid and e.name == DRILL then
          local inv = e.get_fuel_inventory()
          local n = inv and (inv.get_item_count(item) - fuel.STOCK_KEEP) or 0
          if n > 0 then out[#out + 1] = {entity = e, count = n} end
        end
      end
    end
  end
  return out
end)

---------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------

local function carried_count(ctx, item)
  return ctx.data.entity.get_main_inventory().get_item_count(item)
end

local function have(ctx, item)
  return carried_count(ctx, item) + (supply.get(ctx.player.force, ctx.surface).totals[item] or 0)
end

local function can_make(ctx, item, count)
  local stock = crafting.inventory_counts(ctx.data.entity.get_main_inventory())
  for k, v in pairs(supply.get(ctx.player.force, ctx.surface).totals) do stock[k] = (stock[k] or 0) + v end
  for k, v in pairs(ctx.data.pending or {}) do stock[k] = (stock[k] or 0) + v end
  if (stock[item] or 0) >= count then return true end
  return crafting.resolve(common.ENTITY_NAME, ctx.player.force, item, count, crafting.copy(stock)) ~= nil
end

local function raw_cost(ctx, item)
  local stock = {["iron-plate"] = 1e6, ["copper-plate"] = 1e6, ["stone"] = 1e6}
  local plan = crafting.resolve(common.ENTITY_NAME, ctx.player.force, item, 1, stock)
  return plan and plan.raw or {}
end

-- The furnaces of the iron cells (they hold the plates the drills are made of).
local function iron_furnaces(ctx)
  local list = {}
  for _, zone in ipairs(zones.list(ctx.player.index, "iron_start")) do
    for _, f in pairs(zones.index_entities(zone, ctx.player.force)) do
      if not f.ghost and f.entity.valid and f.entity.type == "furnace" then list[#list + 1] = f.entity end
    end
  end
  return list
end

local function plates_in(furnace)
  local out = furnace.get_output_inventory()
  return out and out.get_item_count("iron-plate") or 0
end

---------------------------------------------------------------------
-- Planning: two drills facing each other on the ore
---------------------------------------------------------------------

local function plan_pair(ctx, ore_name)
  local surface, force = ctx.surface, ctx.player.force
  local from = ctx.data.entity.position

  local vec = common.try_get(prototypes.entity[DRILL], "vector_to_place_result")
  local vx, vy = -0.5, -1.3
  if vec then vx, vy = vec.x or vec[1], vec.y or vec[2] end

  local sites = ore.drill_sites(surface, ore_name, from, SEARCH_RADII, ORE_UNDER_DRILL)
  if #sites == 0 then return nil, "no " .. ore_name .. " within " .. SEARCH_RADII[#SEARCH_RADII] .. " tiles" end

  for _, site in ipairs(sites) do
    local cx, cy = site.x, site.y
    for _, dir in ipairs({DIR.north, DIR.east, DIR.south, DIR.west}) do
      local turns = geometry.dir_to_turns(dir)
      local rx, ry = geometry.rotate(vx, vy, turns)
      local ux, uy = geometry.unit(rx, ry)               -- the way drill A drops its ore
      local bx, by = cx + ux * 2, cy + uy * 2             -- drill B sits right where A drops it
      local under_b = surface.count_entities_filtered{name = ore_name, area = {{bx - 1, by - 1}, {bx + 1, by + 1}}}
      if under_b >= ORE_UNDER_DRILL then
        local entries = {
          {name = DRILL, x = cx, y = cy, direction = dir},
          {name = DRILL, x = bx, y = by, direction = geometry.turns_to_dir(turns + 2)}, -- faces back at A
        }
        local ok = true
        for _, e in ipairs(entries) do
          if not surface.can_place_entity{
            name = e.name, position = {e.x, e.y}, direction = e.direction, force = force,
            build_check_type = defines.build_check_type.ghost_place,
          } then ok = false break end
        end
        if ok then
          local x0, y0, x1, y1 = geometry.bbox_of(entries, 1)
          if not zones.overlaps_any(ctx.player.index, surface.index, {x0 = x0, y0 = y0, x1 = x1, y1 = y1}) then
            return entries
          end
        end
      end
    end
  end
  return nil, "no free spot for two drills on the " .. ore_name
end

---------------------------------------------------------------------
-- Objective
---------------------------------------------------------------------

local function step(ctx)
  local player, data = ctx.player, ctx.data
  local force, idx = player.force, player.index
  ctx.surface = data.entity.surface
  local params = ctx.params or {}
  local ore_name = params.coal_ore or "coal"
  local wanted = params.coal_pairs or DEFAULT_PAIRS

  local recipe = force.recipes[DRILL]
  if not (recipe and recipe.enabled) then return "satisfied", "burner mining drills are not available" end

  -- 1. every planned drill exists as a ghost or a building
  local built, pending = 0, 0
  local zs = zones.list(idx, PURPOSE)
  for _, zone in ipairs(zs) do
    local surface = game.get_surface(zone.surface_index)
    if surface then
      local b, p, failed = zones.ensure_ghosts(zone, surface, force)
      if failed > 0 then
        if b == 0 then -- nothing built there yet: drop the plan, it gets planned again elsewhere
          for _, f in pairs(zones.index_entities(zone, force)) do
            if f.ghost and f.entity.valid then f.entity.destroy() end
          end
          zones.remove(idx, zone.purpose)
          return "working", "coal drills can't be placed there, planning another spot"
        end
        return "blocked", "a coal drill can't be placed (something in the way?)"
      end
      built, pending = built + b, pending + p
    end
  end

  -- 2. enough pairs planned?
  if #zs < wanted then
    local entries, err = plan_pair(ctx, ore_name)
    if not entries then return "satisfied", "no automatic coal: " .. err end -- never hold the game up
    zones.create(player, zones.next_purpose(idx, PURPOSE), ctx.surface, entries, {})
    return "working", "assigned two burner drills facing each other on the " .. ore_name
  end

  -- 3. built?
  if pending == 0 then
    return "satisfied", string.format("%d coal drills running (the companion collects from them)", built)
  end

  if data.task then return "working", "busy: " .. (data.status or "task") end

  -- 4. materials for the missing drills (the normal auto-build then crafts and places them)
  if can_make(ctx, DRILL, pending) then return "working", "waiting for the coal drills to be built" end

  local raw = raw_cost(ctx, DRILL)
  local stone_missing = (raw["stone"] or 0) * pending - have(ctx, "stone")
  if stone_missing > 0 then
    local target = carried_count(ctx, "stone") + stone_missing
    tasks.start(data, tasks.new("mine", {item = "stone", target = target}))
    return "working", "hand-mining stone for the coal drills"
  end

  local plates_missing = (raw["iron-plate"] or 0) * pending - have(ctx, "iron-plate")
  if plates_missing > 0 then
    local best, best_n
    for _, f in ipairs(iron_furnaces(ctx)) do
      local n = plates_in(f)
      if n > 0 and (not best or n > best_n) then best, best_n = f, n end
    end
    if best then
      tasks.start(data, tasks.new("transfer", {target = best, mode = "collect", item = "iron-plate", count = 0}))
      return "working", "collecting iron plates for the coal drills"
    end
    return "working", "waiting for iron plates for the coal drills"
  end
  return "working", "preparing the coal drills"
end

return {
  id = "coal_drills",
  caption = "Automatic coal",
  implemented = true,
  step = step,
}
