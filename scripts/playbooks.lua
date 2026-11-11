-- Playbooks: what the companion should have in place at each point of the technology tree.
--
-- STAGES are ordered. A stage is "active" until `until_tech` has been researched. Objectives of
-- the active stage AND of every earlier stage apply (later stages override parameters, e.g.
-- raise the power goal). Objectives with no implementation yet are listed so the plan is visible;
-- the Progress action skips them until they are written (scripts/objectives/<id>.lua).

local research = require("scripts.research")

local M = {}

M.STAGES = {
  {
    id = "bootstrap", until_tech = "automation",
    objectives = {
      {id = "iron_start", plates = 50, cells = 4}, -- from zero: grows burner drill -> furnace cells until 50 plates
      {id = "coal_drills", coal_pairs = 1}, -- automatic coal: two burner drills facing each other
      {id = "power", goal_kw = 60},     -- then steam power, enough to start
      {id = "copper_start", cells = 2, plates = 50}, -- once the steam engine stands: the iron setup again, on copper...
      {id = "stone_start", cells = 2},  -- ...and burner drills feeding chests with stone
      {id = "mining"}, {id = "smelting"}, {id = "science", labs = 1}, -- a lab next to the engines, wired with poles
      {id = "research_packs", tech = "automation"}, -- hand-craft the red science for the assembler and feed the lab
      {id = "assembler", item = "assembling-machine-1", count = 1}, -- then craft the first assembling machine
    },
  },
  {
    id = "red-green", until_tech = "logistic-science-pack",
    objectives = {
      {id = "power", goal_kw = 600}, {id = "mining"}, {id = "smelting"}, {id = "science"},
      -- 3 assemblers making red science, connected to the power plant, fed by hand for now
      {id = "science_factory", assemblers = 3, pack = "automation-science-pack"},
      -- the rate calculator sizes the labs to what the factory makes: the lab zone grows (a feed chest, then
      -- labs chained one tile apart with an inserter between them) instead of a new zone being created
      {id = "lab_expansion", max_labs = 8, after_tech = "logistics"},
      -- the lab takes its red science from the factory; "logistics" is researched before anything else
      -- (research.PRIORITY, so before steel-processing) because it unlocks the belt assembler below
      {id = "research_packs_2", tech = "logistics"},
      {id = "belt_factory", tech = "logistics"}, -- gear + belt assembler, iron plates by hand until the line below stands
      -- belt line from the iron furnaces to the assemblers (inserters at both ends): no more carrying plates
      {id = "factory_supply", factory = "belt_factory", item = "iron-plate", source = "iron_start"},
      -- zones that exist ONLY when the player assigns a blueprint to them (menu "Assign blueprints"); skipped otherwise
      {id = "green_science_factory", pack = "logistic-science-pack"},
    },
  },
  {
    id = "oil-age", until_tech = "chemical-science-pack",
    objectives = {{id = "power", goal_kw = 3000}, {id = "defense"}},
  },
  {
    id = "launch", until_tech = "rocket-silo",
    objectives = {{id = "power", goal_kw = 20000}, {id = "defense"}},
  },
}

-- Returns the active stage (or nil when every stage is done) and the merged, ordered
-- objective list {{id = ..., goal_kw = ...}, ...}.
function M.current(force)
  local merged, order = {}, {}
  local active
  for _, stage in ipairs(M.STAGES) do
    for _, o in ipairs(stage.objectives) do
      if not merged[o.id] then
        merged[o.id] = {}
        order[#order + 1] = o.id
      end
      for k, v in pairs(o) do merged[o.id][k] = v end
    end
    if not research.is_researched(force, stage.until_tech) then
      active = stage
      break
    end
  end
  local list = {}
  for _, id in ipairs(order) do list[#list + 1] = merged[id] end
  return active, list
end

return M
