-- Ore / resource finding for ANY resource (iron-ore, coal, stone, copper-ore, ...).
--
-- Nothing in here knows about a specific ore: callers pass the resource entity name(s).
-- Used by:
--   scripts/objectives/iron_start.lua   where to put a burner drill (ore = "iron-ore")
--   scripts/fuel.lua                    is there a coal patch near a burner? (names come from prototypes)
--   scripts/tasks/mine.lua              which tile to hand-mine
--
--   ore.has(surface, names, pos, radius)             true when any of the resource is within radius
--   ore.nearest(surface, names, pos, radius, from)   closest resource entity (or nil)
--   ore.find(surface, names, pos, radii)             -> list sorted by distance, radius used  (or nil)
--   ore.drill_sites(surface, names, pos, radii, min) -> list of {x, y} drill centres, nearest first
--   ore.find_charted(surface, force, names, pos, max_tiles) -> {x, y, distance} of the closest ore
--                                                    inside the area the force has CHARTED (the map)

local common = require("scripts.common")

local M = {}

M.FIND_LIMIT = 300

local function as_names(names)
  if type(names) == "string" then return {names} end
  return names
end

function M.has(surface, names, pos, radius)
  return surface.count_entities_filtered{name = as_names(names), position = pos, radius = radius, limit = 1} > 0
end

function M.nearest(surface, names, pos, radius, from)
  from = from or pos
  names = as_names(names)
  -- widen the search step by step: a small ring first, so the CLOSEST tile is found even in a
  -- huge patch (find_entities_filtered with a limit does not return results nearest-first)
  local rings = {8, 20, 40, 80, 150, 250, radius}
  for _, r in ipairs(rings) do
    if r >= radius then r = radius end
    local list = surface.find_entities_filtered{name = names, position = pos, radius = r, limit = 60}
    local best, best_d
    for _, e in pairs(list) do
      local d = common.dist2(e.position, from)
      if not best or d < best_d then best, best_d = e, d end
    end
    if best then return best end
    if r >= radius then break end
  end
  return nil
end

-- Tries each radius in turn (small to large). Returns entities sorted by distance, radius.
function M.find(surface, names, pos, radii)
  names = as_names(names)
  for _, radius in ipairs(radii) do
    local list = surface.find_entities_filtered{name = names, position = pos, radius = radius, limit = M.FIND_LIMIT}
    if #list > 0 then
      table.sort(list, function(a, b) return common.dist2(a.position, pos) < common.dist2(b.position, pos) end)
      return list, radius
    end
  end
  return nil
end

-- Tile centres where a 2x2 drill would sit on at least `min_tiles` ore tiles, nearest first.
-- (Placement checks - can the drill really go there? - stay with the caller.)
function M.drill_sites(surface, names, pos, radii, min_tiles)
  names = as_names(names)
  local sites, seen = {}, {}
  for _, radius in ipairs(radii) do
    local ores = surface.find_entities_filtered{name = names, position = pos, radius = radius, limit = M.FIND_LIMIT}
    table.sort(ores, function(a, b) return common.dist2(a.position, pos) < common.dist2(b.position, pos) end)
    for _, ore in ipairs(ores) do
      local cx, cy = math.floor(ore.position.x + 0.5), math.floor(ore.position.y + 0.5)
      local key = cx .. "," .. cy
      if not seen[key] then
        seen[key] = true
        local under = surface.count_entities_filtered{name = names, area = {{cx - 1, cy - 1}, {cx + 1, cy + 1}}}
        if under >= min_tiles then sites[#sites + 1] = {x = cx, y = cy} end
      end
    end
  end
  return sites
end


---------------------------------------------------------------------
-- Searching the charted map
---------------------------------------------------------------------

M.FAR_CACHE_TICKS = 600 -- a "far ore" answer is reused this long (the search walks many chunks)

local function chunk_hit(surface, names, cx, cy)
  local list = surface.find_entities_filtered{
    area = {{cx * 32, cy * 32}, {cx * 32 + 32, cy * 32 + 32}}, name = names, limit = 1,
  }
  return list[1]
end

-- Closest ore of `names` inside chunks the force has charted, up to `max_tiles` from `pos`.
-- Returns {x, y, distance} (the position of one ore tile) or nil. Results are cached in
-- `storage` so every machine in a multiplayer game sees the same answer.
function M.find_charted(surface, force, names, pos, max_tiles)
  names = as_names(names)
  storage.ore_far = storage.ore_far or {}
  local pcx, pcy = math.floor(pos.x / 32), math.floor(pos.y / 32)
  local key = table.concat({surface.index, force.index, table.concat(names, "+"), pcx, pcy, max_tiles}, "|")
  local cached = storage.ore_far[key]
  if cached and game.tick - cached.tick < M.FAR_CACHE_TICKS then return cached.result end

  local best, best_d
  local max_ring = math.ceil(max_tiles / 32)
  local found_ring
  for ring = 0, max_ring do
    if found_ring and ring > found_ring + 1 then break end -- one more ring: a corner can be nearer
    for dx = -ring, ring do
      for dy = -ring, ring do
        if ring == 0 or math.max(math.abs(dx), math.abs(dy)) == ring then
          local cx, cy = pcx + dx, pcy + dy
          if force.is_chunk_charted(surface, {x = cx, y = cy}) then
            local e = chunk_hit(surface, names, cx, cy)
            if e then
              local d = common.dist2(e.position, pos)
              if d <= max_tiles * max_tiles and (not best or d < best_d) then
                best, best_d = {x = e.position.x, y = e.position.y}, d
                found_ring = found_ring or ring
              end
            end
          end
        end
      end
    end
  end
  if best then best.distance = math.sqrt(best_d) end
  storage.ore_far[key] = {tick = game.tick, result = best}
  return best
end

return M
