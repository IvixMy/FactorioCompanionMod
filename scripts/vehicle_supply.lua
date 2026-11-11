-- Vehicle supply (0.19.2): what scripts/vehicles.lua needs before it can drive.
--
--   acquire(data, far)       no vehicle near and the trip is far: put down a car the companion carries, else craft
--                            one (hand-crafting, like any other item: planner.craft_for takes the materials from what it
--                            carries or fetches them from the chests, then queues the craft).
--   fuel_state(data, v, far) is there enough fuel for the trip? "ok" | "carried" (it is put in when boarding) |
--                            "chain" (a task chain fetches the BEST fuel it can get - chest, coal drills, mined or
--                            chopped by hand - puts it into the vehicle and then goes back to what it was doing) |
--                            "none" (no fuel anywhere).
--   fill(data, v, far)       puts the best fuel it CARRIES into the vehicle (a better fuel replaces a worse one in the
--                            slot). Also used to top up during a long drive.
--   low(v, far)              not enough energy in the tank for the way that is left.
--
-- "Best" is the same as everywhere (scripts/fuel.lua): the most energy per item among the fuels the vehicle burns.
--
-- Hooked in as vehicles.supplier (vehicles.lua cannot require the planner: planner -> crafting -> vehicles).

local common   = require("scripts.common")
local vehicles = require("scripts.vehicles")
local fuel     = require("scripts.fuel")
local planner  = require("scripts.planner")
local tasks    = require("scripts.tasks")

local M = {}

M.CRAFTABLE      = {"car"}   -- vehicle items it may make (a tank or a spidertron is far too expensive for this)
M.TILES_PER_SEC  = 6         -- a (slow) estimate of the speed, for the fuel a trip needs
M.TRIP_SLACK     = 1.3
M.MIN_SECONDS    = 30        -- ... and never less than this much running time
M.MAX_FETCHES    = 6         -- material trips for ONE car before it gives up for a while
M.GIVE_UP_TICKS  = 7200

local function owner(data)
  for index, d in pairs(storage.companions or {}) do
    if d == data then return game.get_player(index) end
  end
  return nil
end

local function say(data, text)
  data.status = text
end

---------------------------------------------------------------------
-- Fuel
---------------------------------------------------------------------

function M.low(v, far)
  if not (v and v.valid) or not fuel.is_burner(v) then return false end
  local need = math.max(M.MIN_SECONDS, (far or 0) / M.TILES_PER_SEC * M.TRIP_SLACK)
  return fuel.seconds_left(v) < need
end

local function fuel_value(name)
  local proto = prototypes.item[name]
  return proto and common.try_get(proto, "fuel_value") or 0
end

-- Puts the best CARRIED fuel into the vehicle. Returns true when it has enough fuel for `far` tiles afterwards.
function M.fill(data, v, far)
  if not (v and v.valid) then return false end
  local inv = v.get_fuel_inventory()
  if not inv then return true end
  local cinv = data.entity.get_main_inventory()

  for _, f in ipairs(fuel.candidates(v)) do -- best (most energy per item) first
    if not M.low(v, far) then break end
    local have = cinv.get_item_count{name = f.name, quality = "normal"}
    if have > 0 then
      local usable = true
      if not inv.can_insert{name = f.name, count = 1} then
        -- the slot holds ANOTHER fuel: replace it only when this one is better (the old one goes back to my inventory)
        for _, s in pairs(inv.get_contents()) do
          if s.name ~= f.name and fuel_value(s.name) >= f.value then usable = false end
        end
        if usable then
          for _, s in pairs(inv.get_contents()) do
            if s.name ~= f.name then
              local moved = cinv.insert{name = s.name, count = s.count, quality = s.quality}
              if moved > 0 then inv.remove{name = s.name, count = moved, quality = s.quality} end
            end
          end
          usable = inv.can_insert{name = f.name, count = 1}
        end
      end
      if usable then
        local n = math.min(have, fuel.load_count(v, f))
        local inserted = inv.insert{name = f.name, count = n}
        if inserted > 0 then
          cinv.remove{name = f.name, count = inserted, quality = "normal"}
          say(data, string.format("Fuelled the %s with %d %s", v.name, inserted, f.name))
        end
      end
    end
  end
  return not M.low(v, far)
end

-- "ok" | "carried" | "chain" | "none" (+ a reason), see the header.
function M.fuel_state(data, v, far)
  if not M.low(v, far) then return "ok" end
  local player = owner(data)
  if not player then return "none", "no player" end

  local plan = fuel.plan(player, data, v)
  if not plan then
    return "none", "no fuel I can get (" .. fuel.explain(player, data, v) .. ")"
  end
  if plan.source == "carried" or plan.source == "partial" then return "carried" end

  -- the fuel is elsewhere: fetch it, put it into the vehicle, then carry on with the current task
  local original = data.task
  if not original then return "none", "no fuel on me and no task to come back to" end
  fuel.start(data, plan)
  local tail, n = data.task, 0
  while tail and tail.then_task and n < 30 do tail, n = tail.then_task, n + 1 end
  if tail and tail ~= original then tail.then_task = original end
  say(data, string.format("Getting %s for the %s", plan.item, v.name))
  return "chain"
end

---------------------------------------------------------------------
-- A vehicle to drive
---------------------------------------------------------------------

local function place(data, item)
  local c = data.entity
  local cinv = c.get_main_inventory()
  local spot = c.surface.find_non_colliding_position(item, c.position, 12, 1)
  if not spot then return nil end
  local ok, v = pcall(function()
    return c.surface.create_entity{name = item, position = spot, force = c.force, raise_built = true}
  end)
  if not (ok and v and v.valid) then return nil end
  cinv.remove{name = item, count = 1, quality = "normal"}
  return v
end

-- Returns: a vehicle (put down just now) | nil, "busy" (crafting / fetching the materials: carry on and try later)
--          | nil, nil, reason (it cannot get one)
function M.acquire(data, far)
  local c = data.entity
  local player = owner(data)
  if not player then return nil, nil, "no player" end
  if game.tick < (data.make_cd or 0) then return nil, nil, "I could not get one a moment ago" end
  local cinv = c.get_main_inventory()
  local force = c.force

  -- 1. one in the inventory
  for _, item in ipairs(M.CRAFTABLE) do
    if prototypes.entity[item] and cinv.get_item_count{name = item, quality = "normal"} > 0 then
      local v = place(data, item)
      if v then
        data.make_fetches = 0
        return v
      end
      return nil, nil, "there is no room to put a " .. item .. " down"
    end
  end

  -- 2. one is being crafted
  for _, item in ipairs(M.CRAFTABLE) do
    if (data.pending and data.pending[item] or 0) > 0 then return nil, "busy" end
  end

  -- 3. craft one: the first vehicle it has the recipe for
  local item
  for _, name in ipairs(M.CRAFTABLE) do
    local recipe = force.recipes[name]
    if prototypes.entity[name] and recipe and recipe.enabled then item = name break end
  end
  if not item then
    data.make_cd = game.tick + 3600
    return nil, nil, "no vehicle recipe is researched"
  end

  local result = planner.craft_for(player, data, item, 1, c.position)
  if result == "queued" then
    data.make_fetches = 0
    say(data, "Crafting a " .. item .. " for the long trip (" .. math.floor(far) .. " tiles)")
    return nil, "busy"
  elseif type(result) == "table" then
    -- materials are in a chest: fetch them, then come back to the current task (which asks again and queues the craft)
    data.make_fetches = (data.make_fetches or 0) + 1
    if data.make_fetches > M.MAX_FETCHES or not data.task then
      data.make_fetches = 0
      data.make_cd = game.tick + M.GIVE_UP_TICKS
      return nil, nil, "I could not gather the materials for a " .. item
    end
    result.then_task = data.task
    tasks.start(data, result)
    say(data, "Fetching materials for a " .. item .. " (long trip)")
    return nil, "busy"
  end
  data.make_cd = game.tick + 1800
  return nil, nil, "the materials for a " .. item .. " are not on me or in any chest"
end

vehicles.supplier = M

return M
