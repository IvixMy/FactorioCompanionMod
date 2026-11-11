-- Objective "research_packs": research a technology by hand-feeding the lab.
--
--   1. puts the technology (default "automation" = the assembling machine) first in the research queue,
--   2. works out how many science packs are still needed (units left x pack amounts), minus what the
--      labs already hold,
--   3. crafts the missing packs (the companion's own hand-crafting; the plates are collected from the
--      furnaces when it doesn't carry them),
--   4. carries them to the lab and puts them into its input slots.
--
-- Satisfied once every needed pack sits in the labs (or the technology is researched), so the
-- other objectives and the refuelling can carry on while the lab works.
--
-- Once the lab zone has a feed chest (objective lab_expansion), the packs are put into that chest instead
-- of a lab: it can hold lots of them and the inserters decide which lab gets them. The feed chest is never
-- used as a source of packs.
--
-- Packs made by the science factory (scripts/objectives/science_factory.lua) are used first: when a
-- chest holds the pack it is fetched and carried to the lab. While a factory that makes this pack
-- stands, the companion waits for it instead of hand-crafting.
--
-- Params (playbook): tech (default "automation"). The same objective is registered a second time as
-- "research_packs_2" so a later playbook stage can research another technology further down the list.

local common   = require("scripts.common")
local zones    = require("scripts.zones")
local tasks    = require("scripts.tasks")
local planner  = require("scripts.planner")
local lab      = require("scripts.objectives.lab")
local supply   = require("scripts.supply")

local DEFAULT_TECH = "automation"

-- Built labs standing in the companion's science zones.
local function built_labs(ctx)
  local out = {}
  for _, zone in ipairs(zones.list(ctx.player.index, "science")) do
    for _, f in pairs(zones.index_entities(zone, ctx.player.force)) do
      if not f.ghost and f.entity.valid and f.entity.name == "lab" then out[#out + 1] = f.entity end
    end
  end
  return out
end

-- Built feed chests of the lab zones (objective lab_expansion): the companion drops the packs there
-- and an inserter feeds the first lab. -> list, set of their unit numbers
local function feed_chests(ctx)
  local list, set = {}, {}
  for _, zone in ipairs(zones.list(ctx.player.index, "science")) do
    local found
    for _, e in ipairs(zone.entries or {}) do
      if e.role == "lab_feed" then
        found = found or zones.index_entities(zone, ctx.player.force)
        local f = found[zones.key(e.name, {x = e.x, y = e.y})]
        if f and not f.ghost and f.entity.valid then
          list[#list + 1] = f.entity
          set[f.entity.unit_number] = true
        end
      end
    end
  end
  return list, set
end

local function chest_packs(chest, item)
  return chest.get_item_count(item)
end

local function lab_packs(l, item)
  local inv = l.get_inventory(defines.inventory.lab_input)
  return inv and inv.get_item_count(item) or 0
end

-- Progress (0..1) of a technology. It lives on the FORCE, not on the technology: the current
-- research has force.research_progress, any other one has a saved value.
local function progress_of(force, tech)
  local current = force.current_research
  if current and current.name == tech.name then
    local ok, v = pcall(function() return force.research_progress end)
    if ok and type(v) == "number" then return v end
  end
  local ok, v = pcall(function() return force.get_saved_technology_progress(tech) end)
  if ok and type(v) == "number" then return v end
  return 0
end

-- Does a built science factory of the companion make this pack?
local function factory_makes(ctx, pack)
  local force = ctx.player.force
  for _, zone in ipairs(zones.list(ctx.player.index, "science_factory")) do
    if zone.pack == pack and zones.progress(zone, force) > 0 then return true end
  end
  return false
end

-- Where carried packs go: the feed chest when the lab zone has one (an inserter hands the packs to the
-- first lab, which passes them on), else the lab holding the fewest. -> entity, slot
local function lab_target(labs, feeds, pack)
  if feeds[1] then return feeds[1], "chest" end
  local target, least
  for _, l in ipairs(labs) do
    local n = lab_packs(l, pack)
    if not least or n < least then target, least = l, n end
  end
  return target, "lab"
end

-- Make `tech` the research in progress (first in the queue).
local function focus_research(force, tech)
  local current = force.current_research
  if current and current.name == tech.name then return end
  local ok = pcall(function() force.research_queue = {tech} end)
  if not ok then pcall(function() force.add_research(tech) end) end
end

local def = {
  id = "research_packs",
  caption = "Hand-fed research",
  implemented = true,
  background = true, -- looked at before the other objectives (see scripts/progress.lua): the labs must never starve

  step = function(ctx)
    local player, data = ctx.player, ctx.data
    local force = player.force
    ctx.surface = data.entity.surface
    local name = (ctx.params and ctx.params.tech) or DEFAULT_TECH

    local tech = force.technologies[name]
    if not tech then return "satisfied", "technology '" .. name .. "' does not exist" end
    if tech.researched then return "satisfied", name .. " is researched" end

    local labs = built_labs(ctx)
    if #labs == 0 then return "blocked", "no lab built yet to research " .. name end

    for _, pre in pairs(tech.prerequisites) do
      if not pre.researched then return "working", name .. " waits for the technology '" .. pre.name .. "'" end
    end

    focus_research(force, tech)

    local feeds, feed_set = feed_chests(ctx)

    -- packs still needed: units left x amount per unit
    local units_left = math.max(1, math.ceil((tech.research_unit_count or 1) * (1 - progress_of(force, tech))))
    local cinv = data.entity.get_main_inventory()
    local missing_total = 0
    for _, ing in pairs(tech.research_unit_ingredients) do
      local pack = ing.name
      local needed = units_left * (ing.amount or 1)
      local in_labs = 0
      for _, l in ipairs(labs) do in_labs = in_labs + lab_packs(l, pack) end
      for _, c in ipairs(feeds) do in_labs = in_labs + chest_packs(c, pack) end -- waiting in the feed chest
      local missing = needed - in_labs
      if missing > 0 then
        missing_total = missing_total + missing
        if data.task then return "working", "busy: " .. (data.status or "task") end

        local carried = cinv.get_item_count(pack)
        local pending = (data.pending or {})[pack] or 0

        -- deliver what the companion carries (as soon as it has enough, or nothing more is on the way)
        if carried > 0 and (carried >= missing or pending == 0) then
          local target, slot = lab_target(labs, feeds, pack)
          tasks.start(data, tasks.new("transfer", {
            target = target, mode = "insert", slot = slot, item = pack,
            count = math.min(carried, missing),
          }))
          return "working", string.format("putting %s into the %s (%d missing)", pack,
            slot == "chest" and "lab feed chest" or "lab", missing)
        end

        -- packs made by the science factory: from its chests to the lab
        if carried < missing then
          local chest = supply.find_chest(force, ctx.surface, pack, "normal", missing - carried, data.entity.position, feed_set)
          if chest then
            local target, slot = lab_target(labs, feeds, pack)
            tasks.start(data, tasks.new("fetch", {
              chest = chest, item = pack, quality = "normal", count = missing - carried,
              fetch = 1, fetch_max = missing - carried, purpose = "the lab",
              then_task = tasks.new("transfer", {
                target = target, mode = "insert", slot = slot, item = pack, count = missing,
              }),
            }))
            return "working", string.format("fetching %s from the science factory (%d missing)", pack, missing)
          end
          if factory_makes(ctx, pack) and carried + pending == 0 then
            return "blocked", string.format("waiting for the science factory to make %s (%d missing)", pack, missing)
          end
        end

        -- otherwise make them
        local to_craft = missing - carried - pending
        if to_craft > 0 then
          local r = planner.craft_for(player, data, pack, to_craft, data.entity.position)
          if r == "queued" then return "working", string.format("crafting %d x %s", to_craft, pack) end
          if type(r) == "table" then
            tasks.start(data, r)
            return "working", "fetching materials for " .. pack
          end
          local status, note = lab.provide_materials(ctx, {[pack] = to_craft})
          if status then return status, note end
          return "working", "waiting for the materials of " .. pack
        end
        return "working", string.format("crafting %s (%d missing)", pack, missing)
      end
    end

    return "satisfied", string.format("%s: all science packs are in the lab (%d%% done)",
      name, math.floor(progress_of(force, tech) * 100))
  end,
}

local def2 = {}
for k, v in pairs(def) do def2[k] = v end
def2.id = "research_packs_2"
def2.caption = "Hand-fed research (factory packs)"

return {def, def2}
