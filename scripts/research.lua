-- Reads the technology tree to measure how far the game has progressed.
--
-- The end goal is a technology (default: "rocket-silo"). Every technology it depends on,
-- directly or not, is part of the "path". Progress = researched / total on that path, and the
-- next technology to research is the cheapest unresearched one whose prerequisites are done.

local common = require("scripts.common")

local M = {}

M.TARGET = "rocket-silo"

-- Technologies that jump the queue: when one of these is ready it is researched BEFORE the cheapest
-- one (first entry wins). "logistics" unlocks the belt factory (scripts/objectives/belt_factory.lua),
-- so it comes before everything else, e.g. steel-processing.
M.PRIORITY = {"logistics"}

local path_cache -- {names = {tech name -> true}, list = {names}} (prototypes never change at runtime)

local function build_path(target)
  local names, list = {}, {}
  local function visit(name)
    if names[name] then return end
    local proto = prototypes.technology[name]
    if not proto then return end
    names[name] = true
    list[#list + 1] = name
    for pre_name in pairs(proto.prerequisites) do visit(pre_name) end
  end
  visit(target)
  return {names = names, list = list}
end

local function path()
  if not path_cache then path_cache = build_path(M.TARGET) end
  return path_cache
end

-- Technologies completed by a trigger (craft X, build Y) instead of laboratories.
local function is_trigger_tech(tech)
  return common.try_get(tech.prototype, "research_trigger") ~= nil
end

local function cost(tech)
  local packs = #tech.research_unit_ingredients
  return (tech.research_unit_count or 1) * math.max(1, packs)
end

-- The first PRIORITY technology that can be researched now (any technology of the game: it does not have to be
-- on the path to the target). nil when there is none.
function M.priority_tech(force)
  for _, name in ipairs(M.PRIORITY) do
    local tech = force.technologies[name]
    if tech and tech.enabled and not tech.researched then
      local ready = true
      for _, pre in pairs(tech.prerequisites) do
        if not pre.researched then ready = false break end
      end
      if ready then return tech end
    end
  end
  return nil
end

-- Make `tech` the research in progress (first in the queue).
function M.focus(force, tech)
  local current = force.current_research
  if current and current.name == tech.name then return end
  local ok = pcall(function() force.research_queue = {tech} end)
  if not ok then pcall(function() force.add_research(tech) end) end
end

-- Returns {target, done, total, pct, next (LuaTechnology|nil), trigger (LuaTechnology|nil), finished}
function M.progress(force)
  local p = path()
  local result = {target = M.TARGET, done = 0, total = #p.list, pct = 0}
  if result.total == 0 then
    result.missing_target = true
    return result
  end

  local best, best_cost, trigger
  local ready_by_name = {}
  for _, name in ipairs(p.list) do
    local tech = force.technologies[name]
    if tech then
      if tech.researched then
        result.done = result.done + 1
      elseif tech.enabled then
        local ready = true
        for _, pre in pairs(tech.prerequisites) do
          if not pre.researched then ready = false break end
        end
        if ready then
          if is_trigger_tech(tech) then
            trigger = trigger or tech
          else
            ready_by_name[tech.name] = tech
            local c = cost(tech)
            if not best or c < best_cost or (c == best_cost and tech.name < best.name) then
              best, best_cost = tech, c
            end
          end
        end
      end
    end
  end

  local priority = M.priority_tech(force)
  if priority and not is_trigger_tech(priority) then best = priority end

  result.pct = math.floor(100 * result.done / result.total)
  result.next, result.trigger = best, trigger
  local target_tech = force.technologies[M.TARGET]
  result.finished = target_tech and target_tech.researched or false
  return result
end

function M.is_researched(force, name)
  local tech = force.technologies[name]
  return tech == nil or tech.researched -- unknown techs (other modpacks) never block a stage
end

-- Put `tech` on the research queue if nothing is being researched. Returns true if queued.
function M.queue_if_idle(force, tech)
  if not tech or #force.research_queue > 0 then return false end
  return force.add_research(tech) == true
end

return M
