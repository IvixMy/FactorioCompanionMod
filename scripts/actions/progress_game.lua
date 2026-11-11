-- Action "progress_game": keep the factory in step with the technology tree.
-- The real work is in scripts/progress.lua; this action only drives it.

local progress = require("scripts.progress")

return {
  id = "progress_game",
  caption = "Progress game",
  description = "Follows the technology tree towards the rocket silo: assigns construction zones and builds what each research stage needs (power first). Keeps running until stopped.",

  prepare = function(player, data)
    return {surface_index = data.entity.surface.index}
  end,

  start_message = function() return "progressing the game along the technology tree." end,

  step = function(player, data, a)
    progress.tick(player, data, a)
    if data.action then data.action_status = a.summary or "starting" end
    return false -- never takes over movement: the task system builds what the objectives place
  end,
}
