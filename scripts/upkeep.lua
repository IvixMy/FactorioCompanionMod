-- Upkeep: keeps every burner building the companion has put in a zone supplied with fuel,
-- no matter which objective created it or whether that objective is "satisfied" already.
-- (Objectives only build things; this is what keeps them running.)
--
-- Other code can add more burner entities to look after - heaters, vehicles, anything with a
-- fuel slot - without touching this file:
--
--     upkeep.register_source(function(player, data) return {entity, entity, ...} end)
--
-- Called from the Progress controller before the objectives, on every evaluation.

local names = require("scripts.names")
local zones = require("scripts.zones")
local fuel  = require("scripts.fuel")
local supply = require("scripts.supply")

local M = {}

local HOLD_REFRESH = 180 -- the planner stays paused this long after the last "someone needs fuel" check

local sources = {}

-- Which zone family (purpose without the _N suffix) a burner entity belongs to; only for entities found
-- through the zone source. Used by the scope below.
local zone_of = setmetatable({}, {__mode = "k"})

function M.register_source(fn) sources[#sources + 1] = fn end

-- Built burner entities inside the player's zones (on the companion's surface).
M.register_source(function(player, data)
  local out = {}
  local surface_index = data.entity.surface.index
  for _, zone in ipairs(zones.all(player.index)) do
    if zone.surface_index == surface_index then
      for _, f in pairs(zones.index_entities(zone, player.force)) do
        if not f.ghost and f.entity.valid and fuel.is_burner(f.entity) then
          out[#out + 1] = f.entity
          zone_of[f.entity] = (zone.purpose:gsub("_%d+$", ""))
        end
      end
    end
  end
  return out
end)

local function all_entities(player, data)
  local list, seen = {}, {}
  for _, fn in ipairs(sources) do
    for _, e in ipairs(fn(player, data)) do
      if e.valid and not seen[e] then
        seen[e] = true
        list[#list + 1] = e
      end
    end
  end
  -- stable order whatever the sources returned
  table.sort(list, function(a, b) return (a.unit_number or 0) < (b.unit_number or 0) end)
  return list
end

-- True while the planner should not start new tasks (so a refuelling run can begin).
function M.holding(data)
  return data.upkeep_hold ~= nil and game.tick - data.upkeep_hold < HOLD_REFRESH
end

-- Running dry within this many seconds counts as CRITICAL: the Progress controller refuels these
-- even while objectives could carry on; everything else waits until the objectives have nothing
-- they can continue (see scripts/progress.lua).
M.CRITICAL_SECONDS = 20

-- All entities that need fuel, the one closest to running dry first.
local function needy(list)
  local out = {}
  for _, e in ipairs(list) do
    if e.valid and fuel.needs_fuel(e) then out[#out + 1] = e end
  end
  table.sort(out, function(a, b) return fuel.seconds_left(a) < fuel.seconds_left(b) end)
  return out
end

local RECHECK_CHESTS = 120 -- while blocked, re-read the chest contents at most this often (ticks)

-- opts.critical = true: only look after machines that are about to stop (see CRITICAL_SECONDS);
-- the others are left for later and the planner is not held up for them.
-- Returns nil when nothing needs fuel, else "working" | "blocked", note.
-- Walks down the list of needy machines and refuels the first one that CAN be supplied, so a
-- machine nobody can supply right now (no fuel anywhere) does not hold up the others.
-- data.upkeep_scope (set by the Progress controller from the focused objective's `upkeep_scope`): a list of zone
-- purposes. While it is set ONLY the burners of those zones are looked after, so the companion does not go
-- round every copper / stone cell while it should be getting iron to a factory.
local function in_scope(list, data)
  local scope = data.upkeep_scope
  if not scope then return list end
  local allowed = {}
  for _, purpose in ipairs(scope) do allowed[purpose] = true end
  local kept = {}
  for _, e in ipairs(list) do
    if allowed[zone_of[e] or ""] then kept[#kept + 1] = e end
  end
  return kept
end

function M.step(player, data, opts)
  local list = in_scope(needy(all_entities(player, data)), data)   -- everything that needs fuel (the refuel round tops up the group)
  local candidates = list
  if opts and opts.critical then
    candidates = {}
    for _, e in ipairs(list) do
      if fuel.seconds_left(e) < M.CRITICAL_SECONDS then candidates[#candidates + 1] = e end
    end
  end
  if #candidates == 0 then
    data.upkeep_hold = nil
    return nil
  end

  local entity, plan
  for _, e in ipairs(candidates) do
    plan = fuel.plan(player, data, e, {group = list})
    if plan then entity = e break end
  end

  if not plan then
    data.upkeep_hold = nil -- nothing to deliver: don't stall everything else
    -- chests may have been filled since the last look: refresh the index now and then
    if game.tick - (data.upkeep_recheck or 0) >= RECHECK_CHESTS then
      data.upkeep_recheck = game.tick
      supply.invalidate()
    end
    local note = string.format("%s needs fuel but I found none (%s)", candidates[1].name,
      fuel.explain(player, data, candidates[1]))
    -- also tell the player in chat now and then, so the reason is easy to read and report
    if note ~= data.upkeep_note or game.tick - (data.upkeep_note_tick or 0) > 1800 then
      data.upkeep_note, data.upkeep_note_tick = note, game.tick
      player.print(names.prefix() .. note)
    end
    return "blocked", note
  end

  if data.task then
    -- let the current task finish, but don't start another before refuelling
    data.upkeep_hold = game.tick
    return nil
  end

  data.upkeep_hold = nil
  return fuel.refuel(player, data, entity, {group = list})
end

return M
