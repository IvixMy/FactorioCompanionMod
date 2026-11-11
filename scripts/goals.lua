-- Goals: tells the game (and the Progress controller) when something the companion did counts.
--
-- Why: the companion hand-crafts, builds and mines through its own simulation, so the game never
-- sees "the player crafted a lab". Technologies that complete by a TRIGGER (craft X, build Y, mine Z)
-- then stay unresearched for ever and everything behind them is soft-locked.
--
-- How it works (all modular):
--   * A GOAL is {key, kind, name, count, label, complete = function(force), satisfied = function(force, data)}
--       kind: "craft" | "build" | "mine" | "obtain"       (what has to happen to which item / entity)
--       complete:  what to do once it is met (e.g. mark a technology as researched)
--       satisfied: optional extra check of the CURRENT state of the world (default: see below)
--   * SOURCES produce the goals that matter right now:  goals.register_source(function(force) return {goal, ...} end)
--     The built-in source lists every technology that is researched by a trigger and whose
--     prerequisites are done. Add your own source for anything else (an objective, a milestone...).
--   * EVENTS report what the companion does:  goals.notify(force, kind, name, count)
--     Hooked into: scripts/crafting.lua (finished crafts), scripts/tasks/build.lua and control.lua
--     (ghosts built), scripts/tasks/mine.lua (mined resources / trees).
--   * goals.check(player, data) (called by the Progress controller every evaluation) also looks at the
--     world: what the companion carries / the chests hold, and which entities stand, so goals that were
--     met BEFORE this system existed (old saves) or by other means are completed too.
--
-- Default state check by kind:
--   obtain : carried + chest count of the item >= count
--   craft  : same, or (for an item that places an entity) that many such entities stand
--   build  : that many entities of that name stand
--   mine   : events only

local names = require("scripts.names")
local supply = require("scripts.supply")

local M = {}

local sources = {}
local cache = {} -- [force.index] = {tick, list}

function M.register_source(fn) sources[#sources + 1] = fn end

local function counts()
  storage.goal_counts = storage.goal_counts or {}
  return storage.goal_counts
end

local function name_of(v)
  if type(v) == "table" then return v.name end
  return v
end

local function try(obj, key)
  local ok, v = pcall(function() return obj[key] end)
  if ok then return v end
  return nil
end

---------------------------------------------------------------------
-- State checks
---------------------------------------------------------------------

local function carried_and_stored(force, data, item)
  local n = 0
  if data and data.entity and data.entity.valid then
    n = n + data.entity.get_main_inventory().get_item_count(item)
    n = n + (supply.get(force, data.entity.surface).totals[item] or 0)
  end
  return n
end

local function entities_standing(force, name, need)
  local total = 0
  for _, surface in pairs(game.surfaces) do
    total = total + surface.count_entities_filtered{name = name, force = force, limit = need}
    if total >= need then return total end
  end
  return total
end

local function default_satisfied(g, force, data)
  if g.kind == "obtain" then
    return carried_and_stored(force, data, g.name) >= g.count
  elseif g.kind == "craft" then
    if carried_and_stored(force, data, g.name) >= g.count then return true end
    local proto = prototypes.item[g.name]
    local place = proto and try(proto, "place_result")
    return place ~= nil and entities_standing(force, place.name, g.count) >= g.count
  elseif g.kind == "build" then
    return entities_standing(force, g.name, g.count) >= g.count
  end
  return false
end

---------------------------------------------------------------------
-- Built-in source: technologies completed by a research trigger
---------------------------------------------------------------------

local TRIGGER_KINDS = {
  ["craft-item"] = {kind = "craft", field = "item"},
  ["build-entity"] = {kind = "build", field = "entity"},
  ["mine-entity"] = {kind = "mine", field = "entity"},
}

M.register_source(function(force)
  local out = {}
  for _, tech in pairs(force.technologies) do
    if tech.enabled and not tech.researched then
      local trigger = try(tech.prototype, "research_trigger")
      local map = trigger and TRIGGER_KINDS[trigger.type]
      if map then
        local ready = true
        for _, pre in pairs(tech.prerequisites) do
          if not pre.researched then ready = false break end
        end
        local name = name_of(trigger[map.field])
        if ready and name then
          local tech_name = tech.name
          out[#out + 1] = {
            key = "tech:" .. tech_name, kind = map.kind, name = name, count = trigger.count or 1,
            label = string.format("%s (%s %s)", tech_name, map.kind, name),
            complete = function(f)
              local t = f.technologies[tech_name]
              if t and not t.researched then
                local ok = pcall(function() t.researched = true end)
                return ok
              end
              return true
            end,
          }
        end
      end
    end
  end
  return out
end)

---------------------------------------------------------------------
-- Pending goals / completion
---------------------------------------------------------------------

local CACHE_TICKS = 60

function M.pending(force)
  local c = cache[force.index]
  if c and game.tick - c.tick < CACHE_TICKS then return c.list end
  local list = {}
  for _, fn in ipairs(sources) do
    for _, g in ipairs(fn(force) or {}) do list[#list + 1] = g end
  end
  cache[force.index] = {tick = game.tick, list = list}
  return list
end

local function complete(force, g)
  local ok = g.complete and g.complete(force)
  if ok == false then return false end
  counts()[g.key] = nil
  cache[force.index] = nil -- the list changes (new techs may become ready)
  force.print("[" .. names.get() .. "] goal met: " .. (g.label or g.key))
  return true
end

-- Something happened. kind: "craft" | "build" | "mine" | "obtain".
function M.notify(force, kind, name, count)
  if not (force and force.valid and name) then return end
  count = count or 1
  for _, g in ipairs(M.pending(force)) do
    if g.kind == kind and g.name == name then
      local c = counts()
      c[g.key] = (c[g.key] or 0) + count
      if c[g.key] >= g.count then complete(force, g) end
    end
  end
end

-- Look at the world as well (carried items, chests, standing entities). Cheap: once per evaluation.
function M.check(player, data)
  local force = player.force
  for _, g in ipairs(M.pending(force)) do
    local met = (counts()[g.key] or 0) >= g.count
    if not met then
      local fn = g.satisfied or function(f, d) return default_satisfied(g, f, d) end
      met = fn(force, data) == true
    end
    if met then complete(force, g) end
  end
end

return M
