-- Shared constants and helpers (movement, settings, bookkeeping) used by every other script.

local M = {}

M.ENTITY_NAME = "engineer-companion-character"

M.GHOST_TYPES = {"entity-ghost", "tile-ghost"}
M.CHEST_TYPES = {"container", "logistic-container"}

-- Logistic network support: items in the force's roboport networks (storage / passive provider /
-- active provider / buffer chests) count as supply; requester chests are left alone (their stock is reserved).
M.USE_LOGISTIC_NETWORK = true

-- The companion also removes entities (and trees / rocks) marked for deconstruction.
M.DECONSTRUCT = true
-- ... and upgrades the buildings marked for upgrade (needs the new building's item: fetched / crafted like a ghost's).
M.UPGRADE = true

-- Following
M.FOLLOW_START      = 5
M.FOLLOW_STOP       = 3
M.TELEPORT_DISTANCE = 40
M.STEER_TOLERANCE   = math.rad(40)

-- "Follow and build nearby" mode (uses the player's inventory)
M.NEAR_BUILD_RADIUS = 15

-- Auto-build mode (uses chests, crafts when needed)
M.CHEST_REACH        = 3
M.BUILD_REACH        = 5
M.NEAR_SEARCH_RADIUS = 64
M.NEAR_GHOST_LIMIT   = 500  -- how many ghosts are looked at (also used to add up how much material a job needs)
M.FAR_GHOST_LIMIT    = 1000
M.FETCH_BATCH        = 10   -- only used when M.FETCH_ALL is false: fetch enough for ~10 ghosts per chest visit
M.FETCH_ALL          = true -- fetch the material for ALL the visible ghosts of an item in one trip (as far as it fits)
M.FETCH_KEEP_FREE_STACKS = 2 -- a big fetch never fills the last free slots of the inventory
M.CRAFT_BATCH        = 5    -- gather raw materials for ~5 crafts per chest visit
M.BLOCKED_COOLDOWN   = 600
M.SUPPLY_REFRESH     = 300
M.MINE_RADIUS        = 80   -- how far the companion looks for things to hand-mine

-- Roaming (idle behaviour of auto-build)
M.ROAM_RADIUS      = 8
M.ROAM_MAX_ANCHORS = 60

local DIRECTIONS = {
  [0] = defines.direction.east,
  [1] = defines.direction.southeast,
  [2] = defines.direction.south,
  [3] = defines.direction.southwest,
  [4] = defines.direction.west,
  [5] = defines.direction.northwest,
  [6] = defines.direction.north,
  [7] = defines.direction.northeast,
}

-- Reads a property that may not exist in every Factorio version (a missing property on a
-- prototype throws). Returns nil when it can't be read.
function M.try_get(obj, key)
  local ok, value = pcall(function() return obj[key] end)
  if ok then return value end
  return nil
end

---------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------

function M.builds_per_second(player)
  local s = settings.get_player_settings(player)["ec-builds-per-second"]
  return (s and s.value) or 1
end

function M.crafting_speed(player)
  local s = settings.get_player_settings(player)["ec-crafting-speed"]
  local base = (s and s.value) or 1
  return math.max(0.1, base * (1 + player.force.manual_crafting_speed_modifier))
end

---------------------------------------------------------------------
-- Movement
---------------------------------------------------------------------

function M.dist2(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return dx * dx + dy * dy
end

function M.steer(data, from, to, tolerance)
  tolerance = tolerance or M.STEER_TOLERANCE
  local angle = math.atan2(to.y - from.y, to.x - from.x)
  local octant = math.floor(angle / (math.pi / 4) + 0.5) % 8
  if data.octant then
    local diff = (angle - data.octant * math.pi / 4) % (2 * math.pi)
    if diff > math.pi then diff = 2 * math.pi - diff end
    if diff <= tolerance then octant = data.octant end
  end
  data.octant = octant
  return DIRECTIONS[octant]
end

M.walker = nil

-- Walks towards `target`; returns true once within `stop` tiles. Goes round obstacles (scripts/pathing.lua).
function M.walk_towards(data, target, stop)
  -- scripts/pathing.lua registers itself here when control.lua loads it (require is not allowed at runtime)
  return M.walker(data, target, stop)
end

---------------------------------------------------------------------
-- Bookkeeping
---------------------------------------------------------------------

-- Remember where the companion built something, so it can roam around there when idle.
function M.record_placed(data, surface_index, pos)
  data.placed = data.placed or {}
  local list = data.placed
  list[#list + 1] = {x = pos.x, y = pos.y, s = surface_index}
  if #list > M.ROAM_MAX_ANCHORS then table.remove(list, 1) end
end

function M.ghost_key(ghost)
  local p = ghost.position
  return string.format("%s@%.1f,%.1f", ghost.ghost_name, p.x, p.y)
end

-- Teleports `entity` NEXT TO a position, never onto it: two characters on the same spot block each other and both stay
-- stuck. Tries free spots 3, 4, 5... tiles from the position around it (the side it came from first), at least
-- MIN_GAP tiles away from it. surface: another surface (the entity is moved there). Returns true when it moved.
M.TELEPORT_GAP = 2.5
function M.teleport_beside(entity, position, surface)
  surface = surface or entity.surface
  local px, py = position.x, position.y
  local ex, ey = entity.position.x, entity.position.y
  if entity.surface.index ~= surface.index then ex, ey = px + 1, py end -- came from elsewhere: any side
  local base = math.atan2(ey - py, ex - px) -- the side it comes from
  local gap2 = M.TELEPORT_GAP * M.TELEPORT_GAP
  for _, radius in ipairs({3, 4, 5, 6.5, 8}) do
    for i = 0, 7 do
      local angle = base + ((i % 2 == 0) and 1 or -1) * math.ceil(i / 2) * (math.pi / 4)
      local want = {x = px + math.cos(angle) * radius, y = py + math.sin(angle) * radius}
      local spot = surface.find_non_colliding_position(M.ENTITY_NAME, want, 1.5, 0.25)
      if spot and (spot.x - px) ^ 2 + (spot.y - py) ^ 2 >= gap2 then
        return entity.teleport(spot, surface)
      end
    end
  end
  -- nothing free around it: the nearest free spot at all, even if it is close
  local spot = surface.find_non_colliding_position(M.ENTITY_NAME, position, 16, 0.25)
  if spot then return entity.teleport(spot, surface) end
  return false
end

return M
