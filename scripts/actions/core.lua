-- Action core: registry + lifecycle helpers.
--
-- An ACTION is a high-level job started from the GUI (e.g. "deploy miners on the best patch").
-- It runs alongside the task system: the action drives movement / places ghosts, and the normal
-- auto-build tasks (fetch / craft / build) then work through those ghosts.
-- The active action lives in data.action = {id = "<id>", surface_index = n, ...own fields}.
--
-- To add a new action:
--   1. create scripts/actions/<name>.lua returning
--        { id = "...", caption = "...",
--          complex = true,                    -- optional: needs an assigned blueprint
--          prepare = function(player, data)   -- validate; return the action table, or nil, "error text"
--          step    = function(player, data, action)  -- every tick; return true if it used the
--                                                    -- companion's movement this tick
--          start_message = function(action) } -- optional chat message
--   2. add "<name>" to the BUILTIN list in scripts/actions.lua
-- Finish with cancel(data, "done ...") from inside step.

local names = require("scripts.names")
local blueprints = require("scripts.blueprints")

local M = {}

local defs, order = {}, {}

function M.register(def)
  assert(def.id and def.caption and def.prepare and def.step, "incomplete action definition")
  defs[def.id] = def
  order[#order + 1] = def.id
end

function M.get(id) return defs[id] end

-- Definitions in registration order (used to build the GUI).
function M.list()
  local out = {}
  for _, id in ipairs(order) do out[#out + 1] = defs[id] end
  return out
end

function M.cancel(data, text)
  data.action = nil
  data.action_status = text
end

-- Returns true while the action is using the companion's movement this tick.
function M.run(player, data)
  local a = data.action
  local def = defs[a.id]
  if not def then
    M.cancel(data, "cancelled (unknown action)")
    return false
  end
  if data.entity.surface.index ~= a.surface_index then
    M.cancel(data, "cancelled (different surface)")
    return false
  end
  return def.step(player, data, a) == true
end

function M.start(player, id)
  local def = defs[id]
  local data = storage.companions[player.index]
  if not (def and data and data.entity.valid) then
    player.print(names.prefix() .. "summon " .. names.get() .. " first.")
    return false
  end
  if def.complex and not blueprints.get(player.index, id) then
    player.print(names.prefix() .. "this action needs a blueprint. Hold one in your cursor and press 'Assign blueprint from cursor'.")
    return false
  end

  local action, err = def.prepare(player, data)
  if not action then
    if err then player.print(names.prefix() .. err) end
    return false
  end

  action.id = id
  action.surface_index = action.surface_index or data.entity.surface.index
  data.action = action
  data.task, data.roam = nil, nil
  data.action_status = "starting"
  storage.modes[player.index] = "auto_build" -- ghosts are only built in this mode
  if def.start_message then player.print(names.prefix() .. def.start_message(action)) end
  return true
end

return M
