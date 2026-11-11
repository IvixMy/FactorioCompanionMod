-- Shared code of the small assembler factories (science_factory.lua, belt_factory.lua).
--
-- A factory objective is described by a LOCAL TEMPLATE: a list of entities in local coordinates where
-- the first power pole is (0, 0), the row runs along +x and the "output side" is +y:
--
--   {name, x, y, direction, rotates, drop = {x, y}, recipe = "...", hand = {"item", ...}}
--
--   rotates : the direction turns with the layout (inserters, belts); chests / machines / poles don't
--   drop    : (inserters) the tile the inserter must drop onto
--   recipe  : (assembling machines) the recipe the machine is set to
--   hand    : (assembling machines) ingredients the companion puts in BY HAND; every other
--             ingredient arrives some other way (an inserter from another machine)
--   "pole" / "chest" are replaced by the pole / chest the companion actually uses.
--
-- This file turns the template into a plan:
--   * the factory is put on a free, dry spot (ring search around the power plant) that keeps `spacing` tiles
--     from every other factory, nearest to the power network first; both mirror images and all 4 turns are tried;
--   * a power line is run to it from the NEAREST POLE THAT HAS POWER: poles at most as far apart as the LOWER
--     of the two wire reaches, never inside another zone or the factory (see plan_line);
--   * the plan becomes a zone (scripts/zones.lua): ghosts, auto-build, permanent once built;
--   * built machines get their recipe, inserters are turned to drop where the template says;
--   * the machines are kept stocked by hand with `stock` crafts of every hand-fed ingredient.
--
-- BLUEPRINT ZONES: when the player assigned a blueprint to the objective's slot (scripts/bpslots.lua, menu
-- "Assign blueprints") the template is not used: the blueprint is placed as ghosts on a free dry spot (same
-- site search, spacing and power line as below, the line ends at the blueprint's nearest electric pole) and the
-- zone remembers the blueprint (zone.bp_str). Everything after planning is identical: auto-build, recipes,
-- power check, keeping the machines stocked. Ingredients that no other machine of the blueprint makes are the
-- ones fed by hand (derive_hand); whatever the blueprint's own inserters / belts carry is left to them.
--
-- def = {
--   id, caption, purpose,
--   slot,                                            -- blueprint slot (default: purpose)
--   blueprint_only,                                  -- no built-in layout: skipped until a blueprint is assigned
--   default_stock,                                   -- crafts kept in every machine (default 20)
--   gate(ctx, params)         -> status, note | nil  -- e.g. "satisfied", "waiting for research"
--   choose_mode(ctx, params)  -> mode string | nil   -- stored on the zone, passed to template
--   template(ctx, params, mode) -> local template
--   zone_extra(ctx, params)   -> table | nil         -- more fields for the zone
--   output_note(chests)       -> string | nil        -- shown when everything is stocked
--   upkeep_scope              -- zone purposes whose burners are refuelled while this objective is the focus
--   output_slots              -> number | nil        -- output chests are limited to this many slots (the machines
--                                                       stop when full instead of eating plates for ever)
--   spacing                                          -- tiles of free space kept between this factory and every
--                                                       other one (default 0); params.spacing overrides it
--   legacy(ctx, params)       -> recipe, hand | nil  -- zones saved before machines carried a recipe:
--                                                       their assembling machines get this one
-- }

local names = require("scripts.names")
local common   = require("scripts.common")
local geometry = require("scripts.geometry")
local zones    = require("scripts.zones")
local supply   = require("scripts.supply")
local tasks    = require("scripts.tasks")
local planner  = require("scripts.planner")
local poles    = require("scripts.poles")
local blueprints = require("scripts.blueprints")
local bpslots  = require("scripts.bpslots")
local debug    = require("scripts.debug")
local iron     = require("scripts.objectives.iron_start")
local lab      = require("scripts.objectives.lab")

local M = {}

local INSERTER = "inserter"
local RESTOCK_BELOW = 0.25    -- top a machine up once a hand-fed ingredient is below this fraction of `stock`
local CONNECT_TIMEOUT = 600   -- ticks a built machine may take to show up in the generators' network
local DEFAULT_STOCK = 20
local PARTIAL_LOAD = 15       -- hand-fed items: deliver as soon as the companion carries this many

local DIR = defines.direction
local GENERATORS = {["steam-engine"] = true, ["steam-turbine"] = true, ["solar-panel"] = true, ["burner-generator"] = true}

-- the four directions the pole chain can leave an engine in; `turns` rotates the template (+x = east)
local SIDES = {
  {dx = 1,  dy = 0,  turns = 0},
  {dx = 0,  dy = 1,  turns = 1},
  {dx = -1, dy = 0,  turns = 2},
  {dx = 0,  dy = -1, turns = 3},
}

---------------------------------------------------------------------
-- Small helpers
---------------------------------------------------------------------

local function snap(v) return math.floor(v) + 0.5 end

local function carried_count(ctx, item)
  return ctx.data.entity.get_main_inventory().get_item_count(item)
end

local function area_is_dry_and_clear(surface, area)
  if surface.count_entities_filtered{area = area, type = "resource", limit = 1} > 0 then return false end
  local ok, water = pcall(function()
    return surface.count_tiles_filtered{area = area, collision_mask = "water_tile", limit = 1}
  end)
  return not (ok and water > 0)
end

local function entry_entity(found, entry)
  local f = found[zones.key(entry.name, {x = entry.x, y = entry.y})]
  return f and not f.ghost and f.entity.valid and f.entity or nil
end

-- Generators as {name, x, y, direction}: planned ones of the power zones, else the built ones.
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
-- Template helpers (exported so objectives can build their templates)
---------------------------------------------------------------------

-- Collects template entries: tpl:add(name, x, y, direction, rotates, extra)
function M.new_template()
  local tpl = {}
  function tpl.add(name, x, y, direction, rotates, extra)
    local e = {name = name, x = x, y = y, direction = direction or DIR.north, rotates = rotates or false}
    for k, v in pairs(extra or {}) do e[k] = v end
    tpl[#tpl + 1] = e
    return e
  end
  return tpl
end

-- Item ingredients of a recipe that the companion must hand-feed: all of them except `skip` (a set).
function M.hand_items(force, recipe_name, skip)
  local out = {}
  local recipe = force.recipes[recipe_name]
  if not recipe then return out end
  for _, ing in ipairs(recipe.ingredients) do
    if ing.type == "item" and not (skip and skip[ing.name]) then out[#out + 1] = ing.name end
  end
  return out
end

local function amount_of(force, recipe_name, item)
  local recipe = force.recipes[recipe_name]
  if recipe then
    for _, ing in ipairs(recipe.ingredients) do
      if ing.name == item then return ing.amount end
    end
  end
  return 1
end

local function flip_dir(d)
  if d == DIR.north then return DIR.south elseif d == DIR.south then return DIR.north end
  return d
end

-- Local template -> world entries. origin = the first pole; flip mirrors the output side.
function M.place_template(tpl, origin, turns, flip, names)
  local out = {}
  for _, e in ipairs(tpl) do
    local x, y, d = e.x, e.y, e.direction
    local drop = e.drop and {x = e.drop.x, y = e.drop.y} or nil
    if flip then
      y = -y
      if drop then drop.y = -drop.y end
      if e.rotates then d = flip_dir(d) end
    end
    local rx, ry = geometry.rotate(x, y, turns)
    if e.rotates then d = (d + turns * 4) % 16 end

    local entry = {}
    for k, v in pairs(e) do entry[k] = v end
    entry.rotates = nil
    entry.name = names[e.name] or e.name
    entry.x, entry.y, entry.direction = origin.x + rx, origin.y + ry, d
    if drop then
      local dx, dy = geometry.rotate(drop.x, drop.y, turns)
      entry.drop = {x = origin.x + dx, y = origin.y + dy}
    end
    out[#out + 1] = entry
  end
  return out
end

---------------------------------------------------------------------
-- Planning
---------------------------------------------------------------------

local function can_place_all(surface, force, entries)
  for _, e in ipairs(entries) do
    if not surface.can_place_entity{
      name = e.name, position = {e.x, e.y}, direction = e.direction, force = force,
      build_check_type = defines.build_check_type.ghost_place,
    } then return false end
  end
  return true
end

local function pick_chest(force)
  local iron_chest = force.recipes["iron-chest"]
  if iron_chest and iron_chest.enabled then return "iron-chest" end
  return "wooden-chest"
end

-- Purposes of the factory objectives (filled by M.new): their zones keep `spacing` tiles from each other.
local factory_purposes = {}

-- Boxes {x0, y0, x1, y1} of every factory zone on the surface (the rectangle of the machines).
local function factory_boxes(idx, surface_index)
  local boxes = {}
  for _, zone in ipairs(zones.all(idx)) do
    local family = zone.purpose:gsub("_%d+$", "")
    if factory_purposes[family] and zone.surface_index == surface_index then
      boxes[#boxes + 1] = {x0 = zone.x0, y0 = zone.y0, x1 = zone.x1, y1 = zone.y1}
    end
  end
  return boxes
end

-- Distance between two rectangles along the axis where they are furthest apart (0 when they touch).
local function box_gap(a, b)
  local dx = math.max(a.x0 - b.x1, b.x0 - a.x1, 0)
  local dy = math.max(a.y0 - b.y1, b.y0 - a.y1, 0)
  return math.max(dx, dy)
end

local function point_box(x, y)
  return {x0 = math.floor(x), y0 = math.floor(y), x1 = math.floor(x) + 1, y1 = math.floor(y) + 1}
end

-- Are the chunks under the factory and under every pole of the chain generated?
local function generated(surface, box, chain)
  local function chunk(x, y) return surface.is_chunk_generated{x = math.floor(x / 32), y = math.floor(y / 32)} end
  for x = box.x0 - 1, box.x1 + 32, 32 do
    for y = box.y0 - 1, box.y1 + 32, 32 do
      if not chunk(math.min(x, box.x1 + 1), math.min(y, box.y1 + 1)) then return false end
    end
  end
  for _, p in ipairs(chain) do
    if not chunk(p.x, p.y) then return false end
  end
  return true
end

local MAX_LINE = 60                   -- poles of one power line, at most
local LINE_OFFSETS = {0, 1, -1, 2, -2, 3, -3}
local ZONE_PAD = 3                   -- free tiles kept between the machines and any other zone
local TRIED_SITES = 80               -- sites that get the expensive checks (the nearest to the power first)

local function dist(ax, ay, bx, by) return math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2) end

-- Power line from `src` (a pole that has power: {x, y, reach}) to `to` (the factory's first pole):
-- poles at most `reach` apart, where reach is the LOWEST of the two poles' wire reaches (the existing
-- one and the one that is placed). Each new pole goes as far along the way as it can, never inside
-- another zone or the factory, and is moved sideways when the spot is taken. nil when it gets stuck.
local function plan_line(ctx, pole, src, to, fpad)
  local surface, force, idx = ctx.surface, ctx.player.force, ctx.player.index
  local reach = math.min(src.reach, pole.reach) - 0.5
  local chain, cur = {}, {x = src.x, y = src.y}

  local function spot_ok(x, y)
    if x > fpad.x0 and x < fpad.x1 and y > fpad.y0 and y < fpad.y1 then return false end
    if zones.overlaps_any(idx, surface.index, point_box(x, y)) then return false end
    for _, c in ipairs(chain) do
      if c.x == x and c.y == y then return false end
    end
    if not surface.is_chunk_generated{x = math.floor(x / 32), y = math.floor(y / 32)} then return false end
    return surface.can_place_entity{
      name = pole.name, position = {x, y}, force = force,
      build_check_type = defines.build_check_type.ghost_place,
    }
  end

  for _ = 1, MAX_LINE do
    local d = dist(cur.x, cur.y, to.x, to.y)
    if d <= reach then return chain end
    local ux, uy = (to.x - cur.x) / d, (to.y - cur.y) / d
    local best
    for step = math.floor(reach), 2, -1 do
      for _, off in ipairs(LINE_OFFSETS) do
        local x, y = snap(cur.x + ux * step - uy * off), snap(cur.y + uy * step + ux * off)
        if dist(cur.x, cur.y, x, y) <= reach and dist(x, y, to.x, to.y) < d - 1 and spot_ok(x, y) then
          best = {x = x, y = y}
          break
        end
      end
      if best then break end
    end
    if not best then return nil end
    chain[#chain + 1] = {name = pole.name, x = best.x, y = best.y, direction = DIR.north}
    cur = best
    reach = pole.reach - 0.5 -- new pole to new pole
  end
  return nil
end

-- One search at a fixed `gap` (tiles between this factory and every other one).
-- Sites are tried in rings around the power plant; those nearest to a pole that HAS POWER come first.
-- The factory is placed first, then a power line is run to it from the nearest powered pole(s).
-- Returns entries (line poles first, then the factory), the number of line poles and the factory's box;
-- nil when nothing fits; nil, error when there is nothing to connect to.
local function search_site(ctx, pole, tpl, gens, names, gap)
  local surface, force, idx = ctx.surface, ctx.player.force, ctx.player.index

  local nets = generator_networks(ctx)
  local powered = {}
  for _, e in pairs(surface.find_entities_filtered{type = "electric-pole", force = force}) do
    local id = e.electric_network_id
    if id and nets[id] then
      powered[#powered + 1] = {x = e.position.x, y = e.position.y, reach = poles.reach_of(e.name)}
    end
  end
  if #powered == 0 then return nil, "no electric pole with power found to connect the factory to" end

  local ax, ay = 0, 0
  for _, g in ipairs(gens) do ax, ay = ax + g.x, ay + g.y end
  ax, ay = ax / #gens, ay / #gens

  local others = gap > 0 and factory_boxes(idx, surface.index) or {}
  local cands = {}
  for r = 0, gap + 140, 6 do
    local n = r == 0 and 1 or math.min(32, math.max(8, math.floor(2 * math.pi * r / 10)))
    for a = 0, n - 1 do
      local ang = 2 * math.pi * a / n
      local ox, oy = snap(ax + r * math.cos(ang)), snap(ay + r * math.sin(ang))
      local near = math.huge
      for _, p in ipairs(powered) do near = math.min(near, dist(p.x, p.y, ox, oy)) end

      for turns = 0, 3 do
        for _, flip in ipairs({false, true}) do
          local factory = M.place_template(tpl, {x = ox, y = oy}, turns, flip, names)
          local x0, y0, x1, y1 = geometry.bbox_of(factory, 0)
          local fbox = {x0 = x0, y0 = y0, x1 = x1, y1 = y1}
          local ok = true
          for _, o in ipairs(others) do
            if box_gap(fbox, o) < gap then ok = false break end
          end
          if ok and zones.overlaps_any(idx, surface.index,
            {x0 = x0 - ZONE_PAD, y0 = y0 - ZONE_PAD, x1 = x1 + ZONE_PAD, y1 = y1 + ZONE_PAD}) then ok = false end
          if ok then cands[#cands + 1] = {d = near, ox = ox, oy = oy, turns = turns, flip = flip} end
        end
      end
    end
  end
  table.sort(cands, function(a, b) return a.d < b.d end)

  for i = 1, math.min(#cands, TRIED_SITES) do
    local c = cands[i]
    local factory = M.place_template(tpl, {x = c.ox, y = c.oy}, c.turns, c.flip, names)
    local x0, y0, x1, y1 = geometry.bbox_of(factory, 0)
    local fbox = {x0 = x0, y0 = y0, x1 = x1, y1 = y1}
    local fpad = {x0 = x0 - 1, y0 = y0 - 1, x1 = x1 + 1, y1 = y1 + 1}

    if generated(surface, fbox, {})
      and area_is_dry_and_clear(surface, {{fpad.x0, fpad.y0}, {fpad.x1, fpad.y1}})
      and can_place_all(surface, force, factory) then
      -- the three powered poles nearest to the factory's first pole
      table.sort(powered, function(p, q) return dist(p.x, p.y, c.ox, c.oy) < dist(q.x, q.y, c.ox, c.oy) end)
      for k = 1, math.min(3, #powered) do
        local chain = plan_line(ctx, pole, powered[k], {x = c.ox, y = c.oy}, fpad)
        if chain then
          local entries = {}
          for _, e in ipairs(chain) do entries[#entries + 1] = e end
          for _, e in ipairs(factory) do entries[#entries + 1] = e end
          return entries, #chain, fbox, {src = {x = powered[k].x, y = powered[k].y}, origin = {x = c.ox, y = c.oy}}
        end
      end
    end
  end
  return nil
end

-- Returns entries (power line first, then the factory), the number of line poles, the box of the machines
-- and the spacing that was achieved; or nil, error.
--
-- `spacing`: tiles of free space wanted between this factory and every other factory (the base spreads out
-- and keeps room to grow). The factory is put where that room exists, near the power network; the power
-- line is then run to it from the nearest pole that has power (see plan_line) and only the machines
-- reserve ground (zone.box). When no spot with that much room exists the spacing is lowered step by
-- step (75 %, 50 %, 25 %, 0) instead of giving up.
local function plan_factory(ctx, pole, tpl, spacing)
  local gens = generators(ctx)
  if #gens == 0 then return nil, "no generator found to connect the factory to" end

  local names = {pole = pole.name, chest = pick_chest(ctx.player.force)}

  local ladder = {spacing}
  if spacing > 0 then
    for _, f in ipairs({0.75, 0.5, 0.25}) do ladder[#ladder + 1] = math.floor(spacing * f) end
    ladder[#ladder + 1] = 0
  end
  for _, gap in ipairs(ladder) do
    local entries, n, fbox, line = search_site(ctx, pole, tpl, gens, names, gap)
    if entries then return entries, n, fbox, gap, line end
    if n then return nil, n end -- nothing to connect to: no point in trying other spacings
  end
  return nil, "no free spot with a power line to it (checked sites all around the power plant)"
end

---------------------------------------------------------------------
-- Planning from a blueprint
---------------------------------------------------------------------

local BP_TRIALS = 24   -- trial placements per search (each one is rolled back when it does not fit)
local BP_VISITS = 500  -- candidate spots looked at per search

local function turned_size(bp, direction)
  if direction == DIR.east or direction == DIR.west then return bp.h, bp.w end
  return bp.w, bp.h
end

local function box_of(entries)
  local x0, y0, x1, y1 = geometry.bbox_of(entries, 0)
  return {x0 = x0, y0 = y0, x1 = x1, y1 = y1}
end

-- The electric pole of the placed blueprint nearest to `p` (the power line ends there).
local function nearest_bp_pole(entries, p)
  local best, best_d
  for _, e in ipairs(entries) do
    local proto = prototypes.entity[e.name]
    if proto and proto.type == "electric-pole" then
      local d = dist(e.x, e.y, p.x, p.y)
      if not best_d or d < best_d then best, best_d = e, d end
    end
  end
  return best
end

-- One search at a fixed `gap`. Spots are visited nearest-to-a-powered-pole first; at each one the blueprint is
-- really placed as ghosts (all four turns are tried) and rolled back unless EVERY entity could be placed, the
-- spacing holds and a power line can be run to it. Returns entries (line poles first, then the blueprint's
-- entities), the number of line poles, the box of the blueprint, the line and {pos, dir}; nil when nothing
-- fits; nil, error when there is nothing to connect to.
local function search_bp_site(ctx, pole, bp, gens, gap)
  local surface, force, idx = ctx.surface, ctx.player.force, ctx.player.index

  local nets = generator_networks(ctx)
  local powered = {}
  for _, e in pairs(surface.find_entities_filtered{type = "electric-pole", force = force}) do
    local id = e.electric_network_id
    if id and nets[id] then
      powered[#powered + 1] = {x = e.position.x, y = e.position.y, reach = poles.reach_of(e.name)}
    end
  end
  if #powered == 0 then return nil, "no electric pole with power found to connect the factory to" end

  local ax, ay = 0, 0
  for _, g in ipairs(gens) do ax, ay = ax + g.x, ay + g.y end
  ax, ay = ax / #gens, ay / #gens

  local others = gap > 0 and factory_boxes(idx, surface.index) or {}
  local cands = {}
  for r = 0, gap + 140, 6 do
    local n = r == 0 and 1 or math.min(32, math.max(8, math.floor(2 * math.pi * r / 10)))
    for a = 0, n - 1 do
      local ang = 2 * math.pi * a / n
      local ox, oy = snap(ax + r * math.cos(ang)), snap(ay + r * math.sin(ang))
      local near = math.huge
      for _, p in ipairs(powered) do near = math.min(near, dist(p.x, p.y, ox, oy)) end

      for _, direction in ipairs({DIR.north, DIR.east, DIR.south, DIR.west}) do
        local w, h = turned_size(bp, direction)
        local box = {x0 = ox - w / 2, y0 = oy - h / 2, x1 = ox + w / 2, y1 = oy + h / 2}
        local ok = true
        for _, o in ipairs(others) do
          if box_gap(box, o) < gap then ok = false break end
        end
        if ok and zones.overlaps_any(idx, surface.index,
          {x0 = box.x0 - ZONE_PAD, y0 = box.y0 - ZONE_PAD, x1 = box.x1 + ZONE_PAD, y1 = box.y1 + ZONE_PAD}) then ok = false end
        if ok then cands[#cands + 1] = {d = near, ox = ox, oy = oy, dir = direction, box = box} end
      end
    end
  end
  table.sort(cands, function(a, b) return a.d < b.d end)

  local trials = 0
  for i = 1, math.min(#cands, BP_VISITS) do
    local c = cands[i]
    local pad = {x0 = c.box.x0 - 1, y0 = c.box.y0 - 1, x1 = c.box.x1 + 1, y1 = c.box.y1 + 1}
    if generated(surface, c.box, {}) and area_is_dry_and_clear(surface, {{pad.x0, pad.y0}, {pad.x1, pad.y1}}) then
      trials = trials + 1
      local ghosts = blueprints.stamp_ghosts(surface, force, bp, {x = c.ox, y = c.oy}, c.dir)
      local placed = 0
      for _, g in ipairs(ghosts) do
        if g.valid and g.type == "entity-ghost" then placed = placed + 1 end
      end

      if placed == bp.n then
        local entries = blueprints.ghost_entries(ghosts)
        local fbox = box_of(entries)
        local fpad = {x0 = fbox.x0 - 1, y0 = fbox.y0 - 1, x1 = fbox.x1 + 1, y1 = fbox.y1 + 1}

        -- the real footprint (not the estimate) must keep to the spacing and stay clear of the other zones
        local ok = true
        for _, o in ipairs(others) do
          if box_gap(fbox, o) < gap then ok = false break end
        end
        if ok and zones.overlaps_any(idx, surface.index,
          {x0 = fbox.x0 - ZONE_PAD, y0 = fbox.y0 - ZONE_PAD, x1 = fbox.x1 + ZONE_PAD, y1 = fbox.y1 + ZONE_PAD}) then ok = false end

        if ok then
          table.sort(powered, function(p, q) return dist(p.x, p.y, c.ox, c.oy) < dist(q.x, q.y, c.ox, c.oy) end)
          for k = 1, math.min(3, #powered) do
            local target = nearest_bp_pole(entries, powered[k])
            local chain = target and plan_line(ctx, pole, powered[k], {x = target.x, y = target.y}, fpad)
            if chain then
              local all = {}
              for _, e in ipairs(chain) do all[#all + 1] = e end
              for _, e in ipairs(entries) do all[#all + 1] = e end
              return all, #chain, fbox,
                {src = {x = powered[k].x, y = powered[k].y}, origin = {x = target.x, y = target.y}},
                {pos = {x = c.ox, y = c.oy}, dir = c.dir}
            end
          end
        end
      end

      -- did not fit: take the trial placement back
      for _, g in ipairs(ghosts) do
        if g.valid then g.destroy() end
      end
      if trials >= BP_TRIALS then break end
    end
  end
  return nil
end

-- Same contract as plan_factory (+ the placement info at the end). The spacing is lowered step by step
-- when no spot has that much room.
local function plan_blueprint(ctx, pole, bp, spacing)
  if bp.poles == 0 then
    return nil, "the blueprint has no electric pole, so it cannot be connected to the power plant"
  end
  local gens = generators(ctx)
  if #gens == 0 then return nil, "no generator found to connect the factory to" end

  local ladder = {spacing}
  if spacing > 0 then
    for _, f in ipairs({0.75, 0.5, 0.25}) do ladder[#ladder + 1] = math.floor(spacing * f) end
    ladder[#ladder + 1] = 0
  end
  for _, gap in ipairs(ladder) do
    local entries, n, fbox, line, info = search_bp_site(ctx, pole, bp, gens, gap)
    if entries then return entries, n, fbox, gap, line, info end
    if n then return nil, n end
  end
  return nil, string.format("no free dry spot for the %dx%d blueprint with a power line to it", bp.w, bp.h)
end

-- Recipes and hand-fed ingredients of a blueprint zone, worked out from what the zone really holds.
-- A machine's recipe is read from its ghost / building. Once every assembling machine stands, the
-- ingredients that NO OTHER machine of the zone makes are the ones the companion feeds by hand.
local function bp_refresh(zone, found, force)
  local complete = true
  local machines = {}
  for _, e in ipairs(zone.entries) do
    local proto = prototypes.entity[e.name]
    if proto and proto.type == "assembling-machine" then
      if not e.recipe then
        local f = found[zones.key(e.name, {x = e.x, y = e.y})]
        if f and f.entity.valid then
          local ok, r = pcall(function() return f.entity.get_recipe() end)
          if ok and r then e.recipe = type(r) == "string" and r or r.name end
          if not e.recipe and not f.ghost then e.no_recipe = true end -- stands, has no recipe: nothing to feed
        end
        if not e.recipe and not e.no_recipe then complete = false end
      end
      if e.recipe then machines[#machines + 1] = e end
    end
  end
  if not complete then return end

  for _, e in ipairs(machines) do
    local recipe = force.recipes[e.recipe]
    e.hand = {}
    if recipe then
      for _, ing in ipairs(recipe.ingredients) do
        if ing.type == "item" then
          local made_elsewhere = false
          for _, other in ipairs(machines) do
            local orecipe = other ~= e and force.recipes[other.recipe]
            if orecipe then
              for _, product in ipairs(orecipe.products) do
                if product.type == "item" and product.name == ing.name then made_elsewhere = true end
              end
            end
          end
          if not made_elsewhere then e.hand[#e.hand + 1] = ing.name end
        end
      end
    end
  end
end

---------------------------------------------------------------------
-- Built machines: recipe, inserter direction
---------------------------------------------------------------------

local function set_recipes(machines)
  for _, m in ipairs(machines) do
    if m.entity.valid then
      local r = m.entity.get_recipe()
      if not r or r.name ~= m.recipe then m.entity.set_recipe(m.recipe) end
    end
  end
end

-- An inserter must drop onto the tile the template meant. If the game's idea of "direction" is the
-- other way round, turn it (and the zone's plan, so a rebuilt ghost matches).
local function fix_inserters(inserters)
  for _, i in ipairs(inserters) do
    local ins, e = i.entity, i.entry
    if ins.valid and e.drop then
      local dp = ins.drop_position
      if dp and (math.abs(dp.x - e.drop.x) > 0.8 or math.abs(dp.y - e.drop.y) > 0.8) then
        local turned = (ins.direction + 8) % 16
        if pcall(function() ins.direction = turned end) then e.direction = turned end
      end
    end
  end
end

---------------------------------------------------------------------
-- The power line: make sure the wires are really there
---------------------------------------------------------------------

local function pole_at(surface, x, y)
  for _, e in pairs(surface.find_entities_filtered{
    area = {{x - 0.4, y - 0.4}, {x + 0.4, y + 0.4}}, type = "electric-pole",
  }) do
    return e
  end
  return nil
end

-- Wires: existing powered pole -> line poles (in order) -> the factory's first pole. Poles built from ghosts
-- normally connect themselves; this connects whatever did not (within the wire reach).
local function connect_line(zone)
  local line = zone.line
  if not (line and zone.line_poles) then return end
  local surface = game.get_surface(zone.surface_index)
  if not surface then return end

  local chain = {pole_at(surface, line.src.x, line.src.y)}
  for i = 1, zone.line_poles do
    local e = zone.entries[i]
    chain[#chain + 1] = e and pole_at(surface, e.x, e.y) or false
  end
  chain[#chain + 1] = pole_at(surface, line.origin.x, line.origin.y)

  for i = 1, #chain - 1 do
    local a, b = chain[i], chain[i + 1]
    if a and b and a.valid and b.valid then
      pcall(function()
        local ca = a.get_wire_connector(defines.wire_connector_id.pole_copper, true)
        local cb = b.get_wire_connector(defines.wire_connector_id.pole_copper, true)
        if not ca.is_connected_to(cb) then ca.connect_to(cb, false, defines.wire_origin.script) end
      end)
    end
  end
end

---------------------------------------------------------------------
-- Feeding by hand
---------------------------------------------------------------------

-- A "working" answer with no task started means the companion is only waiting for something, which
-- must not hold up the rest (refuelling...).
local function waiting_to_blocked(ctx, status, note)
  if status == "working" and not ctx.data.task then return "blocked", note end
  return status, note
end

-- Make sure the companion carries `need` of `item`. Returns nil when it does, else status, note.
local function acquire(ctx, item, need)
  local data, player = ctx.data, ctx.player
  local missing = need - carried_count(ctx, item)
  if missing <= 0 then return nil end

  -- 1. in a chest
  local chest = supply.find_chest(player.force, ctx.surface, item, "normal", missing, data.entity.position)
  if chest then
    tasks.start(data, tasks.new("fetch", {
      chest = chest, item = item, quality = "normal", count = missing,
      fetch = 1, fetch_max = missing, purpose = "the assemblers",
    }))
    return "working", "fetching " .. item .. " for the assemblers"
  end

  -- 2. craftable by hand (gear wheels)
  local pending = (data.pending or {})[item] or 0
  if pending >= missing then return "working", "crafting " .. item end
  local r = planner.craft_for(player, data, item, missing - pending, data.entity.position)
  if r == "queued" then return "working", "crafting " .. item end
  if type(r) == "table" then
    tasks.start(data, r)
    return "working", "fetching materials for " .. item
  end

  -- 3. raw plates: from the furnaces. Anything else: let the lab helper work out the raw materials.
  local status, note
  if item == "copper-plate" then
    status = lab.collect_copper(ctx)
    note = "collecting copper plates for the assemblers"
  elseif item == "iron-plate" then
    status = iron.collect(ctx, 1)
    note = "collecting iron plates for the assemblers"
  else
    status, note = lab.provide_materials(ctx, {[item] = missing - pending})
  end
  if status then return waiting_to_blocked(ctx, status, note) end
  return "blocked", "no " .. item .. " available for the assemblers"
end

-- Keeps every machine stocked with its hand-fed ingredients. Returns status, note.
local function feed(ctx, machines, stock)
  local data, force = ctx.data, ctx.player.force

  -- the machine that is lowest on any hand-fed ingredient (relative to what one stock is)
  local target, lowest
  for _, m in ipairs(machines) do
    for _, item in ipairs(m.hand) do
      local fill = m.entity.get_item_count(item) / (stock * amount_of(force, m.recipe, item))
      if fill < RESTOCK_BELOW and (not lowest or fill < lowest) then target, lowest = m, fill end
    end
  end
  if not target then
    return "satisfied", string.format("%d machines stocked for %d crafts", #machines, stock)
  end

  if data.task then return "working", "busy: " .. (data.status or "task") end

  -- how much of each hand-fed ingredient this machine is missing; make sure the companion has it all
  local needs = {}
  for _, item in ipairs(target.hand) do
    local count = stock * amount_of(force, target.recipe, item) - target.entity.get_item_count(item)
    if count > 0 then needs[#needs + 1] = {name = item, count = count} end
  end
  -- plates are scarce and other work (crafting belts for ghosts...) eats what the companion carries: deliver
  -- what it has once that is a useful amount, instead of waiting for a full load
  for _, n in ipairs(needs) do
    local have = carried_count(ctx, n.name)
    if have >= math.min(n.count, PARTIAL_LOAD) then
      n.count = math.min(n.count, have)
    else
      local status, note = acquire(ctx, n.name, n.count)
      if status then return status, note end
    end
  end

  -- deliver: one chained transfer per ingredient
  local chain
  for i = #needs, 1, -1 do
    chain = tasks.new("transfer", {
      target = target.entity, mode = "insert", slot = "machine", item = needs[i].name,
      count = needs[i].count, then_task = chain,
    })
  end
  if not chain then return "working", "stocking the machines" end
  tasks.start(data, chain)
  return "working", string.format("feeding %s (%s) by hand", target.entity.name, target.recipe)
end

---------------------------------------------------------------------
-- Objective factory
---------------------------------------------------------------------

function M.new(def)
  factory_purposes[def.purpose] = true
  return {
    id = def.id,
    caption = def.caption,
    implemented = true,
    upkeep_scope = def.upkeep_scope,

    step = function(ctx)
      local player, data = ctx.player, ctx.data
      local force, idx = player.force, player.index
      ctx.surface = data.entity.surface
      local params = ctx.params or {}
      local stock = params.stock or def.default_stock or DEFAULT_STOCK
      local bp = bpslots.get(idx, def.slot or def.purpose)

      local gate_status, gate_note = def.gate(ctx, params)
      if gate_status then return gate_status, gate_note end

      -- a zone without a built-in layout waits for the player's blueprint (a zone already placed is kept up)
      if def.blueprint_only and not bp and #zones.list(idx, def.purpose) == 0 then
        return "satisfied", "no blueprint assigned (" .. names.get() .. " menu > Assign blueprints)"
      end

      -- 1. every planned entity of the factory zones exists as a ghost or a building
      local machines, inserters, chests, missing_items, pending = {}, {}, {}, {}, 0
      for _, zone in ipairs(zones.list(idx, def.purpose)) do
        local surface = game.get_surface(zone.surface_index)
        if surface then
          if def.legacy and not zone.bp_str then
            for _, e in ipairs(zone.entries) do
              local proto = prototypes.entity[e.name]
              if not e.recipe and proto and proto.type == "assembling-machine" then
                e.recipe, e.hand = def.legacy(ctx, params)
              end
            end
          end
          local _, _, failed, found = zones.ensure_ghosts(zone, surface, force)
          if failed > 0 then
            local built = zones.progress(zone, force)
            if built == 0 then -- nothing stands there yet: drop the plan, it is planned again elsewhere
              for _, f in pairs(zones.index_entities(zone, force)) do
                if f.ghost and f.entity.valid then f.entity.destroy() end
              end
              zones.remove(idx, zone.purpose)
              return "working", "the factory spot can't be used, planning another one"
            end
            return "blocked", "the " .. def.caption:lower() .. " can't be completed (something in the way?)"
          end
          if zone.bp_str then bp_refresh(zone, found, force) end
          for _, e in ipairs(zone.entries) do
            local entity = entry_entity(found, e)
            if entity then
              if e.recipe then
                machines[#machines + 1] = {entity = entity, recipe = e.recipe, hand = e.hand or {}}
              elseif e.name == INSERTER then
                inserters[#inserters + 1] = {entity = entity, entry = e}
              elseif entity.type == "container" then
                chests[#chests + 1] = entity
              end
            else
              missing_items[e.name] = (missing_items[e.name] or 0) + 1
              pending = pending + 1
            end
          end
        end
      end

      -- whatever stands is set up at once, whether or not the rest is finished: recipes, inserters, wires, chests
      set_recipes(machines)
      fix_inserters(inserters)
      for _, zone in ipairs(zones.list(idx, def.purpose)) do connect_line(zone) end
      if def.output_slots then
        for _, c in ipairs(chests) do
          local inv = c.valid and c.get_inventory(defines.inventory.chest)
          if inv and inv.supports_bar() then inv.set_bar(def.output_slots + 1) end
        end
      end

      -- 2. planned yet?
      if #zones.list(idx, def.purpose) < 1 then
        local pole = poles.get_available_power_pole(ctx, 1, true)
        if not pole then return "blocked", "no electric pole is researched" end

        local spacing = params.spacing or def.spacing or 0
        local mode, tpl, entries, extra, fbox, gap, line, info
        if bp then
          -- a failed search places and removes trial ghosts: do not repeat it every second
          local st = ctx.state or {}
          if (st.bp_retry_at or 0) > game.tick then return "blocked", st.bp_note end
          entries, extra, fbox, gap, line, info = plan_blueprint(ctx, pole, bp, spacing)
          if not entries then
            st.bp_retry_at = game.tick + 600
            st.bp_note = "cannot plan the " .. def.caption:lower() .. " from the blueprint: " .. tostring(extra)
          end
        else
          mode = def.choose_mode and def.choose_mode(ctx, params) or nil
          tpl = def.template(ctx, params, mode)
          entries, extra, fbox, gap, line = plan_factory(ctx, pole, tpl, spacing)
        end
        if not entries then return "blocked", "cannot plan the " .. def.caption:lower() .. ": " .. extra end

        local zone_fields = {margin = 0, pole = pole.name, mode = mode, box = fbox, line = line, line_poles = extra}
        if bp then
          zone_fields.bp_str, zone_fields.bp_label = bp.str, bp.label
          zone_fields.bp_pos, zone_fields.bp_dir = info.pos, info.dir
        end
        for k, v in pairs(def.zone_extra and def.zone_extra(ctx, params) or {}) do zone_fields[k] = v end
        zones.create(player, zones.next_purpose(idx, def.purpose), ctx.surface, entries, zone_fields)

        local n_machines = 0
        if tpl then
          for _, e in ipairs(tpl) do if e.recipe then n_machines = n_machines + 1 end end
        else
          for _, e in ipairs(entries) do
            local proto = prototypes.entity[e.name]
            if proto and proto.type == "assembling-machine" then n_machines = n_machines + 1 end
          end
        end
        local source = bp and string.format("blueprint '%s'", bp.label) or "built-in layout"
        debug.say(player, string.format("%s planned from the %s: %d machines, mode %s, %d poles in the power line (%s), %d tiles from the other factories (wanted %d)",
          def.id, source, n_machines, mode or "-", extra, pole.status, gap, spacing))
        return "working", string.format("planned the %s from the %s (%d assembling machines, %d poles of power line from the nearest powered pole, %d tiles from other factories)",
          def.caption:lower(), source, n_machines, extra, gap)
      end

      -- 3. something is still a ghost: make sure the materials exist, then wait for the auto-build
      if pending > 0 then
        if data.task then return "working", "busy: " .. (data.status or "task") end
        local status, note = lab.provide_materials(ctx, missing_items)
        if status then return status, note end
        return "working", string.format("waiting for %d factory ghosts to be built", pending)
      end

      -- 4. built: is it on the generators' electric network?
      local nets = generator_networks(ctx)
      local connected = 0
      local zone = zones.list(idx, def.purpose)[1]
      for _, m in ipairs(machines) do
        local id = m.entity.electric_network_id
        if id and nets[id] then
          connected = connected + 1
          zone.connected_since = nil
        else
          zone.connected_since = zone.connected_since or game.tick
          if game.tick - zone.connected_since > CONNECT_TIMEOUT then
            return "blocked", "the assemblers are built but not connected to the power plant (is a pole missing?)"
          end
        end
      end
      if connected < #machines then return "working", "waiting for the assemblers to join the power network" end

      -- 5. (recipes and inserters were set up above)

      -- 6. keep the machines stocked by hand
      local status, note = feed(ctx, machines, stock)
      if status == "satisfied" and def.output_note then
        local extra_note = def.output_note(chests)
        if extra_note then note = note .. "; " .. extra_note end
      end
      return status, note
    end,
  }
end

return M
