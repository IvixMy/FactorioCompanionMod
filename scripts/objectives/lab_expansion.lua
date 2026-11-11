-- Objective "lab_expansion": grows the EXISTING lab zone ("science") until the labs use up all the
-- science the science factory makes. It never creates a second zone: the new parts are added to the
-- entries of the zone that already holds the first lab (zones.set_entries), where the normal
-- "science" objective ghosts, builds and power-checks them like everything else.
--
--   1. The rate calculator (scripts/rates.lua, same formulas as the Rate Calculator mod) measures
--      what the science factory makes per second and what ONE lab uses for the current research.
--      labs needed = ceil(made / used by one lab), at least 1, at most `max_labs`.
--   2. A chest + inserter is added next to the first ("parent") lab. The companion drops the packs into
--      that chest instead of choosing a lab; the inserter hands them to the parent lab.
--   3. Every further lab is a "child": 1 free tile away from its parent, an inserter in that gap takes
--      packs from the parent and puts them into the child, a pole in the gap powers both:
--
--        [pole]--[parent lab] [ins>] [child lab] [ins>] [child lab] ...      (line away from the pole)
--                    [ins^]  [pole]  [pole]
--                    [chest]
--
--      The line continues away from the pole chain; when it is blocked the next lab hangs on the side
--      of any lab (dir, then the two perpendicular ones).
--
-- Labs are only ever added, never removed. Entries carry `role = "lab_feed"` (the chest) so other code
-- can tell that chest from the science factory's output chests.
--
-- Params (playbook): max_labs (default 8), tech (research to size the labs for when none is running),
-- after_tech (no lab is added before this technology is researched; the feed chest is).

local zones    = require("scripts.zones")
local geometry = require("scripts.geometry")
local rates    = require("scripts.rates")
local poles    = require("scripts.poles")
local debug    = require("scripts.debug")

local LAB = "lab"
local INSERTER = "inserter"
local FEED_ROLE = "lab_feed"
local DEFAULT_MAX_LABS = 8
local RETRY_TICKS = 900   -- wait this long before looking for room again after a failed search

---------------------------------------------------------------------
-- Zone helpers
---------------------------------------------------------------------

-- The lab zone this objective grows: the first "science" zone that has a lab entry.
local function lab_zone(idx)
  for _, zone in ipairs(zones.list(idx, "science")) do
    for _, e in ipairs(zone.entries or {}) do
      if e.name == LAB then return zone end
    end
  end
  return nil
end

local function entries_named(zone, name)
  local out = {}
  for _, e in ipairs(zone.entries) do
    if e.name == name then out[#out + 1] = e end
  end
  return out
end

local function is_pole(name)
  local proto = prototypes.entity[name]
  return proto ~= nil and proto.type == "electric-pole"
end

-- Unit vector the lab line runs in: from the pole that powers the first lab to that lab.
local function line_direction(zone, parent)
  local best, best_d
  for _, e in ipairs(zone.entries) do
    if is_pole(e.name) then
      local d = (e.x - parent.x) ^ 2 + (e.y - parent.y) ^ 2
      if not best or d < best_d then best, best_d = e, d end
    end
  end
  if not best then return {x = 1, y = 0} end
  local ux, uy = geometry.unit(parent.x - best.x, parent.y - best.y)
  return {x = ux, y = uy}
end

-- Tiles taken by the zone's entries (and by `extra`), as a set.
local function occupied_tiles(entries)
  local set = {}
  for _, e in ipairs(entries) do
    local w, h = geometry.footprint(e.name)
    local x0, y0 = math.floor(e.x - w / 2 + 0.01), math.floor(e.y - h / 2 + 0.01)
    for i = 0, w - 1 do
      for j = 0, h - 1 do set[(x0 + i) .. "," .. (y0 + j)] = true end
    end
  end
  return set
end

local function tiles_free(set, entry)
  local w, h = geometry.footprint(entry.name)
  local x0, y0 = math.floor(entry.x - w / 2 + 0.01), math.floor(entry.y - h / 2 + 0.01)
  for i = 0, w - 1 do
    for j = 0, h - 1 do
      if set[(x0 + i) .. "," .. (y0 + j)] then return false end
    end
  end
  return true
end

local function area_is_dry_and_clear(surface, area)
  if surface.count_entities_filtered{area = area, type = "resource", limit = 1} > 0 then return false end
  local ok, water = pcall(function()
    return surface.count_tiles_filtered{area = area, collision_mask = "water_tile", limit = 1}
  end)
  return not (ok and water > 0)
end

-- Are all `new` entries placeable (no clash with the zone's own plan, other zones, ore, water, buildings)?
local function can_place_new(ctx, zone, new)
  local surface, force, idx = ctx.surface, ctx.player.force, ctx.player.index
  local taken = occupied_tiles(zone.entries)
  for _, e in ipairs(new) do
    if not tiles_free(taken, e) then return false end
  end
  local x0, y0, x1, y1 = geometry.bbox_of(new, 0)
  if not area_is_dry_and_clear(surface, {{x0, y0}, {x1, y1}}) then return false end
  if zones.overlaps_any(idx, surface.index, {x0 = x0, y0 = y0, x1 = x1, y1 = y1}, zone) then return false end
  for _, e in ipairs(new) do
    if not surface.can_place_entity{
      name = e.name, position = {e.x, e.y}, direction = e.direction, force = force,
      build_check_type = defines.build_check_type.ghost_place,
    } then return false end
  end
  return true
end

local function pick_chest(force)
  local recipe = force.recipes["iron-chest"]
  if recipe and recipe.enabled then return "iron-chest" end
  return "wooden-chest"
end

-- Is some pole of the zone within wire reach of `pole_entry`?
local function reaches_network(zone, pole_entry, reach)
  for _, e in ipairs(zone.entries) do
    if is_pole(e.name) and (e.x - pole_entry.x) ^ 2 + (e.y - pole_entry.y) ^ 2 <= (reach - 0.5) ^ 2 then
      return true
    end
  end
  return false
end

local function pole_reach(name)
  local proto = prototypes.entity[name]
  if not proto then return 7.5 end
  local ok, v = pcall(function() return proto.get_max_wire_distance("normal") end)
  if ok and type(v) == "number" then return v end
  ok, v = pcall(function() return proto.get_max_wire_distance() end)
  if ok and type(v) == "number" then return v end
  ok, v = pcall(function() return proto.max_wire_distance end)
  return (ok and type(v) == "number") and v or 7.5
end

---------------------------------------------------------------------
-- Planning the additions
---------------------------------------------------------------------

-- Chest + inserter feeding the first lab from the side. -> new entries or nil
local function plan_feed(ctx, zone, parent, dir)
  local sides = {{x = -dir.y, y = dir.x}, {x = dir.y, y = -dir.x}}
  for _, w in ipairs(sides) do
    local new = {
      {name = INSERTER, x = parent.x + 2 * w.x, y = parent.y + 2 * w.y,
       direction = geometry.vec_to_dir(w.x, w.y), -- an inserter's direction is its PICK-UP side
       drop = {x = parent.x + w.x, y = parent.y + w.y}},
      {name = pick_chest(ctx.player.force), x = parent.x + 3 * w.x, y = parent.y + 3 * w.y,
       direction = defines.direction.north, role = FEED_ROLE},
    }
    if can_place_new(ctx, zone, new) then return new end
  end
  return nil
end

-- A lab one free tile away from a lab that already exists + the inserter and pole in the gap.
local function plan_child(ctx, zone, labs, dir)
  local pole_name = zone.pole
  if not pole_name then
    local pole = poles.get_available_power_pole(ctx, 1, true)
    pole_name = pole and pole.name
  end
  if not pole_name then return nil, "no electric pole is researched" end
  local reach = pole_reach(pole_name)

  local dirs = {dir, {x = -dir.y, y = dir.x}, {x = dir.y, y = -dir.x}}
  for _, parent in ipairs(labs) do
    for _, v in ipairs(dirs) do
      local ins = {x = parent.x + 2 * v.x, y = parent.y + 2 * v.y}
      for _, w in ipairs({{x = -v.y, y = v.x}, {x = v.y, y = -v.x}}) do
        local new = {
          {name = LAB, x = parent.x + 4 * v.x, y = parent.y + 4 * v.y, direction = defines.direction.north},
          {name = INSERTER, x = ins.x, y = ins.y, direction = geometry.vec_to_dir(-v.x, -v.y), -- picks up from the parent
           drop = {x = ins.x + v.x, y = ins.y + v.y}},
          {name = pole_name, x = ins.x + w.x, y = ins.y + w.y, direction = defines.direction.north},
        }
        if reaches_network(zone, new[3], reach) and can_place_new(ctx, zone, new) then return new end
      end
    end
  end
  return nil, "no free spot one tile away from a lab"
end

---------------------------------------------------------------------
-- Objective
---------------------------------------------------------------------

return {
  id = "lab_expansion",
  caption = "Labs sized to the science",
  implemented = true,

  step = function(ctx)
    local player, data = ctx.player, ctx.data
    local force, idx = player.force, player.index
    ctx.surface = data.entity.surface
    local params = ctx.params or {}
    local max_labs = params.max_labs or DEFAULT_MAX_LABS

    local recipe = force.recipes[LAB]
    if not (recipe and recipe.enabled) then return "satisfied", "labs are not available yet" end

    local zone = lab_zone(idx)
    if not zone then return "satisfied", "no lab zone yet" end

    local factories = zones.list(idx, "science_factory")
    local standing = false
    for _, f in ipairs(factories) do
      if zones.progress(f, force) > 0 then standing = true end
    end
    if not standing then return "satisfied", "waiting for the science factory" end

    local labs = entries_named(zone, LAB)
    local parent = labs[1]
    local dir = line_direction(zone, parent)

    -- the chest the companion drops the packs into (the "science" objective builds it)
    local has_feed = false
    for _, e in ipairs(zone.entries) do
      if e.role == FEED_ROLE then has_feed = true end
    end
    if not has_feed and game.tick >= (zone.expand_retry or 0) then
      local new = plan_feed(ctx, zone, parent, dir)
      if new then
        local entries = {}
        for _, e in ipairs(zone.entries) do entries[#entries + 1] = e end
        for _, e in ipairs(new) do entries[#entries + 1] = e end
        zones.set_entries(player, zone, entries)
        debug.say(player, "lab zone: added a feed chest + inserter next to the first lab")
        return "working", "added a chest to the lab zone (the packs go there, an inserter feeds the lab)"
      end
      zone.expand_retry = game.tick + RETRY_TICKS
      debug.say(player, "lab zone: no room for a feed chest; packs keep going straight into the lab")
    end

    -- a lab costs 4 transport belts (and circuits): until `after_tech` is researched the single lab keeps
    -- researching and nothing is crafted for more
    local after = params.after_tech and force.technologies[params.after_tech]
    if after and not after.researched then
      return "satisfied", "more labs wait for the research of " .. after.name
    end

    -- how many labs does the science need?
    local production = rates.production(idx, force, "science_factory")
    local tech = rates.pick_tech(force, params.tech)
    local built_lab
    for _, f in pairs(zones.index_entities(zone, force)) do
      if not f.ghost and f.entity.valid and f.entity.name == LAB then built_lab = f.entity break end
    end
    local consumption = rates.lab_consumption(force, tech, built_lab)
    local needed = rates.labs_needed(production, consumption)
    if not needed then return "satisfied", "no research to size the labs for" end
    needed = math.min(needed, max_labs)

    local made_text, used_text = {}, {}
    for pack, n in pairs(production) do made_text[#made_text + 1] = string.format("%.2f %s/s", n, pack) end
    for pack, n in pairs(consumption) do used_text[#used_text + 1] = string.format("%.3f %s/s", n, pack) end
    local summary = string.format("factory makes %s; one lab uses %s for %s -> %d lab(s), have %d",
      table.concat(made_text, ", "), table.concat(used_text, ", "), tech and tech.name or "?", needed, #labs)

    if #labs >= needed then return "satisfied", summary end
    if game.tick < (zone.expand_retry or 0) then return "satisfied", summary .. " (no room, retrying later)" end

    local new, err = plan_child(ctx, zone, labs, dir)
    if not new then
      zone.expand_retry = game.tick + RETRY_TICKS
      debug.say(player, "lab zone: cannot add a lab: " .. err)
      return "satisfied", summary .. " (cannot add a lab: " .. err .. ")"
    end

    local entries = {}
    for _, e in ipairs(zone.entries) do entries[#entries + 1] = e end
    for _, e in ipairs(new) do entries[#entries + 1] = e end
    zones.set_entries(player, zone, entries)
    debug.say(player, "lab zone: " .. summary)
    return "working", string.format("added lab %d of %d to the lab zone", #labs + 1, needed)
  end,
}
