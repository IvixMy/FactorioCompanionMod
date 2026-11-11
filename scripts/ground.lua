-- Ground first (0.19.2): an entity ghost that stands on WATER cannot be built until there is land under it. The
-- companion used to try, fail ("something in the way?") and put the ghost on cooldown for ever.
--
-- fix(player, data, ghost) is called by the build task (scripts/tasks/build.lua) when reviving an entity ghost FAILED
-- (it costs nothing while everything works; an earlier version checked every ghost on every planning round and
-- made the game slow):
--   * it looks at the tiles under the footprint (only when the game says the ghost cannot be placed);
--   * tiles that collide with the ghost AND are water get a TILE GHOST of the landfill item (the item that places a
--     tile over water: "landfill", else any item whose tile may be put there), unless one is already there;
--   * the build task puts the entity ghost aside for a moment. From then on the normal pipeline does the rest: tile
--     ghosts are supplied (carried / chest / crafted) and built like any ghost, and once the ground is there the
--     entity ghost is built.
-- Nothing is created for an item that cannot be had (not carried, in no chest, recipe not researched).
-- Setting: ec-build-ground.
--
-- Limit: a ghost far out in a lake gets landfill under ITS footprint only (no causeway to it); the companion must be
-- able to reach the footprint from the shore (build reach) or from land that is already there.

local common = require("scripts.common")
local supply = require("scripts.supply")

local M = {}

M.MAX_NEW_TILES   = 200   -- tile ghosts created in one round
M.PREFERRED       = "landfill"

local function layers_of(mask)
  if not mask then return {} end
  return mask.layers or mask
end

local function collides(a, b)
  for layer, on in pairs(a) do
    if on == true and b[layer] == true then return true end
  end
  return false
end

-- Items that place a tile: [{item, tile, tile_layers}], the preferred one (landfill) first.
local candidates
local function get_candidates()
  if candidates then return candidates end
  candidates = {}
  for name, proto in pairs(prototypes.item) do
    local res = common.try_get(proto, "place_as_tile_result")
    local tile = res and common.try_get(res, "result")
    if tile and not common.try_get(proto, "hidden") then
      candidates[#candidates + 1] = {item = name, tile = tile.name, layers = layers_of(tile.collision_mask)}
    end
  end
  table.sort(candidates, function(a, b)
    local ap, bp = (a.item == M.PREFERRED), (b.item == M.PREFERRED)
    if ap ~= bp then return ap end
    return a.item < b.item
  end)
  return candidates
end

-- Can the force get this item at all? (carried, in a chest / the network, or the recipe is there)
local function obtainable(data, force, item)
  if data.entity.get_main_inventory().get_item_count{name = item, quality = "normal"} > 0 then return true end
  if (supply.get(force, data.entity.surface).totals[item] or 0) > 0 then return true end
  local recipe = force.recipes[item]
  return recipe ~= nil and recipe.enabled
end

-- The landfill-like item for the ghost, or nil.
local function ground_for(data, force, ghost_layers)
  for _, cand in ipairs(get_candidates()) do
    if not collides(cand.layers, ghost_layers) and obtainable(data, force, cand.item) then return cand end
  end
  return nil
end

local function footprint(g)
  local box = g.bounding_box
  local lt, rb = box.left_top or box[1], box.right_bottom or box[2]
  local l, t = lt.x or lt[1], lt.y or lt[2]
  local r, b = rb.x or rb[1], rb.y or rb[2]
  return l, t, r, b
end

-- "fine" (nothing to do) | "wait" (tile ghosts exist / were made under it) | "stuck" (water, but no ground to be had)
-- plus the new tile ghosts.
local function check(player, data, g, budget)
  local surface, force = g.surface, g.force
  local proto = g.ghost_prototype
  if not proto then return "fine" end

  local ok, can = pcall(function()
    return surface.can_place_entity{
      name = g.ghost_name, position = g.position, direction = g.direction, force = force,
      build_check_type = defines.build_check_type.ghost_revive,
    }
  end)
  if ok and can then return "fine" end

  -- which tiles under it stop it, and are they water?
  local ghost_layers = layers_of(proto.collision_mask)
  local l, t, r, b = footprint(g)
  local eps = 0.01
  local bad = {}
  for x = math.floor(l + eps), math.floor(r - eps) do
    for y = math.floor(t + eps), math.floor(b - eps) do
      local tile = surface.get_tile(x, y)
      local tl = layers_of(tile.prototype.collision_mask)
      if collides(tl, ghost_layers) and tl.water_tile == true then
        bad[#bad + 1] = {x = x, y = y}
      end
    end
  end
  if #bad == 0 then return "fine" end -- blocked by something else: not a matter of ground

  local cand = ground_for(data, force, ghost_layers)
  if not cand then return "stuck" end

  local have = {}
  for _, tg in pairs(surface.find_entities_filtered{
      area = {{l - 1, t - 1}, {r + 1, b + 1}}, type = "tile-ghost", force = force}) do
    local p = tg.position
    have[math.floor(p.x) .. "," .. math.floor(p.y)] = true
  end

  local made, waiting = {}, false
  for _, tpos in ipairs(bad) do
    local key = tpos.x .. "," .. tpos.y
    if have[key] then
      waiting = true
    elseif budget.n > 0 then
      local created_ok, tg = pcall(function()
        return surface.create_entity{
          name = "tile-ghost", inner_name = cand.tile, force = force, raise_built = true,
          position = {x = tpos.x + 0.5, y = tpos.y + 0.5},
        }
      end)
      if created_ok and tg and tg.valid then
        made[#made + 1] = tg
        budget.n = budget.n - 1
        waiting = true
      end
    end
  end
  return waiting and "wait" or "stuck", made
end

-- Called by the build task when a ghost could not be revived (so it costs nothing while all is well).
-- Returns true when there are tile ghosts under it now (made just now or already there): the caller leaves the ghost
-- for a moment and the normal pipeline builds the ground first.
function M.fix(player, data, g)
  local setting = settings.get_player_settings(player)["ec-build-ground"]
  if setting and setting.value == false then return false end
  local state = check(player, data, g, {n = M.MAX_NEW_TILES})
  return state == "wait"
end

return M
