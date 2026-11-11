-- A visual cue (0.19.9): the ghost the companion is building - or fetching the material for - is shaded in a colour
-- from the mod settings. It is only a picture: nothing is reserved, bots and the player can still build the ghost.
--
-- Settings (per player): ec-ghost-mark-enabled, ec-ghost-mark-color.
-- data.mark = {ghost, obj, color}; the rectangle lives 5 s and is redrawn while the ghost is still the target, so
-- a mark never stays behind when the task ends in a way that does not call clear().

local M = {}

local TTL = 300

local function setting(player, name)
  local s = settings.get_player_settings(player)[name]
  return s and s.value
end

function M.clear(data)
  local mk = data.mark
  if mk and mk.obj and mk.obj.valid then mk.obj.destroy() end
  data.mark = nil
end

-- The ghost the companion works on now (building it, or fetching for it), or nil.
local function target_of(task)
  if not task then return nil end
  if task.type == "build" then return task.ghost end
  if task.type == "fetch" and task.then_task and task.then_task.type == "build" then return task.then_task.ghost end
  return nil
end

local function box_of(ghost)
  local ok, box = pcall(function() return ghost.selection_box end)
  if not (ok and box) then box = ghost.bounding_box end
  local lt, rb = box.left_top or box[1], box.right_bottom or box[2]
  local l, t = lt.x or lt[1], lt.y or lt[2]
  local r, b = rb.x or rb[1], rb.y or rb[2]
  if r - l < 0.2 or b - t < 0.2 then
    local p = ghost.position
    return p.x - 0.5, p.y - 0.5, p.x + 0.5, p.y + 0.5
  end
  return l, t, r, b
end

-- Called every tick the task runs (scripts/tasks/core.lua).
function M.sync(player, data)
  local ghost = target_of(data.task)
  if not (ghost and ghost.valid) or setting(player, "ec-ghost-mark-enabled") == false then
    if data.mark then M.clear(data) end
    return
  end
  local color = setting(player, "ec-ghost-mark-color") or {r = 0.25, g = 0.8, b = 1, a = 0.35}
  local mk = data.mark
  if mk and mk.ghost == ghost and mk.obj and mk.obj.valid
      and mk.color.r == color.r and mk.color.g == color.g and mk.color.b == color.b and mk.color.a == color.a then
    return
  end
  M.clear(data)
  local l, t, r, b = box_of(ghost)
  local ok, obj = pcall(rendering.draw_rectangle, {
    color = color, filled = true, left_top = {x = l, y = t}, right_bottom = {x = r, y = b},
    surface = ghost.surface, players = {player}, time_to_live = TTL, render_layer = "selection-box",
  })
  if ok and obj then
    data.mark = {ghost = ghost, obj = obj, color = {r = color.r, g = color.g, b = color.b, a = color.a}}
  end
end

return M
