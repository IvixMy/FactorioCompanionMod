-- Auto research: when the force's research queue is empty, the companion queues technologies by itself.
--
--   * Only runs when the queue is EMPTY (it never touches what the player queued).
--   * Candidates: technologies that are enabled, not researched, not trigger-based, and whose prerequisites are
--     all researched (or, when filling, already queued).
--   * Order: the cheapest first = fewest science pack TYPES, then the fewest packs in total
--     (research_unit_count * the packs per unit), then the name (so the order is stable).
--   * Mode (setting ec-auto-research):
--       "off"  does nothing
--       "one"  queues a single technology
--       "fill" keeps adding the cheapest one until the game refuses (queue full) or FILL_LIMIT is reached
--
-- Usage (from the companion's periodic update, e.g. every 60 ticks):
--     auto_research.update(player.force, settings.get_player_settings(player)["ec-auto-research"].value)

local M = {}

M.FILL_LIMIT = 10   -- most technologies queued in one go in "fill" mode
M.INTERVAL   = 60   -- ticks between two checks (used by M.due)

local last_check = {} -- [force index] = tick

-- true when it is time to look again for this force (throttle for the caller)
function M.due(force)
  local t = last_check[force.index]
  if t and game.tick - t < M.INTERVAL then return false end
  last_check[force.index] = game.tick
  return true
end

-- {types, packs} of a technology
local function cost(tech)
  local types, per_unit = 0, 0
  for _, ing in pairs(tech.research_unit_ingredients or {}) do
    types = types + 1
    per_unit = per_unit + (ing.amount or 1)
  end
  local units = tech.research_unit_count or 0
  return types, units * per_unit
end

local function usable(tech)
  if tech.researched or not tech.enabled then return false end
  local proto = tech.prototype
  if proto and proto.hidden then return false end
  if tech.research_trigger then return false end        -- researched by doing something, cannot be queued
  if (tech.research_unit_count or 0) <= 0 then return false end
  return true
end

local function available(tech, queued)
  for name, pre in pairs(tech.prerequisites or {}) do
    if not pre.researched and not queued[name] then return false end
  end
  return true
end

-- Sorted list (cheapest first) of the technologies that could be researched at all.
local function sorted_candidates(force)
  local list = {}
  for name, tech in pairs(force.technologies) do
    if usable(tech) then
      local types, packs = cost(tech)
      list[#list + 1] = {tech = tech, name = name, types = types, packs = packs}
    end
  end
  table.sort(list, function(a, b)
    if a.types ~= b.types then return a.types < b.types end
    if a.packs ~= b.packs then return a.packs < b.packs end
    return a.name < b.name
  end)
  return list
end

-- mode: "off" | "one" | "fill". Returns the names of the technologies queued (may be empty).
function M.update(force, mode)
  local queued_names = {}
  if not force or not force.valid or mode == nil or mode == "off" then return queued_names end
  if #force.research_queue > 0 then return queued_names end -- something is being researched: leave it

  local list = sorted_candidates(force)
  if #list == 0 then return queued_names end

  local limit = (mode == "fill") and M.FILL_LIMIT or 1
  local queued, rejected, fails = {}, {}, 0

  local progress = true
  while progress and #queued_names < limit do
    progress = false
    for _, c in ipairs(list) do
      if not queued[c.name] and not rejected[c.name] and available(c.tech, queued) then
        local ok, added = pcall(force.add_research, c.tech)
        if ok and added then
          queued[c.name] = true
          queued_names[#queued_names + 1] = c.name
          progress = true
        else
          rejected[c.name] = true
          fails = fails + 1
        end
        break -- start again from the cheapest: queuing one may have unlocked cheaper ones
      end
    end
    if fails >= 3 then break end -- the game keeps refusing (queue full / not allowed)
  end
  return queued_names
end

return M
