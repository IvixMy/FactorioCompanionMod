-- Bookkeeping for items the companion receives from deconstructing / upgrading.
-- data.salvage[item] = count received. When the inventory fills up, ONLY these items are carried to a storage chest
-- (never the materials the companion is keeping for builds).

local common   = require("scripts.common")
local crafting = require("scripts.crafting")

local M = {}

M.MIN_FREE_STACKS = 2

function M.needs_stash(cinv)
  return cinv.count_empty_stacks() < M.MIN_FREE_STACKS
end

function M.record(data, item, n)
  if n <= 0 then return end
  data.salvage = data.salvage or {}
  data.salvage[item] = (data.salvage[item] or 0) + n
end

-- Everything that appeared in the inventory since `before` (a crafting.inventory_counts snapshot) is salvage.
function M.record_gain(data, before, cinv)
  for item, n in pairs(crafting.inventory_counts(cinv)) do
    M.record(data, item, n - (before[item] or 0))
  end
end

-- Only storage / passive-provider logistic chests: never a requester, and never a plain chest that may be a
-- feed chest of the lab or a factory.
function M.find_stash(c)
  local best, best_d
  local chests = c.surface.find_entities_filtered{
    type = "logistic-container", force = c.force, position = c.position, radius = common.MINE_RADIUS,
  }
  for _, ch in pairs(chests) do
    local mode = ch.valid and common.try_get(ch.prototype, "logistic_mode")
    if mode == "storage" or mode == "passive-provider" then
      local inv = ch.get_inventory(defines.inventory.chest)
      if inv and inv.count_empty_stacks() > 0 then
        local d = common.dist2(ch.position, c.position)
        if not best or d < best_d then best, best_d = ch, d end
      end
    end
  end
  return best
end

function M.stash(data, chest)
  local cinv = data.entity.get_main_inventory()
  local dest = chest.get_inventory(defines.inventory.chest)
  for item, n in pairs(data.salvage or {}) do
    local have = math.min(n, cinv.get_item_count(item))
    if have > 0 then
      local inserted = dest.insert{name = item, count = have}
      if inserted > 0 then cinv.remove{name = item, count = inserted} end
    end
  end
  data.salvage = {}
end

return M
