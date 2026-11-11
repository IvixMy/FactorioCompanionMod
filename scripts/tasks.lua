-- Task system entry point. Loads every built-in task type into the registry.
-- See scripts/tasks/core.lua for how to add a new one.

local core = require("scripts.tasks.core")

local BUILTIN = {"fetch", "build", "mine", "transfer", "deconstruct", "upgrade", "restock", "deposit"}

for _, name in ipairs(BUILTIN) do
  core.register(require("scripts.tasks." .. name))
end

return core
