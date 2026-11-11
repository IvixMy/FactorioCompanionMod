-- Task "build": walk to a ghost and revive it using items the companion carries.
--   fields: ghost, ghost_name, item, quality, count

local common = require("scripts.common")
local core   = require("scripts.tasks.core")
local goals  = require("scripts.goals")
local ground = require("scripts.ground")
local bot_claims = require("scripts.bot_claims")

-- Trees and rocks block construction; mine them like a player would.
local function clear_obstacles(c, ghost)
  local cinv = c.get_main_inventory()
  local found = ghost.surface.find_entities_filtered{
    area = ghost.bounding_box, type = {"tree", "simple-entity"},
  }
  local cleared = false
  for _, e in pairs(found) do
    if e.valid and e.minable and e.mine{inventory = cinv, force = true} then cleared = true end
  end
  return cleared
end

-- Max times the Companion hops out of the same ghost's footprint before the ghost is put on cooldown
-- (so a spot that keeps failing can never loop "step aside" <-> "build" for ever).
local MAX_STEP_ASIDES = 2
local MAX_STEP_STREAK = 8    -- hops in a row (over different ghosts) without a single build in between: give up on this one

local function box_xy(b)
  local lt, rb = b.left_top or b[1], b.right_bottom or b[2]
  return lt.x or lt[1], lt.y or lt[2], rb.x or rb[1], rb.y or rb[2]
end

local function boxes_overlap(a, b)
  local al, at, ar, ab = box_xy(a)
  local bl, bt, br, bb = box_xy(b)
  local eps = 0.01 -- merely touching is fine
  return al < br - eps and ar > bl + eps and at < bb - eps and ab > bt + eps
end

-- Does a ghost of this type stop the Companion from standing on it? Only if their collision layers share one
-- (belts, for example, do not stop a character, poles and machines do).
local blocks_cache = {} -- [ghost_name] = bool
local function ghost_blocks_companion(c, ghost)
  if ghost.type ~= "entity-ghost" then return false end
  local name = ghost.ghost_name
  local hit = blocks_cache[name]
  if hit == nil then
    hit = true -- when in doubt, assume it blocks
    local ok, res = pcall(function()
      local gm, cm = ghost.ghost_prototype.collision_mask, c.prototype.collision_mask
      local gl, cl = gm and (gm.layers or gm), cm and (cm.layers or cm)
      if not gl or not cl then return true end
      for layer, on in pairs(gl) do
        if on == true and cl[layer] == true then return true end
      end
      return false
    end)
    if ok then hit = res end
    blocks_cache[name] = hit
  end
  return hit
end

-- Does the Companion's collision box overlap the ghost's footprint (so that reviving it fails)?
local function companion_in_way(c, ghost)
  return ghost_blocks_companion(c, ghost) and boxes_overlap(c.bounding_box, ghost.bounding_box)
end

-- Another character (the player, another Companion) standing in the footprint also stops the revive,
-- and the Companion can't move it.
local function other_character_in_way(c, ghost)
  for _, e in pairs(ghost.surface.find_entities_filtered{area = ghost.bounding_box, type = "character"}) do
    if e.valid and e ~= c then return true end
  end
  return false
end

-- Footprints of every ghost around `center` that the Companion could not stand in either.
local function ghost_zones(c, center, radius)
  local zones = {}
  local list = c.surface.find_entities_filtered{
    type = "entity-ghost", force = c.force, position = center, radius = radius, limit = 400,
  }
  for _, g in pairs(list) do
    if g.valid and ghost_blocks_companion(c, g) then
      local l, t, r, b = box_xy(g.bounding_box)
      zones[#zones + 1] = {l = l, t = t, r = r, b = b}
    end
  end
  return zones
end

-- Nearest free spot for the Companion that lies OUTSIDE the footprint of the ghost AND of every other ghost around
-- it. (find_non_colliding_position ignores ghosts, so on its own it happily returns a spot inside a footprint. And
-- a spot outside only the ghost being built is no better in a cramped blueprint: it lands inside the NEXT ghost,
-- which then has to be stepped out of in turn - that was the endless "step aside" <-> "build" loop.)
-- wide = false: only spots from which the ghost is still within build reach.
-- wide = true : any spot up to WIDE_RADIUS away (the caller then builds from there without walking back).
local WIDE_RADIUS = 14
local function spot_outside(c, ghost, wide)
  local cl, ct, cr, cb = box_xy(c.bounding_box)
  local hw, hh = (cr - cl) / 2, (cb - ct) / 2
  local center = ghost.position
  local maxr = wide and WIDE_RADIUS or (common.BUILD_REACH - 0.25)
  local zones = ghost_zones(c, center, maxr + 6)

  local function free(p)
    for _, z in ipairs(zones) do
      if p.x + hw > z.l - 0.05 and p.x - hw < z.r + 0.05 and p.y + hh > z.t - 0.05 and p.y - hh < z.b + 0.05 then
        return false
      end
    end
    return true
  end

  local step = wide and 1 or 0.5
  local here = c.position
  local cands = {}
  local d = -maxr
  while d <= maxr do
    local e = -maxr
    while e <= maxr do
      if d * d + e * e <= maxr * maxr then
        local p = {x = center.x + d, y = center.y + e}
        if free(p) then cands[#cands + 1] = p end
      end
      e = e + step
    end
    d = d + step
  end
  table.sort(cands, function(a, b) return common.dist2(a, here) < common.dist2(b, here) end)

  for i = 1, math.min(#cands, 40) do
    local spot = c.surface.find_non_colliding_position(common.ENTITY_NAME, cands[i], 0.5, 0.1)
    if spot and free(spot) and (wide or common.dist2(spot, center) <= (common.BUILD_REACH - 0.1) ^ 2) then
      return spot
    end
  end
  return nil
end

-- Another ghost within reach of where the companion stands that the carried items can build right now.
-- (So one visit builds everything around it instead of one ghost per trip.)
local function next_in_reach(data, c, cinv)
  local list = c.surface.find_entities_filtered{
    type = common.GHOST_TYPES, force = c.force, position = c.position, radius = common.BUILD_REACH - 0.5, limit = 60,
  }
  local best, best_d, bn, bc, bq
  for _, g in pairs(list) do
    if g.valid and (data.blocked[common.ghost_key(g)] or 0) < game.tick and not companion_in_way(c, g) then
      local proto = g.ghost_prototype
      local item = proto and proto.items_to_place_this and proto.items_to_place_this[1]
      if item then
        local count = item.count or 1
        local quality = (g.type == "entity-ghost" and g.quality) and g.quality.name or nil
        if cinv.get_item_count{name = item.name, quality = quality} >= count then
          local d = common.dist2(g.position, c.position)
          if not best or d < best_d then best, best_d, bn, bc, bq = g, d, item.name, count, quality end
        end
      end
    end
  end
  return best, bn, bc, bq
end

return {
  id = "build",

  describe = function(task) return "Building " .. task.ghost_name end,

  execute = function(player, data, task)
    local c = data.entity
    if not task.ghost.valid then
      return core.finish(data)
    end
    local key = common.ghost_key(task.ghost)
    -- on a long way to it: did construction robots take the job meanwhile? Then it is not worth the trip.
    if game.tick >= (task.bot_check or 0) then
      task.bot_check = game.tick + 90
      if bot_claims.enabled(player)
          and common.dist2(c.position, task.ghost.position) >= bot_claims.min_distance(player) ^ 2
          and bot_claims.claimed(task.ghost, task.item, task.count) then
        data.blocked[key] = game.tick + bot_claims.RECHECK
        return core.finish(data, "Left " .. task.ghost_name .. " to the construction robots")
      end
    end
    -- after stepping out of a footprint the Companion builds from where it landed, even when that is a bit
    -- farther than the build reach (walking back towards the ghost would walk it into the footprint again)
    local st = data.stand
    if st and st.key == key and st.walk then
      -- walking out of the footprint (no teleport): done when it is at the spot
      if game.tick - st.tick > 600 then
        data.stand = nil
        st = nil
      elseif common.walk_towards(data, st.spot, 0.5) then
        st.walk, st.tick = nil, game.tick
        data.next_build = game.tick + 5
      else
        return
      end
    end
    local standing = st and st.key == key and game.tick - st.tick < 600 and common.dist2(c.position, st.spot) < 4
    if not standing and not common.walk_towards(data, task.ghost.position, common.BUILD_REACH) then return end
    if game.tick < (data.next_build or 0) then return end -- construction speed limit

    local cinv = c.get_main_inventory()
    if cinv.get_item_count{name = task.item, quality = task.quality} >= task.count then
      -- read everything needed BEFORE reviving: the ghost no longer exists afterwards
      local gpos = task.ghost.position
      local collided, entity = task.ghost.revive{raise_revive = true}
      if collided ~= nil or entity ~= nil then
        cinv.remove{name = task.item, count = task.count, quality = task.quality}
        if data.stepped_aside then data.stepped_aside[key] = nil end
        data.step_streak, data.stand = 0, nil
        common.record_placed(data, c.surface.index, gpos)
        goals.notify(c.force, "build", task.ghost_name, 1)
        data.status = "Built " .. task.ghost_name
        data.next_build = game.tick + math.max(1, math.ceil(60 / common.builds_per_second(player)))
        -- keep going with the ghosts around it, no new planning round and no walking in between
        local g, name, count, quality = next_in_reach(data, c, cinv)
        if g then
          task.ghost, task.ghost_name, task.item, task.count, task.quality = g, g.ghost_name, name, count, quality
          return
        end
      elseif clear_obstacles(c, task.ghost) then
        data.status = "Cleared obstacles at " .. task.ghost_name
      elseif companion_in_way(c, task.ghost) then
        -- the Companion itself stands in the footprint (it has collision): hop out of it, then retry the same ghost
        data.stepped_aside = data.stepped_aside or {}
        local n = (data.stepped_aside[key] or 0) + 1
        data.stepped_aside[key] = n
        local streak = (data.step_streak or 0) + 1 -- hops since the last successful build (any ghost)
        data.step_streak = streak
        local spot = nil
        if n <= MAX_STEP_ASIDES and streak <= MAX_STEP_STREAK then
          spot = spot_outside(c, task.ghost, false) or spot_outside(c, task.ghost, true)
        end
        if spot then
          local setting = settings.get_player_settings(player)["ec-teleport-fallback"]
          if setting and setting.value then
            c.teleport(spot)
            data.stand = {key = key, spot = spot, tick = game.tick}
            data.next_build = game.tick + 5 -- let the position settle before the next revive
            data.status = "Stepped aside to build " .. task.ghost_name
          else
            data.stand = {key = key, spot = spot, tick = game.tick, walk = true} -- walks there (see above)
            data.status = "Stepping out of the way of " .. task.ghost_name
          end
          return -- keep the task: no replanning round, the same ghost is retried next
        end
        data.stepped_aside[key] = nil
        data.step_streak, data.stand = 0, nil
        data.blocked[key] = game.tick + common.BLOCKED_COOLDOWN
        data.status = "Could not step out of the way of " .. task.ghost_name
      elseif other_character_in_way(c, task.ghost) then
        data.blocked[key] = game.tick + 120 -- do something else meanwhile and come back
        data.status = "Waiting: someone stands where " .. task.ghost_name .. " goes"
      elseif task.ghost.type == "entity-ghost" and ground.fix(player, data, task.ghost) then
        -- it stands on water: landfill ghosts are under it now, build those first and come back
        data.blocked[key] = game.tick + 180
        data.status = "Laying ground under " .. task.ghost_name
      else
        data.blocked[key] = game.tick + common.BLOCKED_COOLDOWN
        data.status = "Could not build (something in the way?)"
      end
    end
    core.finish(data) -- keeps the status text set above
  end,
}
