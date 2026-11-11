-- Objective "science": a lab next to the power plant, connected to it with power poles.
--
-- The first science pack (automation) needs a lab. The companion
--   1. picks the pole to use with poles.get_available_power_pole (wooden pole first; takes one
--      from its logistics or creates it),
--   2. looks for a free, dry spot right next to the engines OUTSIDE every existing zone, and
--      reserves a "science" zone for it:
--
--            [engine] [pole] ... [pole] [LAB]        (the first pole touches the engine's
--                                                     supply area, every pole reaches the
--                                                     next one, the last one powers the lab)
--
--   3. lets the normal auto-build craft and place the ghosts; gathers what is missing by hand
--      (wood, stone) or from the furnaces (iron / copper plates),
--   4. checks that the lab really sits in the same electric network as the generators.
--
-- Once something of the zone is built it is permanent (scripts/zones.lua): the companion never
-- plans over it and puts back missing parts; it is only removed with "Erase" in the menu.
--
-- Params (playbook): labs (default 1).

local common   = require("scripts.common")
local geometry = require("scripts.geometry")
local zones    = require("scripts.zones")
local supply   = require("scripts.supply")
local crafting = require("scripts.crafting")
local tasks    = require("scripts.tasks")
local iron     = require("scripts.objectives.iron_start")
local poles    = require("scripts.poles")
local debug    = require("scripts.debug")

local PURPOSE = "science"
local LAB = "lab"
local DEFAULT_LABS = 1
local MAX_EXTRA_POLES = 3
local CONNECT_TIMEOUT = 600 -- ticks a built lab may take to show up in the network

local DIR = defines.direction
local GENERATORS = {["steam-engine"] = true, ["steam-turbine"] = true, ["solar-panel"] = true, ["burner-generator"] = true}

---------------------------------------------------------------------
-- Helpers (stock / crafting)
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

local function entry_entity(found, entry)
  local f = found[zones.key(entry.name, {x = entry.x, y = entry.y})]
  return f and not f.ghost and f.entity.valid and f.entity or nil
end

-- Collect finished copper plates from the copper cells (starts a transfer task).
local function collect_copper(ctx)
  local best, best_n
  for _, zone in ipairs(zones.list(ctx.player.index, "copper_start")) do
    for _, f in pairs(zones.index_entities(zone, ctx.player.force)) do
      if not f.ghost and f.entity.valid and f.entity.type == "furnace" then
        local out = f.entity.get_output_inventory()
        local n = out and out.get_item_count("copper-plate") or 0
        if n > 0 and (not best or n > best_n) then best, best_n = f.entity, n end
      end
    end
  end
  if not best then return nil end
  tasks.start(ctx.data, tasks.new("transfer", {target = best, mode = "collect", item = "copper-plate", count = 0}))
  return "working"
end

-- Gather the base materials for items that can't be made from what the companion has yet.
-- Returns status, note when something was started / is being waited for; nil when the normal
-- auto-build can go ahead (everything is available or craftable).
local function provide_materials(ctx, missing_items)
  for item, n in pairs(missing_items) do
    if not can_make(ctx, item, n) then
      local raw = raw_cost(ctx, item)
      local wood_missing = (raw["wood"] or 0) * n - have(ctx, "wood")
      if wood_missing > 0 then
        tasks.start(ctx.data, tasks.new("mine", {item = "wood", from_trees = true, target = carried_count(ctx, "wood") + wood_missing}))
        return "working", "chopping wood for the " .. item
      end
      local stone_missing = (raw["stone"] or 0) * n - have(ctx, "stone")
      if stone_missing > 0 then
        tasks.start(ctx.data, tasks.new("mine", {item = "stone", target = carried_count(ctx, "stone") + stone_missing}))
        return "working", "hand-mining stone for the " .. item
      end
      if (raw["iron-plate"] or 0) * n - have(ctx, "iron-plate") > 0 then
        local status = iron.collect(ctx, 1)
        if status then return status, "collecting iron plates for the " .. item end
        return "working", "waiting for iron plates for the " .. item
      end
      if (raw["copper-plate"] or 0) * n - have(ctx, "copper-plate") > 0 then
        local status = collect_copper(ctx)
        if status then return status, "collecting copper plates for the " .. item end
        return "working", "waiting for copper plates for the " .. item
      end
      return "working", "preparing the " .. item
    end
  end
  return nil
end

---------------------------------------------------------------------
-- Where are the engines?
---------------------------------------------------------------------

-- Generators as {name, x, y, direction}: the planned ones of the power zones, or (a plant that was
-- not planned by the companion) the built ones of the force.
local function generators(ctx)
  local list = {}
  for _, zone in ipairs(zones.list(ctx.player.index, "power")) do
    if zone.surface_index == ctx.surface.index then
      for _, e in ipairs(zone.entries or {}) do
        if GENERATORS[e.name] then list[#list + 1] = e end
      end
    end
  end
  if #list == 0 then
    for _, e in pairs(ctx.surface.find_entities_filtered{type = "generator", force = ctx.player.force, limit = 8}) do
      list[#list + 1] = {name = e.name, x = e.position.x, y = e.position.y, direction = e.direction}
    end
  end
  return list
end

local function snap(v) return math.floor(v) + 0.5 end

-- Resources or water under the area?
local function area_is_dry_and_clear(surface, area)
  if surface.count_entities_filtered{area = area, type = "resource", limit = 1} > 0 then return false end
  local ok, water = pcall(function()
    return surface.count_tiles_filtered{area = area, collision_mask = "water_tile", limit = 1}
  end)
  return not (ok and water > 0)
end

---------------------------------------------------------------------
-- Planning: poles from the engine, then the lab
---------------------------------------------------------------------

-- Candidate layouts, nearest to the engine first.
local function plan_lab(ctx, pole)
  local surface, force, idx = ctx.surface, ctx.player.force, ctx.player.index
  local gens = generators(ctx)
  if #gens == 0 then return nil, "no generator found to connect the lab to" end

  local step = math.max(2, math.min(6, math.floor(pole.reach) - 1)) -- tiles between poles
  local sides = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}}

  for extra = 0, MAX_EXTRA_POLES do
    for _, g in ipairs(gens) do
      local w, h = geometry.footprint(g.name)
      if g.direction == DIR.east or g.direction == DIR.west then w, h = h, w end

      for _, s in ipairs(sides) do
        -- first pole: 1.5 tiles beyond the engine's edge (just outside the plant's zone, still inside
        -- the pole's supply area), in the middle of that side
        local px = s[1] ~= 0 and (g.x + s[1] * (w / 2 + 1.5)) or snap(g.x)
        local py = s[2] ~= 0 and (g.y + s[2] * (h / 2 + 1.5)) or snap(g.y)
        px, py = snap(px), snap(py)

        local chain = {}
        for i = 0, extra do
          chain[#chain + 1] = {name = pole.name, x = px + s[1] * step * i, y = py + s[2] * step * i, direction = DIR.north}
        end
        local last = chain[#chain]

        for _, ld in ipairs({{s[1], s[2]}, {s[2], s[1]}, {-s[2], -s[1]}}) do
          -- the lab touches the last pole: its centre is 2 tiles from the pole
          local lab = {name = LAB, x = last.x + ld[1] * 2, y = last.y + ld[2] * 2, direction = DIR.north}
          local entries = {}
          for _, e in ipairs(chain) do entries[#entries + 1] = e end
          entries[#entries + 1] = lab

          local x0, y0, x1, y1 = geometry.bbox_of(entries, 0)
          local ok = area_is_dry_and_clear(surface, {{x0, y0}, {x1, y1}})
            and not zones.overlaps_any(idx, surface.index, {x0 = x0, y0 = y0, x1 = x1, y1 = y1})
          if ok then
            for _, e in ipairs(entries) do
              if not surface.can_place_entity{
                name = e.name, position = {e.x, e.y}, direction = e.direction, force = force,
                build_check_type = defines.build_check_type.ghost_place,
              } then ok = false break end
            end
          end
          if ok then return entries end
        end
      end
    end
  end
  return nil, "no free spot for a lab next to the engines (outside the other zones)"
end

---------------------------------------------------------------------
-- Power network check
---------------------------------------------------------------------

local function generator_networks(ctx)
  local ids = {}
  for _, e in pairs(ctx.surface.find_entities_filtered{
    type = {"generator", "solar-panel", "burner-generator"}, force = ctx.player.force,
  }) do
    local id = e.electric_network_id
    if id then ids[id] = true end
  end
  return ids
end

---------------------------------------------------------------------
-- Inserters of the zone (feed chest -> lab, lab -> lab)
---------------------------------------------------------------------

-- An inserter must drop onto the tile the plan meant. If the game's idea of "direction" is the other
-- way round, turn it (and the plan, so a rebuilt ghost matches).
local function fix_inserters(ctx)
  for _, zone in ipairs(zones.list(ctx.player.index, PURPOSE)) do
    local found
    for _, e in ipairs(zone.entries) do
      if e.drop then
        found = found or zones.index_entities(zone, ctx.player.force)
        local ins = entry_entity(found, e)
        local dp = ins and ins.drop_position
        if dp and (math.abs(dp.x - e.drop.x) > 0.8 or math.abs(dp.y - e.drop.y) > 0.8) then
          local turned = (ins.direction + 8) % 16
          if pcall(function() ins.direction = turned end) then e.direction = turned end
        end
      end
    end
  end
end

---------------------------------------------------------------------
-- Objective
---------------------------------------------------------------------

local def = {
  id = "science",
  caption = "Lab",
  implemented = true,

  step = function(ctx)
    local player, data = ctx.player, ctx.data
    local force, idx = player.force, player.index
    ctx.surface = data.entity.surface
    local wanted = (ctx.params and ctx.params.labs) or DEFAULT_LABS

    local recipe = force.recipes[LAB]
    if not (recipe and recipe.enabled) then return "satisfied", "labs are not available yet" end

    -- 1. every planned entity of every science zone exists as a ghost or a building
    local labs, missing_items, pending = {}, {}, 0
    for _, zone in ipairs(zones.list(idx, PURPOSE)) do
      local surface = game.get_surface(zone.surface_index)
      if surface then
        local _, _, failed, found = zones.ensure_ghosts(zone, surface, force)
        if failed > 0 then
          local built = zones.progress(zone, force)
          if built == 0 then -- nothing stands there yet: drop the plan, it is planned again elsewhere
            for _, f in pairs(zones.index_entities(zone, force)) do
              if f.ghost and f.entity.valid then f.entity.destroy() end
            end
            zones.remove(idx, zone.purpose)
            return "working", "the lab spot can't be used, planning another one"
          end
          return "blocked", "the lab or its poles can't be placed (something in the way?)"
        end
        for _, e in ipairs(zone.entries) do
          local entity = entry_entity(found, e)
          if entity then
            if e.name == LAB then labs[#labs + 1] = {entity = entity, zone = zone} end
          else
            missing_items[e.name] = (missing_items[e.name] or 0) + 1
            pending = pending + 1
          end
        end
      end
    end

    -- 2. enough lab zones planned?
    local planned = #zones.list(idx, PURPOSE)
    if planned < wanted then
      local pole = poles.get_available_power_pole(ctx, 1, true)
      if not pole then return "blocked", "no electric pole is researched" end
      local entries, err = plan_lab(ctx, pole)
      if not entries then return "blocked", "cannot plan the lab: " .. err end
      zones.create(player, zones.next_purpose(idx, PURPOSE), ctx.surface, entries, {margin = 0, pole = pole.name})
      debug.say(player, string.format("lab zone planned with %d x %s (%s)", #entries - 1, pole.name, pole.status))
      return "working", string.format("assigned a lab zone next to the engines (%d x %s + lab)", #entries - 1, pole.name)
    end

    -- 3. something is still a ghost: make sure the materials exist, then wait for the auto-build
    if pending > 0 then
      if data.task then return "working", "busy: " .. (data.status or "task") end
      local status, note = provide_materials(ctx, missing_items)
      if status then return status, note end
      return "working", string.format("waiting for %d lab/pole ghosts to be built", pending)
    end

    fix_inserters(ctx)

    -- 4. built: is the lab on the generators' electric network?
    local nets = generator_networks(ctx)
    local connected = 0
    for _, l in ipairs(labs) do
      local id = l.entity.electric_network_id
      if id and nets[id] then
        connected = connected + 1
        l.zone.connected_since = nil
      else
        l.zone.connected_since = l.zone.connected_since or game.tick
        if game.tick - l.zone.connected_since > CONNECT_TIMEOUT then
          return "blocked", "the lab is built but not connected to the power plant (is a pole missing?)"
        end
      end
    end
    if connected < #labs then return "working", "waiting for the lab to join the power network" end
    return "satisfied", string.format("%d lab(s) connected to power", connected)
  end,
}

-- shared with the research objective: gather the base materials of items that can't be made yet
def.provide_materials = provide_materials
-- shared with the science factory: fetch finished copper plates from the copper cells
def.collect_copper = collect_copper

return def
