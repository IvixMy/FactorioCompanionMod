-- Companion requests: the items the companion keeps on itself, edited by the player in a window that works like the
-- personal logistics (request) window of the player: one row per slot with an item, a MIN and a MAX.
--
--   * below MIN  -> the companion starts a restock trip (scripts/loadout.lua)
--   * a trip fills it up to MAX
--   * an empty slot (no item) is ignored; the table is stored per player in storage.companion_requests
--
-- Opened with the "Requests" button of the talk window (scripts/interaction.lua) or requests.toggle(player).
--
-- GUI events (control.lua has to forward these two, see README_requests.md):
--   script.on_event(defines.events.on_gui_elem_changed, function(e) requests.on_elem_changed(e) end)
--   script.on_event(defines.events.on_gui_text_changed, function(e) requests.on_text_changed(e) end)
-- Clicks are routed through tags.ec_interact like every other button of the mod.

local names = require("scripts.names")

local M = {}

M.FRAME = "ec_requests_frame"
M.SLOTS = 30         -- number of rows
local COLUMNS = 2    -- rows per line (two columns of slots, like the player's logistics window)
local ROWS_PER_COLUMN = math.floor(M.SLOTS / COLUMNS)

-- Old versions read the fixed mod settings "ec-loadout-<key>"; the first time a player opens the table
-- the values of those settings (when they exist) are imported once.
local LEGACY = {
  {key = "inserter",      item = "inserter"},
  {key = "long-inserter", item = "long-handed-inserter"},
  {key = "belt",          item = "transport-belt"},
  {key = "splitter",      item = "splitter"},
  {key = "underground",   item = "underground-belt"},
  {key = "chest",         item = "iron-chest"},
  {key = "assembler",     item = "assembling-machine-1"},
  {key = "pole",          item = "small-electric-pole"},
  {key = "furnace",       item = "stone-furnace"},
  {key = "iron-plate",    item = "iron-plate"},
  {key = "copper-plate",  item = "copper-plate"},
  {key = "circuit",       item = "electronic-circuit"},
}

---------------------------------------------------------------------
-- Data
---------------------------------------------------------------------

local function legacy_import(player)
  local list = {}
  local ps = settings.get_player_settings(player)
  for _, l in ipairs(LEGACY) do
    local s = ps["ec-loadout-" .. l.key]
    local target = s and math.floor(tonumber(s.value) or 0) or 0
    if target > 0 and prototypes.item[l.item] then
      list[#list + 1] = {name = l.item, min = math.max(1, math.floor(target / 2)), max = target}
    end
  end
  return list
end

-- The player's slots: {[1..SLOTS] = {name = item or nil, min = n, max = n}}
function M.get(player)
  storage.companion_requests = storage.companion_requests or {}
  local t = storage.companion_requests[player.index]
  if not t then
    t = {}
    local old = legacy_import(player)
    for i = 1, M.SLOTS do t[i] = old[i] or {min = 0, max = 0} end
    storage.companion_requests[player.index] = t
  end
  return t
end

-- {{name, min, max}, ...} of the slots in use (max is never below min; slots without an item or a max are skipped)
function M.active(player)
  local out = {}
  for _, r in ipairs(M.get(player)) do
    if r.name and prototypes.item[r.name] then
      local min = math.max(0, math.floor(r.min or 0))
      local max = math.max(min, math.floor(r.max or 0))
      if max > 0 then out[#out + 1] = {name = r.name, min = min, max = max} end
    end
  end
  return out
end

function M.remove_player(player_index)
  if storage.companion_requests then storage.companion_requests[player_index] = nil end
end

---------------------------------------------------------------------
-- Window
---------------------------------------------------------------------

function M.is_open(player) return player.gui.screen[M.FRAME] ~= nil end

local function find_by_tag(el, kind, slot)
  if el.tags and el.tags.ec_req == kind and el.tags.slot == slot then return el end
  for _, ch in pairs(el.children or {}) do
    local f = find_by_tag(ch, kind, slot)
    if f then return f end
  end
  return nil
end

-- Reads every slot straight from the window into storage (does not depend on any GUI event hook).
function M.save(player)
  local frame = player.gui.screen[M.FRAME]
  if not frame then return end
  local reqs = M.get(player)
  for i = 1, M.SLOTS do
    local fitem = find_by_tag(frame, "item", i)
    local fmin, fmax = find_by_tag(frame, "min", i), find_by_tag(frame, "max", i)
    if fitem then
      local r = reqs[i]
      r.name = fitem.elem_value and tostring(fitem.elem_value) or nil
      r.min = math.max(0, math.floor(tonumber(fmin and fmin.text) or 0))
      r.max = math.max(0, math.floor(tonumber(fmax and fmax.text) or 0))
      if r.name and r.max <= 0 then
        -- item picked without amounts: start with about a stack
        local proto = prototypes.item[r.name]
        r.max = math.min(proto and proto.stack_size or 50, 200)
        if r.min <= 0 then r.min = math.max(1, math.floor(r.max / 2)) end
      end
      if r.max < r.min then r.max = r.min end
    end
  end
end

function M.close(player)
  local f = player.gui.screen[M.FRAME]
  if f then
    M.save(player)
    f.destroy()
  end
end

local function number_field(parent, value, tags, tooltip)
  local f = parent.add{
    type = "textfield", text = tostring(value or 0), numeric = true,
    allow_decimal = false, allow_negative = false, tags = tags, tooltip = tooltip,
  }
  f.style.width = 56
  f.style.horizontal_align = "center"
  return f
end

local function build_row(grid, i, r)
  local row = grid.add{type = "flow", direction = "horizontal"}
  row.style.vertical_align = "center"
  row.style.horizontal_spacing = 4

  local b = row.add{
    type = "choose-elem-button", elem_type = "item", name = "ec_req_item_" .. i,
    style = "slot_button", tags = {ec_req = "item", slot = i},
    tooltip = "Item the companion should keep on itself.",
  }
  if r.name and prototypes.item[r.name] then b.elem_value = r.name end

  row.add{type = "label", caption = "min"}
  number_field(row, r.min, {ec_req = "min", slot = i}, "Below this amount the companion goes to restock.")
  row.add{type = "label", caption = "max"}
  number_field(row, r.max, {ec_req = "max", slot = i}, "A restock trip fills up to this amount.")

  local have = row.add{type = "label", name = "ec_req_have_" .. i, caption = ""}
  have.style.width = 60
  have.style.font_color = {0.7, 0.7, 0.7}

  row.add{
    type = "sprite-button", style = "tool_button", sprite = "utility/trash",
    tooltip = "Clear this slot.", tags = {ec_interact = "req_clear", slot = i},
  }
end

local function fill(player, frame)
  local body = frame.ec_requests_body
  body.clear()
  body.add{
    type = "label", style = "bold_label",
    caption = "Items " .. names.get() .. " keeps on itself. Below MIN it goes to restock, up to MAX.",
  }
  local reqs = M.get(player)
  local columns = body.add{type = "flow", direction = "horizontal"}
  columns.style.horizontal_spacing = 16
  for col = 1, COLUMNS do
    local grid = columns.add{type = "flow", direction = "vertical"}
    grid.style.vertical_spacing = 2
    for k = 1, ROWS_PER_COLUMN do
      local i = (col - 1) * ROWS_PER_COLUMN + k
      build_row(grid, i, reqs[i])
    end
  end
end

-- Shows how many of each item the companion carries right now (red while below MIN).
local function find_by_name(el, name)
  if el.name == name then return el end
  for _, ch in pairs(el.children or {}) do
    local f = find_by_name(ch, name)
    if f then return f end
  end
  return nil
end

function M.refresh(player, force)
  local frame = player.gui.screen[M.FRAME]
  if not frame then return end
  storage.requests_refresh = storage.requests_refresh or {}
  if not force and game.tick - (storage.requests_refresh[player.index] or -100) < 30 then return end
  storage.requests_refresh[player.index] = game.tick
  local data = storage.companions and storage.companions[player.index]
  if not (data and data.entity and data.entity.valid) then return M.close(player) end
  local cinv = data.entity.get_main_inventory()
  if not cinv then return end
  local body = frame.ec_requests_body
  for i, r in ipairs(M.get(player)) do
    local label = find_by_name(body, "ec_req_have_" .. i)
    if label then
      if r.name then
        local n = cinv.get_item_count{name = r.name, quality = "normal"}
        label.caption = "has " .. n
        label.style.font_color = (n < (r.min or 0)) and {1, 0.5, 0.4} or {0.7, 0.7, 0.7}
      else
        label.caption = ""
      end
    end
  end
end

function M.open(player)
  local data = storage.companions and storage.companions[player.index]
  if not (data and data.entity and data.entity.valid) then return end
  M.close(player)

  local frame = player.gui.screen.add{type = "frame", name = M.FRAME, direction = "vertical"}
  local bar = frame.add{type = "flow", direction = "horizontal"}
  bar.drag_target = frame
  local title = bar.add{type = "label", caption = names.get() .. "'s requests", style = "frame_title"}
  title.drag_target = frame
  local filler = bar.add{type = "empty-widget", style = "draggable_space_header"}
  filler.style.horizontally_stretchable = true
  filler.style.height = 24
  filler.drag_target = frame
  bar.add{
    type = "sprite-button", style = "frame_action_button", sprite = "utility/close",
    tooltip = {"gui.close-instruction"}, tags = {ec_interact = "req_close"},
  }
  frame.add{type = "frame", name = "ec_requests_body", style = "inside_shallow_frame_with_padding", direction = "vertical"}
  fill(player, frame)
  local footer = frame.add{type = "flow", direction = "horizontal"}
  footer.style.top_margin = 4
  local fill_space = footer.add{type = "empty-widget"}
  fill_space.style.horizontally_stretchable = true
  footer.add{type = "button", style = "confirm_button", caption = "Save",
    tooltip = "Save the requests (they are also saved when this window closes).", tags = {ec_interact = "req_save"}}
  frame.force_auto_center()
  M.refresh(player, true)
end

function M.toggle(player)
  if M.is_open(player) then M.close(player) else M.open(player) end
end

---------------------------------------------------------------------
-- Events
---------------------------------------------------------------------

-- on_gui_elem_changed: an item was picked / removed in a slot.
function M.on_elem_changed(event)
  local el = event.element
  if not (el and el.valid and el.tags and el.tags.ec_req == "item") then return false end
  local player = game.get_player(event.player_index)
  local r = M.get(player)[el.tags.slot]
  r.name = el.elem_value and tostring(el.elem_value) or nil
  if r.name and (r.max or 0) <= 0 then
    -- a sensible start: keep a stack-ish amount so picking an item is enough to make it work
    local proto = prototypes.item[r.name]
    r.max = math.min(proto and proto.stack_size or 50, 200)
    r.min = math.max(1, math.floor(r.max / 2))
    local frame = player.gui.screen[M.FRAME]
    if frame then
      local fmin, fmax = find_by_tag(frame, "min", el.tags.slot), find_by_tag(frame, "max", el.tags.slot)
      if fmin then fmin.text = tostring(r.min) end
      if fmax then fmax.text = tostring(r.max) end
    end
  end
  return true
end

-- on_gui_text_changed: a min / max field was edited.
function M.on_text_changed(event)
  local el = event.element
  if not (el and el.valid and el.tags and (el.tags.ec_req == "min" or el.tags.ec_req == "max")) then return false end
  local player = game.get_player(event.player_index)
  local r = M.get(player)[el.tags.slot]
  local value = math.max(0, math.floor(tonumber(el.text) or 0))
  r[el.tags.ec_req] = value

  -- keep max >= min (the other field follows)
  local frame = player.gui.screen[M.FRAME]
  if el.tags.ec_req == "min" and (r.max or 0) < value then
    r.max = value
    local fmax = frame and find_by_tag(frame, "max", el.tags.slot)
    if fmax then fmax.text = tostring(value) end
  end
  return true
end

-- Clicks with tags.ec_interact = "req_clear" / "req_close" (called from interaction.handle_click).
function M.handle_click(player, el)
  local kind = el.tags.ec_interact
  if kind == "req_close" then
    M.close(player)
  elseif kind == "req_save" then
    M.save(player)
    player.create_local_flying_text{text = "Requests saved", create_at_cursor = true}
    M.refresh(player, true)
  elseif kind == "req_clear" then
    M.save(player)
    M.get(player)[el.tags.slot] = {min = 0, max = 0}
    local frame = player.gui.screen[M.FRAME]
    if frame then fill(player, frame) M.refresh(player, true) end
  else
    return false
  end
  return true
end

return M
