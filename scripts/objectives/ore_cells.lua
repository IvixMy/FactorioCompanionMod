-- Objectives "copper_start" and "stone_start": the same self-running setup the iron start builds,
-- for the other two bootstrap resources. They run after the power plant (see scripts/playbooks.lua).
--
--   copper_start :  CELL = [burner drill on copper ore] -> [stone furnace]     -> copper plates
--   stone_start  :  CELL = [burner drill on stone]      -> [wooden chest]      -> stone
--
-- The chest of a stone cell is a normal chest: every other part of the mod (crafting, fetching for
-- ghosts) already takes stone from chests, so the stone simply becomes available.
-- Fuel for the drills/furnaces is kept up by scripts/upkeep.lua (every burner in every zone).
-- Items are made the usual way: the cells' ghosts are placed in zones and the normal auto-build
-- fetches / crafts / builds them; this file only makes sure the raw materials are there (hand-mining
-- stone and wood, collecting iron plates from the iron cells).
--
-- Params (playbook): cells (default 2), plates (copper plates wanted in stock, default 50).

local common   = require("scripts.common")
local geometry = require("scripts.geometry")
local zones    = require("scripts.zones")
local supply   = require("scripts.supply")
local crafting = require("scripts.crafting")
local ore      = require("scripts.ore")
local tasks    = require("scripts.tasks")
local iron     = require("scripts.objectives.iron_start")

local DRILL = "burner-mining-drill"
local FURNACE = "stone-furnace"
local SEARCH_RADII = {40, 100, 200}
local ORE_UNDER_DRILL = 3
local COLLECT_AT, COLLECT_AT_IDLE = 5, 20

local DIR = defines.direction

local VARIANTS = {
  {id = "copper_start", caption = "Copper cells", ore = "copper-ore", output = "furnace",
   plate = "copper-plate", default_cells = 2, default_plates = 50},
  {id = "stone_start", caption = "Stone drills", ore = "stone", output = "chest", default_cells = 2},
}

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
  local stock = {["iron-plate"] = 1e6, ["copper-plate"] = 1e6, ["stone"] = 1e6, ["wood"] = 1e6}
  local plan = crafting.resolve(common.ENTITY_NAME, ctx.player.force, item, 1, stock)
  return plan and plan.raw or {}
end

local function chest_name(force)
  local r = force.recipes["wooden-chest"]
  if r and r.enabled then return "wooden-chest" end
  return "iron-chest"
end

local function entry_entity(found, entry)
  local f = found[zones.key(entry.name, {x = entry.x, y = entry.y})]
  return f and not f.ghost and f.entity.valid and f.entity or nil
end

local function drop_ghosts(zone, force)
  for _, f in pairs(zones.index_entities(zone, force)) do
    if f.ghost and f.entity.valid then f.entity.destroy() end
  end
end

---------------------------------------------------------------------
-- Planning: a burner drill on the ore + what catches its output
---------------------------------------------------------------------

local function plan_cell(ctx, v, anchor)
  local surface, force = ctx.surface, ctx.player.force
  local from = anchor or ctx.data.entity.position

  local vec = common.try_get(prototypes.entity[DRILL], "vector_to_place_result")
  local vx, vy = -0.5, -1.3 -- where a north-facing drill drops its output, relative to its centre
  if vec then vx, vy = vec.x or vec[1], vec.y or vec[2] end

  local sites = ore.drill_sites(surface, v.ore, from, SEARCH_RADII, ORE_UNDER_DRILL)
  if #sites == 0 then
    if not ore.find(surface, v.ore, from, SEARCH_RADII) then
      return nil, "no " .. v.ore .. " within " .. SEARCH_RADII[#SEARCH_RADII] .. " tiles (explore or chart more)"
    end
    return nil, "no free spot for a drill on the " .. v.ore
  end

  local out_name = v.output == "furnace" and FURNACE or chest_name(force)
  for _, site in ipairs(sites) do
    local cx, cy = site.x, site.y
    for _, dir in ipairs({DIR.north, DIR.east, DIR.south, DIR.west}) do
      local rx, ry = geometry.rotate(vx, vy, geometry.dir_to_turns(dir))
      local ux, uy = geometry.unit(rx, ry)
      local out
      if v.output == "furnace" then
        out = {name = out_name, x = cx + ux * 2, y = cy + uy * 2, direction = DIR.north}
      else -- the chest sits on the exact tile the drill drops into
        out = {name = out_name, x = math.floor(cx + rx) + 0.5, y = math.floor(cy + ry) + 0.5, direction = DIR.north}
      end
      local entries = {{name = DRILL, x = cx, y = cy, direction = dir}, out}
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
  return nil, "no free spot for a drill on the " .. v.ore
end

-- Makes sure every cell has its ghosts and reports what is built. A cell whose ghosts can't be
-- placed and that has nothing built yet is dropped (it gets replanned elsewhere).
local function read_cells(ctx, v)
  local idx, force = ctx.player.index, ctx.player.force
  local cells = {}
  for _, zone in ipairs(zones.list(idx, v.id)) do
    local surface = game.get_surface(zone.surface_index)
    if surface then
      local _, _, failed, found = zones.ensure_ghosts(zone, surface, force)
      local cell = {
        zone = zone,
        drill = entry_entity(found, zone.entries[1]),
        out = entry_entity(found, zone.entries[2]),
      }
      if failed > 0 then
        if cell.drill or cell.out then return nil, "a drill/" .. v.output .. " can't be placed (something in the way?)" end
        drop_ghosts(zone, force)
        zones.remove(idx, zone.purpose)
      else
        cells[#cells + 1] = cell
      end
    end
  end
  return cells
end

---------------------------------------------------------------------
-- Raw materials for what is still a ghost
---------------------------------------------------------------------

-- Returns status, note when something was started / is being waited for; nil when the normal
-- auto-build can go ahead on its own.
local function provide_materials(ctx, v, missing_items, cells)
  local data = ctx.data
  for item, n in pairs(missing_items) do
    if not can_make(ctx, item, n) then
      local raw = raw_cost(ctx, item)
      -- hand-mined / collected materials, in order of what is easiest to get
      local stone_missing = (raw["stone"] or 0) * n - have(ctx, "stone")
      if stone_missing > 0 then
        tasks.start(data, tasks.new("mine", {item = "stone", target = carried_count(ctx, "stone") + stone_missing}))
        return "working", "hand-mining stone for the " .. item
      end
      local wood_missing = (raw["wood"] or 0) * n - have(ctx, "wood")
      if wood_missing > 0 then
        tasks.start(data, tasks.new("mine", {item = "wood", from_trees = true, target = carried_count(ctx, "wood") + wood_missing}))
        return "working", "chopping wood for the " .. item
      end
      local plates_missing = (raw["iron-plate"] or 0) * n - have(ctx, "iron-plate")
      if plates_missing > 0 then
        local status, note = iron.collect(ctx, 1)
        if status then return status, "collecting iron plates for the " .. item end
        return "working", "waiting for iron plates for the " .. item
      end
      local copper_missing = (raw["copper-plate"] or 0) * n - have(ctx, "copper-plate")
      if copper_missing > 0 then return "working", "waiting for copper plates for the " .. item end
      return "working", "preparing the " .. item
    end
  end
  return nil
end

---------------------------------------------------------------------
-- Objective factory
---------------------------------------------------------------------

local function make(v)
  return {
    id = v.id,
    caption = v.caption,
    implemented = true,

    step = function(ctx)
      local player, data = ctx.player, ctx.data
      local force, idx = player.force, player.index
      ctx.surface = data.entity.surface
      local params = ctx.params or {}
      local wanted = params.cells or v.default_cells

      local recipe = force.recipes[DRILL]
      if not (recipe and recipe.enabled) then return "satisfied", "burner mining drills are not available" end

      local cells, blocked = read_cells(ctx, v)
      if not cells then return "blocked", blocked end

      -- 1. enough cells planned? (one per step, next to the first)
      if #cells < wanted then
        local first = cells[1] and cells[1].zone.entries[1]
        local entries, err = plan_cell(ctx, v, first and {x = first.x, y = first.y} or nil)
        if entries then
          zones.create(player, zones.next_purpose(idx, v.id), ctx.surface, entries, {})
          return "working", string.format("assigned %s cell %d of %d: burner drill -> %s",
            v.ore, #cells + 1, wanted, v.output == "furnace" and "stone furnace" or chest_name(force))
        end
        if #cells == 0 then return "satisfied", "no " .. v.id .. ": " .. err end -- never hold the game up
        -- no room for more: carry on with what there is
      end

      -- 2. what is still a ghost?
      local missing_items, pending = {}, 0
      for _, cell in ipairs(cells) do
        if not cell.drill then
          missing_items[DRILL] = (missing_items[DRILL] or 0) + 1
          pending = pending + 1
        end
        if not cell.out then
          local name = cell.zone.entries[2].name
          missing_items[name] = (missing_items[name] or 0) + 1
          pending = pending + 1
        end
      end

      if pending > 0 then
        if data.task then return "working", "busy: " .. (data.status or "task") end
        local status, note = provide_materials(ctx, v, missing_items, cells)
        if status then return status, note end
        return "working", string.format("waiting for %d %s cell parts to be built", pending, v.ore)
      end

      -- 3. everything stands. Copper: fetch the finished plates now and then (stone is in chests already)
      if v.plate then
        if not data.task then
          local stock = have(ctx, v.plate)
          local threshold = stock < (params.plates or v.default_plates) and COLLECT_AT or COLLECT_AT_IDLE
          local best, best_n
          for _, cell in ipairs(cells) do
            local out = cell.out and cell.out.get_output_inventory()
            local n = out and out.get_item_count(v.plate) or 0
            if n >= threshold and (not best or n > best_n) then best, best_n = cell.out, n end
          end
          if best then
            tasks.start(data, tasks.new("transfer", {target = best, mode = "collect", item = v.plate, count = 0}))
            return "working", "collecting " .. v.plate .. " from the furnaces"
          end
        end
        return "satisfied", string.format("%d %s cells running (%d %s in stock)", #cells, v.ore, have(ctx, v.plate), v.plate)
      end
      return "satisfied", string.format("%d stone drills running into chests", #cells)
    end,
  }
end

local list = {}
for _, v in ipairs(VARIANTS) do list[#list + 1] = make(v) end
return list
