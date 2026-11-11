-- Objective "iron_start": the very first step from zero. Get `plates` iron plates (default 50,
-- what the first steam power plant needs) and do it by SCALING UP instead of waiting on one drill:
--
--     CELL = [burner mining drill] --drops ore into--> [stone furnace]      (one zone per cell)
--
-- Growth, all derived from the world every step (zones, inventories), so interruptions resume:
--   1. Start with two cells. Furnaces go up first (5 stone each) - hand-mined ore is far faster
--      than one furnace can smelt, so every extra furnace speeds up the plates for the first drills.
--   2. Hand-mine ore and spread it over ALL furnaces to make the plates for the next drill.
--   3. Every drill that comes online pays for the next one. While much of the goal is still
--      missing, more cells are planned (up to `cells`, default 4); near the goal it stops growing.
--
-- Bootstrapping by hand, only for what chests can't provide: stone, the first iron ore.
-- Fuel is NOT handled here: scripts/upkeep.lua (built on scripts/fuel.lua) keeps every burner
-- in every zone running with the best fuel it can find - also after this objective is satisfied.
-- Once satisfied, finished plates are still collected from the furnaces now and then.

local common   = require("scripts.common")
local geometry = require("scripts.geometry")
local zones    = require("scripts.zones")
local supply   = require("scripts.supply")
local crafting = require("scripts.crafting")
local fuel     = require("scripts.fuel")
local ore      = require("scripts.ore")
local coal     = require("scripts.objectives.coal_drills")
local tasks    = require("scripts.tasks")

local PURPOSE = "iron_start"
local ORE = "iron-ore"
local SEARCH_RADII = {25, 60, 150}
local DEFAULT_PLATES, DEFAULT_CELLS = 50, 4
local START_CELLS = 2
local PLATES_PER_CELL = 12  -- a new cell is only worth it while this many plates are still missing
local COLLECT_AT = 5        -- collect finished plates from a furnace at this many (goal not met)
local COLLECT_AT_IDLE = 20  -- ...and at this many once the goal is met (don't interrupt other work)
local ORE_UNDER_DRILL = 3   -- ore tiles (of the drill's 4) required

local DIR = defines.direction

---------------------------------------------------------------------
-- Inventory / supply helpers
---------------------------------------------------------------------

local function carried_count(ctx, item)
  return ctx.data.entity.get_main_inventory().get_item_count(item)
end

local function chest_count(ctx, item)
  return supply.get(ctx.player.force, ctx.surface).totals[item] or 0
end

local function have(ctx, item) return carried_count(ctx, item) + chest_count(ctx, item) end

-- Can the companion obtain `count` of the item from what it carries + the chests + what its
-- crafting queue is about to deliver (crafting included)?
local function can_make(ctx, item, count)
  local stock = crafting.inventory_counts(ctx.data.entity.get_main_inventory())
  for k, v in pairs(supply.get(ctx.player.force, ctx.surface).totals) do stock[k] = (stock[k] or 0) + v end
  for k, v in pairs(ctx.data.pending or {}) do stock[k] = (stock[k] or 0) + v end
  if (stock[item] or 0) >= count then return true end
  return crafting.resolve(common.ENTITY_NAME, ctx.player.force, item, count, crafting.copy(stock)) ~= nil
end

-- Base materials needed to craft one of the item from scratch.
local function raw_cost(ctx, item)
  local stock = {["iron-plate"] = 1e6, ["copper-plate"] = 1e6, ["stone"] = 1e6}
  local plan = crafting.resolve(common.ENTITY_NAME, ctx.player.force, item, 1, stock)
  return plan and plan.raw or {}
end

local function start_mine(ctx, item, missing, note)
  local target = carried_count(ctx, item) + math.max(1, missing)
  tasks.start(ctx.data, tasks.new("mine", {item = item, target = target}))
  return "working", note
end

local function start_transfer(ctx, fields)
  tasks.start(ctx.data, tasks.new("transfer", fields))
  return "working", ctx.data.status
end

local function plates_in(furnace)
  local out = furnace.get_output_inventory()
  return out and out.get_item_count("iron-plate") or 0
end

---------------------------------------------------------------------
-- Planning: where to put a drill + furnace cell
---------------------------------------------------------------------

local function plan_site(ctx, anchor, ore_name)
  ore_name = ore_name or ORE
  local surface, force = ctx.surface, ctx.player.force
  local from = anchor or ctx.data.entity.position

  -- where a north-facing drill drops its ore, relative to its centre
  local vec = common.try_get(prototypes.entity["burner-mining-drill"], "vector_to_place_result")
  local vx, vy = -0.5, -1.3
  if vec then vx, vy = vec.x or vec[1], vec.y or vec[2] end

  -- candidate drill centres on the ore (shared finder: scripts/ore.lua)
  local sites = ore.drill_sites(surface, ore_name, from, SEARCH_RADII, ORE_UNDER_DRILL)
  if #sites == 0 then
    if not ore.find(surface, ore_name, from, SEARCH_RADII) then
      return nil, "no " .. ore_name .. " within " .. SEARCH_RADII[#SEARCH_RADII] .. " tiles (explore or chart more)"
    end
    return nil, "no free spot for a drill on the " .. ore_name
  end

  for _, site in ipairs(sites) do
    local cx, cy = site.x, site.y
    for _, dir in ipairs({DIR.north, DIR.east, DIR.south, DIR.west}) do
      local rx, ry = geometry.rotate(vx, vy, geometry.dir_to_turns(dir))
      local ux, uy = geometry.unit(rx, ry)
      local entries = {
        {name = "burner-mining-drill", x = cx, y = cy, direction = dir},
        {name = "stone-furnace", x = cx + ux * 2, y = cy + uy * 2, direction = DIR.north},
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
  return nil, "no free spot for a drill on the " .. ore_name
end

---------------------------------------------------------------------
-- Cells
---------------------------------------------------------------------

local function entry_entity(found, entry)
  local f = found[zones.key(entry.name, {x = entry.x, y = entry.y})]
  return f and not f.ghost and f.entity.valid and f.entity or nil
end

-- Makes sure every cell has its ghosts and reports what is built. A cell whose ghosts can't be
-- placed and that has nothing built yet is dropped (it gets replanned elsewhere).
-- Returns cells = {{zone, drill, furnace}, ...} or nil, "blocked" note.
local function read_cells(ctx)
  local idx, force = ctx.player.index, ctx.player.force
  local cells = {}
  for _, zone in ipairs(zones.list(idx, PURPOSE)) do
    local surface = game.get_surface(zone.surface_index)
    if surface then
      local _, _, failed, found = zones.ensure_ghosts(zone, surface, force)
      local cell = {
        zone = zone,
        drill = entry_entity(found, zone.entries[1]),
        furnace = entry_entity(found, zone.entries[2]),
      }
      if failed > 0 then
        if cell.drill or cell.furnace then
          return nil, "a drill/furnace can't be placed (something in the way?)"
        end
        for _, f in pairs(zones.index_entities(zone, force)) do
          if f.ghost and f.entity.valid then f.entity.destroy() end
        end
        zones.remove(idx, zone.purpose)
      else
        cells[#cells + 1] = cell
      end
    end
  end
  return cells
end

-- Reserve a zone for one more cell, close to the first one. Returns true or nil, error.
local function new_cell(ctx, cells)
  local anchor
  local first = cells[1] and cells[1].zone.entries[1]
  if first then anchor = {x = first.x, y = first.y} end
  local entries, err = plan_site(ctx, anchor)
  if not entries then return nil, err end
  local zone = zones.create(ctx.player, zones.next_purpose(ctx.player.index, PURPOSE), ctx.surface, entries, {
    goal_plates = ctx.params.plates or DEFAULT_PLATES,
  })
  cells[#cells + 1] = {zone = zone}
  return true
end

-- How many cells are worth having: enough that much of the goal is still missing.
local function wanted_cells(target, stock, max_cells)
  local remaining = math.max(0, target - stock)
  return math.min(max_cells, math.max(1, math.ceil(remaining / PLATES_PER_CELL)))
end

-- Collect finished plates from the furnace holding the most (at least `threshold`).
local function collect_from(ctx, cells, threshold)
  local best, best_n
  for _, cell in ipairs(cells) do
    if cell.furnace then
      local n = plates_in(cell.furnace)
      if n >= threshold and (not best or n > best_n) then best, best_n = cell.furnace, n end
    end
  end
  if not best then return nil end
  return start_transfer(ctx, {target = best, mode = "collect", item = "iron-plate", count = 0})
end

---------------------------------------------------------------------
-- Hand-smelting the first plates (needed to craft the drills)
---------------------------------------------------------------------

-- Produce `need` more plates with the ore the companion mines, spread over every furnace.
local function hand_smelt(ctx, furnaces, need)
  local fuelled = false
  local ore_in, least, least_n = 0, nil, nil
  for _, f in ipairs(furnaces) do
    local src = f.get_inventory(defines.inventory.furnace_source or defines.inventory.crafter_input)
    local n = src and src.get_item_count(ORE) or 0
    ore_in = ore_in + n
    if not least or n < least_n then least, least_n = f, n end
    if (fuel.energy_left(f) or 0) > 0 then fuelled = true end
  end
  if not fuelled then return "blocked", "the furnaces have no fuel (and I found none to give them)" end

  local shortfall = need - ore_in
  if shortfall <= 0 then return "working", string.format("smelting %d plates by hand", need) end

  local carried = carried_count(ctx, ORE)
  if carried >= shortfall then
    local share = math.ceil(need / #furnaces)
    return start_transfer(ctx, {
      target = least, mode = "insert", slot = "source", item = ORE,
      count = math.min(carried, math.max(1, share - least_n)),
    })
  end
  return start_mine(ctx, ORE, shortfall - carried, "hand-mining iron ore for the first plates")
end

---------------------------------------------------------------------
-- Objective
---------------------------------------------------------------------

local def = {
  id = "iron_start",
  caption = "First iron plates",
  implemented = true,

  step = function(ctx)
    local player, data = ctx.player, ctx.data
    ctx.surface = data.entity.surface
    local idx = player.index
    local target = ctx.params.plates or DEFAULT_PLATES
    local max_cells = ctx.params.cells or DEFAULT_CELLS

    local cells, blocked = read_cells(ctx)
    if not cells then return "blocked", blocked end

    local plates = have(ctx, "iron-plate")
    local pending, furnaces, drills = 0, {}, 0
    local missing_furnaces, missing_drills = 0, 0
    for _, cell in ipairs(cells) do
      if cell.furnace then
        furnaces[#furnaces + 1] = cell.furnace
        pending = pending + plates_in(cell.furnace)
      else
        missing_furnaces = missing_furnaces + 1
      end
      if cell.drill then drills = drills + 1 else missing_drills = missing_drills + 1 end
    end

    -- Goal met: nothing more to build, but the machines keep producing - fetch their plates
    -- now and then (fuel is kept up by scripts/upkeep.lua).
    local power_planned = #zones.list(idx, "power") > 0
    if power_planned or plates >= target then
      if not data.task then
        local status, note = collect_from(ctx, cells, COLLECT_AT_IDLE)
        if status then return status, note end
      end
      return "satisfied", power_planned and "power plant already planned"
        or string.format("%d iron plates ready", plates)
    end

    -- 1. first cells
    if #cells == 0 then
      local want = wanted_cells(target, plates, max_cells)
      local err
      for _ = 1, math.min(START_CELLS, want) do
        local ok
        ok, err = new_cell(ctx, cells)
        if not ok then break end
      end
      if #cells == 0 then return "blocked", "cannot plan iron: " .. err end
      return "working", string.format("assigned %d iron cell(s): burner drill -> stone furnace", #cells)
    end

    if data.task then return "working", "busy: " .. (data.status or "task") end

    -- 2. the goal is within reach of what the furnaces already hold
    if plates + pending >= target then
      local status, note = collect_from(ctx, cells, 1)
      if status then return status, note end
    end

    -- 3. furnaces first (5 stone each): hand-smelting scales with their number
    if missing_furnaces > 0 then
      local stone_needed = 5 * missing_furnaces
      local stone = have(ctx, "stone")
      if stone < stone_needed then
        return start_mine(ctx, "stone", stone_needed - stone, "hand-mining stone for the furnaces")
      end
      return "working", "waiting for the furnaces to be built"
    end

    -- 4. burner drills (plates + a furnace worth of stone each)
    if missing_drills > 0 then
      if can_make(ctx, "burner-mining-drill", 1) then return "working", "waiting for the burner drill" end

      local raw = raw_cost(ctx, "burner-mining-drill")
      -- line up plates for as many drills as there are furnaces to smelt them
      local batch = math.max(1, math.min(missing_drills, #furnaces))

      local stone_missing = (raw["stone"] or 0) * batch - have(ctx, "stone")
      if stone_missing > 0 then return start_mine(ctx, "stone", stone_missing, "hand-mining stone for the drills") end

      local first_missing = (raw["iron-plate"] or 0) - plates
      if first_missing > 0 and pending >= first_missing then
        local status, note = collect_from(ctx, cells, 1)
        if status then return status, note end
      end
      local need = (raw["iron-plate"] or 0) * batch - plates - pending
      if need > 0 then return hand_smelt(ctx, furnaces, need) end
      return "working", "smelting plates for the next drill"
    end

    -- 5a. coal first: two self-feeding coal drills save a lot of hand-mining, so they come
    --     before scaling the iron up (when they can't be built, iron carries on)
    local cstatus, cnote = coal.step(ctx)
    if cstatus == "working" then return cstatus, cnote end

    -- 5. everything planned is built: grow while much of the goal is still missing
    local want = wanted_cells(target, plates + pending, max_cells)
    if #cells < want then
      local ok, err = new_cell(ctx, cells)
      if ok then
        return "working", string.format("scaling up: planned iron cell %d of %d", #cells, want)
      end
      -- no room for more: carry on with what there is
    end

    -- 6. production
    local status, note = collect_from(ctx, cells, math.min(COLLECT_AT, target - plates))
    if status then return status, note end
    return "working", string.format("producing plates: %d/%d (%d drills)", plates, target, drills)
  end,
}

-- For other objectives: collect finished plates from the iron cells (starts a transfer task).
-- Returns status, note, or nil when no furnace holds `threshold` plates (default 1).
function def.collect(ctx, threshold)
  ctx.surface = ctx.data.entity.surface
  local cells = read_cells(ctx)
  if not cells then return nil end
  return collect_from(ctx, cells, threshold or 1)
end

return def
