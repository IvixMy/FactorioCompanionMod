-- Task "deposit": walk to a free storage chest and put the surplus (what is above the MAX of the requests) into it.
--   fields: chest, entries = {{name, count}, ...}      (planned by scripts/deposit.lua)
-- On arrival everything is checked again: the chest may have got an inserter since the trip was planned, and the
-- companion may have used some of the items on the way. It never drops below the MAX of a request.

local common   = require("scripts.common")
local supply   = require("scripts.supply")
local core     = require("scripts.tasks.core")
local requests = require("scripts.requests")
local chests   = require("scripts.storage_chests")

local BLOCK_TIME = 1800

local function block(data, chest)
  data.deposit_blocked = data.deposit_blocked or {}
  if chest.valid then data.deposit_blocked[chest.unit_number] = game.tick + BLOCK_TIME end
end

return {
  id = "deposit",

  describe = function(task)
    local names = {}
    for _, e in ipairs(task.entries or {}) do names[#names + 1] = e.name end
    return "Storing surplus: " .. table.concat(names, ", ")
  end,

  execute = function(player, data, task)
    local chest = task.chest
    if not (chest and chest.valid) then return core.abort(data, "Storage chest disappeared") end
    if not common.walk_towards(data, chest.position, common.CHEST_REACH) then return end

    if not chests.is_free(player, chest) then
      block(data, chest)
      return core.abort(data, "That chest is in use by a machine now, not storing there")
    end

    local inv = chest.get_inventory(defines.inventory.chest)
    local cinv = data.entity.get_main_inventory()
    if not inv then return core.abort(data, "Chest has no inventory") end

    local keep = {}
    for _, r in ipairs(requests.active(player)) do keep[r.name] = r.max end

    local stored = {}
    for _, e in ipairs(task.entries) do
      local give = math.min(e.count, cinv.get_item_count{name = e.name, quality = "normal"} - (keep[e.name] or 0))
      if give > 0 then
        local inserted = inv.insert{name = e.name, count = give, quality = "normal"}
        if inserted > 0 then
          cinv.remove{name = e.name, count = inserted, quality = "normal"}
          stored[#stored + 1] = e.name .. " x" .. inserted
        end
        if inserted < give then block(data, chest) end -- full: try another chest next time
      end
    end

    supply.invalidate()
    data.next_deposit = game.tick + 120
    core.finish(data, #stored > 0 and ("Stored " .. table.concat(stored, ", ")) or "Nothing to store")
  end,
}
