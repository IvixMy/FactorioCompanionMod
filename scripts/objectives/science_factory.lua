-- Objective "science_factory": a small factory that makes automation science (red science packs).
-- Planning, power chain and hand-feeding live in scripts/objectives/factory_base.lua.
--
--   [gear] [pole] [gear] [pole] [gear]        gear wheel assemblers (iron plates put in BY HAND)
--     |             |             |
--   [ins]         [ins]         [ins]         gear wheels go straight into the science machines
--     |             |             |
--   [sci ] [pole] [sci ] [pole] [sci ]        3 assembling machines set to "automation-science-pack"
--     |             |             |             (copper plates put in BY HAND)
--   [ins]         [ins]         [ins]
--     |             |             |
--   [chest]       [chest]       [chest]       CHEST MODE (no transport belts in stock): own chest each
--
--   ...and in BELT MODE (enough transport belts in stock when the factory is planned) the three
--   output inserters drop on one belt that ends in an inserter + chest.
--
-- Only copper plates (and the iron for the gear assemblers) are fed by hand; set the playbook param
-- `gear_assemblers = false` to go back to feeding gear wheels by hand as well.
--
-- Params (playbook): assemblers (default 3), pack (default "automation-science-pack"),
--   gear_assemblers (default true), stock (crafts kept in every machine, default 20),
--   belts_needed (belts in stock that switch on belt mode; default: the belt line length).

local base     = require("scripts.objectives.factory_base")
local supply   = require("scripts.supply")

local ASSEMBLER = "assembling-machine-1"
local INSERTER = "inserter"
local BELT = "transport-belt"
local GEAR = "iron-gear-wheel"
local DEFAULT_PACK = "automation-science-pack"
local DEFAULT_COUNT = 3

local DIR = defines.direction

local function belts_in_template(n) return 4 * (n - 1) + 1 end

return base.new({
  id = "science_factory",
  caption = "Automation science factory",
  purpose = "science_factory",
  default_stock = 20,

  gate = function(ctx, params)
    local force = ctx.player.force
    local arecipe = force.recipes[ASSEMBLER]
    if not (arecipe and arecipe.enabled) then return "satisfied", "waiting for the research that unlocks " .. ASSEMBLER end
    local pack = params.pack or DEFAULT_PACK
    local precipe = force.recipes[pack]
    if not precipe then return "satisfied", pack .. " does not exist" end
    if not precipe.enabled then return "satisfied", pack .. " is not available yet" end
    return nil
  end,

  -- belt mode only when the belts for the whole line are at hand
  choose_mode = function(ctx, params)
    local n = params.assemblers or DEFAULT_COUNT
    local belts = ctx.data.entity.get_main_inventory().get_item_count(BELT)
      + (supply.get(ctx.player.force, ctx.surface).totals[BELT] or 0)
    return belts >= (params.belts_needed or belts_in_template(n)) and "belt" or "chest"
  end,

  zone_extra = function(ctx, params) return {pack = params.pack or DEFAULT_PACK} end,

  -- a factory planned by version 0.10.0 (3 science machines, no gear assemblers, everything by hand)
  legacy = function(ctx, params)
    local pack = params.pack or DEFAULT_PACK
    return pack, base.hand_items(ctx.player.force, pack)
  end,

  template = function(ctx, params, mode)
    local force = ctx.player.force
    local n = params.assemblers or DEFAULT_COUNT
    local pack = params.pack or DEFAULT_PACK
    local gears = params.gear_assemblers ~= false and force.recipes[GEAR] ~= nil and force.recipes[GEAR].enabled
    local last = -2 + 4 * (n - 1)

    local pack_hand = base.hand_items(force, pack, gears and {[GEAR] = true} or nil)
    local gear_hand = base.hand_items(force, GEAR)

    local tpl = base.new_template()
    for i = 0, n - 1 do
      tpl.add(ASSEMBLER, -2 + 4 * i, 0, DIR.north, false, {recipe = pack, hand = pack_hand})
    end
    for j = 0, math.max(0, n - 2) do tpl.add("pole", 4 * j, 0) end

    -- output side (+y): one inserter per machine, then a chest each or a shared belt
    for i = 0, n - 1 do
      local x = -2 + 4 * i
      tpl.add(INSERTER, x, 2, DIR.north, true, {drop = {x = x, y = 3}})
      if mode == "chest" then tpl.add("chest", x, 3) end
    end
    if mode == "belt" then
      for x = -2, last do tpl.add(BELT, x, 3, DIR.east, true) end
      tpl.add(INSERTER, last + 1, 3, DIR.west, true, {drop = {x = last + 2, y = 3}}) -- belt end -> chest
      tpl.add("chest", last + 2, 3)
      tpl.add("pole", last + 1, 2)                                                     -- powers that inserter
    end

    -- input side (-y): a gear wheel assembler above every science machine
    if gears then
      for i = 0, n - 1 do
        local x = -2 + 4 * i
        tpl.add(ASSEMBLER, x, -4, DIR.north, false, {recipe = GEAR, hand = gear_hand})
        tpl.add(INSERTER, x, -2, DIR.north, true, {drop = {x = x, y = -1}})
      end
      for j = 0, math.max(0, n - 2) do tpl.add("pole", 4 * j, -3) end
    end
    return tpl
  end,

  output_note = function(chests)
    local n = 0
    for _, c in ipairs(chests) do
      if c.valid then n = n + c.get_item_count(DEFAULT_PACK) end
    end
    return string.format("%d x %s waiting in the output", n, DEFAULT_PACK)
  end,
})
