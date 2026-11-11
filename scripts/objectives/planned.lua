-- Objectives that are part of the playbooks but not written yet.
-- Replace an entry with its own file (and add it to BUILTIN in scripts/objectives.lua).

local function planned(id, caption)
  return {
    id = id, caption = caption, implemented = false,
    step = function() return "blocked", "not implemented yet" end,
  }
end

return {
  planned("mining",   "Ore mining (will reuse the Deploy miners action)"),
  planned("smelting", "Smelting"),
  planned("defense",  "Defenses"),
}
