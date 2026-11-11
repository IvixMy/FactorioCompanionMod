-- Interaction with the Companion: a window with a PORTRAIT that plays an animation, like the talking-head screens of
-- old games (Fallout 1...).
--
-- Opened with SHIFT+F, with E while the mouse is over the Companion (linked to the "open GUI" control), or with the
-- "Talk" button of the main menu. The Companion has to be near you.
--
-- The frame of the system:
--
--   ANIMATIONS  scripts/portrait_animations.lua: sprite sheets (data-final-fixes.lua turns every frame into a sprite
--               prototype, this file swaps the sprite of the window every few ticks). Packs of other mods and the
--               folder custom/ add / replace animations (custom/README.md).
--   DIALOGUES   scripts/dialogues.lua: the lines it says, per situation; packs and custom/dialogues.lua change them.
--   STATES      what the portrait shows is decided by registered STATES, highest priority first:
--                 interaction.register_state(id, priority, function(ctx) return {animation = "working",
--                                                                               line = "Mining stone."} end)
--               ctx = {player, data (the companion), force}. Return nil when the state does not apply.
--               Built in: event, blocked, working, waiting, research, following, idle.
--   EVENTS      interaction.notify(force, animation, line, seconds): something happened (research finished...):
--               the portrait shows it for a while, whether the window is open or opened later.
--   LINES       the log of the window; say(player, line, animation, seconds) adds a line and makes the
--               Companion talk for a moment.
--
-- GUI events are routed here by control.lua (clicks with tags.ec_interact, closing, the animation tick).

local names = require("scripts.names")
local common    = require("scripts.common")
local portraits = require("scripts.portrait_animations")
local dialogues = require("scripts.dialogues")
local crafting  = require("scripts.crafting")
local inventory_view = require("scripts.inventory_view")
local requests  = require("scripts.requests")

local function try_require(name)
  local ok, result = pcall(require, name)
  if ok then return result end
  return nil
end
local custom_states = try_require("custom.states") -- loaded now: require() is not allowed at runtime
-- sound/sounds.lua (written by build_custom.py): {group = {files}}; each group is the prototype "ec-sound-<group>"
local sound_groups = try_require("sound.sounds")
if type(sound_groups) ~= "table" then sound_groups = {} end

local M = {}

M.FRAME = "ec_interact_frame"
local REACH = 12
local MAX_LOG = 40
local NOISE_TICKS    = 30   -- how long the static plays when the animation changes (0.5 s)
local NOISE_COOLDOWN = 90   -- ticks between two statics: an animation that flickers does not strobe

---------------------------------------------------------------------
-- Storage
---------------------------------------------------------------------

function M.init()
  storage.interact = storage.interact or {}        -- [player_index] = window session
  storage.interact_events = storage.interact_events or {} -- [force.index] = {animation, line, tick_until}
end

local function session(player_index) return storage.interact and storage.interact[player_index] end

---------------------------------------------------------------------
-- States
---------------------------------------------------------------------

local states = {}

function M.register_state(id, priority, fn)
  for i, s in ipairs(states) do
    if s.id == id then table.remove(states, i) break end
  end
  states[#states + 1] = {id = id, priority = priority, fn = fn}
  table.sort(states, function(a, b) return a.priority > b.priority end)
end

-- Something happened: show `animation` / `line` for `seconds`.
function M.notify(force, animation, line, seconds)
  M.init()
  storage.interact_events[force.index] = {
    animation = animation, line = line, tick_until = game.tick + 60 * (seconds or 10),
  }
end

local function mode_of(player_index) return storage.modes and storage.modes[player_index] or "follow" end

M.register_state("event", 100, function(ctx)
  local ev = storage.interact_events and storage.interact_events[ctx.force.index]
  if ev and game.tick < ev.tick_until then return {animation = ev.animation, line = ev.line} end
  return nil
end)

M.register_state("blocked", 80, function(ctx)
  local status = ctx.data.status or ""
  local lower = status:lower()
  if lower:find("could not") or lower:find("blocked") or lower:find("cannot") or lower:find("can't") then
    return {animation = "worried", line = dialogues.text("status_blocked", {status = status})}
  end
  return nil
end)

M.register_state("working", 60, function(ctx)
  local data = ctx.data
  local crafting_text = crafting.status(data)
  if data.task or crafting_text then
    local line = data.status or "Busy."
    if crafting_text then line = line .. " (crafting: " .. crafting_text .. ")" end
    return {animation = "working", line = dialogues.text("status_working", {status = line})}
  end
  return nil
end)

M.register_state("waiting", 50, function(ctx)
  if mode_of(ctx.player.index) == "wait" then
    return {animation = "tired", line = dialogues.text("mode_wait")}
  end
  return nil
end)

M.register_state("research", 40, function(ctx)
  local tech = ctx.force.current_research
  if tech then
    local pct = math.floor((ctx.force.research_progress or 0) * 100)
    return {animation = "thinking", line = dialogues.text("status_research", {tech = tech.name, pct = pct})}
  end
  return nil
end)

M.register_state("following", 20, function(ctx)
  local mode = mode_of(ctx.player.index)
  if mode == "follow" or mode == "follow_build" then
    return {animation = "idle", line = dialogues.text("status_idle", {status = ctx.data.status or "Right behind you."})}
  end
  return nil
end)

M.register_state("idle", 0, function(ctx)
  return {animation = "idle", line = dialogues.text("status_idle", {status = ctx.data.status or "Ready."})}
end)

-- custom/states.lua: `return function(interaction) interaction.register_state(...) end`
if type(custom_states) == "function" then custom_states(M) end

-- {animation, line} of the first state that applies
function M.evaluate(player, data)
  local ctx = {player = player, data = data, force = player.force}
  for _, s in ipairs(states) do
    local ok, result = pcall(s.fn, ctx)
    if ok and result and result.animation then
      result.animation = portraits.resolve(result.animation) -- aliases of the character's pack
      result.id = s.id
      return result
    end
  end
  return {animation = "idle", line = ""}
end

---------------------------------------------------------------------
-- The window
---------------------------------------------------------------------

local SIZE_STEP = 10
local MIN_SIZE, MAX_SIZE = 30, 100
local LOG_WIDTH = 380

local function companion_near(player)
  local data = storage.companions and storage.companions[player.index]
  if not (data and data.entity and data.entity.valid and player.character) then
    return nil, dialogues.text("not_summoned")
  end
  if data.entity.surface.index ~= player.character.surface.index
    or common.dist2(data.entity.position, player.character.position) > REACH * REACH then
    return nil, dialogues.text("too_far")
  end
  return data
end

-- Portrait height in pixels: a percentage of the screen height (setting ec-portrait-size, changed with the - / +
-- buttons of the window).
local function portrait_percent(player)
  local chosen = storage.interact_size and storage.interact_size[player.index]
  if chosen then return chosen end
  local setting = settings.get_player_settings(player)["ec-portrait-size"]
  return setting and setting.value or 75
end

local function portrait_height(player)
  local res = player.display_resolution
  local scale = player.display_scale or 1
  local screen_h = (res and res.height or 1080) / scale
  return math.max(200, math.floor(screen_h * portrait_percent(player) / 100 - 90))
end

-- Size of the portrait for the animation that is playing (the frame's own aspect ratio).
local function portrait_size(player, anim)
  local h = portrait_height(player)
  local fw, fh = portraits.frame_size(anim)
  return math.floor(h * fw / fh), h
end

local function window_parts(player)
  local frame = player.gui.screen[M.FRAME]
  if not frame then return nil end
  local body = frame.ec_interact_body
  return frame, body.ec_interact_left, body.ec_interact_right
end

local function apply_size(player, anim)
  local frame, left, right = window_parts(player)
  if not frame then return end
  local w, h = portrait_size(player, anim)
  local sprite = left.ec_interact_screen.ec_interact_portrait
  sprite.style.width, sprite.style.height = w, h
  left.ec_interact_caption.style.width = w
  right.ec_interact_log.style.height = math.max(120, h - 110)
end

local function set_sprite(player, s)
  local frame, left = window_parts(player)
  if not frame then return end
  local anim = portraits.get().animations[s.animation]
  if not anim then return end
  local name = portraits.sprite_name(s.animation, s.frame)
  if helpers.is_valid_sprite_path(name) then -- a pack may have been removed since the save was made
    left.ec_interact_screen.ec_interact_portrait.sprite = name
  end
  left.ec_interact_caption.caption = anim.caption or s.animation
  if s.sized ~= s.animation then -- another animation may have another frame size
    s.sized = s.animation
    apply_size(player, anim)
  end
end

local function add_line(player, text)
  local frame, _, right = window_parts(player)
  local s = session(player.index)
  if not (frame and s and text and text ~= "") then return end
  local pane = right.ec_interact_log
  local label = pane.add{type = "label", caption = text}
  label.style.single_line = false
  label.style.maximal_width = LOG_WIDTH - 20
  while #pane.children > MAX_LOG do pane.children[1].destroy() end
  pane.scroll_to_bottom()
end

-- The Companion says something: a line in the log + the "talk" animation (or the line's own) for a moment.
function M.say(player, line, seconds, animation)
  local s = session(player.index)
  if not s then return end
  add_line(player, {"", names.prefix(), line})
  s.talk_until = game.tick + 60 * (seconds or 2)
  s.talk_animation = animation or "talk"
end

-- Plays the sound group `group` (a folder of sound/) for a player; does nothing when there is no such group.
function M.play_sound(player, group)
  if not (group and sound_groups[group] and player and player.valid) then return false end
  player.play_sound{path = "ec-sound-" .. group}
  return true
end

-- The static of the "noise" animation (custom/noise/, or whatever the alias "noise" points at); nil when there is none.
local function noise_name()
  local reg = portraits.get()
  local name = reg.aliases.noise or "noise"
  return reg.animations[name] and name or nil
end

-- The Engineer's animation changes (idle -> talk -> working -> thinking -> happy ...) or its state does: a short
-- burst of static (the noise animation, shown by M.tick) and a sound (sound group state_<id>, else state_change).
-- At most one every NOISE_COOLDOWN ticks. Returns true when it started.
local function start_noise(player, s, state_id)
  if game.tick < (s.noise_ready or 0) then return false end
  s.noise_ready = game.tick + NOISE_COOLDOWN
  if noise_name() then s.noise_until = game.tick + NOISE_TICKS end
  if not M.play_sound(player, "state_" .. tostring(state_id)) then M.play_sound(player, "state_change") end
  return true
end

-- The state changed (idle -> working, working -> blocked...), even when both show the same animation.
local function state_changed(player, s, state_id)
  if s.last_state == nil then s.last_state = state_id return end -- first look: nothing changed yet
  if state_id == s.last_state then return end
  s.last_state = state_id
  start_noise(player, s, state_id)
end

-- Says a line of a SITUATION of scripts/dialogues.lua (random one; it may bring its own animation).
function M.say_situation(player, situation, vars, seconds)
  local l = dialogues.pick(situation, vars)
  if not l then return end
  M.say(player, l.text, l.seconds or seconds, l.animation)
  M.play_sound(player, l.sound or situation) -- the line's own sound, else the group named like the situation
end

function M.is_open(player) return player.gui.screen[M.FRAME] ~= nil end

function M.close(player)
  local frame = player.gui.screen[M.FRAME]
  if frame then frame.destroy() end
  inventory_view.close(player)
  requests.close(player)
  if storage.interact then storage.interact[player.index] = nil end
end

function M.open(player)
  M.init()
  if M.is_open(player) then return end
  local data, err = companion_near(player)
  if not data then
    player.print(err)
    return
  end

  local reg = portraits.get()
  local first = reg.animations[portraits.resolve("talk")]

  local frame = player.gui.screen.add{type = "frame", name = M.FRAME, direction = "vertical"}
  frame.auto_center = true

  local bar = frame.add{type = "flow", name = "ec_interact_bar", direction = "horizontal"}
  bar.drag_target = frame
  local title = bar.add{type = "label", caption = names.get(), style = "frame_title"}
  title.drag_target = frame
  local filler = bar.add{type = "empty-widget", style = "draggable_space_header"}
  filler.style.horizontally_stretchable = true
  filler.style.height = 24
  filler.style.right_margin = 4
  filler.drag_target = frame
  bar.add{type = "button", caption = "-", style = "frame_action_button", tooltip = "Smaller portrait", tags = {ec_interact = "smaller"}}
  bar.add{type = "button", caption = "+", style = "frame_action_button", tooltip = "Bigger portrait", tags = {ec_interact = "bigger"}}
  bar.add{
    type = "sprite-button", style = "frame_action_button", sprite = "utility/close",
    tooltip = {"gui.close-instruction"}, tags = {ec_interact = "close"},
  }

  local body = frame.add{type = "flow", name = "ec_interact_body", direction = "horizontal"}
  body.style.horizontal_spacing = 12

  -- the character: a big screen like the talking-head windows of old games
  local left = body.add{type = "flow", name = "ec_interact_left", direction = "vertical"}
  local screen = left.add{type = "frame", name = "ec_interact_screen", style = "inside_deep_frame"}
  screen.add{type = "sprite", name = "ec_interact_portrait", sprite = portraits.sprite_name(portraits.resolve("talk"), 1)}
  screen.ec_interact_portrait.style.stretch_image_to_widget_size = true
  local caption = left.add{type = "label", name = "ec_interact_caption", caption = first and first.caption or "", style = "caption_label"}
  caption.style.horizontal_align = "center"

  local right = body.add{type = "flow", name = "ec_interact_right", direction = "vertical"}
  right.style.width = LOG_WIDTH
  local pane = right.add{type = "scroll-pane", name = "ec_interact_log", style = "naked_scroll_pane"}
  pane.style.width = LOG_WIDTH
  pane.style.vertically_stretchable = false
  local status = right.add{type = "label", name = "ec_interact_status", style = "bold_label"}
  status.style.single_line = false
  status.style.maximal_width = LOG_WIDTH
  local buttons = right.add{type = "flow", direction = "horizontal"}
  buttons.add{type = "button", caption = "Status", tooltip = "Ask what it is doing.", tags = {ec_interact = "status"}}
  buttons.add{type = "button", caption = "Follow me", tags = {ec_interact = "mode", mode = "follow"}}
  buttons.add{type = "button", caption = "Wait here", tags = {ec_interact = "mode", mode = "wait"}}
  buttons.add{type = "button", caption = "Base development", tags = {ec_interact = "mode", mode = "auto_build"}}
  local more = right.add{type = "flow", direction = "horizontal"}
  more.add{type = "button", caption = "Inventory", tooltip = "Show exactly what it is carrying.", tags = {ec_interact = "inventory"}}
  more.add{type = "button", caption = "Requests", tooltip = "Choose which items it keeps on itself (min / max, like your logistic requests).", tags = {ec_interact = "requests"}}
  more.add{type = "button", caption = "Open " .. names.get() .. " menu", tags = {ec_interact = "menu"}}

  player.opened = frame

  storage.interact[player.index] = {
    animation = "", frame = 1, next_tick = game.tick, talk_until = game.tick + 90, talk_animation = "talk",
  }
  M.say_situation(player, "greeting", nil, 2)
  apply_size(player, first or reg.animations.idle)
  M.refresh(player)
end

-- Status line under the log.
function M.refresh(player)
  local frame, _, right = window_parts(player)
  local s = session(player.index)
  local data = storage.companions and storage.companions[player.index]
  if not (frame and s and data and data.entity and data.entity.valid) then return end
  local st = M.evaluate(player, data)
  if st.line ~= s.last_status then
    s.last_status = st.line
    right.ec_interact_status.caption = st.line or ""
  end
  return st
end

-- Every few ticks (control.lua): advance the animation of an open window.
function M.tick(player)
  local frame = player.gui.screen[M.FRAME]
  local s = session(player.index)
  if not (frame and s) then return end
  local data = storage.companions and storage.companions[player.index]
  if not (data and data.entity and data.entity.valid) then M.close(player) return end

  local st = M.refresh(player)
  if st and st.id then state_changed(player, s, st.id) end
  inventory_view.refresh(player)
  requests.refresh(player)
  local target
  if game.tick < s.talk_until then
    target = portraits.resolve(s.talk_animation or "talk")
  else
    target = portraits.resolve((st and st.animation) or "idle")
  end

  -- static between two animations: while it plays the target is only remembered (s.shown), shown when it is over
  local want = target
  local noise = noise_name()
  if noise and s.noise_until and game.tick < s.noise_until then
    want = noise
    s.shown = target
  else
    s.noise_until = nil
    if s.shown ~= nil and target ~= s.shown then start_noise(player, s, st and st.id or "change") end
    s.shown = target
    if noise and s.noise_until then want = noise end
  end
  local anim = portraits.get().animations[want]
  if not anim then return end

  if want ~= s.animation then
    s.animation, s.frame, s.next_tick = want, 1, game.tick + anim.ticks
    if want == noise and anim.frames > 1 then s.frame = (game.tick * 7) % anim.frames + 1 end -- another bit of static each time
    set_sprite(player, s)
  elseif game.tick >= s.next_tick then
    if anim.loop == false then
      s.frame = math.min(anim.frames, s.frame + 1)
    else
      s.frame = s.frame % anim.frames + 1
    end
    s.next_tick = game.tick + anim.ticks
    set_sprite(player, s)
  end
end

---------------------------------------------------------------------
-- Clicks (control.lua passes every click on an element with tags.ec_interact)
---------------------------------------------------------------------

local function resize(player, delta)
  storage.interact_size = storage.interact_size or {}
  local size = math.max(MIN_SIZE, math.min(MAX_SIZE, portrait_percent(player) + delta))
  storage.interact_size[player.index] = size
  local s = session(player.index)
  local anim = s and portraits.get().animations[s.animation]
  if anim then apply_size(player, anim) end
end

-- returns "menu" when the main menu should be opened
function M.handle_click(player, el)
  local kind = el.tags.ec_interact
  local data = storage.companions and storage.companions[player.index]
  if kind == "close" then
    M.close(player)
  elseif kind == "bigger" then
    resize(player, SIZE_STEP)
  elseif kind == "smaller" then
    resize(player, -SIZE_STEP)
  elseif kind == "status" then
    local st = data and data.entity.valid and M.evaluate(player, data)
    if st and st.line and st.line ~= "" then
      M.say(player, st.line, 2, st.animation)
    else
      M.say_situation(player, "nothing_special", nil, 2)
    end
  elseif kind == "mode" then
    storage.modes[player.index] = el.tags.mode
    if data then
      data.task, data.roam = nil, nil
      if el.tags.mode ~= "auto_build" then data.action = nil end
    end
    M.say_situation(player, "mode_" .. el.tags.mode, nil, 2)
  elseif kind == "inventory" then
    inventory_view.toggle(player)
  elseif kind == "inventory_close" then
    inventory_view.close(player)
  elseif kind == "requests" then
    requests.toggle(player)
  elseif kind == "req_clear" or kind == "req_close" or kind == "req_save" then
    requests.handle_click(player, el)
  elseif kind == "menu" then
    M.close(player)
    return "menu"
  end
  return nil
end

function M.remove_player(player_index)
  if storage.interact then storage.interact[player_index] = nil end
  if storage.inventory_view then storage.inventory_view[player_index] = nil end
end

return M
