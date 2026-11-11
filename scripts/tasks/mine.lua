-- Task "mine": hand-mine the nearest source of an item until the companion carries `target` of it.
--   fields: item, target (carried count),
--           resource   (optional) names of the resource entities that yield the item (e.g. {"coal"});
--                      default: an entity named like the item
--           from_trees (optional) mine trees instead (wood)
--           near       (optional) look around this position instead of the companion's
--           radius     (optional) how far to look (default common.MINE_RADIUS)
--           then_task  (optional) task started when the target is reached
-- Resource tiles lose 1 amount per item; trees are mined whole.

local common = require("scripts.common")
local core   = require("scripts.tasks.core")
local ore    = require("scripts.ore")
local goals  = require("scripts.goals")

local MINE_INTERVAL = 20 -- ticks per item
local REACH = 2

local function nearest_source(surface, task, from)
  local center = task.near or from
  if task.from_trees or task.item == "wood" then
    local list = surface.find_entities_filtered{type = "tree", position = center, radius = task.radius or common.MINE_RADIUS, limit = 60}
    local best, best_d
    for _, e in pairs(list) do
      local d = common.dist2(e.position, from)
      if not best or d < best_d then best, best_d = e, d end
    end
    return best
  end
  return ore.nearest(surface, task.resource or task.item, center, task.radius or common.MINE_RADIUS, from)
end

local NO_GAIN_TICKS = 300 -- real mining gave nothing for this long: fall back to the manual way

-- Plays the mining animation and mines for real (the engine adds the items to the inventory).
local function set_mining(c, on, position)
  local ok = pcall(function()
    if on then c.mining_state = {mining = true, position = position} else c.mining_state = {mining = false} end
  end)
  return ok
end

local function leave(c) set_mining(c, false) end

return {
  id = "mine",
  timeout = 60 * 60 * 5, -- far patches (charted map search) mean a long walk

  describe = function(task)
    return "Mining " .. task.item .. " by hand" .. (task.batched and (" (up to " .. task.target .. ", everything the zones need)") or "")
  end,

  execute = function(player, data, task)
    local c = data.entity
    local cinv = c.get_main_inventory()
    local have = cinv.get_item_count(task.item)
    if have >= task.target then
      leave(c)
      if task.then_task then return core.chain(data, task.then_task) end
      return core.finish(data, "Mined " .. task.item)
    end

    local src = task.source
    if not (src and src.valid) then
      src = nearest_source(c.surface, task, c.position)
      if not src then
        leave(c)
        return core.abort(data, "No " .. task.item .. " within " .. (task.radius or common.MINE_RADIUS) .. " tiles")
      end
      task.source = src
    end
    if not common.walk_towards(data, src.position, REACH) then
      leave(c)
      return
    end

    -- track whether real mining is producing items
    if task.last_count ~= have then
      task.last_count = have
      task.last_gain = game.tick
    end
    task.last_gain = task.last_gain or game.tick

    if not task.manual then
      if set_mining(c, true, src.position) and game.tick - task.last_gain <= NO_GAIN_TICKS then
        return -- the engine is mining; the animation plays
      end
      task.manual = true -- real mining is stuck: add the items by hand, but keep the animation going
    end
    -- manual fallback: keep the mining animation playing while the items are added
    if task.manual then set_mining(c, true, src.position) end

    if game.tick < (data.next_mine or 0) then return end
    data.next_mine = game.tick + MINE_INTERVAL

    if src.type == "resource" then
      if cinv.insert{name = task.item, count = 1} == 0 then
        return core.abort(data, "Inventory full")
      end
      goals.notify(c.force, "mine", src.name, 1)
      if not src.prototype.infinite_resource then
        -- a resource's amount may never be set to 0: remove the tile when its last unit is taken
        if src.amount <= 1 then
          src.destroy()
        else
          src.amount = src.amount - 1
        end
      end
    else
      local src_name = src.name
      if src.mine{inventory = cinv, force = true} then
        goals.notify(c.force, "mine", src_name, 1)
      else
        task.source = nil -- pick another one next tick
      end
    end
  end,
}
