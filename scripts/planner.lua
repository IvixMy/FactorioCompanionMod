-- Auto-build planner: looks at the ghosts on the surface and picks the next task
-- (build it, fetch its items, or gather materials so the missing item can be crafted).

local common   = require("scripts.common")
local crafting = require("scripts.crafting")
local supply   = require("scripts.supply")
local tasks    = require("scripts.tasks")
local loadout  = require("scripts.loadout")
local bot_claims = require("scripts.bot_claims")
local deposit  = require("scripts.deposit")

local M = {}

local function ghost_requirement(ghost)
  local proto = ghost.ghost_prototype
  local item = proto and proto.items_to_place_this and proto.items_to_place_this[1]
  if not item then return nil end
  local quality = nil
  if ghost.type == "entity-ghost" and ghost.quality then quality = ghost.quality.name end
  return item.name, item.count or 1, quality
end

-- The item is neither on the companion nor in any chest. Can it be crafted?
--  * everything needed is already carried  -> queue the craft (returns "queued")
--  * needed raw materials are in chests    -> returns a fetch task for the first missing one
--  * otherwise                             -> nil
local function craft_for(player, data, name, need, from)
  local c = data.entity
  local force = player.force
  local cinv = c.get_main_inventory()
  local carried = crafting.inventory_counts(cinv)

  local plan = crafting.resolve(common.ENTITY_NAME, force, name, need, crafting.copy(carried))
  if plan then
    crafting.enqueue(data, cinv, plan, name, common.crafting_speed(player))
    data.status = "Queued crafting: " .. name
    return "queued"
  end

  local stock = crafting.copy(carried)
  for item, total in pairs(supply.get(force, c.surface).totals) do
    stock[item] = (stock[item] or 0) + total
  end
  plan = crafting.resolve(common.ENTITY_NAME, force, name, need, stock)
  if not plan then return nil end

  for item, n in pairs(plan.raw) do
    local missing = n - (carried[item] or 0)
    if missing > 0 then
      local chest = supply.find_chest(force, c.surface, item, "normal", missing, from)
      if chest then
        return tasks.new("fetch", {
          chest = chest, item = item, quality = "normal", count = missing,
          fetch = missing, fetch_max = missing + n * (common.CRAFT_BATCH - 1),
        })
      end
    end
  end
  return nil
end

-- The item can't be made from what the companion carries + the chests. If the only thing missing
-- is wood (or wood is part of it), go and chop trees for it, like a player would.
-- Returns a mine task or nil.
local function wood_task_for(player, data, name, need)
  local force, c = player.force, data.entity
  local plenty = {["iron-plate"] = 1e6, ["copper-plate"] = 1e6, ["stone"] = 1e6, ["wood"] = 1e6}
  local plan = crafting.resolve(common.ENTITY_NAME, force, name, need, plenty)
  local wood_needed = plan and plan.raw["wood"] or 0
  if wood_needed <= 0 then return nil end
  local carried = c.get_main_inventory().get_item_count("wood")
  local in_chests = supply.get(force, c.surface).totals["wood"] or 0
  local missing = wood_needed - carried - in_chests - ((data.pending or {})["wood"] or 0)
  if missing <= 0 then return nil end
  data.status = "Needs " .. missing .. " more wood for " .. name
  return tasks.new("mine", {item = "wood", from_trees = true, target = carried + missing})
end

M.craft_for = craft_for -- for objectives that need an item made without a ghost (science packs)

-- How many of an item still fit into the inventory (keeps a few stacks free for mined / salvaged items).
local function room_for(cinv, name, quality)
  local proto = prototypes.item[name]
  local size = proto and proto.stack_size or 1
  local ok, fits = pcall(cinv.get_insertable_count, {name = name, quality = quality or "normal"})
  if not ok or type(fits) ~= "number" then return math.huge end
  return math.max(0, fits - common.FETCH_KEEP_FREE_STACKS * size)
end

-- Adds up what ALL the listed jobs need, per item: {["name|quality"] = total}. Jobs that are blocked are skipped.
local function total_demand(data, entities, spec)
  local demand = {}
  for _, e in pairs(entities) do
    if e.valid and (data.blocked[spec.key(e)] or 0) < game.tick then
      local name, count, quality = spec.requirement(e)
      if name then
        local k = name .. "|" .. (quality or "normal")
        demand[k] = (demand[k] or 0) + count
      end
    end
  end
  return demand
end

-- Generic "supply and do" loop for work that needs ONE item per job (a ghost to build, a building to upgrade).
-- spec = {requirement = fn(e) -> name, count, quality, key = fn(e) -> blocked key,
--         label = fn(e) -> text, task = fn(e, name, count, quality) -> task}
-- carried_only: stop after step 1 (jobs the carried items can do right now); never fetch or craft.
local function try_supplied(player, data, entities, spec, carried_only)
  local c = data.entity
  local cinv = c.get_main_inventory()
  local pos = c.position

  local list = {}
  for _, e in pairs(entities) do
    list[#list + 1] = {e = e, d = common.dist2(e.position, pos)}
  end
  table.sort(list, function(a, b) return a.d < b.d end)

  -- a job far away that construction robots are about to do is left to them: no trip for it (spec.claimed)
  local bots_on = spec.claimed ~= nil and bot_claims.enabled(player)
  local bot_min2 = bots_on and bot_claims.min_distance(player) ^ 2 or 0
  local function bot_job(g, d2, name, count)
    if not bots_on or d2 < bot_min2 then return false end
    if bot_claims.claimed(g, name, count) then
      data.blocked[spec.key(g)] = game.tick + bot_claims.RECHECK
      return true
    end
    return false
  end

  -- 1) USE WHAT IT CARRIES FIRST: the nearest job that the carried items can do right now. Only when none can be
  --    done, go and fetch / craft for the nearest one (before, the nearest job decided, even when it needed a trip
  --    while other jobs could be done on the spot).
  for _, entry in ipairs(list) do
    local g = entry.e
    if g.valid and (data.blocked[spec.key(g)] or 0) < game.tick then
      local name, count, quality = spec.requirement(g)
      if name and cinv.get_item_count{name = name, quality = quality} >= count
          and not bot_job(g, entry.d, name, count) then
        return spec.task(g, name, count, quality)
      end
    end
  end

  if carried_only then return nil end

  -- 2) nothing buildable from the inventory: supply the nearest job
  local pend = crafting.copy(data.pending or {})
  local unsupplied = {}
  local demand = total_demand(data, entities, spec) -- e.g. 90 walls -> {["stone-wall|normal"] = 90}

  for _, entry in ipairs(list) do
    local g = entry.e
    if g.valid and (data.blocked[spec.key(g)] or 0) < game.tick then
      local name, count, quality = spec.requirement(g)
      local skey = name and (name .. "|" .. (quality or "normal"))
      if name and not unsupplied[skey] and not bot_job(g, entry.d, name, count) then
        local have = cinv.get_item_count{name = name, quality = quality}

        if have >= count then
          return spec.task(g, name, count, quality)
        end

        local need = count - have
        local normal = (quality == nil or quality == "normal")
        -- everything the visible jobs need of this item, minus what is carried / being crafted (at least `need`)
        local total = math.max(need, (demand[skey] or count) - have - (normal and (data.pending or {})[name] or 0))
        if normal and (pend[name] or 0) >= need then
          pend[name] = pend[name] - need -- a queued craft will cover this one
        else
          local want_total = total
          if common.FETCH_ALL then
            want_total = math.min(total, math.max(need, room_for(cinv, name, quality)))
          else
            want_total = need + count * (common.FETCH_BATCH - 1)
          end
          local chest = supply.find_chest(player.force, c.surface, name, quality, want_total, pos)
          if not chest and want_total > need then
            chest = supply.find_chest(player.force, c.surface, name, quality, need, pos) -- some chest holding at least one job's worth
          end
          if chest then
            return tasks.new("fetch", {
              chest = chest, item = name, quality = quality, count = count,
              fetch = need, fetch_max = math.max(need, want_total),
              ghost_name = spec.label(g),
              then_task = spec.task(g, name, count, quality),
            })
          end
          local result = nil
          if normal then
            -- craft everything that is needed in one go when the materials allow it, else just this job's share
            if total > need then result = craft_for(player, data, name, total, pos) end
            if result == nil then result = craft_for(player, data, name, need, pos) end
          end
          if type(result) == "table" then
            return result
          elseif result == "queued" then
            pend[name] = math.max(0, (data.pending[name] or 0) - need)
          else
            local wood = normal and wood_task_for(player, data, name, need) or nil
            if wood then return wood end
            unsupplied[skey] = true
          end
        end
      end
    end
  end
  return nil
end

local GHOST_SPEC = {
  requirement = ghost_requirement,
  key = common.ghost_key,
  label = function(g) return g.ghost_name end,
  claimed = true, -- ghosts can be left to construction robots (scripts/bot_claims.lua)
  task = function(ghost, name, count, quality)
    return tasks.new("build", {
      ghost = ghost, ghost_name = ghost.ghost_name, item = name, quality = quality, count = count,
    })
  end,
}

-- Upgrades: the item needed is the one that places the UPGRADE TARGET.
local function upgrade_key(e)
  local p = e.position
  return string.format("upg@%s@%.1f,%.1f", e.name, p.x, p.y)
end

local UPGRADE_SPEC = {
  requirement = function(e)
    local ok, proto, q = pcall(e.get_upgrade_target)
    if not ok or not proto then return nil end
    local item = proto.items_to_place_this and proto.items_to_place_this[1]
    if not item then return nil end
    local quality = (q and (type(q) == "string" and q or q.name)) or (e.quality and e.quality.name) or "normal"
    return item.name, item.count or 1, quality
  end,
  key = upgrade_key,
  label = function(e) return e.name end,
  task = function(e, name, count, quality)
    return tasks.new("upgrade", {target = e, item = name, quality = quality, count = count, label = e.name})
  end,
}

local function try_ghosts(player, data, ghosts, carried_only)
  return try_supplied(player, data, ghosts, GHOST_SPEC, carried_only)
end

-- Buildings marked for upgrade (center/radius nil = whole surface).
local function upgrade_task(player, data, center, radius)
  if not common.UPGRADE then return nil end
  local c = data.entity
  local filter = {to_be_upgraded = true, force = player.force, limit = radius and common.NEAR_GHOST_LIMIT or common.FAR_GHOST_LIMIT}
  if radius then filter.position, filter.radius = center, radius end
  local list = {}
  for _, e in pairs(c.surface.find_entities_filtered(filter)) do
    if e.valid and e.to_be_upgraded() then list[#list + 1] = e end
  end
  if #list == 0 then return nil end
  return try_supplied(player, data, list, UPGRADE_SPEC)
end

-- Nearest entity marked for deconstruction that the companion can mine (center/radius nil = whole surface).
local function deconstruct_task(player, data, center, radius)
  if not common.DECONSTRUCT then return nil end
  local c = data.entity
  local filter = {to_be_deconstructed = true, limit = radius and common.NEAR_GHOST_LIMIT or common.FAR_GHOST_LIMIT}
  if radius then filter.position, filter.radius = center, radius end
  local best, best_d
  for _, e in pairs(c.surface.find_entities_filtered(filter)) do
    if e.valid and e ~= c and e.minable and e.type ~= "character"
       and e.type ~= "entity-ghost" and e.type ~= "tile-ghost" and e.force.name ~= "enemy" then
      local key = string.format("decon@%s@%.1f,%.1f", e.name, e.position.x, e.position.y)
      if (data.blocked[key] or 0) < game.tick then
        local d = common.dist2(e.position, c.position)
        if not best or d < best_d then best, best_d = e, d end
      end
    end
  end
  return best and tasks.new("deconstruct", {target = best}) or nil
end

-- Pick the next task (if any) and store it in data.task.
--   opts (optional): {center = position, radius = tiles, near_only = true}
--   With near_only the planner only looks at ghosts within `radius` of `center` (default: the companion):
--   this is the "follow me and build what is near" behaviour. Materials come from what the companion carries,
--   the chests and the logistic network, and missing items are crafted (craft_for).
function M.plan(player, data, opts)
  opts = opts or {}
  local c = data.entity
  local surface = c.surface

  local near = surface.find_entities_filtered{
    type = common.GHOST_TYPES, force = player.force,
    position = opts.center or c.position, radius = opts.radius or common.NEAR_SEARCH_RADIUS,
    limit = common.NEAR_GHOST_LIMIT,
  }
  -- Order (0.19.10) - the point is to SAVE TRIPS:
  --   1. work the carried items can do right now (nearest first): deconstruct near, build near, build far.
  --      It keeps building until the carried items cannot build anything more - never interrupted by a restock.
  --   2. nothing doable from the inventory: the carried loadout (scripts/loadout.lua) is topped up in ONE round with
  --      everything on the requests list, so the next stretch of work needs no trip. Following the player, only
  --      chests near the player count.
  --   3. otherwise fetch / craft for the nearest job (as before): upgrades, far ghosts, far deconstruction.
  local near_limit = opts.near_only and {center = opts.center or c.position, radius = opts.radius or common.NEAR_SEARCH_RADIUS} or nil
  local far_list
  local function far_ghosts()
    if not far_list then
      far_list = surface.find_entities_filtered{
        type = common.GHOST_TYPES, force = player.force, limit = common.FAR_GHOST_LIMIT,
      }
    end
    return far_list
  end

  local task = deconstruct_task(player, data, opts.center or c.position, opts.radius or common.NEAR_SEARCH_RADIUS)
  if not task and #near > 0 then task = try_ghosts(player, data, near, true) end
  if not task and not opts.near_only then
    local far = far_ghosts()
    if #far > 0 then task = try_ghosts(player, data, far, true) end
  end

  if not task then
    local restock = loadout.next_task(player, data, {mode = "low", near = near_limit})
    if restock then return tasks.start(data, restock) end
  end

  if not task and #near > 0 then task = try_ghosts(player, data, near) end
  if not task then task = upgrade_task(player, data, opts.center or c.position, opts.radius or common.NEAR_SEARCH_RADIUS) end

  if not task and not opts.near_only then
    local far = far_ghosts()
    if #far > 0 then task = try_ghosts(player, data, far) end
    if not task then task = upgrade_task(player, data, nil, nil) end
    if not task then task = deconstruct_task(player, data, nil, nil) end
  end

  -- nothing to do: use the time to top the loadout up completely
  if not task then
    task = loadout.next_task(player, data, {mode = "top", near = near_limit})
  end

  -- still nothing: put what is above the MAX of the requests into a free storage chest (scripts/deposit.lua)
  if not task then
    task = deposit.next_task(player, data, {near = near_limit})
  end

  if task then
    tasks.start(data, task)
  elseif data.craft_queue and #data.craft_queue > 0 then
    data.status = "Idle: waiting for crafts to finish"
  else
    data.status = opts.near_only and "Idle: nothing near me to build, upgrade or remove" or "Idle: no ghosts I can supply"
  end
end

-- "Follow me and build what is near": call every tick from the follow loop (see README_near_build.md).
-- Returns true while a task is running (the follow code should then not steer the companion).
function M.near_build_step(player, data)
  if data.task then
    tasks.run(player, data)
    return data.task ~= nil
  end
  if game.tick >= (data.next_plan or 0) then
    data.next_plan = game.tick + 30
    M.plan(player, data, {center = player.position, radius = common.NEAR_BUILD_RADIUS, near_only = true})
  end
  return data.task ~= nil
end

return M
