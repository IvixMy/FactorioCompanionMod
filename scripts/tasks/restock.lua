-- Task "restock": walk to a chest and take several materials in one visit (the carried loadout, scripts/loadout.lua).
--   fields: chest, entries = {{name, count, want}, ...}
-- Armor that was taken is put on straight away. Items the chest could not fully give are put on a cooldown
-- (data.loadout_cd) so the companion does not walk back and forth for a few leftovers.

local common  = require("scripts.common")
local supply  = require("scripts.supply")
local core    = require("scripts.tasks.core")
local loadout = require("scripts.loadout")

return {
  id = "restock",

  describe = function(task)
    local names = {}
    for _, e in ipairs(task.entries or {}) do names[#names + 1] = e.name end
    return "Restocking: " .. table.concat(names, ", ")
  end,

  execute = function(player, data, task)
    if not task.chest.valid then
      supply.invalidate()
      return core.abort(data, "Chest disappeared")
    end
    if not common.walk_towards(data, task.chest.position, common.CHEST_REACH) then return end

    local chest_inv = task.chest.get_inventory(defines.inventory.chest)
    local cinv = data.entity.get_main_inventory()
    local took = {}
    if chest_inv then
      for _, e in ipairs(task.entries) do
        local removed = chest_inv.remove{name = e.name, count = e.count, quality = "normal"}
        if removed > 0 then
          local inserted = cinv.insert{name = e.name, count = removed, quality = "normal"}
          if inserted < removed then chest_inv.insert{name = e.name, count = removed - inserted, quality = "normal"} end
          took[#took + 1] = e.name .. " x" .. inserted
          if inserted < e.want then
            data.loadout_cd = data.loadout_cd or {}
            data.loadout_cd[e.name] = game.tick + loadout.COOLDOWN
          end
        else
          data.loadout_cd = data.loadout_cd or {}
          data.loadout_cd[e.name] = game.tick + loadout.COOLDOWN
        end
      end
    end

    supply.invalidate()
    loadout.equip(data)
    data.next_loadout = 0
    core.finish(data, #took > 0 and ("Restocked " .. table.concat(took, ", ")) or "Restock found nothing")
  end,
}
