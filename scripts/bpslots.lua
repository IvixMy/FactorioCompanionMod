-- Zone blueprints: one optional blueprint per building zone ("slot").
--
-- A slot is a zone family the Companion plans by itself (the red science factory, the belt factory...).
-- When a slot has a blueprint, the Companion builds THAT instead of its own hand-coded layout the next time
-- it plans the zone: it finds a free dry spot near the power plant, places the blueprint as ghosts, runs a
-- power line to the blueprint's nearest electric pole and builds everything with the normal auto-build.
-- Without a blueprint nothing changes (a slot with `needs_blueprint` is simply skipped).
--
-- Blueprints are stored as export strings (they survive the original being deleted and are what players
-- share), so the menu takes a pasted string or the blueprint / book held in the cursor.
--
-- To make another zone blueprintable: add a row to SLOTS and give the objective that plans it
-- `slot = "<id>"` (scripts/objectives/factory_base.lua) - see scripts/objectives/bp_factories.lua.

local blueprints = require("scripts.blueprints")
local zones      = require("scripts.zones")

local M = {}

-- id = the objective's slot; purpose = the zone family it creates (used to show its progress).
M.SLOTS = {
  {id = "science_factory", purpose = "science_factory", caption = "Red science factory",
   empty = "Built-in layout (3 science + 3 gear assemblers)"},
  {id = "belt_factory", purpose = "belt_factory", caption = "Transport belt factory",
   empty = "Built-in layout (gear + belt assembler)"},
  {id = "green_science_factory", purpose = "green_science_factory", caption = "Green science factory",
   empty = "Not built: needs a blueprint", needs_blueprint = true},
}

function M.init()
  storage.bp_slots = storage.bp_slots or {} -- [player_index][slot id] = blueprint record
end

function M.slot(id)
  for _, s in ipairs(M.SLOTS) do
    if s.id == id then return s end
  end
  return nil
end

function M.get(player_index, id)
  M.init()
  local t = storage.bp_slots[player_index]
  return t and t[id]
end

local function put(player_index, id, bp)
  M.init()
  storage.bp_slots[player_index] = storage.bp_slots[player_index] or {}
  storage.bp_slots[player_index][id] = bp
end

function M.clear(player_index, id) put(player_index, id, nil) end

function M.remove_player(player_index)
  M.init()
  storage.bp_slots[player_index] = nil
end

-- Stores a freshly read blueprint record for the slot and tells the player what to expect.
local function accept(player, slot, bp, err)
  if not bp then return false, err end
  put(player.index, slot.id, bp)

  local notes = {}
  if bp.poles == 0 then
    notes[#notes + 1] = "it has no electric pole, so it cannot be connected to the power plant"
  end
  local locked = blueprints.locked_items(bp, player.force)
  if #locked > 0 then
    notes[#notes + 1] = "not unlocked yet: " .. table.concat(locked, ", ")
  end
  local msg = string.format("blueprint '%s' (%dx%d, %d entities) assigned to '%s'.",
    bp.label, bp.w, bp.h, bp.n, slot.caption)
  if #notes > 0 then msg = msg .. " Note: " .. table.concat(notes, "; ") .. "." end
  return true, msg
end

-- -> ok, message
function M.set_from_string(player, id, text)
  local slot = M.slot(id)
  if not slot then return false, "unknown zone." end
  local bp, err = blueprints.from_string(text)
  return accept(player, slot, bp, err)
end

function M.set_from_cursor(player, id)
  local slot = M.slot(id)
  if not slot then return false, "unknown zone." end
  local bp, err = blueprints.from_cursor(player)
  return accept(player, slot, bp, err)
end

-- How many slots have a blueprint: for the one-line summary in the main menu.
function M.count(player_index)
  local n = 0
  for _, s in ipairs(M.SLOTS) do
    if M.get(player_index, s.id) then n = n + 1 end
  end
  return n
end

function M.summary(player_index)
  return string.format("%d of %d zones have a blueprint", M.count(player_index), #M.SLOTS)
end

-- One or two short lines for the slot's row in the dialog.
function M.status_text(player, slot)
  local bp = M.get(player.index, slot.id)
  local lines = {}
  if bp then
    lines[1] = string.format("Blueprint \"%s\": %dx%d tiles, %d entities", bp.label, bp.w, bp.h, bp.n)
  else
    lines[1] = slot.empty
  end

  local zone = zones.list(player.index, slot.purpose)[1]
  if zone then
    local built, total = zones.progress(zone, player.force)
    local state = string.format("Zone placed: %d/%d built", built, total)
    local planned_from = zone.bp_str
    if (bp and bp.str ~= planned_from) or (not bp and planned_from) then
      state = state .. " - erase the zone in the main menu to apply the change"
    end
    lines[2] = state
  end
  return table.concat(lines, "\n")
end

return M
