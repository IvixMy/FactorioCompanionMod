-- CUSTOM STATES (see README.md in this folder).
--
-- A state decides which animation and line the portrait shows. Highest priority that returns something wins.
-- Built-in priorities: event 100, blocked 80, working 60, waiting 50, research 40, following 20, idle 0.
--
-- ctx = {player = LuaPlayer, data = the companion's data (data.entity, data.status, data.task...), force = LuaForce}
--
-- Example (remove the "--" to use it):
--
-- return function(interaction)
--   local dialogues = require("scripts.dialogues")  -- NOT allowed here at runtime: require it at the top of the file
--   interaction.register_state("night", 70, function(ctx)
--     if ctx.player.surface.darkness > 0.6 then
--       return {animation = "tired", line = "It's getting dark..."}
--     end
--   end)
-- end

return function(interaction)
end
