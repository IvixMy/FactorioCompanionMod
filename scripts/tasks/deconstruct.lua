-- Task "deconstruct": walk to an entity marked for deconstruction and MINE it, exactly like a player does:
--   * the engine's own hand-mining is used (mining animation), so it takes mining_time / mining speed
--     for trees, rocks and buildings alike, and the engine adds the real mining products to the inventory
--     (a tree gives wood, a rock stone/coal, a chest its contents, ...)
--   * if the engine does not finish within the expected time (blocked, out of reach, ...), the entity is
--     mined by script once that time has passed, so the result is never faster than a player's
--   fields: target (LuaEntity), stash (optional chest, see scripts/salvage.lua)

local common  = require("scripts.common")
local core    = require("scripts.tasks.core")
local salvage = require("scripts.salvage")
local crafting = require("scripts.crafting")

local function key_of(e)
  return string.format("decon@%s@%.1f,%.1f", e.name, e.position.x, e.position.y)
end

local function set_mining(c, on, position)
  pcall(function()
    if on then c.mining_state = {mining = true, position = position} else c.mining_state = {mining = false} end
  end)
end

-- Same formula as the engine: base mining speed * (1 + force bonus + character bonus).
local function mining_speed(c)
  local base = common.try_get(c.prototype, "mining_speed") or 0.5
  local bonus = (common.try_get(c.force, "manual_mining_speed_modifier") or 0)
              + (common.try_get(c, "character_mining_speed_modifier") or 0)
  return math.max(0.05, base * (1 + bonus))
end

local function expected_ticks(c, e)
  local props = common.try_get(e.prototype, "mineable_properties")
  local mining_time = (props and common.try_get(props, "mining_time")) or 0.5
  return math.ceil(mining_time / mining_speed(c) * 60)
end

return {
  id = "deconstruct",
  timeout = 60 * 60 * 2,

  describe = function(task)
    local name = task.name or (task.target.valid and task.target.name) or "an entity"
    return (task.stash and "Storing salvage after deconstructing " or "Deconstructing ") .. name
  end,

  execute = function(player, data, task)
    local c = data.entity
    local cinv = c.get_main_inventory()

    -- phase 2: carrying salvage to a storage chest
    if task.stash then
      set_mining(c, false)
      if not task.stash.valid then task.stash = nil; return end
      if not common.walk_towards(data, task.stash.position, common.CHEST_REACH) then return end
      salvage.stash(data, task.stash)
      task.stash = nil
      return -- next tick continues with the target
    end

    local e = task.target

    -- finished: mined by the engine (or cancelled meanwhile)
    if not (e.valid and e.to_be_deconstructed()) then
      set_mining(c, false)
      if task.started then
        salvage.record_gain(data, task.before, cinv)
        return core.finish(data, "Deconstructed " .. (task.name or "entity"))
      end
      return core.finish(data)
    end

    -- inventory nearly full: first empty the salvage into a storage chest
    if not task.started and salvage.needs_stash(cinv) then
      local chest = salvage.find_stash(c)
      if not chest then
        data.blocked[key_of(e)] = game.tick + common.BLOCKED_COOLDOWN
        return core.abort(data, "Could not deconstruct " .. e.name .. ": inventory full, no storage chest with room")
      end
      task.stash = chest
      return
    end

    local box = e.bounding_box
    local half = math.max(box.right_bottom.x - box.left_top.x, box.right_bottom.y - box.left_top.y) / 2
    if not common.walk_towards(data, e.position, math.min(4, 2 + half)) then
      set_mining(c, false)
      return
    end

    if not task.started then
      task.started = game.tick
      task.name = e.name
      task.before = crafting.inventory_counts(cinv)
      task.expected = expected_ticks(c, e)
      data.status = task.stash and data.status or ("Deconstructing " .. e.name)
    end

    set_mining(c, true, e.position)

    -- the engine had its chance (expected time + 50% + 1.5 s): finish it by script
    if game.tick - task.started > task.expected * 1.5 + 90 then
      local name = e.name
      set_mining(c, false)
      if e.mine{inventory = cinv, force = false, raise_destroyed = true} then
        salvage.record_gain(data, task.before, cinv)
        return core.finish(data, "Deconstructed " .. name)
      end
      data.blocked[key_of(e)] = game.tick + common.BLOCKED_COOLDOWN
      return core.abort(data, "Could not deconstruct " .. name)
    end
  end,
}
