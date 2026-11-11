-- Task "upgrade": walk to an entity marked for upgrade and replace it with its upgrade target.
-- The new building's item is taken from what the companion carries (the planner fetches / crafts it first);
-- the old building's item goes back into the inventory and is counted as salvage (scripts/salvage.lua).
--   fields: target (LuaEntity), item, quality, count (the NEW building's item), label

local common  = require("scripts.common")
local core    = require("scripts.tasks.core")
local goals   = require("scripts.goals")
local salvage = require("scripts.salvage")

local function key_of(e)
  return string.format("upg@%s@%.1f,%.1f", e.name, e.position.x, e.position.y)
end

local function target_of(e)
  local ok, proto, q = pcall(e.get_upgrade_target)
  if not ok or not proto then return nil end
  local qname = q and (type(q) == "string" and q or q.name) or (e.quality and e.quality.name) or "normal"
  return proto, qname
end

-- Replace e by its upgrade target. Returns true on success.
local function replace(e)
  local ok, new = pcall(e.apply_upgrade) -- engine way (keeps contents, modules, settings, connections)
  if ok and new then return true end
  if ok and not e.valid then return true end

  -- fallback: fast replace
  local proto, qname = target_of(e)
  if not proto then return false end
  local params = {
    name = proto.name, position = e.position, direction = e.direction, force = e.force,
    fast_replace = true, spill = false, raise_built = true, quality = qname,
  }
  if e.type == "underground-belt" then params.type = e.belt_to_ground_type end
  if e.type == "loader" or e.type == "loader-1x1" then params.type = e.loader_type end
  return e.surface.create_entity(params) ~= nil
end

return {
  id = "upgrade",

  describe = function(task) return "Upgrading " .. (task.label or "building") end,

  execute = function(player, data, task)
    local c = data.entity
    local e = task.target
    if not (e.valid and e.to_be_upgraded()) then return core.finish(data) end

    if not common.walk_towards(data, e.position, common.BUILD_REACH) then return end
    if game.tick < (data.next_build or 0) then return end -- construction speed limit

    local cinv = c.get_main_inventory()
    if cinv.get_item_count{name = task.item, quality = task.quality} < task.count then
      return core.finish(data) -- the planner fetches / crafts it again
    end

    -- what the old building gives back
    local old_quality = e.quality and e.quality.name or "normal"
    local old_items, before = {}, {}
    for _, it in pairs(e.prototype.items_to_place_this or {}) do
      old_items[#old_items + 1] = {name = it.name, count = it.count or 1}
      before[it.name] = cinv.get_item_count{name = it.name, quality = old_quality}
    end
    local old_name, key, pos = e.name, key_of(e), e.position

    if replace(e) then
      cinv.remove{name = task.item, count = task.count, quality = task.quality}
      for _, it in ipairs(old_items) do
        -- the engine may already have handed the old item over: give back only what is missing
        local gained = cinv.get_item_count{name = it.name, quality = old_quality} - before[it.name]
        local missing = it.count - math.max(0, gained)
        if missing > 0 then cinv.insert{name = it.name, count = missing, quality = old_quality} end
        salvage.record(data, it.name, it.count)
      end
      common.record_placed(data, c.surface.index, pos)
      goals.notify(c.force, "build", task.label or old_name, 1)
      data.next_build = game.tick + math.max(1, math.ceil(60 / common.builds_per_second(player)))
      return core.finish(data, "Upgraded " .. old_name)
    end

    data.blocked[key] = game.tick + common.BLOCKED_COOLDOWN
    core.abort(data, "Could not upgrade " .. old_name)
  end,
}
