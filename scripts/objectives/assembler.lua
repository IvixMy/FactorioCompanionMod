-- Objective "assembler": once the assembling machine is unlocked, craft the first one.
--
-- The companion keeps it in its inventory (it is placed later by whatever needs it). The materials
-- (iron / copper plates) are collected from the furnaces when it doesn't carry them, then the
-- normal hand-crafting makes the machine. Crafts are reported to scripts/goals.lua as usual.
--
-- Params (playbook): item (default "assembling-machine-1"), count (default 1).

local zones    = require("scripts.zones")
local tasks    = require("scripts.tasks")
local supply   = require("scripts.supply")
local planner  = require("scripts.planner")
local lab      = require("scripts.objectives.lab")

local DEFAULT_ITEM = "assembling-machine-1"

return {
  id = "assembler",
  caption = "First assembling machine",
  implemented = true,

  step = function(ctx)
    local player, data = ctx.player, ctx.data
    local force = player.force
    ctx.surface = data.entity.surface
    local item = (ctx.params and ctx.params.item) or DEFAULT_ITEM
    local count = (ctx.params and ctx.params.count) or 1

    local recipe = force.recipes[item]
    if not recipe then return "satisfied", item .. " does not exist" end
    -- not unlocked yet: the research objective in front of this one is working on it
    if not recipe.enabled then return "satisfied", "waiting for the research that unlocks " .. item end

    local have = data.entity.get_main_inventory().get_item_count(item)
      + (supply.get(force, ctx.surface).totals[item] or 0)
    -- machines already standing count too (it may have been used already)
    if have < count then
      have = have + ctx.surface.count_entities_filtered{name = item, force = force, limit = count}
    end
    if have >= count then return "satisfied", string.format("%d x %s available", have, item) end

    local need = count - have
    local pending = (data.pending or {})[item] or 0
    if pending >= need then return "working", "crafting " .. item end
    if data.task then return "working", "busy: " .. (data.status or "task") end

    local r = planner.craft_for(player, data, item, need - pending, data.entity.position)
    if r == "queued" then return "working", "crafting " .. item end
    if type(r) == "table" then
      tasks.start(data, r)
      return "working", "fetching materials for " .. item
    end
    local status, note = lab.provide_materials(ctx, {[item] = need - pending})
    if status then return status, note end
    return "working", "waiting for the materials of " .. item
  end,
}
