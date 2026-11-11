-- Free storage chests: chests the companion may drop its surplus into.
--
-- A chest counts as FREE STORAGE only when nothing automated uses it:
--   * no inserter (built OR ghost) picks up from it or drops into it   (assembler output, train stop in/out, lab feed...)
--   * no mining drill outputs into it
--   * no loader / belt-loader faces it
--   * it is not inside one of the zones the objectives manage (lab / factory feed and output chests)
--   * it is a plain chest, or a logistic chest in "storage" / "passive-provider" mode
--     (requester, buffer and active-provider chests are never used)
--
-- Used by scripts/deposit.lua (planning) and scripts/tasks/deposit.lua (re-check on arrival).

local common = require("scripts.common")
local zones  = require("scripts.zones")

local M = {}

-- Tiles around the chest that are searched for inserters / drills. A long-handed inserter reaches 2 tiles,
-- modded ones and big drills a bit more, so this is generous.
M.SCAN_MARGIN = 8

local OTHER_USERS = {"inserter", "mining-drill", "loader", "loader-1x1"}

local function inside(pos, box)
  local eps = 0.01
  return pos.x >= box.left_top.x - eps and pos.x <= box.right_bottom.x + eps
     and pos.y >= box.left_top.y - eps and pos.y <= box.right_bottom.y + eps
end

local function xy(v)
  if not v then return nil end
  return {x = v.x or v[1] or 0, y = v.y or v[2] or 0}
end

-- Rotates a vector given for a NORTH-facing entity to `direction` (Factorio 2.0: 16 directions, clockwise).
local function rotate(v, direction)
  local a = (direction or 0) / 16 * 2 * math.pi
  local s, c = math.sin(a), math.cos(a)
  return {x = v.x * c - v.y * s, y = v.x * s + v.y * c}
end

-- Does a built inserter / drill / loader work on this chest?
local function entity_uses(e, chest, box)
  if not e.valid then return false end
  if e.type == "inserter" then
    if common.try_get(e, "pickup_target") == chest or common.try_get(e, "drop_target") == chest then return true end
    local p, d = common.try_get(e, "pickup_position"), common.try_get(e, "drop_position")
    return (p and inside(p, box)) or (d and inside(d, box)) or false
  elseif e.type == "mining-drill" then
    if common.try_get(e, "drop_target") == chest then return true end
    local d = common.try_get(e, "drop_position")
    return (d and inside(d, box)) or false
  else -- loader / loader-1x1
    return common.try_get(e, "loader_container") == chest
  end
end

-- Does a GHOST inserter (not built yet) point at this chest? Unknown prototype data counts as "yes" (stay away).
local function ghost_uses(g, box)
  if not g.valid then return false end
  local proto = g.ghost_prototype
  local pick = xy(common.try_get(proto, "inserter_pickup_position"))
  local drop = xy(common.try_get(proto, "inserter_drop_position"))
  if not (pick and drop) then return true end
  local p = g.position
  for _, v in ipairs({pick, drop}) do
    local r = rotate(v, g.direction)
    if inside({x = p.x + r.x, y = p.y + r.y}, box) then return true end
  end
  return false
end

-- Is the chest inside a zone the objectives manage?
local function in_managed_zone(player, chest)
  for _, zone in ipairs(zones.all(player.index) or {}) do
    if zone.surface_index == chest.surface.index and zones.contains(zone, chest.position) then return true end
  end
  return false
end

-- Type / mode check only (cheap).
function M.allowed_type(chest)
  if not (chest and chest.valid) then return false end
  if chest.type == "container" then return true end
  if chest.type == "logistic-container" then
    local mode = common.try_get(chest.prototype, "logistic_mode")
    return mode == "storage" or mode == "passive-provider"
  end
  return false
end

-- True when the chest is a free storage chest. Second value: why not (for debugging).
function M.is_free(player, chest)
  if not M.allowed_type(chest) then return false, "type" end
  if in_managed_zone(player, chest) then return false, "zone" end

  local b = chest.bounding_box
  local m = M.SCAN_MARGIN
  local area = {{b.left_top.x - m, b.left_top.y - m}, {b.right_bottom.x + m, b.right_bottom.y + m}}
  local surface = chest.surface

  for _, e in pairs(surface.find_entities_filtered{area = area, type = OTHER_USERS}) do
    if entity_uses(e, chest, b) then return false, "machine" end
  end

  local ok, ghosts = pcall(surface.find_entities_filtered, {area = area, type = "entity-ghost", ghost_type = "inserter"})
  if ok and ghosts then
    for _, g in pairs(ghosts) do
      if ghost_uses(g, b) then return false, "ghost inserter" end
    end
  end

  return true
end

return M
