-- Task "transfer": walk to a machine and move items in or out of it by hand.
--   fields: target (LuaEntity), mode ("insert" | "collect" | "take"), item, count,
--           slot (for insert: "fuel" | "source" | "lab" | "machine" | "chest")   -- collect always reads a furnace's output
--           take: removes up to `count` of the item from the machine's FUEL slot, leaving `keep`
--           then_task (optional): task started when this one is done (chains several machines)

local common = require("scripts.common")
local core   = require("scripts.tasks.core")

return {
  id = "transfer",

  describe = function(task)
    local name = task.target.valid and task.target.name or "a machine"
    if task.mode == "collect" then return "Collecting " .. task.item .. " from " .. name end
    if task.mode == "take" then return "Taking " .. task.item .. " from " .. name end
    return "Putting " .. task.item .. " into " .. name
  end,

  execute = function(player, data, task)
    local target = task.target
    local function done(text)
      if task.then_task then return core.chain(data, task.then_task) end
      return core.finish(data, text)
    end
    if not target.valid then return done() end
    if not common.walk_towards(data, target.position, common.BUILD_REACH) then return end

    local c = data.entity
    local cinv = c.get_main_inventory()

    if task.mode == "insert" and task.slot == "machine" then
      -- hand-feed an assembling machine: entity.insert puts ingredients into the right input slots
      local n = math.min(task.count, cinv.get_item_count(task.item))
      local inserted = 0
      if n > 0 then
        inserted = target.insert{name = task.item, count = n}
        if inserted > 0 then cinv.remove{name = task.item, count = inserted} end
      end
      if inserted == 0 and not task.then_task then
        return core.abort(data, "Could not put " .. task.item .. " into " .. target.name)
      end
      return done("Loaded " .. target.name)
    end

    if task.mode == "insert" then
      local inv
      if task.slot == "fuel" then
        inv = target.get_fuel_inventory()
      elseif task.slot == "lab" then
        inv = target.get_inventory(defines.inventory.lab_input)
      elseif task.slot == "chest" then
        inv = target.get_inventory(defines.inventory.chest)
      else
        inv = target.get_inventory(defines.inventory.furnace_source or defines.inventory.crafter_input)
      end
      local n = math.min(task.count, cinv.get_item_count(task.item))
      if inv and n > 0 and task.slot == "fuel" and not inv.can_insert{name = task.item, count = 1} then
        -- the slot holds a different fuel: take it out (it goes back to my inventory) to make room
        for _, s in pairs(inv.get_contents()) do
          if s.name ~= task.item then
            local moved = cinv.insert{name = s.name, count = s.count, quality = s.quality}
            if moved > 0 then inv.remove{name = s.name, count = moved, quality = s.quality} end
          end
        end
      end
      local inserted = 0
      if inv and n > 0 then
        inserted = inv.insert{name = task.item, count = n}
        if inserted > 0 then cinv.remove{name = task.item, count = inserted} end
      end
      if inserted == 0 and not task.then_task then
        -- nothing went in (no items left, or the slot is full): say so and try again shortly
        return core.abort(data, "Could not put " .. task.item .. " into " .. target.name)
      end
      return done("Loaded " .. target.name)
    end

    if task.mode == "take" then
      local inv = target.get_fuel_inventory()
      if inv then
        local n = math.min(task.count, inv.get_item_count(task.item) - (task.keep or 0))
        if n > 0 then
          local removed = inv.remove{name = task.item, count = n}
          local inserted = cinv.insert{name = task.item, count = removed}
          if inserted < removed then inv.insert{name = task.item, count = removed - inserted} end
        end
      end
      return done("Took " .. task.item .. " from " .. target.name)
    end

    local out = target.get_output_inventory()
    if out then
      local n = out.get_item_count(task.item)
      if n > 0 then
        local removed = out.remove{name = task.item, count = n}
        local inserted = cinv.insert{name = task.item, count = removed}
        if inserted < removed then
          c.surface.spill_item_stack{position = c.position, stack = {name = task.item, count = removed - inserted}, enable_looted = false}
        end
      end
    end
    done("Collected " .. task.item)
  end,
}
