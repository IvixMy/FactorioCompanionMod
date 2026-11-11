-- Task core: registry + lifecycle helpers.
--
-- A TASK is one low-level step the companion executes while in auto-build mode
-- (fetch items from a chest, build a ghost, ...). Exactly one task is active at a time,
-- stored in data.task as a plain table {type = "<id>", expires = tick, ...fields}.
--
-- To add a new task type:
--   1. create scripts/tasks/<name>.lua returning
--        { id = "...",
--          execute  = function(player, data, task) ... end,   -- called every tick while active
--          describe = function(task) return "status text" end -- optional }
--   2. add "<name>" to the BUILTIN list in scripts/tasks.lua
--   3. have the planner (or an action) create it with tasks.new("<id>", {...}) and start it
--      with tasks.start(data, task).
-- Inside execute, finish the task with one of: finish(), abort(), chain().

local ghost_mark = require("scripts.ghost_mark")

local M = {}

local defs = {}
local DEFAULT_TIMEOUT = 60 * 60 * 3

function M.register(def)
  assert(def.id and def.execute, "a task definition needs an id and an execute function")
  defs[def.id] = def
end

function M.get(id) return defs[id] end

-- Create a task table (does not start it).
function M.new(id, fields)
  local def = assert(defs[id], "unknown task type: " .. tostring(id))
  fields = fields or {}
  fields.type = id
  fields.expires = game.tick + (def.timeout or DEFAULT_TIMEOUT)
  return fields
end

function M.describe(task)
  local def = defs[task.type]
  if def and def.describe then return def.describe(task) end
  return tostring(task.type or "?")
end

-- scripts/demand.lua registers itself here when control.lua loads it (require is not allowed at runtime)
M.mine_batcher = nil

-- Make `task` the active one and update the status line.
function M.start(data, task)
  -- a mine task also covers what the zones are missing of the same material (scripts/demand.lua)
  if task.type == "mine" and not task.no_batch and not task.then_task and not task.near then
    local ok, target = false, nil
    if M.mine_batcher then ok, target = pcall(M.mine_batcher, data, task) end
    if ok and type(target) == "number" and target > task.target then
      task.target = target
      task.batched = true
    end
  end
  data.task = task
  data.status = M.describe(task)
end

-- The task is done; plan the next one immediately.
function M.finish(data, status)
  ghost_mark.clear(data)
  data.task = nil
  if status then data.status = status end
  data.next_plan = game.tick
end

-- The task failed; back off a moment before planning again.
function M.abort(data, reason)
  ghost_mark.clear(data)
  data.task = nil
  data.status = reason
  data.next_plan = game.tick + 60
end

-- Replace the active task with a follow-up one (its timeout restarts).
function M.chain(data, next_task)
  local def = defs[next_task.type]
  next_task.expires = game.tick + ((def and def.timeout) or DEFAULT_TIMEOUT)
  M.start(data, next_task)
end

-- Execute the active task for this tick.
function M.run(player, data)
  local task = data.task
  local def = defs[task.type] -- nil for tasks saved by older versions
  if not def then return M.abort(data, "Dropped an unknown task") end
  if game.tick > task.expires then return M.abort(data, "Task timed out") end
  def.execute(player, data, task)
  ghost_mark.sync(player, data) -- shade the ghost it is working on (a visual cue only)
end

return M
