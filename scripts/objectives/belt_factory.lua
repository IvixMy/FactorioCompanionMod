-- Objective "belt_factory": an automatic transport belt assembler, planned once the belt research
-- (technology "logistics") is done. Planning, power chain and hand-feeding: factory_base.lua.
--
--   [gear asm] [ins] [belt asm]     the gear assembler feeds the belt assembler directly
--        \      |      /           (iron plates for BOTH are put in by hand, for now)
--              [pole]
--                         [ins]
--                         [chest]   finished belts end up here (other plans count them as belt stock)
--
-- Params (playbook): tech (default "logistics"), spacing (tiles between factories, default 100), stock (crafts kept in every machine, default 30).

local base = require("scripts.objectives.factory_base")

local ASSEMBLER = "assembling-machine-1"
local INSERTER = "inserter"
local BELT = "transport-belt"
local GEAR = "iron-gear-wheel"
local DEFAULT_TECH = "logistics"

local DIR = defines.direction

return base.new({
  id = "belt_factory",
  caption = "Transport belt factory",
  purpose = "belt_factory",
  default_stock = 30,
  -- while the belt factory needs iron only the burners that make iron (and the power plant) are refuelled
  upkeep_scope = {"iron_start", "coal", "power"},
  output_slots = 4, -- 400 belts in the chest, then the assemblers wait

  -- from here on the base spreads out: 100 tiles of free space between the factories (playbook param
  -- `spacing` changes it), so later factories and extensions have room. The power line is as long as needed.
  spacing = 100,

  gate = function(ctx, params)
    local force = ctx.player.force
    local tech = force.technologies[params.tech or DEFAULT_TECH]
    if tech and not tech.researched then return "satisfied", "waiting for the research of " .. tech.name end
    local arecipe = force.recipes[ASSEMBLER]
    if not (arecipe and arecipe.enabled) then return "satisfied", "waiting for the research that unlocks " .. ASSEMBLER end
    local brecipe = force.recipes[BELT]
    if not (brecipe and brecipe.enabled) then return "satisfied", BELT .. " is not available yet" end
    return nil
  end,

  template = function(ctx, params)
    local force = ctx.player.force
    local belt_hand = base.hand_items(force, BELT, {[GEAR] = true})
    local gear_hand = base.hand_items(force, GEAR)

    local tpl = base.new_template()
    tpl.add("pole", 0, 0)
    tpl.add(ASSEMBLER, -2, -2, DIR.north, false, {recipe = GEAR, hand = gear_hand})
    tpl.add(ASSEMBLER, 2, -2, DIR.north, false, {recipe = BELT, hand = belt_hand})
    -- gear assembler (west) -> belt assembler (east); the inserter's direction is its PICK-UP side
    tpl.add(INSERTER, 0, -2, DIR.west, true, {drop = {x = 1, y = -2}})
    -- belt assembler -> chest on the output side (+y)
    tpl.add(INSERTER, 2, 0, DIR.north, true, {drop = {x = 2, y = 1}})
    tpl.add("chest", 2, 1)
    return tpl
  end,

  output_note = function(chests)
    local n = 0
    for _, c in ipairs(chests) do
      if c.valid then n = n + c.get_item_count(BELT) end
    end
    return string.format("%d x %s in the output chest", n, BELT)
  end,
})
