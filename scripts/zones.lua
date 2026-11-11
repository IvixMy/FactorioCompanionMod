-- Assigned construction zones.
--
-- A zone is a rectangle reserved for one purpose (e.g. "power"). It remembers the planned layout
-- (list of {name, x, y, direction}) and the goal it serves, so work that was interrupted resumes
-- by looking INSIDE the zone instead of scanning every building on the surface.
--
-- Zone size comes from the buildings it must hold (geometry.bbox_of on the layout, plus a margin).
-- A zone may carry `box` (the rectangle of its machines): then entries outside it, like the power line of a
-- factory, are still part of the zone but do not reserve a long strip of the map.
-- A purpose may have several zones: "power", "power_2", "power_3"...
--
-- PERMANENT zones: as soon as something of the plan is built inside a zone it becomes permanent.
-- The rectangle stays reserved (no other plan, blueprint stamp or site search may use it), the
-- planned layout is kept (missing parts are put back as ghosts) and the zone can only be removed
-- on purpose: from the Companion menu ("Building zones") through zones.erase().

local names = require("scripts.names")
local geometry = require("scripts.geometry")
local common   = require("scripts.common")

local M = {}

-- scripts/blueprints.lua registers its restamp function here when control.lua loads it (no require at runtime)
M.restamper = nil

local MARGIN = 1

function M.init()
  storage.zones = storage.zones or {}
  storage.zone_counter = storage.zone_counter or 0
end

local function bucket(player_index)
  storage.zones[player_index] = storage.zones[player_index] or {}
  return storage.zones[player_index]
end

function M.get(player_index, purpose)
  return bucket(player_index)[purpose]
end

-- All zones of a purpose family ("power" -> power, power_2, ...), oldest first.
function M.list(player_index, purpose)
  local out = {}
  for key, zone in pairs(bucket(player_index)) do
    if key == purpose or key:match("^" .. purpose .. "_%d+$") then out[#out + 1] = zone end
  end
  table.sort(out, function(a, b) return a.id < b.id end)
  return out
end

-- First free purpose key of the family: "power", "power_2", "power_3"... (reuses gaps).
function M.next_purpose(player_index, purpose)
  if not M.get(player_index, purpose) then return purpose end
  local n = 2
  while M.get(player_index, purpose .. "_" .. n) do n = n + 1 end
  return purpose .. "_" .. n
end

-- Every zone of the player, oldest first.
function M.all(player_index)
  local out = {}
  for _, zone in pairs(bucket(player_index)) do out[#out + 1] = zone end
  table.sort(out, function(a, b) return a.id < b.id end)
  return out
end

function M.area(zone)
  return {{zone.x0, zone.y0}, {zone.x1, zone.y1}}
end

function M.contains(zone, pos)
  return pos.x >= zone.x0 and pos.x <= zone.x1 and pos.y >= zone.y0 and pos.y <= zone.y1
end

local function overlaps(a, b)
  return not (a.x1 <= b.x0 or b.x1 <= a.x0 or a.y1 <= b.y0 or b.y1 <= a.y0)
end

function M.overlaps_any(player_index, surface_index, box, ignore_zone)
  for _, zone in pairs(bucket(player_index)) do
    if zone ~= ignore_zone and zone.surface_index == surface_index and overlaps(zone, box) then return true end
  end
  return false
end

-- Does the rectangle {{x0, y0}, {x1, y1}} touch any zone of the player?
function M.area_overlaps_zone(player_index, surface_index, area)
  return M.overlaps_any(player_index, surface_index,
    {x0 = area[1][1], y0 = area[1][2], x1 = area[2][1], y1 = area[2][2]})
end

-- Is the area free of resources, water and the force's own buildings?
function M.area_is_free(surface, force, area)
  if surface.count_entities_filtered{area = area, force = force, limit = 1} > 0 then return false end
  if surface.count_entities_filtered{area = area, type = "resource", limit = 1} > 0 then return false end
  local ok, water = pcall(function()
    return surface.count_tiles_filtered{area = area, collision_mask = "water_tile", limit = 1}
  end)
  if ok and water > 0 then return false end
  return true
end

-- Spiral search for a free w x h tile site near `anchor`. Returns {x0, y0, x1, y1} or nil.
function M.find_site(player_index, surface, force, w, h, anchor, max_radius)
  local ax, ay = math.floor(anchor.x), math.floor(anchor.y)
  local step = 4
  for r = 0, max_radius or 80, step do
    for dx = -r, r, step do
      for dy = -r, r, step do
        if r == 0 or math.max(math.abs(dx), math.abs(dy)) == r then
          local box = {x0 = ax + dx, y0 = ay + dy, x1 = ax + dx + w, y1 = ay + dy + h}
          if not M.overlaps_any(player_index, surface.index, box)
             and M.area_is_free(surface, force, {{box.x0, box.y0}, {box.x1, box.y1}}) then
            return box
          end
        end
      end
    end
  end
  return nil
end

local function draw(player, zone, surface)
  local color = {r = 0.3, g = 0.8, b = 1, a = 0.6}
  zone.render = {
    rendering.draw_rectangle{
      color = color, width = 2, filled = false,
      left_top = {zone.x0, zone.y0}, right_bottom = {zone.x1, zone.y1},
      surface = surface, players = {player},
    },
    rendering.draw_text{
      text = names.get() .. " zone: " .. zone.purpose, color = color, scale = 0.8,
      target = {zone.x0 + 0.5, zone.y0 - 1.2}, surface = surface, players = {player},
    },
  }
end

-- Reserve a zone around `entries` (the planned layout).
-- extra: any fields to keep on the zone (goal_kw, capacity_kw, mode, ...).
function M.create(player, purpose, surface, entries, extra)
  M.init()
  local margin = (extra and extra.margin) or MARGIN
  local x0, y0, x1, y1 = geometry.bbox_of(entries, margin)
  if extra and extra.box then -- the rectangle is given: entries outside it (a power line) belong to the zone too
    x0, y0, x1, y1 = extra.box.x0, extra.box.y0, extra.box.x1, extra.box.y1
  end
  storage.zone_counter = storage.zone_counter + 1
  local zone = {
    id = storage.zone_counter, purpose = purpose, surface_index = surface.index,
    x0 = x0, y0 = y0, x1 = x1, y1 = y1, entries = entries, created = game.tick,
  }
  for k, v in pairs(extra or {}) do zone[k] = v end
  bucket(player.index)[purpose] = zone
  draw(player, zone, surface)
  return zone
end

-- Replace the planned layout of a zone (e.g. once the plant has been planned around the pump):
-- the rectangle is recomputed and redrawn.
function M.set_entries(player, zone, entries)
  local x0, y0, x1, y1 = geometry.bbox_of(entries, zone.margin or MARGIN)
  if zone.box then x0, y0, x1, y1 = zone.box.x0, zone.box.y0, zone.box.x1, zone.box.y1 end
  zone.x0, zone.y0, zone.x1, zone.y1 = x0, y0, x1, y1
  zone.entries = entries
  if zone.render then
    for _, obj in pairs(zone.render) do
      if obj.valid then obj.destroy() end
    end
  end
  local surface = game.get_surface(zone.surface_index)
  if surface then draw(player, zone, surface) end
end

-- Drops a zone. A PERMANENT zone (something was built in it) is kept unless `force` is true, so
-- the "give up on this spot" paths of the objectives can never lose a zone that has buildings.
-- Returns true when the zone was removed.
function M.remove(player_index, purpose, force)
  local zone = bucket(player_index)[purpose]
  if not zone then return false end
  if zone.permanent and not force then return false end
  if zone.render then
    for _, obj in pairs(zone.render) do
      if obj.valid then obj.destroy() end
    end
  end
  bucket(player_index)[purpose] = nil
  return true
end

function M.remove_all(player_index)
  for purpose in pairs(bucket(player_index)) do M.remove(player_index, purpose, true) end
  storage.zones[player_index] = nil
end

-- How many planned entries of the zone stand as buildings / are still ghosts. -> built, total
function M.progress(zone, force)
  local found = M.index_entities(zone, force)
  local built = 0
  for _, e in ipairs(zone.entries or {}) do
    local f = found[M.key(e.name, {x = e.x, y = e.y})]
    if f and not f.ghost then built = built + 1 end
  end
  return built, #(zone.entries or {})
end

-- Erase a zone on purpose (menu button): its unbuilt ghosts are deleted, the zone rectangle is
-- freed. Buildings already standing are NOT touched. Returns ghosts_removed.
function M.erase(player_index, purpose, force)
  local zone = bucket(player_index)[purpose]
  if not zone then return 0 end
  local removed = 0
  for _, f in pairs(M.index_entities(zone, force)) do
    if f.ghost and f.entity.valid then
      f.entity.destroy()
      removed = removed + 1
    end
  end
  M.remove(player_index, purpose, true)
  return removed
end

-- Everything of the force inside the zone (ghosts included), keyed by "name@x,y".
-- {entity = LuaEntity, ghost = bool}
function M.index_entities(zone, force)
  local surface = game.get_surface(zone.surface_index)
  local map = {}
  if not surface then return map end
  for _, e in pairs(surface.find_entities_filtered{area = M.area(zone), force = force}) do
    local is_ghost = (e.type == "entity-ghost")
    local name = is_ghost and e.ghost_name or e.name
    map[M.key(name, e.position)] = {entity = e, ghost = is_ghost}
  end
  -- planned entries outside the rectangle (the power line that leads to a factory): looked up one by one
  for _, entry in ipairs(zone.entries or {}) do
    if not M.contains(zone, entry) then
      local r = 0.4
      for _, e in pairs(surface.find_entities_filtered{
        area = {{entry.x - r, entry.y - r}, {entry.x + r, entry.y + r}}, force = force,
      }) do
        local is_ghost = (e.type == "entity-ghost")
        local name = is_ghost and e.ghost_name or e.name
        map[M.key(name, e.position)] = {entity = e, ghost = is_ghost}
      end
    end
  end
  return map
end

-- Make sure every planned entry exists as a ghost or a building inside the zone.
-- Returns built, pending (ghosts), failed (could not place), index (see index_entities).
function M.ensure_ghosts(zone, surface, force)
  local found = M.index_entities(zone, force)

  -- BLUEPRINT zones (zone.bp_str): when something of the blueprint itself is missing (not even a ghost any
  -- more), the whole blueprint is placed again over the same spot: that restores what a plain ghost cannot
  -- (underground belt ends, recipes, inserter settings). The power line poles in front of the entries are
  -- not part of the blueprint; they are handled by the generic loop below.
  if zone.bp_str and game.tick >= (zone.bp_next_restamp or 0) then
    for i = (zone.line_poles or 0) + 1, #zone.entries do
      local e = zone.entries[i]
      if not found[M.key(e.name, {x = e.x, y = e.y})] then
        zone.bp_next_restamp = game.tick + 300
        if M.restamper then M.restamper(zone, surface, force) end
        found = M.index_entities(zone, force)
        break
      end
    end
  end

  local built, pending, failed = 0, 0, 0
  for _, e in ipairs(zone.entries) do
    local f = found[M.key(e.name, {x = e.x, y = e.y})]
    if not f then
      local args = {
        name = "entity-ghost", inner_name = e.name, position = {e.x, e.y},
        direction = e.direction, force = force, raise_built = true,
      }
      -- an assembling machine ghost can carry its recipe: it is built already set
      if e.recipe then args.recipe = e.recipe end
      local ok, ghost = pcall(surface.create_entity, args)
      if not ok and e.recipe then
        args.recipe = nil
        ok, ghost = pcall(surface.create_entity, args)
      end
      if ok and ghost then pending = pending + 1 else failed = failed + 1 end
    elseif f.ghost then
      pending = pending + 1
    else
      built = built + 1
    end
  end
  if built > 0 then zone.permanent = true end -- see the header: built zones are never dropped
  return built, pending, failed, found
end

function M.key(name, pos)
  return string.format("%s@%.1f,%.1f", name, pos.x, pos.y)
end

return M
