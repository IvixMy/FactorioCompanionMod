-- Objective registry. An OBJECTIVE is something the Progress action keeps true
-- ("have at least N kW of power", "have miners running", ...).
--
-- Definition (scripts/objectives/<name>.lua returns one, or a list of them):
--   { id = "power", caption = "Power plant",
--     implemented = true,                      -- false = planned, skipped by the controller
--     step = function(ctx) -> status, note }   -- idempotent; called every ~second
-- status: "satisfied" | "working" | "blocked".
-- ctx: { player, data (companion), params (from the playbook, e.g. goal_kw), state (persistent table) }
-- A step may create zones (scripts/zones.lua), place ghosts inside them and start tasks.

local M = {}

local defs, order = {}, {}

function M.register(def)
  assert(def.id and def.step, "incomplete objective definition")
  defs[def.id] = def
  order[#order + 1] = def.id
end

function M.get(id) return defs[id] end

local BUILTIN = {"iron_start", "coal_drills", "power", "ore_cells", "lab", "research_packs", "assembler", "science_factory", "belt_factory", "lab_expansion", "factory_supply", "bp_factories", "planned"}

for _, name in ipairs(BUILTIN) do
  local mod = require("scripts.objectives." .. name)
  if mod.id then
    M.register(mod)
  else
    for _, def in ipairs(mod) do M.register(def) end
  end
end

return M
