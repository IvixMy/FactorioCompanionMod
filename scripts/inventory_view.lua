-- Read-only window showing exactly what the companion carries (every inventory slot + the worn armor),
-- so you can check it only uses what it really has. Opened with the "Inventory" button of the talk window;
-- scripts/interaction.lua refreshes it while that window is open. Nothing here can move items.

local names = require("scripts.names")

local M = {}

M.FRAME = "ec_inventory_frame"
local COLUMNS = 10

local function state(player_index)
  storage.inventory_view = storage.inventory_view or {}
  storage.inventory_view[player_index] = storage.inventory_view[player_index] or {}
  return storage.inventory_view[player_index]
end

function M.is_open(player)
  return player.gui.screen[M.FRAME] ~= nil
end

function M.close(player)
  local f = player.gui.screen[M.FRAME]
  if f then f.destroy() end
  if storage.inventory_view then storage.inventory_view[player.index] = nil end
end

local function stack_of(inv, i)
  local s = inv[i]
  if s and s.valid_for_read then return s end
  return nil
end

local function add_slot(table_el, stack)
  if not stack then
    table_el.add{type = "sprite-button", style = "slot_button", enabled = false}
    return
  end
  local proto = prototypes.item[stack.name]
  local quality = stack.quality and stack.quality.name or "normal"
  local tip = {"", proto and proto.localised_name or stack.name, quality ~= "normal" and (" (" .. quality .. ")") or ""}
  local b = table_el.add{
    type = "sprite-button", style = "slot_button", sprite = "item/" .. stack.name,
    number = stack.count, tooltip = tip,
  }
  if quality ~= "normal" then pcall(function() b.quality = quality end) end
end

-- Rebuilds the slot grid when the contents changed.
local function fill(player, frame, data)
  local c = data.entity
  local cinv = c.get_main_inventory()
  if not cinv then return end

  local parts, stacks = {}, {}
  for i = 1, #cinv do
    local s = stack_of(cinv, i)
    stacks[i] = s
    parts[#parts + 1] = s and (s.name .. ":" .. s.count .. ":" .. (s.quality and s.quality.name or "n")) or "-"
  end
  local ok, ainv = pcall(c.get_inventory, defines.inventory.character_armor)
  local armor = ok and ainv and stack_of(ainv, 1) or nil
  parts[#parts + 1] = "A:" .. (armor and armor.name or "none")
  local sig = table.concat(parts, "|")

  local st = state(player.index)
  if st.sig == sig then return end
  st.sig = sig

  local body = frame.ec_inventory_body
  body.clear()
  local armor_flow = body.add{type = "flow", direction = "horizontal"}
  armor_flow.style.vertical_align = "center"
  armor_flow.add{type = "label", caption = "Armor:", style = "bold_label"}
  if armor then
    add_slot(armor_flow, armor)
    local proto = prototypes.item[armor.name]
    armor_flow.add{type = "label", caption = proto and proto.localised_name or armor.name}
  else
    armor_flow.add{type = "label", caption = "none worn"}
  end

  local grid = body.add{type = "table", column_count = COLUMNS, style = "filter_slot_table"}
  for i = 1, #cinv do add_slot(grid, stacks[i]) end

  local used = 0
  for i = 1, #cinv do if stacks[i] then used = used + 1 end end
  body.add{type = "label", caption = string.format("%d / %d slots used", used, #cinv)}
end

function M.refresh(player, force)
  local frame = player.gui.screen[M.FRAME]
  if not frame then return end
  local st = state(player.index)
  if not force and game.tick - (st.last or -100) < 15 then return end -- the talk window calls this often
  st.last = game.tick
  local data = storage.companions and storage.companions[player.index]
  if not (data and data.entity and data.entity.valid) then return M.close(player) end
  fill(player, frame, data)
end

function M.open(player)
  local data = storage.companions and storage.companions[player.index]
  if not (data and data.entity and data.entity.valid) then return end
  M.close(player)

  local frame = player.gui.screen.add{type = "frame", name = M.FRAME, direction = "vertical"}
  local bar = frame.add{type = "flow", direction = "horizontal"}
  bar.drag_target = frame
  local title = bar.add{type = "label", caption = names.get() .. "'s inventory", style = "frame_title"}
  title.drag_target = frame
  local filler = bar.add{type = "empty-widget", style = "draggable_space_header"}
  filler.style.horizontally_stretchable = true
  filler.style.height = 24
  filler.drag_target = frame
  bar.add{
    type = "sprite-button", style = "frame_action_button", sprite = "utility/close",
    tooltip = {"gui.close-instruction"}, tags = {ec_interact = "inventory_close"},
  }
  frame.add{type = "flow", name = "ec_inventory_body", direction = "vertical"}
  frame.force_auto_center()
  M.refresh(player, true)
end

function M.toggle(player)
  if M.is_open(player) then M.close(player) else M.open(player) end
end

return M
