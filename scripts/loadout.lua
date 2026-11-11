-- Carried loadout: the companion keeps a stock of items on it all the time, like a player does,
-- so it does not have to run back to a chest for every ghost.
--
--   * WHAT it carries is chosen by the player in the requests window (scripts/requests.lua): per item a MIN and a MAX,
--     like the personal logistics requests of the player. Nothing is fixed in the code any more.
--   * The planner only asks for a restock when the carried items cannot do any more work (scripts/planner.lua, M.plan):
--     it never interrupts building that the carried items can still do. Then:
--   * When an item is below its MIN it plans a "restock" task: ONE trip to the chest that holds the most of the
--     missing items (several materials per visit), filling each up to its MAX, then the next chest, until all is topped up.
--   * It also puts on the best armor it can find: armor raises the inventory size (the character prototype's
--     armor slot), so a better armor means more room to carry.

local common   = require("scripts.common")
local supply   = require("scripts.supply")
local requests = require("scripts.requests")
local tasks  = require("scripts.tasks.core") -- (restock registers itself through scripts/tasks.lua)

local M = {}

-- Ties in inventory bonus are broken by this order (best first); other armors rank by their inventory bonus.
M.ARMOR_TIERS = {"mech-armor", "power-armor-mk2", "power-armor", "modular-armor", "heavy-armor", "light-armor"}

M.MIN_TRIP_SHARE  = 0.25  -- a chest is only worth a visit for an item when it can give this share of the missing amount (max)
M.KEEP_FREE_STACKS = 2    -- restocking never fills the last free slots (room for mined / salvaged items)
M.COOLDOWN        = 1800  -- an item nobody could supply is not asked for again for this long (ticks)
M.CHECK_INTERVAL  = 120   -- ticks between two looks at the inventory
M.FAR_TRIP        = 150   -- tiles: a chest this far is only worth interrupting the work for when something is nearly used up
M.FAR_NEARLY_OUT  = 0.4   -- ... "nearly used up" = this share of the MAX or less is left

---------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------

local function setting(player, name)
  local s = settings.get_player_settings(player)[name]
  return s and s.value
end

function M.enabled(player)
  return setting(player, "ec-loadout-enabled") ~= false
end

-- Researched = some enabled recipe makes it (items without any recipe count as available).
local function unlocked(force, item)
  local filter = {{filter = "has-product-item", elem_filters = {{filter = "name", name = item}}}}
  local any = false
  for name in pairs(prototypes.get_recipe_filtered(filter)) do
    any = true
    local r = force.recipes[name]
    if r and r.enabled then return true end
  end
  return not any
end

local function count(inv, item)
  return inv.get_item_count{name = item, quality = "normal"}
end

---------------------------------------------------------------------
-- Armor
---------------------------------------------------------------------

local armor_list -- {item name, ...} best first (rebuilt lazily; derived from prototypes only)

local function armors()
  if armor_list then return armor_list end
  local found = {}
  for name, proto in pairs(prototypes.get_item_filtered{{filter = "type", type = "armor"}}) do
    local rank = 0
    for i, n in ipairs(M.ARMOR_TIERS) do
      if n == name then rank = #M.ARMOR_TIERS - i + 1 end
    end
    found[#found + 1] = {name = name, bonus = common.try_get(proto, "inventory_size_bonus") or 0, rank = rank}
  end
  table.sort(found, function(a, b)
    if a.bonus ~= b.bonus then return a.bonus > b.bonus end
    if a.rank ~= b.rank then return a.rank > b.rank end
    return a.name < b.name
  end)
  armor_list = {}
  for _, a in ipairs(found) do armor_list[#armor_list + 1] = a end
  return armor_list
end

local function armor_inventory(c)
  local ok, inv = pcall(c.get_inventory, defines.inventory.character_armor)
  return ok and inv or nil
end

local function armor_rank(name)
  for i, a in ipairs(armors()) do
    if a.name == name then return #armors() - i + 1 end
  end
  return 0
end

-- Puts on the best armor that is carried (swapping out a worse one). Returns the name worn afterwards or nil.
function M.equip(data)
  local c = data.entity
  if not (c and c.valid) then return nil end
  local ainv = armor_inventory(c)
  local cinv = c.get_main_inventory()
  if not (ainv and cinv) then return nil end

  local worn = ainv[1] and ainv[1].valid_for_read and ainv[1].name or nil
  local worn_rank = worn and armor_rank(worn) or 0
  local best, best_rank
  for _, a in ipairs(armors()) do
    local r = armor_rank(a.name)
    if r > worn_rank and count(cinv, a.name) > 0 then best, best_rank = a.name, r break end
  end
  if not best then return worn end

  -- take the new one out of the inventory first, then give the old one back (a bigger armor only adds room)
  if cinv.remove{name = best, count = 1, quality = "normal"} < 1 then return worn end
  if worn then
    local old = ainv[1]
    local copy = {name = old.name, count = 1, quality = old.quality}
    ainv.clear()
    if cinv.insert(copy) < 1 then
      c.surface.spill_item_stack{position = c.position, stack = copy, enable_looted = false}
    end
  end
  ainv.insert{name = best, count = 1}
  data.status = "Put on " .. best
  return best
end

local function best_armor_wanted(force, surface, c, cinv)
  local ainv = armor_inventory(c)
  if not ainv then return nil end
  local worn = ainv[1] and ainv[1].valid_for_read and ainv[1].name or nil
  local worn_rank = worn and armor_rank(worn) or 0
  local totals = supply.get(force, surface).totals
  for _, a in ipairs(armors()) do
    local r = armor_rank(a.name)
    if r <= worn_rank then return nil end
    if count(cinv, a.name) > 0 then return nil end -- carried already: equip() puts it on
    if (totals[a.name] or 0) > 0 and unlocked(force, a.name) then return a.name end
  end
  return nil
end

---------------------------------------------------------------------
-- What is missing
---------------------------------------------------------------------

-- {{item, target, have, missing, min_trip}, ...} for the requests that are short.
-- mode "low": only items under their MIN; "top": anything under its MAX.
local function shortages(player, data, mode)
  local c = data.entity
  local cinv = c.get_main_inventory()
  local pending = data.pending or {}
  local cd = data.loadout_cd or {}
  local out = {}

  for _, r in ipairs(requests.active(player)) do
    if (cd[r.name] or 0) <= game.tick then
      local have = count(cinv, r.name) + (pending[r.name] or 0)
      local missing = r.max - have
      -- "low" = under the MIN AND missing enough to be worth a trip (a quarter of the MAX, or less than half of the
      -- MIN left): with MIN = MAX = 50 a single used drill (49 left) must not send it back to the chest
      local share = math.max(1, math.ceil(r.max * M.MIN_TRIP_SHARE))
      local low = have < r.min and (missing >= share or have <= r.min * 0.5)
      if missing > 0 and (mode == "top" or low) then
        out[#out + 1] = {
          item = r.name, target = r.max, have = have, missing = missing,
          min_trip = math.min(missing, math.max(1, math.ceil(r.max * M.MIN_TRIP_SHARE))),
          low = low,
        }
      end
    end
  end
  return out
end

-- How many of an item still fit (keeping some stacks free).
local function room_for(cinv, item)
  local proto = prototypes.item[item]
  local size = proto and proto.stack_size or 1
  local ok, fits = pcall(cinv.get_insertable_count, {name = item, quality = "normal"})
  if not ok or type(fits) ~= "number" then return math.huge end
  return math.max(0, fits - M.KEEP_FREE_STACKS * size)
end

---------------------------------------------------------------------
-- Planning
---------------------------------------------------------------------

-- Next restock task (or nil). opts: {mode = "low" | "top", near = {center = pos, radius = n}}
function M.next_task(player, data, opts)
  opts = opts or {}
  if not M.enabled(player) then return nil end
  local c = data.entity
  if not (c and c.valid) then return nil end
  if game.tick < (data.next_loadout or 0) then return nil end
  data.next_loadout = game.tick + M.CHECK_INTERVAL

  M.equip(data)

  local force, surface, pos = c.force, c.surface, c.position
  local cinv = c.get_main_inventory()
  -- everything under its MAX; in "low" mode the trip only starts when something is under its MIN,
  -- and then tops up ALL of it (like the personal logistics of the player)
  local wants = shortages(player, data, "top")

  local armor = best_armor_wanted(force, surface, c, cinv)
  if armor then wants[#wants + 1] = {item = armor, target = 1, have = 0, missing = 1, min_trip = 1, armor = true, low = true} end
  if #wants == 0 then return nil end
  if (opts.mode or "low") == "low" then
    local any_low = false
    for _, w in ipairs(wants) do if w.low then any_low = true break end end
    if not any_low then return nil end
  end

  -- candidate chests: the best pickup point of every missing item
  local candidates, seen = {}, {}
  for _, w in ipairs(wants) do
    local chest = supply.find_chest(force, surface, w.item, "normal", w.min_trip, pos)
    if chest and chest.valid and not seen[chest.unit_number] then
      local in_range = true
      if opts.near then in_range = common.dist2(chest.position, opts.near.center) <= opts.near.radius ^ 2 end
      if in_range then
        seen[chest.unit_number] = true
        candidates[#candidates + 1] = chest
      end
    end
  end

  -- the chest that covers the most of what is missing (several materials per visit), then the closest
  local best
  for _, chest in ipairs(candidates) do
    local entries, covered = {}, 0
    for _, w in ipairs(wants) do
      local have = chest.get_item_count{name = w.item, quality = "normal"}
      if have >= w.min_trip then
        local take = math.min(have, w.missing, room_for(cinv, w.item))
        if take > 0 then
          entries[#entries + 1] = {name = w.item, count = take, want = w.missing}
          covered = covered + 1
        end
      end
    end
    if covered > 0 then
      local d = common.dist2(chest.position, pos)
      if not best or covered > best.covered or (covered == best.covered and d < best.d) then
        best = {chest = chest, entries = entries, covered = covered, d = d}
      end
    end
  end

  -- items nobody can supply are left alone for a while (no endless trips)
  data.loadout_cd = data.loadout_cd or {}
  for _, w in ipairs(wants) do
    local served = false
    if best then
      for _, e in ipairs(best.entries) do if e.name == w.item then served = true end end
    end
    local elsewhere = false
    for _, chest in ipairs(candidates) do
      if chest.valid and chest.get_item_count{name = w.item, quality = "normal"} >= w.min_trip then elsewhere = true end
    end
    if not served and not elsewhere then data.loadout_cd[w.item] = game.tick + M.COOLDOWN end
  end

  if not best then return nil end
  -- a long trip is not worth interrupting the work for unless something is nearly used up (opts.mode "top" = idle)
  if (opts.mode or "low") == "low" and math.sqrt(best.d) > M.FAR_TRIP then
    local urgent = false
    for _, w in ipairs(wants) do
      if w.low and not w.armor and w.have <= w.target * M.FAR_NEARLY_OUT then urgent = true break end
    end
    if not urgent then return nil end
  end
  data.next_loadout = 0 -- keep going: the next chest is planned as soon as this trip is done
  return tasks.new("restock", {chest = best.chest, entries = best.entries})
end

return M
