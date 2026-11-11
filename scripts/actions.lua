-- Action system entry point. Loads every built-in action into the registry.
-- See scripts/actions/core.lua for how to add a new one.

local core = require("scripts.actions.core")

local BUILTIN = {"progress_game", "deploy_miners", "set_defenses", "attack_bases"}

for _, name in ipairs(BUILTIN) do
  core.register(require("scripts.actions." .. name))
end

return core
