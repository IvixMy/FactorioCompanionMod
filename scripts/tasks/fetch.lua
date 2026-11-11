-- Task "fetch": walk to a chest and take items out of it.
--   fields: chest, item, quality, fetch (minimum needed), fetch_max (take up to this much),
--           then_task (optional task started when the items arrive),
--           ghost_name / purpose (for the status text)

local common = require("scripts.common")
local supply = require("scripts.supply")
local core   = require("scripts.tasks.core")

return {
  id = "fetch",

  describe = function(task)
    if task.then_task then
      return "Fetching " .. task.item .. " for " .. (task.ghost_name or task.purpose or "a task")
    end
    return "Gathering materials: " .. task.item
  end,

  execute = function(player, data, task)
    if not task.chest.valid then
      supply.invalidate()
      return core.abort(data, "Chest disappeared")
    end
    if not common.walk_towards(data, task.chest.position, common.CHEST_REACH) then return end

    local chest_inv = task.chest.get_inventory(defines.inventory.chest)
    local cinv = data.entity.get_main_inventory()
    local removed = chest_inv and chest_inv.remove{name = task.item, count = task.fetch_max, quality = task.quality} or 0
    local inserted = 0
    if removed > 0 then
      inserted = cinv.insert{name = task.item, count = removed, quality = task.quality}
      if inserted < removed then
        chest_inv.insert{name = task.item, count = removed - inserted, quality = task.quality}
      end
    end

    if inserted >= task.fetch then
      if task.then_task then
        core.chain(data, task.then_task)
      else -- gathered raw materials for a craft: the next plan queues the craft
        core.finish(data, "Gathered " .. task.item)
      end
    else
      supply.invalidate()
      core.abort(data, "Chest did not have enough " .. task.item)
    end
  end,
}
