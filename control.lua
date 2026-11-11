-- Engineer Companion v0.5
-- Modes: follow / follow + build near / wait / auto-build from chests.
-- Auto-build: fetch from chests -> (craft what is missing in the background) -> build ghosts;
-- when idle it roams near what it built.
--
-- Code layout:
--   scripts/common.lua      shared constants + movement helpers
--   scripts/supply.lua      chest contents index
--   scripts/crafting.lua    background hand-crafting
--   scripts/planner.lua     decides the next task from the ghosts on the map
--   scripts/tasks.lua       task registry (scripts/tasks/*.lua: fetch, build, ...)
--   scripts/actions.lua     action registry (scripts/actions/*.lua: deploy_miners, ...)
--   scripts/prospecting.lua / blueprints.lua   ore scanning / blueprint storage

local prospecting = require("scripts.prospecting")
local crafting    = require("scripts.crafting")
local voice       = require("scripts.voice") -- the companion speaks in the world (not only in the Talk window)
local blueprints  = require("scripts.blueprints")
local common      = require("scripts.common")
local planner     = require("scripts.planner")
local tasks       = require("scripts.tasks")
local actions     = require("scripts.actions")
local zones       = require("scripts.zones")
local progress    = require("scripts.progress")
local upkeep      = require("scripts.upkeep")
local map         = require("scripts.map")
local geometry    = require("scripts.geometry")
local goals       = require("scripts.goals")
local bpslots     = require("scripts.bpslots")
local interaction = require("scripts.interaction")
local requests    = require("scripts.requests")
local dialogues   = require("scripts.dialogues")
local pathing     = require("scripts.pathing")
local defense     = require("scripts.defense")
require("scripts.vehicle_supply") -- crafts / fuels the vehicle for long trips (hooks into scripts/vehicles.lua)
require("scripts.demand") -- registers the mine batcher in the task core

local ENTITY_NAME = common.ENTITY_NAME
local FRAME       = "ec_frame"
local TOP_BUTTON  = "ec_toggle"
local BPS_FRAME   = "ec_bps_frame"

local dist2          = common.dist2
local walk_towards   = common.walk_towards
local steer          = common.steer
local record_placed  = common.record_placed
local builds_per_second = common.builds_per_second

local MODES = {
  {id = "follow",       caption = "Follow only",
   tooltip = "Follows you and does nothing else."},
  {id = "follow_build", caption = "Follow and build nearby ghosts",
   tooltip = "Follows you and builds ghosts near itself, using items from YOUR inventory."},
  {id = "wait",         caption = "Wait in place",
   tooltip = "Stays where it is."},
  {id = "auto_build",   caption = "Base development",
   tooltip = "Develops the base on its own: builds ghosts anywhere on the surface, fetching items from your chests and crafting what is missing, keeps machines fuelled and carries out the objectives. When idle it roams near the buildings it placed."},
}

---------------------------------------------------------------------
-- Storage / settings
---------------------------------------------------------------------

local function init_storage()
  storage.companions   = storage.companions or {}
  storage.modes        = storage.modes or {}
  storage.supply       = storage.supply or {}
  storage.assigned_ore = storage.assigned_ore or {}
  storage.selected_action = storage.selected_action or {}
  zones.init()
  progress.init()
  prospecting.init()
  blueprints.init()
  bpslots.init()
  interaction.init()
  defense.init()
end

local function get_mode(player_index)
  return storage.modes[player_index] or "follow"
end

---------------------------------------------------------------------
-- Following
---------------------------------------------------------------------

local function follow_player(player, data)
  local c = data.entity
  local char = player.character
  if not char then
    c.walking_state = {walking = false}
    return
  end
  if c.surface.index ~= char.surface.index then
    common.teleport_beside(c, char.position, char.surface)
    data.nav = nil
    return
  end
  local d2 = dist2(c.position, char.position)
  if d2 > common.TELEPORT_DISTANCE * common.TELEPORT_DISTANCE then
    common.teleport_beside(c, char.position, char.surface)
    data.nav = nil
    data.following = false
  elseif d2 > common.FOLLOW_START * common.FOLLOW_START then
    data.following = true
  elseif d2 < common.FOLLOW_STOP * common.FOLLOW_STOP then
    data.following = false
  end
  if data.following then
    walk_towards(data, char.position, common.FOLLOW_STOP - 1) -- goes round obstacles (scripts/pathing.lua)
  else
    c.walking_state = {walking = false}
    data.nav = nil
  end
end

---------------------------------------------------------------------
-- Spawning
---------------------------------------------------------------------

local function spawn_companion(player)
  local char = player.character
  if not char then return end
  local pos = {x = char.position.x + 2, y = char.position.y + 2}
  local c = char.surface.create_entity{name = ENTITY_NAME, position = pos, force = player.force}
  if not c then return end
  c.color = {r = 1, g = 0.6, b = 0}
  c.destructible = false
  rendering.draw_text{
    text = "Engineer",
    surface = c.surface,
    target = {entity = c, offset = {0, -2.5}},
    color = {r = 1, g = 0.8, b = 0.2},
    scale = 0.8,
    alignment = "center",
  }
  storage.companions[player.index] = {
    entity = c, blocked = {}, placed = {}, pending = {}, craft_queue = {}, status = "Ready",
  }
end

-- Whatever the companion is carrying goes back to the player
local function return_items(player, c)
  local inv = c.get_main_inventory()
  if not inv then return end
  for _, s in pairs(inv.get_contents()) do
    local inserted = player.insert{name = s.name, count = s.count, quality = s.quality}
    if inserted < s.count then
      c.surface.spill_item_stack{
        position = c.position,
        stack = {name = s.name, count = s.count - inserted, quality = s.quality},
        enable_looted = false,
      }
    end
  end
end

local function dismiss_companion(player_index)
  local data = storage.companions[player_index]
  map.remove(data)
  if data and data.entity and data.entity.valid then
    local player = game.get_player(player_index)
    defense.unequip(player, data) -- the gun and ammo it was lent
    if player and player.valid then return_items(player, data.entity) end
    data.entity.destroy()
  end
  storage.companions[player_index] = nil
end

local function has_companion(player_index)
  local data = storage.companions[player_index]
  return data ~= nil and data.entity ~= nil and data.entity.valid
end

---------------------------------------------------------------------
-- Mode: follow + build nearby (player's inventory)
---------------------------------------------------------------------

local function build_near(player, data)
  local c = data.entity
  local inv = player.get_main_inventory()
  if not inv then return end

  data.budget = math.min((data.budget or 0) + builds_per_second(player) * 0.5, 2)
  local allowed = math.floor(data.budget)
  if allowed < 1 then return end

  local ghosts = c.surface.find_entities_filtered{
    type = common.GHOST_TYPES, position = c.position, radius = common.NEAR_BUILD_RADIUS,
    force = player.force, limit = 20,
  }
  local built = 0
  for _, ghost in pairs(ghosts) do
    if built >= allowed then break end
    if ghost.valid then
      local proto = ghost.ghost_prototype
      local item = proto and proto.items_to_place_this and proto.items_to_place_this[1]
      if item then
        local count = item.count or 1
        local quality = (ghost.type == "entity-ghost") and ghost.quality or nil
        if inv.get_item_count{name = item.name, quality = quality} >= count then
          local gpos = ghost.position
          local gname = ghost.ghost_name
          local collided, entity = ghost.revive{raise_revive = true}
          if collided ~= nil or entity ~= nil then
            inv.remove{name = item.name, count = count, quality = quality}
            record_placed(data, c.surface.index, gpos)
            goals.notify(player.force, "build", gname, 1)
            built = built + 1
          end
        end
      end
    end
  end
  data.budget = data.budget - built
end

---------------------------------------------------------------------
-- Mode: auto-build (planner picks a task, the task registry executes it)
---------------------------------------------------------------------

local function roam_step(data)
  local c = data.entity
  local anchors = data.placed

  if not anchors or #anchors == 0 then
    c.walking_state = {walking = false}
    return
  end
  data.status = "Idle: roaming near my buildings"

  local r = data.roam
  if r and r.target then
    if walk_towards(data, r.target, 1.5) then
      r.target = nil
      r.wait_until = game.tick + math.random(120, 300)
    elseif game.tick > (r.give_up or math.huge) then
      -- could not get there in time (blocked?): forget this spot and pick another one later
      r.target = nil
      r.wait_until = game.tick + 60
      data.nav = nil
      c.walking_state = {walking = false}
    end
    return
  end
  if r and r.wait_until and game.tick < r.wait_until then
    c.walking_state = {walking = false}
    return
  end

  for _ = 1, 5 do
    local a = anchors[math.random(#anchors)]
    if a.s == c.surface.index then
      local angle = math.random() * 2 * math.pi
      local radius = 2 + math.random() * (common.ROAM_RADIUS - 2)
      -- only spots where it can stand (not inside a building, a tree, water ...)
      local wish = {x = a.x + math.cos(angle) * radius, y = a.y + math.sin(angle) * radius}
      local spot = c.surface.find_non_colliding_position(common.ENTITY_NAME, wish, 3, 0.5)
      if spot then
        data.roam = {target = spot, give_up = game.tick + 900}
        return
      end
    end
  end
  c.walking_state = {walking = false}
end

local function run_auto_build(player, data)
  if data.action and actions.run(player, data) then return end

  if data.task then
    tasks.run(player, data)
    return
  end
  if game.tick >= (data.next_plan or 0) and not upkeep.holding(data) then
    data.next_plan = game.tick + 30
    planner.plan(player, data)
    if data.task then
      data.roam = nil
      return
    end
  end
  roam_step(data)
end

---------------------------------------------------------------------
-- Main loops
---------------------------------------------------------------------

script.on_event(defines.events.on_tick, function()
  prospecting.on_tick()

  for idx, data in pairs(storage.companions) do
    local player = game.get_player(idx)
    if not (player and player.valid) then
      storage.companions[idx] = nil
    elseif not data.entity.valid then
      map.remove(data)
      spawn_companion(player)
    else
      crafting.tick(data) -- background crafting runs in every mode
      if game.tick % voice.POLL_TICKS == 0 then voice.tick(player, data) end
      map.tick(player, data) -- charts + generates terrain around it, keeps its map marker

      local mode = get_mode(idx)
      if mode == "follow" or mode == "follow_build" then
        data.task, data.roam = nil, nil
        if not defense.run(player, data) then -- true = it is shooting an enemy near you this tick
          follow_player(player, data)
          data.status = defense.idle_status(player, data) or "Following you"
        end
      else
        defense.release(data) -- not following: stop shooting
        if mode == "wait" then
          data.task, data.roam = nil, nil
          data.entity.walking_state = {walking = false}
          data.status = "Waiting in place"
        elseif mode == "auto_build" then
          run_auto_build(player, data)
        end
      end
    end
  end
end)

script.on_nth_tick(30, function()
  for idx, data in pairs(storage.companions) do
    if data.entity.valid and get_mode(idx) == "follow_build" then
      local player = game.get_player(idx)
      if player and player.valid then build_near(player, data) end
    end
  end
end)

---------------------------------------------------------------------
-- GUI
---------------------------------------------------------------------

local function status_text(player_index)
  local data = storage.companions[player_index]
  if not (data and data.entity.valid) then return "Status: not summoned" end
  local lines = {"Status: " .. (data.status or "?")}
  if data.action_status then lines[#lines + 1] = "Action: " .. data.action_status end
  if data.nav_note and game.tick - (data.nav_note_tick or 0) < 600 then lines[#lines + 1] = "Navigation: " .. data.nav_note end
  local cs = crafting.status(data)
  if cs then lines[#lines + 1] = "Crafting: " .. cs end
  return table.concat(lines, "\n")
end

local function resource_options()
  local names, items = {}, {}
  for name, proto in pairs(prototypes.get_entity_filtered{{filter = "type", type = "resource"}}) do
    if proto.resource_category ~= "basic-fluid" then names[#names + 1] = name end
  end
  table.sort(names)
  for _, name in ipairs(names) do
    items[#items + 1] = prototypes.entity[name].localised_name
  end
  return names, items
end

local function close_menu(player)
  local frame = player.gui.screen[FRAME]
  if frame then frame.destroy() end
end

local function selected_action_id(player_index)
  local list = actions.list()
  local id = storage.selected_action[player_index]
  if id and actions.get(id) then return id end
  return list[1] and list[1].id
end

-- (Re)builds the panel under the action dropdown for the selected action.
local function fill_action_panel(player, panel)
  panel.clear()
  local id = selected_action_id(player.index)
  local def = id and actions.get(id)
  if not def then return end

  if def.description then
    local d = panel.add{type = "label", caption = def.description}
    d.style.single_line = false
    d.style.maximal_width = 420
  end
  if def.complex then
    panel.add{type = "label", name = "ec_bp_label", caption = blueprints.describe(blueprints.get(player.index, id))}
  end
  local row = panel.add{type = "flow", direction = "horizontal"}
  if def.complex then
    row.add{
      type = "button", caption = "Assign blueprint from cursor",
      tooltip = "Pick up a blueprint (or a book with the right one active), then press this.",
      tags = {ec_kind = "bp_assign", ec_action = id},
    }
    row.add{type = "button", caption = "Clear", tags = {ec_kind = "bp_clear", ec_action = id}}
  end
  row.add{
    type = "button", caption = def.stub and "Not available yet" or "Run", style = "confirm_button",
    enabled = not def.stub, tags = {ec_kind = "run", ec_action = id},
  }
end

local function refresh_action_gui(player, id)
  local frame = player.gui.screen[FRAME]
  local panel = frame and frame.content and frame.content.ec_action_panel
  if panel and panel.ec_bp_label then
    panel.ec_bp_label.caption = blueprints.describe(blueprints.get(player.index, id))
  end
end

---------------------------------------------------------------------
-- Building zones panel (list + erase)
---------------------------------------------------------------------

local function zone_signature(player_index)
  local ids = {}
  for _, zone in ipairs(zones.all(player_index)) do ids[#ids + 1] = zone.id end
  return table.concat(ids, ",")
end

local function zone_caption(player, zone)
  local built, total = zones.progress(zone, player.force)
  return string.format("%s: %d/%d built%s%s, around (%d, %d)", zone.purpose, built, total,
    zone.bp_str and ", from blueprint" or "",
    zone.permanent and ", permanent" or "",
    math.floor((zone.x0 + zone.x1) / 2), math.floor((zone.y0 + zone.y1) / 2))
end

local function fill_zone_panel(player, panel)
  panel.clear()
  panel.tags = {sig = zone_signature(player.index)}
  local list = zones.all(player.index)
  if #list == 0 then
    panel.add{type = "label", caption = "No building zones yet."}
    return
  end
  local scroll = panel.add{type = "scroll-pane", name = "ec_zone_scroll", vertical_scroll_policy = "auto"}
  scroll.style.maximal_height = 180
  for _, zone in ipairs(list) do
    local row = scroll.add{type = "flow", direction = "horizontal"}
    row.style.vertical_align = "center"
    local label = row.add{type = "label", name = "ec_zl_" .. zone.id, caption = zone_caption(player, zone)}
    label.style.maximal_width = 330
    label.style.single_line = false
    local filler = row.add{type = "empty-widget"}
    filler.style.horizontally_stretchable = true
    row.add{
      type = "button", caption = "Erase",
      tooltip = "Deletes the unbuilt ghosts of this zone and frees its area. Buildings already standing are kept. The Engineer may plan the same thing again somewhere else.",
      tags = {ec_kind = "zone_erase", ec_zone = zone.purpose},
    }
  end
  panel.add{
    type = "button", caption = "Erase all zones", name = "ec_zone_erase_all",
    tooltip = "Erases every zone listed above (unbuilt ghosts are deleted, buildings stay).",
    tags = {ec_kind = "zone_erase_all"},
  }
end

-- Rebuilds the list when zones were added/removed, otherwise only refreshes the captions.
local function refresh_zone_panel(player)
  local frame = player.gui.screen[FRAME]
  local panel = frame and frame.content and frame.content.ec_zone_panel
  if not panel then return end
  if (panel.tags and panel.tags.sig) ~= zone_signature(player.index) then
    fill_zone_panel(player, panel)
    return
  end
  for _, zone in ipairs(zones.all(player.index)) do
    for _, row in pairs(panel.ec_zone_scroll and panel.ec_zone_scroll.children or {}) do
      local l = row["ec_zl_" .. zone.id]
      if l and l.valid then l.caption = zone_caption(player, zone) end
    end
  end
end

local function handle_zone_click(player, el)
  local kind = el.tags.ec_kind
  local data = storage.companions[player.index]
  if kind == "zone_erase" then
    local purpose = el.tags.ec_zone
    local removed = zones.erase(player.index, purpose, player.force)
    if data then data.task = nil end
    player.print(string.format("Engineer: zone '%s' erased (%d unbuilt ghosts deleted).", purpose, removed))
  elseif kind == "zone_erase_all" then
    if not el.tags.armed then -- two clicks: the first only asks
      el.caption = "Click again to erase ALL zones"
      el.tags = {ec_kind = "zone_erase_all", armed = true}
      return
    end
    local n, ghosts = 0, 0
    for _, zone in ipairs(zones.all(player.index)) do
      ghosts = ghosts + zones.erase(player.index, zone.purpose, player.force)
      n = n + 1
    end
    if data then data.task = nil end
    player.print(string.format("Engineer: %d zones erased (%d unbuilt ghosts deleted).", n, ghosts))
  end
  local frame = player.gui.screen[FRAME]
  local panel = frame and frame.content and frame.content.ec_zone_panel
  if panel then fill_zone_panel(player, panel) end
end

local function sync_mode_radios(player)
  local frame = player.gui.screen[FRAME]
  if not (frame and frame.content) then return end
  local current = get_mode(player.index)
  for _, child in pairs(frame.content.children) do
    if child.type == "radiobutton" and child.tags and child.tags.ec_mode then
      child.state = (child.tags.ec_mode == current)
    end
  end
end

local function open_menu(player)
  close_menu(player)
  local frame = player.gui.screen.add{type = "frame", name = FRAME, direction = "vertical"}
  frame.auto_center = true

  local titlebar = frame.add{type = "flow", direction = "horizontal"}
  titlebar.drag_target = frame
  titlebar.add{type = "label", caption = "Engineer Companion", style = "frame_title", ignored_by_interaction = true}
  local filler = titlebar.add{type = "empty-widget", style = "draggable_space_header", ignored_by_interaction = true}
  filler.style.horizontally_stretchable = true
  filler.style.height = 24
  titlebar.add{type = "sprite-button", name = "ec_close", style = "frame_action_button", sprite = "utility/close"}

  local content = frame.add{type = "frame", name = "content", style = "inside_shallow_frame_with_padding", direction = "vertical"}
  content.add{type = "label", caption = "Mode", style = "caption_label"}
  local current = get_mode(player.index)
  for _, m in ipairs(MODES) do
    content.add{
      type = "radiobutton", name = "ec_mode_" .. m.id, caption = m.caption,
      tooltip = m.tooltip, state = (m.id == current), tags = {ec_mode = m.id},
    }
  end
  content.add{
    type = "checkbox", name = "ec_defend", caption = "Defend me (shoot the enemy closest to me)",
    tooltip = "While it follows you, the Engineer shoots the enemy that is closest to you. It uses a spare gun from your inventory (or gets a free one) and takes ammo from YOUR inventory; both go back to you when you untick this or dismiss it.",
    state = defense.enabled(player.index), tags = {ec_defend = true},
  }
  content.add{type = "line"}
  local status = content.add{type = "label", name = "ec_status", caption = status_text(player.index)}
  status.style.single_line = false
  status.style.maximal_width = 420
  local buttons = content.add{type = "flow", direction = "horizontal"}
  buttons.add{type = "button", name = "ec_call", caption = "Call to me"}
  buttons.add{type = "button", name = "ec_talk", caption = "Talk", tooltip = "Open the conversation window (also: SHIFT+F, or E while pointing at the Engineer)."}
  buttons.add{
    type = "button", name = "ec_summon",
    caption = has_companion(player.index) and "Dismiss" or "Summon",
    tooltip = "Dismissing returns whatever the Engineer carries to your inventory.",
  }

  -- Ore assignment / prospecting
  content.add{type = "line"}
  content.add{type = "label", caption = "Assigned ore", style = "caption_label"}
  local names, items = resource_options()
  if #names > 0 then
    local assigned = storage.assigned_ore[player.index] or "iron-ore"
    local selected = 1
    for i, name in ipairs(names) do
      if name == assigned then selected = i end
    end
    content.add{
      type = "drop-down", name = "ec_ore_dd", items = items,
      selected_index = selected, tags = {ores = names},
    }
    content.add{
      type = "button", name = "ec_ore_scan", caption = "Find best patch",
      tooltip = "Scans the area you have charted on this surface. Prefers very large patches, then the closest to spawn.",
    }
    local result = content.add{type = "label", name = "ec_ore_result", caption = prospecting.result_text(player.index)}
    result.style.single_line = false
    result.style.maximal_width = 420
  end

  -- Actions (dropdown + panel for the selected one)
  content.add{type = "line"}
  content.add{type = "label", caption = "Action", style = "caption_label"}
  local ids, captions, selected = {}, {}, 1
  local current_action = selected_action_id(player.index)
  for i, def in ipairs(actions.list()) do
    ids[i] = def.id
    captions[i] = def.caption .. (def.stub and " (coming soon)" or "")
    if def.id == current_action then selected = i end
  end
  content.add{
    type = "drop-down", name = "ec_action_dd", items = captions,
    selected_index = selected, tags = {ids = ids},
  }
  local panel = content.add{type = "flow", name = "ec_action_panel", direction = "vertical"}
  fill_action_panel(player, panel)

  -- Zone blueprints: one line here, the assignment itself is a separate dialog (keeps this menu short)
  content.add{type = "line"}
  content.add{type = "label", caption = "Zone blueprints", style = "caption_label"}
  local bp_row = content.add{type = "flow", direction = "horizontal"}
  bp_row.style.vertical_align = "center"
  bp_row.add{
    type = "button", caption = "Assign blueprints...", tags = {ec_kind = "bps_open"},
    tooltip = "Give a building zone (science factory, belt factory...) a blueprint, pasted as a string or taken from your cursor. The Engineer then builds that instead of its own layout.",
  }
  bp_row.add{type = "label", name = "ec_bps_summary", caption = bpslots.summary(player.index)}

  -- Building zones (created by the Engineer; erase them here)
  content.add{type = "line"}
  content.add{type = "label", caption = "Building zones", style = "caption_label"}
  local zpanel = content.add{type = "flow", name = "ec_zone_panel", direction = "vertical"}
  fill_zone_panel(player, zpanel)

  player.opened = frame
end

local function toggle_menu(player)
  if player.gui.screen[FRAME] then close_menu(player) else open_menu(player) end
end

---------------------------------------------------------------------
-- Zone blueprints dialog (opened from the main menu)
---------------------------------------------------------------------

local function close_bps(player)
  local frame = player.gui.screen[BPS_FRAME]
  if frame then frame.destroy() end
end

-- One row per zone: name + Set/Clear, then one grey line saying what it will use / what state it is in.
local function fill_bps_list(player, list)
  list.clear()
  for _, slot in ipairs(bpslots.SLOTS) do
    local box = list.add{type = "flow", direction = "vertical"}
    local row = box.add{type = "flow", direction = "horizontal"}
    row.style.vertical_align = "center"
    row.add{type = "label", caption = slot.caption, style = "bold_label"}
    local filler = row.add{type = "empty-widget"}
    filler.style.horizontally_stretchable = true
    row.add{type = "button", caption = "Set...", tags = {ec_kind = "bps_set", ec_slot = slot.id}}
    row.add{
      type = "button", caption = "Clear", enabled = bpslots.get(player.index, slot.id) ~= nil,
      tags = {ec_kind = "bps_clear", ec_slot = slot.id},
    }
    local status = box.add{type = "label", caption = bpslots.status_text(player, slot)}
    status.style.single_line = false
    status.style.maximal_width = 440
    status.style.font_color = {r = 0.7, g = 0.7, b = 0.7}
  end
end

local function open_bps(player)
  close_menu(player)
  close_bps(player)
  local frame = player.gui.screen.add{type = "frame", name = BPS_FRAME, direction = "vertical"}
  frame.auto_center = true

  local titlebar = frame.add{type = "flow", direction = "horizontal"}
  titlebar.drag_target = frame
  titlebar.add{type = "label", caption = "Zone blueprints", style = "frame_title", ignored_by_interaction = true}
  local filler = titlebar.add{type = "empty-widget", style = "draggable_space_header", ignored_by_interaction = true}
  filler.style.horizontally_stretchable = true
  filler.style.height = 24
  titlebar.add{type = "sprite-button", name = "ec_bps_close", style = "frame_action_button", sprite = "utility/close"}

  local content = frame.add{type = "frame", name = "content", style = "inside_shallow_frame_with_padding", direction = "vertical"}
  local intro = content.add{
    type = "label",
    caption = "The Engineer builds a zone from its blueprint instead of its own layout, the next time it plans that zone. A zone that is already placed keeps what it has: erase it in the main menu to rebuild it from a new blueprint. Raw ingredients that no machine of the blueprint makes are put into the machines by hand.",
  }
  intro.style.single_line = false
  intro.style.maximal_width = 460
  content.add{type = "line"}
  local list = content.add{type = "flow", name = "ec_bps_list", direction = "vertical"}
  list.style.vertical_spacing = 8
  fill_bps_list(player, list)
  content.add{type = "line"}

  local imp = content.add{type = "flow", name = "ec_bps_import", direction = "vertical"}
  imp.visible = false
  imp.add{type = "label", name = "ec_bps_target", caption = "", style = "caption_label"}
  local box = imp.add{type = "text-box", name = "ec_bps_text", word_wrap = true}
  box.style.width = 460
  box.style.height = 90
  local buttons = imp.add{type = "flow", direction = "horizontal"}
  buttons.add{type = "button", caption = "Import pasted string", style = "confirm_button", tags = {ec_kind = "bps_import"},
    tooltip = "Paste the blueprint (or blueprint book) string into the box above first."}
  buttons.add{type = "button", caption = "Use blueprint in cursor", tags = {ec_kind = "bps_cursor"},
    tooltip = "Pick up a blueprint (or a book with the right one active), then press this."}
  buttons.add{type = "button", caption = "Cancel", tags = {ec_kind = "bps_cancel"}}

  local msg = content.add{type = "label", name = "ec_bps_msg", caption = ""}
  msg.style.single_line = false
  msg.style.maximal_width = 460

  player.opened = frame
end

local function handle_bps_click(player, el)
  local kind = el.tags.ec_kind
  if kind == "bps_open" then
    open_bps(player)
    return
  end
  local frame = player.gui.screen[BPS_FRAME]
  local content = frame and frame.content
  if not content then return end
  local imp, list, msg = content.ec_bps_import, content.ec_bps_list, content.ec_bps_msg

  if kind == "bps_set" then
    local slot = bpslots.slot(el.tags.ec_slot)
    if not slot then return end
    imp.tags = {slot = slot.id}
    imp.ec_bps_target.caption = "Blueprint for: " .. slot.caption
    imp.ec_bps_text.text = ""
    imp.visible = true
    msg.caption = ""
    pcall(function() imp.ec_bps_text.focus() end)
  elseif kind == "bps_clear" then
    bpslots.clear(player.index, el.tags.ec_slot)
    msg.caption = "Cleared. The Engineer uses its own layout for that zone again (if it has one)."
    fill_bps_list(player, list)
  elseif kind == "bps_cancel" then
    imp.visible = false
  elseif kind == "bps_import" or kind == "bps_cursor" then
    local slot_id = imp.tags and imp.tags.slot
    if not slot_id then return end
    local ok, text
    if kind == "bps_import" then
      ok, text = bpslots.set_from_string(player, slot_id, imp.ec_bps_text.text)
    else
      ok, text = bpslots.set_from_cursor(player, slot_id)
    end
    msg.caption = text
    if ok then
      imp.visible = false
      imp.ec_bps_text.text = ""
      player.print("Engineer: " .. text)
      fill_bps_list(player, list)
    end
  end
end

local function ensure_top_button(player)
  if not player.gui.top[TOP_BUTTON] then
    player.gui.top.add{type = "button", name = TOP_BUTTON, caption = "Engineer", tooltip = "Open the Engineer menu"}
  end
end

local function toggle_companion(player)
  if has_companion(player.index) then
    dismiss_companion(player.index)
    player.print("Engineer dismissed.")
  else
    spawn_companion(player)
    player.print("Engineer summoned.")
  end
end

local function handle_action_click(player, id, kind)
  if kind == "bp_assign" then
    local bp, err = blueprints.assign_from_cursor(player, id)
    if bp then
      player.print(string.format("Engineer: blueprint '%s' (%dx%d) assigned to '%s'.",
        bp.label, bp.w, bp.h, actions.get(id).caption))
    else
      player.print("Engineer: " .. err)
    end
    refresh_action_gui(player, id)
  elseif kind == "bp_clear" then
    blueprints.clear(player.index, id)
    refresh_action_gui(player, id)
  elseif kind == "run" then
    actions.start(player, id)
    sync_mode_radios(player)
  end
end

script.on_event(defines.events.on_gui_click, function(e)
  local el = e.element
  if not (el and el.valid) then return end
  local player = game.get_player(e.player_index)
  if not player then return end

  local tags = el.tags
  if tags and tags.ec_interact then
    if interaction.handle_click(player, el) == "menu" then open_menu(player) end
    return
  end
  if tags and tags.ec_kind then
    if tags.ec_kind == "zone_erase" or tags.ec_kind == "zone_erase_all" then
      handle_zone_click(player, el)
    elseif type(tags.ec_kind) == "string" and tags.ec_kind:sub(1, 4) == "bps_" then
      handle_bps_click(player, el)
    else
      handle_action_click(player, tags.ec_action, tags.ec_kind)
    end
    return
  end

  if el.name == TOP_BUTTON then
    toggle_menu(player)
  elseif el.name == "ec_close" then
    close_menu(player)
  elseif el.name == "ec_bps_close" then
    close_bps(player)
    open_menu(player)
  elseif el.name == "ec_talk" then
    interaction.open(player)
  elseif el.name == "ec_call" then
    local data = storage.companions[player.index]
    if data and data.entity.valid and player.character then
      common.teleport_beside(data.entity, player.character.position, player.character.surface)
      data.task, data.roam, data.nav = nil, nil, nil
      data.entity.walking_state = {walking = false}
    end
  elseif el.name == "ec_summon" then
    toggle_companion(player)
    el.caption = has_companion(player.index) and "Dismiss" or "Summon"
  elseif el.name == "ec_ore_scan" then
    local dd = el.parent.ec_ore_dd
    local ore = dd and dd.tags.ores and dd.tags.ores[dd.selected_index]
    if ore then
      storage.assigned_ore[player.index] = ore
      prospecting.start(player, ore)
    end
  end
end)

script.on_event(defines.events.on_gui_selection_state_changed, function(e)
  local el = e.element
  if not (el and el.valid) then return end
  if el.name == "ec_ore_dd" then
    local ore = el.tags.ores and el.tags.ores[el.selected_index]
    if ore then storage.assigned_ore[e.player_index] = ore end
  elseif el.name == "ec_action_dd" then
    local id = el.tags.ids and el.tags.ids[el.selected_index]
    if id then
      storage.selected_action[e.player_index] = id
      local player = game.get_player(e.player_index)
      local panel = el.parent and el.parent.ec_action_panel
      if player and panel then fill_action_panel(player, panel) end
    end
  end
end)

script.on_event(defines.events.on_gui_checked_state_changed, function(e)
  local el = e.element
  if el and el.valid and el.tags and el.tags.ec_defend then
    local player = game.get_player(e.player_index)
    if player then defense.set_enabled(player, el.state) end
    return
  end
  if not (el and el.valid and el.tags and el.tags.ec_mode) then return end
  storage.modes[e.player_index] = el.tags.ec_mode
  local data = storage.companions[e.player_index]
  if data then
    data.task, data.roam = nil, nil
    if el.tags.ec_mode ~= "auto_build" then data.action = nil end
  end
  for _, sibling in pairs(el.parent.children) do
    if sibling.type == "radiobutton" then sibling.state = (sibling.name == el.name) end
  end
end)

script.on_event(defines.events.on_gui_closed, function(e)
  if not (e.element and e.element.valid) then return end
  if e.element.name == interaction.FRAME then
    local player = game.get_player(e.player_index)
    if player then interaction.close(player) else e.element.destroy() end
  elseif e.element.name == FRAME then
    e.element.destroy()
  elseif e.element.name == BPS_FRAME then -- Esc: back to the main menu
    e.element.destroy()
    local player = game.get_player(e.player_index)
    if player then open_menu(player) end
  end
end)

script.on_event("ec-toggle-menu", function(e)
  local player = game.get_player(e.player_index)
  if player then toggle_menu(player) end
end)

script.on_event("ec-interact", function(e)
  local player = game.get_player(e.player_index)
  if player then interaction.open(player) end
end)

-- "open GUI" (E) with the mouse over the Engineer
script.on_event("ec-interact-click", function(e)
  local player = game.get_player(e.player_index)
  if not player then return end
  local sel = player.selected
  if sel and sel.valid and sel.name == ENTITY_NAME then interaction.open(player) return end
  -- The Engineer is not selectable (so it never gets in the way of your aim): is the cursor on it?
  local data = storage.companions[e.player_index]
  local pos = e.cursor_position
  if data and data.entity.valid and pos then
    local p = data.entity.position
    if common.dist2(pos, {x = p.x, y = p.y - 1}) <= 1.5 * 1.5 then interaction.open(player) end
  end
end)

script.on_event(defines.events.on_research_finished, function(e)
  local tech = e.research
  if tech and tech.force then
    local l = dialogues.pick("research_finished", {tech = tech.name})
    if l then
      interaction.notify(tech.force, l.animation or "happy", l.text, l.seconds or 20)
      for _, p in pairs(tech.force.players) do interaction.play_sound(p, l.sound or "research_finished") end
    end
  end
end)

script.on_event(defines.events.on_script_path_request_finished, pathing.on_path_finished)

-- Requests window (scripts/requests.lua): item picked / min or max typed
script.on_event(defines.events.on_gui_elem_changed, function(e) requests.on_elem_changed(e) end)
script.on_event(defines.events.on_gui_text_changed, function(e) requests.on_text_changed(e) end)

script.on_nth_tick(3, function()
  for _, player in pairs(game.connected_players) do interaction.tick(player) end
end)

script.on_nth_tick(15, function()
  for _, player in pairs(game.connected_players) do
    local frame = player.gui.screen[FRAME]
    if frame and frame.content then
      if frame.content.ec_status then
        frame.content.ec_status.caption = status_text(player.index)
      end
      if frame.content.ec_ore_result then
        frame.content.ec_ore_result.caption = prospecting.result_text(player.index)
      end
      refresh_zone_panel(player)
    end
  end
end)

---------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------

local function setup_player(player)
  ensure_top_button(player)
  if not has_companion(player.index) then spawn_companion(player) end
end

script.on_init(function()
  init_storage()
  for _, player in pairs(game.players) do setup_player(player) end
end)

script.on_configuration_changed(function()
  init_storage()
  for idx, old in pairs(storage.companions) do
    if type(old) == "userdata" then -- v0.1 saves
      if old.valid then old.destroy() end
      storage.companions[idx] = nil
      storage.modes[idx] = "follow_build"
    else
      old.pending = old.pending or {}
      old.craft_queue = old.craft_queue or {}
      if old.task and not old.task.type then old.task = nil end -- pre-0.5 tasks used `phase`
    end
  end
  for _, player in pairs(game.players) do setup_player(player) end
end)

script.on_event(defines.events.on_player_created, function(e)
  init_storage()
  local player = game.get_player(e.player_index)
  if player then setup_player(player) end
end)

script.on_event(defines.events.on_player_removed, function(e)
  dismiss_companion(e.player_index)
  storage.modes[e.player_index] = nil
  storage.assigned_ore[e.player_index] = nil
  storage.selected_action[e.player_index] = nil
  defense.remove_player(e.player_index)
  zones.remove_all(e.player_index)
  bpslots.remove_player(e.player_index)
  interaction.remove_player(e.player_index)
  progress.remove(e.player_index)
end)

commands.add_command("engineer-connections",
  "Prints the fluidbox connection points of the offshore pump, boiler and steam engine (for tuning scripts/layout_config.lua).",
  function(cmd)
    local player = game.get_player(cmd.player_index)
    if not player then return end
    player.print(string.format("[Engineer] fluidbox position delta in use: %.1f", geometry.position_delta()))
    for _, name in ipairs({"offshore-pump", "boiler", "steam-engine"}) do
      for _, line in ipairs(geometry.describe(name)) do
        player.print("[Engineer] " .. line)
        log("[engineer-companion] " .. line)
      end
    end
  end)

commands.add_command("engineer", "Summon or dismiss your Engineer companion.", function(cmd)
  local player = game.get_player(cmd.player_index)
  if player then toggle_companion(player) end
end)
