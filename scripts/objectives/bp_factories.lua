-- Factory zones that have NO built-in layout: they are built from a blueprint the player assigns in the menu
-- ("Assign blueprints"), and skipped while none is assigned. Planning, power line, auto-build and hand-feeding
-- are the same as for the other factories (scripts/objectives/factory_base.lua, "blueprint zones").
--
-- To add another one:
--   1. add a row to the table below (id = the objective id = the zone purpose = the slot id);
--   2. add the same id to SLOTS in scripts/bpslots.lua (so it shows up in the menu);
--   3. add {id = "<id>", ...} to a stage of scripts/playbooks.lua.
--
-- Fields: id, caption, recipe (the item it is meant to make: the objective waits until that recipe is
-- unlocked; use nil to build as soon as there is power), spacing (tiles kept free around it), stock (crafts of
-- every hand-fed ingredient kept in each machine).

local base = require("scripts.objectives.factory_base")

local FACTORIES = {
  {id = "green_science_factory", caption = "Green science factory", recipe = "logistic-science-pack", spacing = 100, stock = 20},
}

local out = {}
for _, f in ipairs(FACTORIES) do
  out[#out + 1] = base.new({
    id = f.id,
    caption = f.caption,
    purpose = f.id,
    slot = f.id,
    blueprint_only = true,
    default_stock = f.stock or 20,
    spacing = f.spacing or 100,

    gate = function(ctx, params)
      local recipe_name = params.pack or f.recipe
      if not recipe_name then return nil end
      local recipe = ctx.player.force.recipes[recipe_name]
      if not recipe then return "satisfied", recipe_name .. " does not exist" end
      if not recipe.enabled then return "satisfied", "waiting for the research that unlocks " .. recipe_name end
      return nil
    end,

    -- the pack this factory makes: other objectives look for zones by `zone.pack`
    zone_extra = function(ctx, params) return {pack = params.pack or f.recipe} end,
  })
end
return out
