-- Deposit: what the companion carries ABOVE the MAX of its requests goes into a free storage chest.
--
--   * only items that are in the requests window (scripts/requests.lua) and are above their MAX are put away,
--     and only the part above MAX; everything else it carries (materials for builds, mined stuff...) is never touched
--   * only chests that nothing automated uses (scripts/storage_chests.lua): no inserter in or out, no drill, no loader,
--     not a lab / factory chest, not a requester / buffer / active-provider chest
--   * only when the companion has nothing else to do (no task, no craft running), see the hooks in
--     scripts/planner.lua and scripts/progress.lua
--
-- The restock side (scripts/loadout.lua) only ever fills up TO max, so the two never work against each other.

local common   = require("scripts.common")
local requests = require("scripts.requests")
local loadout  = require("scripts.loadout")
local chests   = require("scripts.storage_chests")
local tasks    = require("scripts.tasks.core") -- ("deposit" registers itself through scripts/tasks.lua)

local M = {}

M.ENABLED       = true  -- false: the companion never stores surplus
M.RADIUS        = common.MINE_RADIUS -- how far around the companion a storage chest is looked for
M.MIN_TRIP_SHARE = 0.25 -- a trip starts when some item is this share of its MAX above it (or the inventory is nearly full)
M.CHECK_INTERVAL = 120  -- ticks between two looks
M.IDLE_RETRY    = 1800  -- ticks to wait after "no suitable chest"
M.BLOCK_TIME    = 1800  -- a chest that is in use / full is not tried again for this long
M.MAX_CHECKED   = 10    -- how many candidate chests are inspected per planning

local function count(inv, item)
  return inv.get_item_count{name = item, quality = "normal"}
end

-- {{name, count (above max), min_trip}, ...}
function M.surplus(player, data)
  local cinv = data.entity.get_main_inventory()
  local out = {}
  for _, r in ipairs(requests.active(player)) do
    local extra = count(cinv, r.name) - r.max
    if extra > 0 then
      out[#out + 1] = {name = r.name, count = extra, min_trip = math.max(1, math.ceil(r.max * M.MIN_TRIP_SHARE))}
    end
  end
  return out
end

local function busy(data)
  return data.task ~= nil or (data.craft_queue and #data.craft_queue > 0)
end

-- Next deposit task (or nil). opts: {near = {center = pos, radius = n}} limits the chests like the restock does.
function M.next_task(player, data, opts)
  opts = opts or {}
  if not M.ENABLED or not loadout.enabled(player) then return nil end
  local c = data.entity
  if not (c and c.valid) then return nil end
  if busy(data) then return nil end
  if game.tick < (data.next_deposit or 0) then return nil end
  data.next_deposit = game.tick + M.CHECK_INTERVAL

  local cinv = c.get_main_inventory()
  local wants = M.surplus(player, data)
  if #wants == 0 then return nil end

  -- worth a trip? (a big surplus of something, or the inventory is running out of room)
  local worth = cinv.count_empty_stacks() < loadout.KEEP_FREE_STACKS
  for _, w in ipairs(wants) do
    if w.count >= w.min_trip then worth = true end
  end
  if not worth then return nil end

  -- candidate chests, nearest first
  local pos = c.position
  local list = {}
  for _, chest in pairs(c.surface.find_entities_filtered{
    type = common.CHEST_TYPES, force = c.force, position = pos, radius = M.RADIUS,
  }) do
    if chests.allowed_type(chest) then
      local ok = true
      if opts.near then ok = common.dist2(chest.position, opts.near.center) <= opts.near.radius ^ 2 end
      if ok then list[#list + 1] = {chest = chest, d = common.dist2(chest.position, pos)} end
    end
  end
  table.sort(list, function(a, b) return a.d < b.d end)

  data.deposit_blocked = data.deposit_blocked or {}
  local best, checked = nil, 0
  for _, cand in ipairs(list) do
    local chest = cand.chest
    if chest.valid and (data.deposit_blocked[chest.unit_number] or 0) <= game.tick then
      local inv = chest.get_inventory(defines.inventory.chest)
      local entries = {}
      if inv then
        for _, w in ipairs(wants) do
          local ok, fits = pcall(inv.get_insertable_count, {name = w.name, quality = "normal"})
          local take = math.min(w.count, (ok and type(fits) == "number") and fits or 0)
          if take > 0 then entries[#entries + 1] = {name = w.name, count = take} end
        end
      end
      if #entries > 0 then
        checked = checked + 1
        local free = chests.is_free(player, chest)
        if free then
          if not best or #entries > #best.entries then best = {chest = chest, entries = entries} end
          if #entries == #wants then break end -- the nearest chest that takes everything
        else
          data.deposit_blocked[chest.unit_number] = game.tick + M.BLOCK_TIME
        end
        if checked >= M.MAX_CHECKED then break end
      end
    end
  end

  if not best then
    data.next_deposit = game.tick + M.IDLE_RETRY
    return nil
  end
  return tasks.new("deposit", {chest = best.chest, entries = best.entries})
end

return M
